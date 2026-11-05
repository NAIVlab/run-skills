"""rsk launch: argument parsing, the request replayed at submit time, reply parsing and its exit codes, the card,
plan validity (used / expired / superseded), decisions (chains, busy GPUs, denies) and the plan → approve → submit
flow against a fake remote (launch.call replaced: what the target would answer). The real deployed submit.sh /
launch.sh behind an executing ssh stub: tests/62-rsk-launch.sh."""

import contextlib
import hashlib
import io
import os
import subprocess
import time
import unittest
from pathlib import Path
from unittest import mock

from helpers import ScratchHome

from remote_run import cli, harness, observe
from remote_run import grants as G
from remote_run import launch as X
from remote_run import ledger as L
from remote_run.errors import CONFLICT, FAILED, NEEDS_USER, OK, PLACEMENT, REFUSED, UNKNOWN, USAGE, RskError


WID = (hashlib.sha256(b"").hexdigest(), hashlib.sha256(b"WARNING: only # free\n").hexdigest())   # warnings_id: none, one


def block(kind="slurm", target="fx", name="exp--train--a--scratch--s0--a01", warnings=0, payload="python t.py",
          **kw) -> str:
    if kind == "slurm":
        bound = [("kind", "slurm"), ("target", target), ("partition", kw.get("partition", "gpu")),
                 ("gres", kw.get("gres", "gpu:1")), ("cpus", "8"), ("mem", "40G"), ("time", "1-00:00:00"),
                 ("account", "''"), ("name", name), ("extra", kw.get("extra", "")), ("payload", payload),   # qw "$@": words
                 ("env_kind", "uv"), ("env_name", "''"), ("wandb_mode", "online"), ("env_hook", kw.get("hook", "''")),
                 ("venv_dir", "''"), ("uv_sync_args", "''"), ("conf_extra", kw.get("conf_extra", kw.get("extra", ""))),
                 ("flags", kw.get("flags", "")), ("chain", kw.get("chain", "0"))]
        info = [("info_avail", "free:4/max_node:4/gpu_type:any"), ("info_conf_sha256", "a" * 64),
                ("info_source_commit", "none"), ("info_source_dirty", "none"), ("info_prior", kw.get("prior", "0"))]
    else:
        bound = [("kind", "nohup"), ("target", target), ("name", name), ("gpus_req", kw.get("gpus_req", "n=1")),
                 ("exclude", ""), ("nice", ""), ("launch_cfg", kw.get("launch_cfg", "")),
                 ("busy_ok", kw.get("busy_ok", "")), ("payload", payload.replace(" ", "\\ ")),
                 ("env_kind", "none"), ("env_hook", "''"), ("venv_dir", "''"), ("uv_sync_args", "''"), ("env_name", "''")]
        info = [("info_gpus", kw.get("info_gpus", "1")), ("info_uuids", "GPU-x"), ("info_busy", kw.get("busy", "")),
                ("info_run_gpu", "checked"), ("info_prior", kw.get("prior", "0")), ("info_launchers", "checked")]
    info = [(k, v) for k, v in info if k not in kw.get("drop", ())]
    bound = [(k, v) for k, v in bound if k not in kw.get("drop", ())]
    lines = [f"{k}={v}" for k, v in bound]
    h = hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()
    env = [(k, v) for k, v in (("warnings_avail", kw.get("warnings_avail", warnings)),
                               ("warnings_id", kw.get("warnings_id", WID[int(warnings) > 0])))
           if k not in kw.get("drop", ())]
    return "\n".join(["@@plan v1", "api=3", *lines, *(f"{k}={v}" for k, v in info), *(f"{k}={v}" for k, v in env),
                      f"warnings={warnings}", f"bound_hash={h}", "@@end"]) + "\n"


def run(*argv: str) -> tuple[int, str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        rc = cli.main(list(argv))
    return rc, buf.getvalue()


class Pure(unittest.TestCase):
    def test_parse_splits_at_the_first_double_dash(self):
        ns = X.parse(["-T", "fx", "-p", "gpu", "-g", "2", "--x-user-asked", "--chain", "3", "--", "python", "-g", "--y"])
        self.assertEqual((ns.target, ns.part, ns.gpus, ns.chain), ("fx", "gpu", "2", 3))
        self.assertEqual(ns.policy_flags, ["--x-user-asked"])
        self.assertEqual(ns.cmd, ["python", "-g", "--y"])

    def test_parse_refuses_what_is_not_a_policy_flag(self):
        for argv in (["-T", "fx", "--x", "value"], ["-T", "fx", "stray"], ["--chain", "two"]):
            with self.assertRaises(RskError) as c:
                X.parse(argv)
            self.assertEqual(c.exception.code, USAGE)

    def test_submit_words_add_y_only_after_warnings_and_chain_per_segment(self):
        rec = {"kind": "slurm", "bound_hash": "h" * 64, "warnings": 0, "chain": 0, "flags": ["-p", "gpu"],
               "payload": ["python", "t.py"], "block": {"warnings_id": WID[0]}}
        w = X.submit_words(rec, "n1")
        self.assertEqual(w[:6], ["--rs-attempt", "n1", "--rs-expect", "h" * 64, "--rs-warnings", WID[0]])
        self.assertNotIn("-y", w)
        self.assertEqual(w[-3:], ["--", "python", "t.py"])
        w = X.submit_words({**rec, "warnings": 2, "chain": 3, "block": {"warnings_id": WID[1]}}, "n2")
        self.assertEqual(w[4:6], ["--rs-warnings", WID[1]])                   # which warnings: the card's id
        self.assertIn("-y", w)
        self.assertIn("--rs-chain", w)
        self.assertLess(w.index("--rs-chain"), w.index("--"))

    def test_gpu_busy_ok_only_when_asked_and_the_card_listed_busy_gpus(self):
        rec = {"kind": "nohup", "bound_hash": "h" * 64, "flags": ["-d", "1", "-N", "r"], "payload": ["c"],
               "gpu_busy_ok": True, "warnings": 1, "block": {"info_busy": "1:u:42", "busy_ok": "1:GPU-x:u",
                                                             "info_gpus": "1", "warnings_id": WID[1]}}
        w = X.submit_words(rec, "n")
        self.assertIn("--gpu-busy-ok", w)
        self.assertEqual(w[w.index("-d"):w.index("-d") + 2], ["-d", "1"])        # pinned: the card's own landing
        self.assertEqual(w[4:6], ["--rs-warnings", WID[1]])                     # the card's warnings, recomputed there
        # the card's landing was free (a busy GPU elsewhere): never --gpu-busy-ok, whatever was asked
        self.assertNotIn("--gpu-busy-ok", X.submit_words({**rec, "block": {"info_busy": "2:u:42", "busy_ok": "",
                                                                           "info_gpus": "1", "warnings_id": WID[0]}}, "n"))
        self.assertNotIn("--gpu-busy-ok", X.submit_words({**rec, "block": {"info_busy": "", "busy_ok": "",
                                                                           "warnings_id": WID[0]}}, "n"))
        with self.assertRaises(RskError) as c:                                  # a plan from before warnings_id
            X.submit_words({**rec, "block": {"busy_ok": ""}}, "n")
        self.assertEqual(c.exception.code, CONFLICT)
        self.assertEqual(X._pinned(["-n", "2", "-x", "0", "-N", "r"], "1,3"), ["-d", "1,3", "-N", "r"])
        req = X.Request("ws", "nohup", ["-n", "2"], ["c"], gpu_busy_ok=True)
        self.assertIn("--gpu-busy-ok", X.plan_words(req, "n"))
        self.assertEqual(X.plan_words(req, "n")[:4], ["--rs-attempt", "n", "--rs-mode", "plan"])

    def test_parse_slurm_reads_markers_only_after_the_submit(self):
        done = subprocess.CompletedProcess([], 0, "@@api api=3\n@@k job=666\nattempt: x\n@@rc 0\n"
                                           "@@result stage=done rc=0 verdict=submitted at=1\n@@k job=123\n@@k name=a|b\n", "")
        r = X.parse_slurm(done)
        self.assertEqual((r.api, r.receipt, r.result["verdict"]), ("api=3", {"job": "123", "name": "a|b"}, "submitted"))
        self.assertEqual(r.shown(), ["attempt: x"])

    def test_plan_failures_map_to_exit_codes(self):
        s, w = harness.Place("fx", "slurm", "h", "/r", ".fx"), harness.Place("ws", "nohup", "h", "p", ".ws")
        cases = [(X.Reply(3, err="REFUSED: no"), s, REFUSED), (X.Reply(6, err="ERROR: live"), s, CONFLICT),
                 (X.Reply(2, err="ERROR: usage"), s, USAGE), (X.Reply(None, why="timeout"), s, UNKNOWN),
                 (X.Reply(255), s, UNKNOWN), (X.Reply(65, api="api=2"), s, CONFLICT),
                 (X.Reply(2, err="ERROR: unknown arg '--rs-mode' (usage"), w, CONFLICT),
                 (X.Reply(2, err="ERROR: no .ws/launch.sh in the remote dir: the deploy predates it"), w, CONFLICT),
                 (X.Reply(1, err="ERROR: asked -n 3 but only 1 GPU id(s) free"), w, PLACEMENT),
                 (X.Reply(1, err="ERROR: uv venv not active"), w, FAILED)]
        for reply, place, code in cases:
            with contextlib.redirect_stdout(io.StringIO()) as buf:
                e = X.plan_failure(reply, place)
            self.assertEqual(e.code, code, (reply, str(e)))
            if code == CONFLICT and reply.rc != 6:
                self.assertIn("needs: sync (the deploy predates rsk launch: rsk sync -T", buf.getvalue())
        e = X.plan_failure(X.Reply(6, err="ERROR: -d GPU(s) 1 already run a compute process (1:u:2)"), w)
        self.assertIn("--gpu-busy-ok", str(e))

    def test_busy_landing(self):
        rec = {"kind": "nohup", "gpu_busy_ok": True, "block": {"info_gpus": "1,3", "info_busy": "1:u:42,2:v:7"}}
        self.assertIn("GPU(s) 1 ", X.busy_landing(rec))
        self.assertEqual(X.busy_landing({**rec, "block": {"info_gpus": "0", "info_busy": "1:u:42"}}), "")
        self.assertIn("unknown", X.busy_landing({**rec, "block": {"info_gpus": "0", "info_busy": "unknown"}}))
        self.assertEqual(X.busy_landing({**rec, "gpu_busy_ok": False}), "")

    def test_relaunch_rebuilds_the_flags_from_the_bound_fields(self):
        b = G.parse_plan(block(gres="gpu:a100:2", payload="python t.py --lr 1e-3", chain="1"))
        flags, pay, chain = X._from_bound("slurm", G.bound(b), "r--a02")
        self.assertEqual(flags, ["-p", "gpu", "-g", "2", "-G", "a100", "-c", "8", "-m", "40G", "-t", "1-00:00:00",
                                 "-n", "r--a02"])
        self.assertEqual((pay, chain), (["python", "t.py", "--lr", "1e-3"], 1))
        nb = G.parse_plan(block("nohup", gpus_req="ids=0,2", payload="python t.py"))
        flags, pay, _ = X._from_bound("nohup", G.bound(nb), "r--a02")
        self.assertEqual((flags, pay), (["-d", "0,2", "-N", "r--a02"], ["python t.py"]))

    def test_the_card_decodes_every_bound_field(self):
        b = G.parse_plan(block(payload="python t.py --x 1"))
        rec = {"id": "p-1", "created_at": L.now(), "target": "fx", "kind": "slurm", "action": "launch", "run": "r",
               "class": "train", "relaunch_of": "", "chain": 2, "block": b, "bound_hash": b["bound_hash"],
               "warnings": 1, "lines": ["WARNING: only 0 free"], "references": ["/x/reference.md"],
               "local": {"commit": "abc", "dirty": "0"}}
        card = X.render_card(rec)
        for want in ("plan p-1 — launch on fx (slurm)", "  payload    python t.py --x 1", "  account    -",
                     "  segments   2", "    WARNING: only 0 free", "  reference  /x/reference.md",
                     "DIFFERENT code than this checkout's HEAD", f"  bound_hash {b['bound_hash']}"):
            self.assertIn(want, card)


class Fixture(ScratchHome):
    """Fixture targets (fx: slurm, ws: nohup), a project, its ledger, and a fake remote answering every call."""

    def setUp(self) -> None:
        super().setUp()
        for name, prof in (("fx", "T_KIND=slurm; T_HOST=fxhost\n"), ("ws", "T_KIND=nohup; T_HOST=wshost\n")):
            d = Path(os.environ["RS_USER_DIR"]) / "targets" / name
            d.mkdir(parents=True)
            (d / "profile.sh").write_text(prof)
        self.proj = self.home / "proj"
        self.proj.mkdir()
        (self.proj / ".hpc.conf").write_text("REMOTE_DIR=/r/proj\n")
        (self.proj / ".ws.conf").write_text("WS_REMOTE_DIR=projects/proj\n")
        self.led = L.Ledger(self.proj)
        self.calls: list[list[str]] = []
        self.answers: list = []
        p = mock.patch.object(X, "call", self.fake)
        p.start()
        self.addCleanup(p.stop)
        o = mock.patch.object(observe, "observe", lambda places, *a, **k: [observe.Observation(places[0], why="x")])
        o.start()
        self.addCleanup(o.stop)

    def fake(self, src, proj, place, nonce, words, deadline):
        self.calls.append(words)
        a = self.answers.pop(0)
        return a(nonce, words) if callable(a) else a

    def plan_reply(self, **kw) -> X.Reply:
        return X.Reply(0, block(**kw), "", api="api=3" if kw.get("kind", "slurm") == "slurm" else None)

    def submitted(self, job: str = "101"):
        return lambda nonce, words: X.Reply(0, "Submitted batch job " + job, "", api="api=3",
                                            result={"verdict": "submitted"}, receipt={"job": job})

    def cli(self, *argv: str) -> tuple[int, str]:
        return run(argv[0], "-C", str(self.proj), *argv[1:])

    def plan_id(self, text: str) -> str:
        return next(ln.split("plan ")[-1] for ln in text.splitlines() if ln.startswith("needs user: approval — plan"))


class Flow(Fixture):
    def test_plan_needs_the_user_then_the_approval_submits_with_rs_expect(self):
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "-n", "exp--train--a--scratch--s0--a01", "--", "python", "t.py")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertEqual(self.calls[0][2:4], ["--rs-mode", "plan"])
        pid = self.plan_id(text)
        self.answers = [self.submitted()]
        rc, text = self.cli("launch", "--plan", pid, "--approve", "go ahead")
        self.assertEqual(rc, OK, text)
        self.assertIn("submitted: exp--train--a--scratch--s0 a01 job 101", text)
        self.assertEqual(self.calls[1][2], "--rs-expect")
        att = self.led.read_run("exp--train--a--scratch--s0").data["attempts"]["a01"]
        self.assertEqual((att["submissions"][0]["submit"], att["submissions"][0]["job"]), ("submitted", "101"))
        ap = next(r for r in self.led.state().grants if r["kind"] == "approval")
        self.assertEqual((ap["created_via"], ap["quote"], len(ap["used"])), ("plan-approve", "go ahead", 1))
        self.assertEqual(att["request"]["grant"], ap["id"])
        self.assertEqual(self.cli("launch", "--plan", pid, "--approve", "again")[0], CONFLICT)

    def test_a_covering_grant_submits_at_once(self):
        G.add(self.led, G.new_grant("train runs are fine", {"targets": ["fx"]}, ["launch"], max_live=2,
                                    max_launches=5, expires=None))
        self.answers = [self.plan_reply(), self.submitted()]
        rc, text = self.cli("launch", "-T", "fx", "-n", "exp--train--a--scratch--s0--a01", "--", "python", "t.py")
        self.assertEqual(rc, OK, text)
        self.assertIn("covered by g-", text)

    def test_a_user_asked_policy_flag_is_never_a_grants_call(self):
        G.add(self.led, G.new_grant("train runs are fine", {"targets": ["fx"]}, ["launch"], max_live=None,
                                    max_launches=None, expires=None))
        self.answers = [self.plan_reply(flags="--gate-user-asked")]       # submit.sh binds T_FLAGS as flags=
        rc, text = self.cli("launch", "-T", "fx", "--gate-user-asked", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("policy flag(s) --gate-user-asked", text)
        self.assertIn("  policy     --gate-user-asked  (bound", text)
        self.answers = [self.submitted()]
        rc, text = self.cli("launch", "--plan", self.plan_id(text), "--approve", "yes, I asked for the gate")
        self.assertEqual(rc, OK, text)
        self.assertIn("--gate-user-asked", self.calls[-1])

    def test_a_deny_refuses_with_its_quote(self):
        G.add(self.led, G.new_deny("never on fx", {"targets": ["fx"]}))
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.assertEqual(rc, REFUSED, text)
        self.assertIn("never on fx", text)

    def test_a_chain_is_one_approval_n_submits_in_one_attempt(self):
        self.answers = [self.plan_reply(chain="1")]
        rc, text = self.cli("launch", "-T", "fx", "--chain", "3", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("--rs-chain", self.calls[0])
        self.answers = [self.submitted("201"), self.submitted("202"), self.submitted("203")]
        rc, text = self.cli("launch", "--plan", self.plan_id(text), "--approve", "chain it")
        self.assertEqual(rc, OK, text)
        self.assertEqual(sum(1 for w in self.calls if "--rs-chain" in w and "--rs-expect" in w), 3)
        att = self.led.read_run("exp--train--a--scratch--s0").data["attempts"]
        self.assertEqual(list(att), ["a01"])
        self.assertEqual([s["job"] for s in att["a01"]["submissions"]], ["201", "202", "203"])
        ap = next(r for r in self.led.state().grants if r["kind"] == "approval")
        self.assertEqual((ap["actions"], ap["limits"]["max_launches"], len(ap["used"])), (["chain"], 3, 3))

    def test_a_grant_without_room_for_the_whole_chain_does_not_cover_it(self):
        G.add(self.led, G.new_grant("chains ok", {"targets": ["fx"]}, ["chain"], max_live=None, max_launches=2,
                                    expires=None))
        self.answers = [self.plan_reply(chain="1")]
        rc, text = self.cli("launch", "-T", "fx", "--chain", "3", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("room for 2 of the 3 chain segments", text)

    def test_drift_refunds_the_use_and_records_not_submitted(self):
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        drift = X.Reply(6, block(payload="d"), "ERROR: the resolved submission differs from the approved plan",
                        api="api=3", result={"verdict": "refused", "stage": "expect", "rc": "6"})
        self.answers = [drift]
        rc, text = self.cli("launch", "--plan", self.plan_id(text), "--approve", "go")
        self.assertEqual(rc, CONFLICT, text)
        att = self.led.read_run("exp--train--a--scratch--s0").data["attempts"]["a01"]
        self.assertEqual(L.attempt_state(att), "NOT_SUBMITTED")
        self.assertEqual(next(r for r in self.led.state().grants if r["kind"] == "approval")["used"], [])

    def test_a_lost_reply_is_submit_unknown_and_counts_as_live(self):
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.answers = [X.Reply(255, err="Connection reset")]
        rc, text = self.cli("launch", "--plan", self.plan_id(text), "--approve", "go")
        self.assertEqual(rc, UNKNOWN, text)
        att = self.led.read_run("exp--train--a--scratch--s0").data["attempts"]["a01"]
        self.assertEqual(L.attempt_state(att), "SUBMIT_UNKNOWN")
        self.assertTrue(L.is_live(att))
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")            # the same run again: the unknown one blocks it
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("SUBMIT_UNKNOWN", text)

    def test_a_receipt_that_arrived_wins_over_ssh_255(self):
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.answers = [X.Reply(255, "", "", api="api=3", receipt={"job": "77"})]
        rc, text = self.cli("launch", "--plan", self.plan_id(text), "--approve", "go")
        self.assertEqual(rc, OK, text)

    def test_a_sweep_is_one_approval_and_a_conflict_hides_nothing(self):
        ids = []
        for n in ("a", "b"):
            self.answers = [self.plan_reply(name=f"exp--ablate--{n}--scratch--s0--a01")]
            ids.append(self.plan_id(self.cli("launch", "-T", "fx", "--", "c")[1]))
        self.answers = [X.Reply(3, "", "REFUSED: policy", api="api=3", result={"verdict": "refused", "stage": "policy"}),
                        self.submitted("302")]
        rc, text = self.cli("launch", "--plan", ids[0], "--plan", ids[1], "--approve", "both")
        self.assertEqual(rc, REFUSED, text)
        self.assertIn("submitted: exp--ablate--b--scratch--s0 a01 job 302", text)
        aps = [r for r in self.led.state().grants if r["kind"] == "approval"]
        self.assertEqual((len(aps), len(aps[0]["scope"]["runs"])), (1, 2))

    def test_superseded_expired_and_unknown_plans_submit_nothing(self):
        self.answers = [self.plan_reply(payload="v1"), self.plan_reply(payload="v2")]
        first = self.plan_id(self.cli("launch", "-T", "fx", "--", "v1")[1])
        second = self.plan_id(self.cli("launch", "-T", "fx", "--", "v2")[1])   # same name, same second: created_ns
        rc, text = self.cli("launch", "--plan", first, "--approve", "v1")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn(f"superseded by {second}", text)
        rec = self.led.read_plan(second).data
        self.assertIn("expired", X.plan_state(self.led, rec, now=time.time() + X.PLAN_TTL_S + 60))
        self.assertEqual(self.cli("launch", "--plan", "p-nope", "--approve", "x")[0], USAGE)
        self.assertEqual(len(self.calls), 2)

    def test_usage_errors(self):
        for argv in (("launch", "--approve", "x"), ("launch", "--plan", "p-1", "-T", "fx"), ("launch", "-T", "fx"),
                     ("launch", "-T", "fx", "-d", "1", "--", "c"), ("launch", "-T", "ws", "-n", "x", "--", "c"),
                     ("launch", "-T", "ws", "--chain", "2", "--", "c"), ("launch", "--plan", "p-1", "--approve", " ")):
            self.assertEqual(self.cli(*argv)[0], USAGE, argv)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.cli("launch", "-h")[0], OK)

    def test_an_old_deploy_needs_a_sync(self):
        self.answers = [X.Reply(65, "@@api api=2\n", "", api="api=2")]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("needs: sync (the deploy predates rsk launch: rsk sync -T fx)", text)

    def test_relaunch_is_the_next_attempt_and_needs_its_own_cover(self):
        G.add(self.led, G.new_grant("go", {"targets": ["fx"]}, ["launch"], max_live=None, max_launches=None,
                                    expires=None))
        self.answers = [self.plan_reply(), self.submitted("101")]
        self.cli("launch", "-T", "fx", "--", "python", "t.py")
        self.led.observe("exp--train--a--scratch--s0", "a01", "101", "PREEMPTED", "sacct",
                         end={"state": "PREEMPTED", "rc": "0:0", "evidence": "sacct"})
        self.answers = [self.plan_reply(name="exp--train--a--scratch--s0--a02")]
        rc, text = self.cli("launch", "--relaunch", "exp--train--a--scratch--s0")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("-n", self.calls[-1])
        self.assertEqual(self.calls[-1][self.calls[-1].index("-n") + 1], "exp--train--a--scratch--s0--a02")
        self.assertIn("action relaunch not in launch", text)
        G.add(self.led, G.new_grant("retry failures as they were", {"targets": ["fx"]}, ["relaunch"], max_live=None,
                                    max_launches=3, expires=None))
        self.answers = [self.plan_reply(name="exp--train--a--scratch--s0--a02"), self.submitted("102")]
        rc, text = self.cli("launch", "--relaunch", "exp--train--a--scratch--s0")
        self.assertEqual(rc, OK, text)
        self.assertIn("a02 job 102", text)


class ReviewFixes(Fixture):
    """The P3 review findings, each pinned (M3 H3 H1 M5 M6 L3 L5 H2 and an older api=3 deploy)."""

    def approvals(self) -> list[dict]:
        return [r for r in self.led.state().grants if r["kind"] == "approval"]

    def test_m3_force_and_rs_words_are_never_policy_flags(self):
        for w in ("--force", "--rs-mode", "--rs-expect", "--rs-warnings", "--rs-anything"):
            with self.assertRaises(RskError) as c:
                X.parse(["-T", "fx", w, "--", "c"])
            self.assertEqual(c.exception.code, USAGE, w)
        self.assertEqual(self.cli("launch", "-T", "fx", "--force", "--", "c")[0], USAGE)
        self.assertEqual(self.calls, [])

    def test_h3_a_class_label_never_contradicts_the_names_class(self):
        rc, text = self.cli("launch", "-T", "fx", "--class", "smoke", "-n", "exp--train--big--s0--a01", "--", "c")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("contradicts the name", text)
        self.assertEqual(self.calls, [])                              # refused before any ssh
        self.answers = [self.plan_reply(name="exp--train--conf--s0--a01")]   # the conf's JOB_NAME, known after the plan
        rc, text = self.cli("launch", "-T", "fx", "--class", "smoke", "--", "c")
        self.assertEqual(rc, USAGE, text)
        self.assertEqual(self.led.plans(), [])
        self.answers = [self.plan_reply(name="exp-plain--a01")]
        rc, text = self.cli("launch", "-T", "fx", "--class", "smoke", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("class smoke", text)                            # a label for a name without a class

    def test_h1_gpu_busy_ok_names_the_gpus(self):
        rc, text = self.cli("launch", "-T", "ws", "-g", "1", "--gpu-busy-ok", "--", "c")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("--gpu-busy-ok needs -d IDS", text)
        self.assertEqual(self.calls, [])

    def test_h1_a_free_landing_never_sends_gpu_busy_ok_and_a_grant_never_covers_a_busy_one(self):
        G.add(self.led, G.new_grant("small runs on ws", {"targets": ["ws"]}, ["launch"], max_live=None,
                                    max_launches=None, expires=None))
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="r", gpus_req="ids=1", info_gpus="1",
                                        busy="2:other:7", busy_ok=""),
                        X.Reply(6, "", "ERROR: -d GPU(s) 1 already run a compute process (1:other:9)")]
        rc, text = self.cli("launch", "-T", "ws", "-d", "1", "-N", "r", "--gpu-busy-ok", "--", "c")
        self.assertEqual(rc, CONFLICT, text)                          # GPU 1 got busy since: refused on the box
        self.assertNotIn("--gpu-busy-ok", self.calls[-1])             # the card's landing was free
        self.assertEqual(L.attempt_state(self.led.read_run("r").data["attempts"]["a01"]), "NOT_SUBMITTED")

    def test_m5_a_used_plan_records_no_second_approval(self):
        self.answers = [self.plan_reply()]
        pid = self.plan_id(self.cli("launch", "-T", "fx", "--", "c")[1])
        self.answers = [self.submitted()]
        self.assertEqual(self.cli("launch", "--plan", pid, "--approve", "go")[0], OK)
        rc, text = self.cli("launch", "--plan", pid, "--approve", "go again")
        self.assertEqual(rc, CONFLICT, text)
        self.assertEqual(len(self.approvals()), 1)                    # nothing dangling for a later identical plan
        ap = self.approvals()[0]
        self.assertEqual((ap["scope"]["plans"], bool(ap["limits"]["expires"])), ([pid], True))
        self.assertTrue(self.led.plan_claim(pid))

    def test_m5_the_plans_are_claimed_first_and_a_failed_approval_is_revoked(self):
        self.answers = [self.plan_reply(name="exp--train--a--s0--a01"), self.plan_reply(name="exp--train--b--s0--a01",
                                                                                         chain="1")]
        a = self.plan_id(self.cli("launch", "-T", "fx", "--", "c")[1])
        b = self.plan_id(self.cli("launch", "-T", "fx", "--chain", "2", "--", "c")[1])   # another group: 2 records
        real, n = G.add, []
        def flaky(led, rec):
            n.append(rec["id"])
            if len(n) == 2:
                raise RskError("disk full", USAGE)
            return real(led, rec)
        with mock.patch.object(G, "add", flaky):
            rc, text = self.cli("launch", "--plan", a, "--plan", b, "--approve", "both")
        self.assertEqual(rc, USAGE, text)
        self.assertTrue(self.led.plan_claim(a) and self.led.plan_claim(b))    # claimed before any approval
        self.assertTrue(all(r.get("revoked") for r in self.approvals()))      # the one made is revoked
        self.assertEqual(len(self.calls), 2)                                    # nothing submitted

    def test_m5_a_refund_after_a_refusal_never_covers_the_replan(self):
        self.answers = [self.plan_reply()]
        pid = self.plan_id(self.cli("launch", "-T", "fx", "--", "c")[1])
        self.answers = [X.Reply(1, "", "WARNING: only 0 free", api="api=3",
                                result={"verdict": "refused", "stage": "avail", "rc": "1"})]
        self.assertEqual(self.cli("launch", "--plan", pid, "--approve", "go")[0], CONFLICT)
        self.assertEqual(self.approvals()[0]["used"], [])             # the use was given back
        self.answers = [self.plan_reply()]                            # the same configuration again
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)                        # a new plan: a new card for the user
        self.assertIn("not one of the approved plans", text)

    def test_m6_submit_unknown_blocks_even_same_name_ok_and_same_name_ok_is_never_a_grants_call(self):
        G.add(self.led, G.new_grant("go", {"targets": ["fx"]}, ["launch", "relaunch"], max_live=None,
                                    max_launches=None, expires=None))
        self.answers = [self.plan_reply(), X.Reply(255, err="Connection reset")]
        self.assertEqual(self.cli("launch", "-T", "fx", "--", "c")[0], UNKNOWN)
        n = len(self.calls)
        for argv in (("launch", "-T", "fx", "-n", "exp--train--a--scratch--s0--a01", "--same-name-ok", "--", "c"),
                     ("launch", "--relaunch", "exp--train--a--scratch--s0", "--same-name-ok")):
            rc, text = self.cli(*argv)
            self.assertEqual(rc, CONFLICT, (argv, text))
            self.assertIn("SUBMIT_UNKNOWN", text)
        self.assertEqual(len(self.calls), n)                           # before any ssh
        self.answers = [self.plan_reply(name="exp--train--z--scratch--s0--a01")]
        rc, text = self.cli("launch", "-T", "fx", "-n", "exp--train--z--scratch--s0--a01", "--same-name-ok", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("--same-name-ok (a second live copy sharing logs/ckpts) is never a standing grant's call", text)

    def test_l3_a_launch_line_the_payload_printed_is_never_proof(self):
        G.add(self.led, G.new_grant("go", {"targets": ["ws"]}, ["launch"], max_live=None, max_launches=None,
                                    expires=None))
        spoof = ("[ws] launching on GPU(s) [1] -> /h/logs/r-20261104-120000.log\n          RUN: x\n"
                 "[ws] started PID 1 on GPU(s) 1 ; log /h/logs/z-20261104-120000.log ; pid file /h/z.pid\n")
        def journal(places, *a, **k):
            n = k["nonces"][places[0].target][0]
            o = observe.Observation(places[0], ok=True, attempts_ok=True)
            o.attempts[n] = {"receipt": {}, "result": {"verdict": "failed", "rc": "1"}}
            return [o]
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="r"), X.Reply(1, spoof, "ERROR: uv venv not active")]
        with mock.patch.object(observe, "observe", journal):
            rc, text = self.cli("launch", "-T", "ws", "-N", "r", "--", "x")
        self.assertEqual(rc, FAILED, text)
        self.assertNotIn("launched:", text)
        self.assertEqual(L.attempt_state(self.led.read_run("r").data["attempts"]["a01"]), "NOT_SUBMITTED")
        real = spoof.replace("RUN: x", "RUN: [ws] started PID 1 on GPU(s) 0 ; log logs/y.log ; pid file p") + \
            "[ws] started PID 4242 on GPU(s) 1 ; log /h/logs/r2-20261104-120000.log ; pid file /h/r2.log.pid\n"
        m = X.started(real, "ws")
        self.assertEqual(m.group(1), "4242")                            # the last line that is launch.sh's own
        self.assertIsNone(X.started("  [ws] started PID 1 on GPU(s) 0 ; log logs/a.log ; pid file p", "ws"))

    def test_l5_a_chain_under_max_live_1_sends_every_segment(self):
        G.add(self.led, G.new_grant("chain the long run, one at a time", {"targets": ["fx"]}, ["chain"], max_live=1,
                                    max_launches=10, expires=None))
        self.answers = [self.plan_reply(chain="1"), self.submitted("201"), self.submitted("202"), self.submitted("203")]
        rc, text = self.cli("launch", "-T", "fx", "--chain", "3", "--", "c")
        self.assertEqual(rc, OK, text)
        self.assertEqual(text.count("submitted: "), 3)

    def test_h2_the_card_shows_sbatch_extras_time_and_resources(self):
        self.answers = [self.plan_reply(extra="--time=7-00:00:00 --nodes=8")]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("  TIME       7-00:00:00 — an SBATCH_EXTRA / policy --time comes after the harness's", text)
        self.assertIn("  NO GRANT   SBATCH_EXTRA word(s) --time=7-00:00:00 --nodes=8 — outside what a standing grant", text)

    def test_an_api3_deploy_without_the_new_bound_keys_needs_a_sync(self):
        self.answers = [X.Reply(0, block(drop=("env_hook", "venv_dir", "uv_sync_args")), "", api="api=3")]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("needs: sync", text)
        self.assertIn("lacks env_hook, venv_dir, uv_sync_args", text)

    def test_r4_5_a_box_whose_launch_sh_lets_run_pick_the_gpus_needs_a_sync(self):
        """R4-5: launch.sh refuses a RUN that sets or clears a GPU variable and says so (info_run_gpu=checked); a
        deploy older than that would let RUN's leading CUDA_VISIBLE_DEVICES=… land beside the GPUs the plan shows."""
        G.add(self.led, G.new_grant("anything on ws", {"targets": ["ws"]}, ["launch"], max_live=None,
                                    max_launches=None, expires=None))
        self.answers = [X.Reply(0, block(kind="nohup", target="ws", name="r", drop=("info_run_gpu",)), "")]
        rc, text = self.cli("launch", "-T", "ws", "-N", "r", "--", "c")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("needs: sync", text)
        self.assertIn("lacks info_run_gpu", text)
        self.assertEqual(len(self.calls), 1)                          # the plan only: nothing launched


class Round3(Fixture):
    """The round-2 findings on launch.py, each pinned (grants#4 grants#5 grants#6 grants#9, C-stale-API, F-unknown, L3-regex /
    G-launch-line-regex-space, H1-msg) and the round-3 decisions D1 D3 D5 D9 D10."""

    def grant(self, quote="launches are fine", actions=("launch",), **scope) -> dict:
        return G.add(self.led, G.new_grant(quote, {"targets": ["fx", "ws"], **scope}, list(actions), max_live=None,
                                           max_launches=None, expires=None))

    def test_g2_9_no_word_before_the_double_dash_may_carry_rs(self):
        for argv in (["-T", "fx", "-n--rs-chain", "--x", "--", "c"], ["-T", "fx", "-p", "x--rs-mode", "--", "c"],
                     ["-T", "fx", "--relaunch", "r--rs-chain"], ["-T", "fx", "-n-x", "--", "c"], ["-T", "ws", "-d-1"]):
            with self.assertRaises(RskError) as c:
                X.parse(argv)
            self.assertEqual(c.exception.code, USAGE, argv)
        ns = X.parse(["-T", "fx", "-n", "r", "--", "python", "t.py", "--rs-seed", "3"])   # the payload may
        self.assertEqual(ns.cmd[-2:], ["--rs-seed", "3"])
        self.assertEqual(self.cli("launch", "-T", "fx", "-n--rs-chain", "--x", "--", "c")[0], USAGE)
        self.assertEqual(self.calls, [])

    def test_d5_g2_4_a_plain_launch_of_an_existing_run_is_a_relaunch(self):
        self.grant()
        self.answers = [self.plan_reply(name="exp--smoke--x"), self.submitted("101")]
        self.assertEqual(self.cli("launch", "-T", "fx", "-n", "exp--smoke--x", "--", "c")[0], OK)
        self.led.observe("exp--smoke--x", "a01", "101", "FAILED", "sacct", end={"state": "FAILED", "rc": "1:0",
                                                                                "evidence": "sacct"})
        G.add(self.led, G.new_deny("do not relaunch exp--smoke--x, it is broken", {"names": ["exp--smoke--x"]},
                                   ["relaunch"]))
        self.answers = [self.plan_reply(name="exp--smoke--x")]
        rc, text = self.cli("launch", "-T", "fx", "-n", "exp--smoke--x", "--", "c")
        self.assertEqual(rc, REFUSED, text)
        self.assertIn("— relaunch on fx", text)
        self.assertIn("do not relaunch exp--smoke--x", text)
        self.assertEqual((len(self.calls), self.calls[-1][2]), (3, "--rs-mode"))   # planned, never submitted

    def test_d5_a_not_submitted_attempt_is_no_earlier_run(self):
        self.grant()
        self.answers = [self.plan_reply(name="exp--smoke--n"), X.Reply(3, "", "REFUSED: policy", api="api=3",
                                                                       result={"verdict": "refused", "stage": "policy"})]
        self.assertEqual(self.cli("launch", "-T", "fx", "-n", "exp--smoke--n", "--", "c")[0], REFUSED)
        self.answers = [self.plan_reply(name="exp--smoke--n"), self.submitted("102")]
        rc, text = self.cli("launch", "-T", "fx", "-n", "exp--smoke--n", "--", "c")
        self.assertEqual(rc, OK, text)                           # still a launch: the refused attempt never ran
        self.assertIn("— launch on fx", text)

    def test_d5_g2_5_a_runs_class_is_sticky(self):
        self.grant(actions=("launch", "relaunch"))
        self.answers = [self.plan_reply(name="bigrun"), self.submitted("101")]
        self.assertEqual(self.cli("launch", "-T", "fx", "--class", "train", "-n", "bigrun", "--", "c")[0], OK)
        self.led.observe("bigrun", "a01", "101", "PREEMPTED", "sacct", end={"state": "PREEMPTED", "rc": "",
                                                                            "evidence": "sacct"})
        n = len(self.calls)
        for argv in (("launch", "--relaunch", "bigrun", "--class", "smoke"),
                     ("launch", "-T", "fx", "--class", "smoke", "-n", "bigrun", "--", "c")):
            rc, text = self.cli(*argv)
            self.assertEqual(rc, USAGE, (argv, text))
            self.assertIn("run bigrun is class train (recorded at its first attempt)", text)
        self.assertEqual(len(self.calls), n)                     # before any ssh
        G.add(self.led, G.new_deny("no more train runs, they burn the budget", {"classes": ["train"]}))
        self.answers = [self.plan_reply(name="bigrun--a02")]
        rc, text = self.cli("launch", "--relaunch", "bigrun")
        self.assertEqual(rc, REFUSED, text)
        self.assertIn("class train", text)

    def test_d5_g2_6_an_sbatch_extra_singleton_is_a_chain(self):
        self.grant()
        G.add(self.led, G.new_deny("never chain jobs", {}, ["chain"]))
        self.answers = [self.plan_reply(chain="1", extra="--dependency=singleton")]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.assertEqual(rc, REFUSED, text)
        self.assertIn("never chain jobs", text)
        self.led.write_grants({"version": 1, "records": [r for r in self.led.state().grants if r["kind"] != "deny"],
                               "budgets_unknown": None})
        self.answers = [self.plan_reply(chain="1", extra="--dependency=singleton")]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("action chain not in launch", text)

    def test_d3_y_goes_with_a_grant_whose_kind_covers_the_warnings(self):
        self.grant("queue them even if the cluster is busy", allow_warnings="availability")
        self.answers = [self.plan_reply(warnings=1, warnings_avail=1), self.submitted("101")]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.assertEqual(rc, OK, text)
        self.assertIn("-y", self.calls[-1])
        self.assertEqual(self.calls[-1][self.calls[-1].index("--rs-warnings") + 1], WID[1])
        self.answers = [self.plan_reply(name="exp--train--b--s0--a01", warnings=2, warnings_avail=1,
                                        warnings_id="b" * 64)]   # + a policy gate
        rc, text = self.cli("launch", "-T", "fx", "-n", "exp--train--b--s0--a01", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("the scope allows only the availability gate's", text)
        self.assertIn("  warnings   2  (1 of them the availability gate's)", text)

    def test_d10_a_proven_refusal_frees_the_plan_for_the_same_approval(self):
        self.answers = [self.plan_reply()]
        pid = self.plan_id(self.cli("launch", "-T", "fx", "--", "c")[1])
        self.answers = [X.Reply(3, "", "REFUSED: the env gate", api="api=3",
                                result={"verdict": "refused", "stage": "policy", "rc": "3"})]
        rc, text = self.cli("launch", "--plan", pid, "--approve", "yes, run it")
        self.assertEqual(rc, REFUSED, text)
        self.assertIn(f"plan {pid} is free again", text)
        self.assertIsNone(self.led.plan_claim(pid))
        self.answers = [self.submitted("101")]
        rc, text = self.cli("launch", "--plan", pid)                     # no new words: the same approval covers it
        self.assertEqual(rc, OK, text)
        aps = [r for r in self.led.state().grants if r["kind"] == "approval"]
        self.assertEqual((len(aps), len(aps[0]["used"])), (1, 1))
        self.assertEqual(self.calls[-1][2], "--rs-expect")
        self.assertEqual(self.cli("launch", "--plan", pid)[0], CONFLICT)  # used now

    def test_f_unknown_provably_unsent_submits_are_not_submitted(self):
        self.grant()
        nojournal = X.Reply(2, "@@api api=3\n@@rc 2\n@@claimed 0\n",
                            "ERROR: cannot create /r/.rs/attempts — nothing submitted", api="api=3", claimed=False)
        self.answers = [self.plan_reply(name="nj--smoke"), nojournal]
        rc, text = self.cli("launch", "-T", "fx", "-n", "nj--smoke", "--", "c")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("with no .rs/attempts/", text)
        self.assertEqual(L.attempt_state(self.led.read_run("nj--smoke").data["attempts"]["a01"]), "NOT_SUBMITTED")
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="tf--smoke"),
                        X.Reply(255, "[ws] current GPUs on wshost:\n", "ssh: connect to host wshost: timed out")]
        rc, text = self.cli("launch", "-T", "ws", "-N", "tf--smoke", "--", "c")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("before its launch ssh: nothing was sent", text)
        self.assertEqual(L.attempt_state(self.led.read_run("tf--smoke").data["attempts"]["a01"]), "NOT_SUBMITTED")
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="tf2--smoke"),
                        X.Reply(255, "[ws] current GPUs on wshost:\n[ws] reference: /x/reference.md — the rules\n", "")]
        rc, text = self.cli("launch", "-T", "ws", "-N", "tf2--smoke", "--", "c")
        self.assertEqual(rc, UNKNOWN, text)                              # the launch ssh may have run: unknown
        self.assertEqual(L.attempt_state(self.led.read_run("tf2--smoke").data["attempts"]["a01"]), "SUBMIT_UNKNOWN")

    def test_c_stale_api_the_deployed_submit_sh_marker_decides(self):
        d = self.home / "remote"
        (d / ".fx").mkdir(parents=True)
        (d / ".fx" / "API").write_text("api=3\n")                       # the separate file says api=3 …
        (d / ".fx" / "submit.sh").write_text("#!/usr/bin/env bash\necho ran \"$@\"\n")   # … the script does not
        place = harness.Place("fx", "slurm", "h", str(d), ".fx")
        body = X.slurm_body(place, "n1", ["--rs-mode", "plan"])
        r = X.parse_slurm(subprocess.run(["bash", "-c", body], capture_output=True, text=True))
        self.assertEqual((r.rc, r.api), (65, ""))
        self.assertNotIn("ran", r.out)
        (d / ".fx" / "submit.sh").write_text("#!/usr/bin/env bash\n# rs-api=3\necho ran \"$@\"; exit 2\n")
        r = X.parse_slurm(subprocess.run(["bash", "-c", body], capture_output=True, text=True))
        self.assertEqual((r.rc, r.api, r.claimed), (2, "api=3", False))
        self.assertIn("ran --rs-mode plan", r.out)
        s, w = harness.Place("fx", "slurm", "h", "/r", ".fx"), harness.Place("ws", "nohup", "h", "p", ".ws")
        for reply, place in ((X.Reply(2, err="ERROR: unknown arg 'plan' (flags: -p …)", api="api=3"), s),
                             (X.Reply(2, err="ERROR: '--rs-chain' is not a flag of this submit.sh", api="api=3"), s),
                             (X.Reply(2, err="ERROR: unknown arg '--rs-mode'"), w),
                             (X.Reply(2, err="ERROR: the deployed .ws/launch.sh does not speak rs-api=3 (an older "
                                             "deploy) — run-sync, then plan again; nothing launched"), w)):
            with contextlib.redirect_stdout(io.StringIO()) as buf:
                e = X.plan_failure(reply, place)
            self.assertEqual(e.code, CONFLICT, reply)
            self.assertIn("needs: sync", buf.getvalue())
        self.answers = [self.plan_reply()]
        pid = self.plan_id(self.cli("launch", "-T", "fx", "--", "c")[1])
        self.answers = [X.Reply(2, "", "ERROR: unknown arg '" + "7" * 64 + "' (flags: …)", api="api=3",
                                result={"verdict": "refused", "stage": "pre-policy", "rc": "2"})]
        rc, text = self.cli("launch", "--plan", pid, "--approve", "go")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("needs: sync", text)

    def test_h1_msg_a_refused_launch_names_what_changed(self):
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="r", gpus_req="ids=1", info_gpus="1",
                                        busy="1:me:42", busy_ok="1:GPU-x:me", warnings=1)]
        rc, text = self.cli("launch", "-T", "ws", "-d", "1", "-N", "r", "--gpu-busy-ok", "--", "c")
        pid = self.plan_id(text)
        self.assertIn("  busy ok    1:GPU-x:me", text)
        now = block(kind="nohup", target="ws", name="r", gpus_req="ids=1", info_gpus="1", busy="1:root:1",
                    busy_ok="1:GPU-x:root", warnings=1)
        self.answers = [X.Reply(6, now, "ERROR: the resolved submission differs from the approved plan")]
        rc, text = self.cli("launch", "--plan", pid, "--approve", "share GPU 1 with my eval job")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("busy_ok: 1:GPU-x:me → 1:GPU-x:root", text)
        self.assertNotIn("the conf changed since", text)

    def test_b_m4_another_set_of_warnings_is_refused_and_named(self):
        old = G.parse_plan(block(warnings=1))
        self.assertIn("the warnings: 1 on the card, 1 now", X.drift({"kind": "slurm", "block": old},
                                                                     block(warnings=1, warnings_id="c" * 64)))
        self.assertEqual(X.drift({"kind": "slurm", "block": old}, "no block here"), "")
        self.answers = [self.plan_reply(warnings=1)]
        pid = self.plan_id(self.cli("launch", "-T", "fx", "--", "c")[1])
        swapped = X.Reply(6, block(warnings=1, warnings_id="c" * 64), "ERROR: the resolved submission differs from the "
                          "approved plan: its 1 warning(s) are not the approved card's (warnings_id …)", api="api=3",
                          result={"verdict": "refused", "stage": "expect", "rc": "6"})
        self.answers = [swapped]
        rc, text = self.cli("launch", "--plan", pid, "--approve", "ok, queue it even though the partition is full")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("the warnings differ from the approved card", text)
        self.assertEqual(self.calls[-1][self.calls[-1].index("--rs-warnings") + 1], WID[1])

    def test_l3_g_space_the_launch_line_reads_from_the_end_and_the_receipt_wins(self):
        line = ("[ws] started PID 4242 on GPU(s) 1 ; log /h/projects/my proj/logs/r;1-20261104-120000.log ; pid file "
                "/h/projects/my proj/logs/r;1-20261104-120000.log.pid\n")
        m = X.started(line, "ws")
        self.assertEqual((m.group(1), m.group(2), X.rel_log(m.group(3))), ("4242", "1", "logs/r;1-20261104-120000.log"))
        self.grant()
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="sp1"), X.Reply(0, line, "")]
        rc, text = self.cli("launch", "-T", "ws", "-N", "sp1", "--", "c")
        self.assertEqual(rc, OK, text)
        self.assertIn("launched: sp1 a01 pid 4242", text)
        def journal(places, *a, **k):
            n = k["nonces"][places[0].target][0]
            o = observe.Observation(places[0], ok=True, attempts_ok=True)
            o.attempts[n] = {"receipt": {"pid": "777", "pgid": "777", "start": "55", "boot_id": "b", "gpu_ids": "2",
                                         "log": "logs/sp2-20261104-120000.log"}, "gate": "go",
                             "result": {"verdict": "launched"}}
            return [o]
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="sp2"), X.Reply(0, "[ws] launching …\n", "")]
        with mock.patch.object(observe, "observe", journal):
            rc, text = self.cli("launch", "-T", "ws", "-N", "sp2", "--", "c")
        self.assertEqual(rc, OK, text)                                   # no launch line at all: the receipt decides
        sub = self.led.read_run("sp2").data["attempts"]["a01"]["submissions"][0]
        self.assertEqual((sub["submit"], sub["proc"]["pid"], sub["proc"]["start"]), ("submitted", "777", "55"))


class Round4(Fixture):
    """The round-4 decisions on launch.py / ledger.py, each pinned (R4-2 R4-3 R4-6 R4-8 R4-15)."""

    def grant(self, quote="launches are fine", actions=("launch",), **scope) -> dict:
        return G.add(self.led, G.new_grant(quote, {"targets": ["fx", "ws"], **scope}, list(actions), max_live=None,
                                           max_launches=None, expires=None))

    def test_r4_2_a_plan_named_after_an_older_attempt_is_a_new_attempt(self):
        """NEW-relaunch-orig (ledger side): a new plan named <run>--a01 after a01 ran was folded into the ended a01
        (under a01's old approval: max_live never counted it, rsk status showed the job UNLEDGERED)."""
        name = "exp--train--lr--s0--a01"
        self.answers = [self.plan_reply(name=name, payload="python train.py --lr 1")]
        pid = self.plan_id(self.cli("launch", "-T", "fx", "-n", name, "--", "python", "train.py", "--lr", "1")[1])
        self.answers = [self.submitted("101")]
        self.assertEqual(self.cli("launch", "--plan", pid, "--approve", "run it with lr 1")[0], OK)
        self.led.observe("exp--train--lr--s0", "a01", "101", "CANCELLED", "sacct",
                         end={"state": "CANCELLED", "rc": "0:15", "evidence": "sacct"})
        g = self.grant("auto-resume exp--train if it gets preempted", actions=("relaunch",), names=["exp--train--*"])
        self.answers = [self.plan_reply(name=name, payload="python train.py --lr 1")]
        rc, text = self.cli("launch", "-T", "fx", "-n", name, "--", "python", "train.py", "--lr", "1")
        self.assertEqual(rc, NEEDS_USER, text)                       # CANCELLED is no infrastructure end
        self.assertIn("previous attempt a01 ended CANCELLED", text)
        self.answers = [self.submitted("102")]
        self.assertEqual(self.cli("launch", "--plan", self.plan_id(text), "--approve", "yes, again with lr 1")[0], OK)
        atts = self.led.read_run("exp--train--lr--s0").data["attempts"]
        self.assertEqual(sorted(atts), ["a01", "a02"])               # its own attempt, never joined to the ended a01
        self.assertEqual(([s["job"] for s in atts["a01"]["submissions"]], [s["job"] for s in atts["a02"]["submissions"]]),
                         (["101"], ["102"]))
        self.assertEqual(atts["a02"]["name"], name)
        self.assertNotEqual(atts["a02"]["request"]["grant"], atts["a01"]["request"]["grant"])
        self.assertNotEqual(atts["a02"]["request"]["grant"], g["id"])

    def test_r4_3_a_label_never_sets_the_class_of_a_run_that_had_none(self):
        """NEW-class-unlabelled: bigrun's a01 carried no class; `--relaunch bigrun --class smoke` (or -n bigrun with
        --class) made a smoke-only grant cover it and a train deny miss. Now exit 2, before any ssh."""
        self.grant(actions=("launch", "relaunch"))
        self.answers = [self.plan_reply(name="bigrun"), self.submitted("101")]
        self.assertEqual(self.cli("launch", "-T", "fx", "-n", "bigrun", "--", "c")[0], OK)
        self.led.observe("bigrun", "a01", "101", "PREEMPTED", "sacct", end={"state": "PREEMPTED", "rc": "",
                                                                            "evidence": "sacct"})
        n = len(self.calls)
        for argv in (("launch", "--relaunch", "bigrun", "--class", "smoke"),
                     ("launch", "-T", "fx", "--class", "smoke", "-n", "bigrun", "--", "c")):
            rc, text = self.cli(*argv)
            self.assertEqual(rc, USAGE, (argv, text))
            self.assertIn("run bigrun has no class (its first attempt was recorded without one)", text)
        self.assertEqual(len(self.calls), n)
        self.answers = [self.plan_reply(name="bigrun--a02"), self.submitted("102")]
        rc, text = self.cli("launch", "--relaunch", "bigrun")       # no label: as before
        self.assertEqual(rc, OK, text)

    def test_r4_6_the_card_shows_the_bound_policy_flags_and_a_relaunch_replays_them(self):
        self.grant(max_gpus=1)
        self.answers = [self.plan_reply(flags="--whole-node")]
        rc, text = self.cli("launch", "-T", "fx", "--whole-node", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)                       # NEW-policy-flag: a 1-GPU grant never covers it
        self.assertIn("  policy     --whole-node  (bound", text)
        self.assertIn("policy flag(s) --whole-node", text)
        b = G.parse_plan(block(gres="gpu:1", flags="--whole-node --x-user-asked"))
        flags, _pay, _ = X._from_bound("slurm", G.bound(b), "r--a02")
        self.assertEqual(flags[-4:], ["-n", "r--a02", "--whole-node", "--x-user-asked"])
        for odd in ("--rs-chain", "--force", "-x", "'a b'"):         # never replayed as a policy flag
            with self.assertRaises(RskError):
                X._from_bound("slurm", G.bound(G.parse_plan(block(flags=odd))), "r--a02")
        self.answers = [X.Reply(0, block(drop=("flags",)), "", api="api=3")]   # an api=3 deploy without flags=
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("lacks flags", text)

    def nohup_plan(self, name: str) -> str:
        self.answers = [self.plan_reply(kind="nohup", target="ws", name=name)]
        return self.plan_id(self.cli("launch", "-T", "ws", "-N", name, "--", "c")[1])

    REF = "[ws] current GPUs on wshost:\n[ws] reference: /x/reference.md — the rules\n"

    def journal(self, **att):
        def fake(places, *a, **k):
            n = k["nonces"][places[0].target][0]
            o = observe.Observation(places[0], ok=True, attempts_ok=True)
            o.attempts[n] = {"receipt": {}, "result": {}, "gate": "", "missing": False, **att}
            return [o]
        return fake

    def test_r4_8_nohup_settle_reads_the_journal_before_it_concludes(self):
        """NEW-launch-killed-after-go: launch.sh killed (137) after its gate said go was taken for 'never started' —
        NOT_SUBMITTED, the use given back while the run ran. Now only the journal decides."""
        g = G.add(self.led, G.new_grant("1 on ws", {"targets": ["ws"]}, ["launch"], max_live=1, max_launches=1,
                                        expires=None))
        killed = X.Reply(137, self.REF + "[ws] launching on GPU(s) [2] -> /h/logs/k1-20261105-000000.log\n", "")
        go = self.journal(receipt={"pid": "4242", "pgid": "4242", "start": "77", "boot_id": "b", "gpu_ids": "2",
                                   "log": "logs/k1-20261105-000000.log"}, gate="go", result={})
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="k1"), killed]
        with mock.patch.object(observe, "observe", go):
            rc, text = self.cli("launch", "-T", "ws", "-N", "k1", "--", "sleep", "60")
        self.assertEqual(rc, OK, text)
        self.assertIn("launched: k1 a01 pid 4242", text)
        sub = self.led.read_run("k1").data["attempts"]["a01"]["submissions"][0]
        self.assertEqual((sub["submit"], sub["proc"]["start"]), ("submitted", "77"))
        self.assertEqual(len(next(r for r in self.led.state().grants if r["id"] == g["id"])["used"]), 1)   # kept
        cases = (("unreadable", lambda places, *a, **k: [observe.Observation(places[0], why="no answer")], UNKNOWN,
                  "SUBMIT_UNKNOWN"),
                 ("abort-gate", self.journal(receipt={"pid": "9"}, gate="abort", result={"verdict": "failed"}), UNKNOWN,
                  "SUBMIT_UNKNOWN"),
                 ("no-verdict", self.journal(result={}), UNKNOWN, "SUBMIT_UNKNOWN"),
                 ("failed", self.journal(result={"verdict": "failed", "rc": "1"}), FAILED, "NOT_SUBMITTED"),
                 ("missing", self.journal(missing=True), FAILED, "NOT_SUBMITTED"))
        for name, journal, code, st in cases:
            pid = self.nohup_plan(name)
            self.answers = [X.Reply(1 if name != "unreadable" else 137, self.REF, "ERROR: x")]
            with mock.patch.object(observe, "observe", journal):
                rc, text = self.cli("launch", "--plan", pid, "--approve", "go")
            self.assertEqual(rc, code, (name, text))
            self.assertEqual(L.attempt_state(self.led.read_run(name).data["attempts"]["a01"]), st, name)
        # no attempt dir proves nothing was started only once launch.sh itself exited: an ssh killed by a signal
        # (run-launch's 128+N) or a killed run-launch (< 0) may leave launch.sh on its way to the claim
        for name, code in (("sig-ssh", 143), ("sig-rl", -9)):
            pid = self.nohup_plan(name)
            self.answers = [X.Reply(code, self.REF, "")]
            with mock.patch.object(observe, "observe", self.journal(missing=True)):
                rc, text = self.cli("launch", "--plan", pid, "--approve", "go")
            self.assertEqual(rc, UNKNOWN, (name, text))
            self.assertEqual(L.attempt_state(self.led.read_run(name).data["attempts"]["a01"]), "SUBMIT_UNKNOWN", name)

    def test_r4_15_unreadable_grants_refuse_launch_with_exit_6(self):
        self.answers = [self.plan_reply()]
        pid = self.plan_id(self.cli("launch", "-T", "fx", "--", "c")[1])
        G.add(self.led, G.new_deny("never on fx", {"targets": ["fx"]}))
        (self.led.dir / "grants.json").write_text('{"version": 1, "records": [')
        (self.led.dir / "grants.json.prev").unlink(missing_ok=True)
        rc, text = self.cli("launch", "--plan", pid, "--approve", "go")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("grants unreadable", text)
        self.assertIsNone(self.led.plan_claim(pid))                   # nothing claimed, nothing recorded
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.assertEqual(rc, CONFLICT, text)
        self.assertEqual(sum(1 for w in self.calls if "--rs-expect" in w), 0)


class Round5(Fixture):
    """R5-4 (RW-unledgered-relaunch-deny): a run run-watch launched never enters the ledger, so `rsk launch -n a` was a
    plain launch — a deny of relaunch ('do not relaunch a, it is broken') never matched it and a launch grant covered
    it. The block's envelope info_prior (the target's journal receipts / live jobs of the run) now makes it a relaunch,
    and so does a block that cannot say (no readable info_prior: fail closed)."""

    def test_r5_4_a_run_the_target_knows_is_a_relaunch_though_the_ledger_never_saw_it(self):
        G.add(self.led, G.new_grant("launch the a runs on fx", {"targets": ["fx"], "names": ["a*"]}, ["launch"],
                                    max_live=None, max_launches=None, expires=None))
        self.answers = [self.plan_reply(name="a", prior="1")]
        rc, text = self.cli("launch", "-T", "fx", "-n", "a", "--", "python", "train.py")
        self.assertEqual(rc, NEEDS_USER, text)                       # was: covered, submitted (exit 0)
        self.assertIn(" — relaunch on fx (slurm)", text)
        self.assertIn("  prior      1 earlier attempt(s) of a on fx", text)
        self.assertIn("action relaunch not in launch", text)
        self.assertEqual(self.led.runs(), {})                         # the ledger has no attempt of it
        G.add(self.led, G.new_deny("do not relaunch a, it is broken", {"names": ["a"]}, ["relaunch"]))
        self.answers = [self.plan_reply(name="a", prior="1")]
        rc, text = self.cli("launch", "-T", "fx", "-n", "a", "--", "python", "train.py")
        self.assertEqual(rc, REFUSED, text)
        self.assertIn("do not relaunch a, it is broken", text)
        self.assertEqual(len(self.calls), 2)                          # plans only: nothing submitted
        self.assertTrue(all("--rs-mode" in c for c in self.calls))

    def test_r5_4_a_relaunch_grant_never_resumes_what_only_the_journal_shows(self):
        G.add(self.led, G.new_grant("auto-resume preempted runs on fx", {"targets": ["fx"]}, ["launch", "relaunch"],
                                    max_live=None, max_launches=None, expires=None))
        self.answers = [self.plan_reply(name="a", prior="2")]
        rc, text = self.cli("launch", "-T", "fx", "-n", "a", "--", "python", "train.py")
        self.assertEqual(rc, NEEDS_USER, text)                       # its end is not the ledger's: the user's call
        self.assertIn("the ledger has no earlier attempt of the run that ran", text)
        self.assertIn("no previous attempt in the ledger to repeat", text)

    def test_r5_4_a_block_that_cannot_say_is_a_relaunch(self):
        G.add(self.led, G.new_grant("launch on fx", {"targets": ["fx"]}, ["launch"], max_live=None, max_launches=None,
                                    expires=None))
        for kw in ({"drop": ("info_prior",)}, {"prior": "x"}, {"prior": "-1"}, {"prior": "''"}, {"prior": "1e3"}):
            self.answers = [self.plan_reply(name="b", **kw)]
            rc, text = self.cli("launch", "-T", "fx", "-n", "b", "--", "c")
            self.assertEqual(rc, NEEDS_USER, (kw, text))
            self.assertIn(" — relaunch on fx (slurm)", text)
            self.assertIn("  prior      unknown — the deploy does not count the run's earlier attempts", text)
        self.answers = [self.plan_reply(name="b", prior="0"), self.submitted("101")]   # 0 and no ledger attempt: launch
        rc, text = self.cli("launch", "-T", "fx", "-n", "b", "--", "c")
        self.assertEqual(rc, OK, text)
        self.assertIn(" — launch on fx (slurm)", text)
        self.assertNotIn("  prior  ", text)
        self.assertEqual(X.info_prior({"info_prior": "0"}), 0)
        self.assertEqual([X.info_prior(b) for b in ({}, {"info_prior": ""}, {"info_prior": "07"}, {"info_prior": "²"})],
                         [None, None, 7, None])

    def test_r5_4_nohup_too_and_an_approval_records_the_relaunch(self):
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="r", prior="2")]
        rc, text = self.cli("launch", "-T", "ws", "-N", "r", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn(" — relaunch on ws (nohup)", text)
        self.answers = [lambda nonce, words: X.Reply(0, f"[ws] started PID 4242 on GPU(s) 1 ; log /p/logs/r-1.log ; pid "
                                                        "file /p/logs/r-1.pid\n", "")]
        rc, text = self.cli("launch", "--plan", self.plan_id(text), "--approve", "yes, relaunch r")
        self.assertEqual(rc, OK, text)
        ap = next(r for r in self.led.state().grants if r["kind"] == "approval")
        self.assertEqual(ap["actions"], ["relaunch"])
        att = self.led.read_run("r").data["attempts"]["a01"]
        self.assertEqual(att["request"]["action"], "relaunch")

    def test_r6_4_a_slurm_submit_s_ssh_255_is_unknown_whatever_its_stderr_says(self):
        """V5-notreached-submit-resubmit (R6-4 reverts R5-6 for submits): ssh's exit 255 with no answer and a
        `Connection refused` line in its stderr was taken as proof that nothing was sent — NOT_SUBMITTED, the use given
        back, the plan released — but a ProxyCommand's fallback route prints that line on a session that did open: the
        job existed, and `rsk launch --plan <id>` submitted it again (a --chain approval: every segment again). Now it
        is SUBMIT_UNKNOWN (sticky), the use kept, the plan used: the retry is refused (exit 6) and nothing is sent."""
        self.answers = [self.plan_reply()]
        pid = self.plan_id(self.cli("launch", "-T", "fx", "--", "c")[1])
        self.answers = [X.Reply(255, "", "ssh: connect to host bastion-a port 22: Connection refused\n")]
        rc, text = self.cli("launch", "--plan", pid, "--approve", "run the exp smoke once")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("SUBMIT_UNKNOWN: exp--train--a--scratch--s0 a01", text)
        self.assertIn("ssh's own words are no proof that nothing was sent", text)
        self.assertNotIn("not reached", text)
        self.assertNotIn("is free again", text)
        att = self.led.read_run("exp--train--a--scratch--s0").data["attempts"]["a01"]
        self.assertEqual(L.attempt_state(att), "SUBMIT_UNKNOWN")
        self.assertTrue(L.is_live(att))
        aps = [r for r in self.led.state().grants if r["kind"] == "approval"]
        self.assertEqual((len(aps), len(aps[0]["used"])), (1, 1))      # the use kept
        n = len(self.calls)
        rc, text = self.cli("launch", "--plan", pid)                     # the retry rsk used to offer
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("was used already", text)
        self.assertEqual(len(self.calls), n)                             # nothing sent
        name = "exp--train--c--scratch--s0"                              # a chain approval: the first segment's 255
        self.answers = [self.plan_reply(name=name, chain="1")]           # stops the chain, nothing released
        p2 = self.plan_id(self.cli("launch", "-T", "fx", "-n", name, "--chain", "2", "--", "c")[1])
        self.answers = [X.Reply(255, "", "ssh: connect to host bastion-a port 22: Connection refused\n")]
        n = len(self.calls)
        rc, text = self.cli("launch", "--plan", p2, "--approve", "run c as a 2-segment chain")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("the chain stops: 1 later segment(s) not sent", text)
        self.assertEqual(len(self.calls), n + 1)
        self.assertEqual(self.cli("launch", "--plan", p2)[0], CONFLICT)
        self.assertEqual(len(self.calls), n + 1)
        for i, r in enumerate((X.Reply(255, "", "Connection to fxhost closed by remote host.\n"),
                               X.Reply(255, "@@api api=3\n", "ssh: connect to host fxhost port 22: Connection refused\n"),
                               X.Reply(None, why="no answer from fxhost within 180 s"))):
            name = f"exp--train--u{i}--scratch--s0"
            self.answers = [self.plan_reply(name=name)]
            p = self.plan_id(self.cli("launch", "-T", "fx", "-n", name, "--", "c")[1])
            self.answers = [r]
            rc, text = self.cli("launch", "--plan", p, "--approve", "go")
            self.assertEqual(rc, UNKNOWN, text)
            self.assertNotIn("not reached", text)
            self.assertEqual(L.attempt_state(self.led.read_run(name).data["attempts"]["a01"]), "SUBMIT_UNKNOWN")


class Round6(Fixture):
    """Integration of round 6: launch.sh's launcher / container WARNINGs (R6-2, R6-3) and its env -i refusal (R6-6) say
    so in the block (info_launchers=checked); a deploy without them prints a block those WARNINGs are missing from."""

    def test_r6_a_box_whose_launch_sh_predates_the_launcher_and_container_checks_needs_a_sync(self):
        """An un-synced round-5 launch.sh prints info_run_gpu=checked and info_prior but no WARNING for `docker run
        --gpus all …` or accelerate's config, and lets an `x; env -i …` RUN through: a standing launch grant would cover
        that card. Without info_launchers the plan is `needs: sync` (nothing launched), and a plan stored without it is
        refused at --plan."""
        G.add(self.led, G.new_grant("anything on ws", {"targets": ["ws"]}, ["launch"], max_live=None,
                                    max_launches=None, expires=None))
        self.answers = [X.Reply(0, block(kind="nohup", target="ws", name="r", drop=("info_launchers",)), "")]
        rc, text = self.cli("launch", "-T", "ws", "-N", "r", "--", "docker", "run", "--gpus", "all", "img")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("needs: sync", text)
        self.assertIn("lacks info_launchers", text)
        self.assertEqual(len(self.calls), 1)                          # the plan only: nothing launched
        self.assertIn("info_launchers", G.NEEDED["nohup"])
        self.assertNotIn("info_launchers", G.NEEDED["slurm"])         # submit.sh did not change in round 6
        rec = {"id": "p-old", "kind": "nohup", "created_at": L.now(), "target": "ws", "name": "r",
               "block": {k: "" for k in G.NEEDED["nohup"] if k != "info_launchers"}}
        self.assertIn("lacks info_launchers", X.plan_state(self.led, rec))


class Round7(Fixture):
    """R7-5 (N6-launcher-cfg-drift): the launcher config / hostfile files launch.sh's checks read are bound
    (`launch_cfg=<path>:<sha256>[,…]`, before busy_ok): shown on the card, a change since the card refused (exit 6)
    and named; a block without the key needs a sync."""

    H1, H2 = "1" * 64, "2" * 64

    def test_r7_5_the_launcher_config_is_bound_shown_and_a_change_is_named(self):
        """accel-drift: the card said `gpu_ids: 0 in ddp.yaml`; ddp.yaml then said `gpu_ids: 1` (root's busy GPU) and
        the approved launch went out — the WARNING text is digit-masked in warnings_id and the file was not bound.
        Now the file's sha256 is bound: the target's --rs-expect refuses the new bytes (exit 6), and rsk names it."""
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="ad", launch_cfg=f"ddp.yaml:{self.H1}",
                                        warnings=1)]
        rc, text = self.cli("launch", "-T", "ws", "-N", "ad", "--", "accelerate", "launch", "--config_file",
                            "ddp.yaml", "t.py")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn(f"  launch cfg ddp.yaml (sha256 {self.H1[:12]})", text)
        card = text.splitlines()
        self.assertLess(card.index(next(x for x in card if x.startswith("  launch cfg"))),
                        card.index(next(x for x in card if x.startswith("  busy ok"))))   # bound order: before busy_ok
        pid = self.plan_id(text)
        now = block(kind="nohup", target="ws", name="ad", launch_cfg=f"ddp.yaml:{self.H2}", warnings=1)
        self.answers = [X.Reply(6, now + "changed: launch_cfg\n",
                                "ERROR: the resolved submission differs from the approved plan")]
        rc, text = self.cli("launch", "--plan", pid, "--approve", "ok, accelerate on GPU 0 is fine")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn(f"launch_cfg: ddp.yaml (sha256 {self.H1[:12]}) → ddp.yaml (sha256 {self.H2[:12]})", text)
        self.assertEqual(L.attempt_state(self.led.read_run("ad").data["attempts"]["a01"]), "NOT_SUBMITTED")
        self.assertEqual(X._cfgs(f"'a b.yaml:{self.H1},/job/hostfile:unreadable'"),
                         f"a b.yaml (sha256 {self.H1[:12]}) · /job/hostfile (UNREADABLE on the box: what the launcher "
                         "reads there is unknown)")
        self.assertEqual(X._cfgs(""), "")

    def test_r7_5_a_block_without_launch_cfg_needs_a_sync(self):
        G.add(self.led, G.new_grant("anything on ws", {"targets": ["ws"]}, ["launch"], max_live=None,
                                    max_launches=None, expires=None))
        self.answers = [X.Reply(0, block(kind="nohup", target="ws", name="r", drop=("launch_cfg",)), "")]
        rc, text = self.cli("launch", "-T", "ws", "-N", "r", "--", "accelerate", "launch", "t.py")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("needs: sync", text)
        self.assertIn("lacks launch_cfg", text)
        self.assertEqual(len(self.calls), 1)                          # the plan only: nothing launched
        self.assertIn("launch_cfg", G.NEEDED["nohup"])
        self.assertEqual(G.NOHUP_BOUND[G.NOHUP_BOUND.index("launch_cfg") + 1], "busy_ok")
        rec = {"id": "p-old", "kind": "nohup", "created_at": L.now(), "target": "ws", "name": "r",
               "block": {k: "" for k in G.NEEDED["nohup"] if k != "launch_cfg"}}
        self.assertIn("lacks launch_cfg", X.plan_state(self.led, rec))

    def test_r7_5_the_ledger_records_launch_cfg_so_a_relaunch_repeats_it(self):
        """Integration of R7-5 with the ledger: an attempt's request.bound keeps only ledger.BOUND_KEYS, which lacked
        launch_cfg — so the relaunch of a run whose launcher read a config compared '' with the plan's `<path>:<sha256>`
        and every grant-covered relaunch after a reboot was "not the configuration" (needs the user). The key is now
        recorded: the same config relaunches under the grant, an edited one is a new configuration (the user
        decides)."""
        self.assertLessEqual(set(G.SLURM_BOUND) | set(G.NOHUP_BOUND), L.BOUND_KEYS)     # every bound key is recorded
        G.add(self.led, G.new_grant("run and resume accelerate jobs on ws", {"targets": ["ws"],
                                                                            "allow_warnings": "any"},
                                    ["launch", "relaunch"], max_live=None, max_launches=None, expires=None))
        cfg = f"ddp.yaml:{self.H1}"
        started = lambda nonce, words: X.Reply(0, "[ws] started PID 4242 on GPU(s) 1 ; log /h/projects/proj/logs/"   # noqa: E731
                                                  "ad-20261104-120000.log ; pid file /h/x.pid\n", "")
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="ad", launch_cfg=cfg, warnings=1), started]
        rc, text = self.cli("launch", "-T", "ws", "-N", "ad", "--", "accelerate", "launch", "--config_file",
                            "ddp.yaml", "t.py")
        self.assertEqual(rc, OK, text)
        a01 = self.led.read_run("ad").data["attempts"]["a01"]
        self.assertEqual(a01["request"]["bound"].get("launch_cfg"), cfg)
        self.led.observe("ad", "a01", "logs/ad-20261104-120000.log", "REBOOT", "boot_id",
                         end={"state": "REBOOT", "rc": "", "evidence": "boot_id"})
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="ad--a02", launch_cfg=f"ddp.yaml:{self.H2}",
                                        warnings=1)]
        rc, text = self.cli("launch", "--relaunch", "ad")
        self.assertEqual(rc, NEEDS_USER, text)                     # the config changed since a01: the user decides
        self.assertIn("not the configuration of a01", text)
        self.assertIn("launch_cfg", text)
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="ad--a02", launch_cfg=cfg, warnings=1), started]
        rc, text = self.cli("launch", "--relaunch", "ad")
        self.assertEqual(rc, OK, text)                             # the same config: covered as the grant says
        self.assertNotIn("not the configuration", text)

class Nohup(Fixture):
    def started(self, pid: str = "4242"):
        return lambda nonce, words: X.Reply(0, f"[ws] started PID {pid} on GPU(s) 1 ; log /h/projects/proj/logs/"
                                               f"r-20261104-120000.log ; pid file /h/x.pid\n", "")

    def test_a_busy_gpu_is_never_a_grants_call(self):
        G.add(self.led, G.new_grant("anything on ws", {"targets": ["ws"], "allow_warnings": True}, ["launch"],
                                    max_live=None, max_launches=None, expires=None))
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="r", gpus_req="ids=1", info_gpus="1",
                                        busy="1:other:99", busy_ok="1", warnings=1)]
        rc, text = self.cli("launch", "-T", "ws", "-d", "1", "-N", "r", "--gpu-busy-ok", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("ON A BUSY GPU", text)
        self.answers = [self.started()]
        rc, text = self.cli("launch", "--plan", self.plan_id(text), "--approve", "share GPU 1")
        self.assertEqual(rc, OK, text)
        self.assertIn("--gpu-busy-ok", self.calls[-1])
        sub = self.led.read_run("r").data["attempts"]["a01"]["submissions"][0]
        self.assertEqual((sub["proc"]["pid"], sub["proc"]["log"]), ("4242", "logs/r-20261104-120000.log"))

    def test_refusals_on_the_box_are_not_submitted(self):
        self.answers = [self.plan_reply(kind="nohup", target="ws", name="r")]
        rc, text = self.cli("launch", "-T", "ws", "-N", "r", "--", "c")
        pid = self.plan_id(text)
        self.answers = [X.Reply(1, "", "ERROR: asked -n 1 but only 0 GPU id(s) free")]
        rc, text = self.cli("launch", "--plan", pid, "--approve", "go")
        self.assertEqual(rc, PLACEMENT, text)
        self.assertEqual(L.attempt_state(self.led.read_run("r").data["attempts"]["a01"]), "NOT_SUBMITTED")


if __name__ == "__main__":
    unittest.main()
