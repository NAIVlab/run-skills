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


def block(kind="slurm", target="fx", name="exp--train--a--scratch--s0--a01", warnings=0, payload="python t.py",
          **kw) -> str:
    if kind == "slurm":
        bound = [("kind", "slurm"), ("target", target), ("partition", kw.get("partition", "gpu")),
                 ("gres", kw.get("gres", "gpu:1")), ("cpus", "8"), ("mem", "40G"), ("time", "1-00:00:00"),
                 ("account", "''"), ("name", name), ("extra", kw.get("extra", "")), ("payload", payload),   # qw "$@": words
                 ("env_kind", "uv"), ("env_name", "''"), ("wandb_mode", "online"), ("env_hook", kw.get("hook", "''")),
                 ("venv_dir", "''"), ("uv_sync_args", "''"), ("chain", kw.get("chain", "0"))]
        info = [("info_avail", "free:4/max_node:4/gpu_type:any"), ("info_conf_sha256", "a" * 64),
                ("info_source_commit", "none"), ("info_source_dirty", "none")]
    else:
        bound = [("kind", "nohup"), ("target", target), ("name", name), ("gpus_req", kw.get("gpus_req", "n=1")),
                 ("exclude", ""), ("nice", ""), ("busy_ok", kw.get("busy_ok", "")), ("payload", payload.replace(" ", "\\ ")),
                 ("env_kind", "none"), ("env_hook", "''"), ("venv_dir", "''"), ("uv_sync_args", "''"), ("env_name", "''")]
        info = [("info_gpus", kw.get("info_gpus", "1")), ("info_uuids", "GPU-x"), ("info_busy", kw.get("busy", ""))]
    bound = [(k, v) for k, v in bound if k not in kw.get("drop", ())]
    lines = [f"{k}={v}" for k, v in bound]
    h = hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()
    return "\n".join(["@@plan v1", "api=3", *lines, *(f"{k}={v}" for k, v in info), f"warnings={warnings}",
                      f"bound_hash={h}", "@@end"]) + "\n"


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
               "payload": ["python", "t.py"]}
        w = X.submit_words(rec, "n1")
        self.assertEqual(w[:4], ["--rs-attempt", "n1", "--rs-expect", "h" * 64])
        self.assertNotIn("-y", w)
        self.assertEqual(w[-3:], ["--", "python", "t.py"])
        w = X.submit_words({**rec, "warnings": 2, "chain": 3}, "n2")
        self.assertIn("-y", w)
        self.assertIn("--rs-chain", w)
        self.assertLess(w.index("--rs-chain"), w.index("--"))

    def test_gpu_busy_ok_only_when_asked_and_the_card_listed_busy_gpus(self):
        rec = {"kind": "nohup", "bound_hash": "h" * 64, "flags": ["-d", "1", "-N", "r"], "payload": ["c"],
               "gpu_busy_ok": True, "warnings": 1, "block": {"info_busy": "1:u:42", "busy_ok": "1", "info_gpus": "1"}}
        w = X.submit_words(rec, "n")
        self.assertIn("--gpu-busy-ok", w)
        self.assertEqual(w[w.index("-d"):w.index("-d") + 2], ["-d", "1"])        # pinned: the card's own landing
        self.assertEqual(w[4:6], ["--rs-warnings", "1"])                        # the card's count, recounted there
        # the card's landing was free (a busy GPU elsewhere): never --gpu-busy-ok, whatever was asked
        self.assertNotIn("--gpu-busy-ok", X.submit_words({**rec, "block": {"info_busy": "2:u:42", "busy_ok": "",
                                                                           "info_gpus": "1"}}, "n"))
        self.assertNotIn("--gpu-busy-ok", X.submit_words({**rec, "block": {"info_busy": "", "busy_ok": ""}}, "n"))
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
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "--gate-user-asked", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("--gate-user-asked is the user's own OK for a policy gate", text)
        self.assertIn("  policy     --gate-user-asked", text)
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
        self.led.observe("exp--train--a--scratch--s0", "a01", "101", "FAILED", "sacct",
                         end={"state": "FAILED", "rc": "1:0", "evidence": "sacct"})
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
        self.assertIn("  TIME       7-00:00:00 — SBATCH_EXTRA's --time comes after the harness's", text)
        self.assertIn("  RESOURCES  SBATCH_EXTRA asks for --nodes=8", text)

    def test_an_api3_deploy_without_the_new_bound_keys_needs_a_sync(self):
        self.answers = [X.Reply(0, block(drop=("env_hook", "venv_dir", "uv_sync_args")), "", api="api=3")]
        rc, text = self.cli("launch", "-T", "fx", "--", "c")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("needs: sync", text)
        self.assertIn("lacks env_hook, venv_dir, uv_sync_args", text)


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
