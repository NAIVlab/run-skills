"""grants.py: the plan block parser, the record rules (stated limits, none = unlimited), covers()/check() — deny wins,
warnings need the user, resources beyond the scope, sweep approvals per hash, relaunch = the original configuration,
cancel approvals for named jobs vs cancel_own — the after-deny flag, recovery and recount, and `rsk grant`."""

import contextlib
import hashlib
import io
import json
import math
import os
import subprocess
import time
import unittest

from helpers import ScratchHome

from remote_run import cli, harness
from remote_run import grants as G
from remote_run import ledger as L
from remote_run.errors import CONFLICT, NEEDS_USER, OK, REFUSED, USAGE, RskError

SLURM_BOUND = ("kind", "target", "partition", "gres", "cpus", "mem", "time", "account", "name", "extra", "payload",
               "env_kind", "env_name", "wandb_mode", "env_hook", "venv_dir", "uv_sync_args", "conf_extra", "flags",
               "chain")
WID = hashlib.sha256(b"").hexdigest()


def block(**kv: str) -> str:
    """A Slurm plan reply as remote/submit.sh prints it (values %q; bound_hash over kind= … chain=; conf_extra = the
    conf's SBATCH_EXTRA words, extra = the policy's + those; flags = the policy flags; a key given as None is left out:
    an older deploy's block)."""
    base = {"kind": "slurm", "target": "fx", "partition": "gpu", "gres": "gpu:gt-a:2", "cpus": "16", "mem": "64G",
            "time": "1-00:00:00", "account": "''", "name": "exp--train--base--scratch--s0--a01", "extra": "",
            "payload": "python train.py --lr 0.1", "env_kind": "uv", "env_name": "''", "wandb_mode": "online",
            "env_hook": "''", "venv_dir": "''", "uv_sync_args": "''", "conf_extra": "", "flags": "", "chain": "0",
            "warnings": "0",
            "warnings_avail": "0", "warnings_id": WID}
    if "extra" in kv and "conf_extra" not in kv:
        base["conf_extra"] = kv["extra"]
    base.update(kv)
    bound = [f"{k}={base[k]}" for k in SLURM_BOUND if not (k in ("conf_extra", "flags") and base[k] is None)]
    h = kv.get("bound_hash") or hashlib.sha256(("\n".join(bound) + "\n").encode()).hexdigest()
    return ("attempt: .rs/attempts/n\n@@plan v1\napi=3\n" + "".join(ln + "\n" for ln in bound)
            + f"info_avail=''\nwarnings_avail={base['warnings_avail']}\nwarnings_id={base['warnings_id']}\n"
            + f"warnings={base['warnings']}\nbound_hash={h}\n@@end\n")


def plan(plan_id: str = "p-test", **kv: str) -> dict:
    """A parsed block as rsk launch hands it to check(): + the plan id (approvals name plan ids)."""
    return {**G.parse_plan(block(**kv)), "plan_id": plan_id}


def approval(quote: str, plans: list[dict], **kw) -> dict:
    return G.new_approval(plans, plan_ids=[p.get("plan_id", "p-test") for p in plans], **kw)


def state(*recs: dict, runs: dict | None = None, now: float | None = None) -> L.LedgerState:
    return L.LedgerState(grants=list(recs), runs=runs or {}, now=now)


def grant(scope: dict | None = None, actions=("launch",), **lim) -> dict:
    lim = {"max_live": None, "max_launches": None, "expires": None, **lim}
    return G.new_grant(scope or {}, list(actions), **lim)


def old_cancel_ap(target: str, jobs: list[str]) -> dict:
    """A cancel approval as an older rsk cancel recorded it (S5: none is written or read now; it stays valid)."""
    return G.validate({"id": G.new_id("approval"), "kind": "approval", "quote": "cancel job " + " ".join(jobs),
                       "created_at": L.now(), "created_via": "cli", "source": "",
                       "scope": {"jobs": list(jobs), "targets": [target],
                                 "idents": [json.dumps(["slurm", target, j, "", "/r/proj"]) for j in jobs]},
                       "actions": ["cancel"], "limits": {"max_launches": 1, "max_live": None, "expires": G._in(3600)},
                       "used": [], "revoked": None})


def run(*argv: str) -> tuple[int, str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        try:
            rc = cli.main(list(argv))
        except SystemExit as exc:
            rc = exc.code
    return rc, buf.getvalue()


class PlanBlock(unittest.TestCase):
    def test_parse_strict(self):
        p = plan()
        self.assertEqual((p["target"], p["partition"], p["info_avail"]), ("fx", "gpu", "''"))
        self.assertEqual(G.qwords(p["payload"]), ["python", "train.py", "--lr", "0.1"])
        for bad, why in ((block().replace("@@end\n", ""), "no '@@end'"), (block() + block(), "2 '@@plan v1'"),
                         (block().replace("chain=0", "chain=0\nchain=1"), "twice"),
                         (block(bound_hash="xyz"), "bound_hash"), (block(warnings="two"), "warnings"),
                         (block().replace("api=3\n", ""), "missing api"), ("nothing here", "no '@@plan v1'"),
                         (block().replace("cpus=16", "cpus 16"), "not a key=value"),
                         (block(kind="k8s"), "kind"), (block(bound_hash="0" * 64), "does not match"),
                         (block().replace("cpus=16", "cpus=32"), "does not match"),
                         (block().replace("chain=0\n", ""), "no bound list")):
            with self.assertRaises(RskError) as cm:
                G.parse_plan(bad)
            self.assertIn(why, str(cm.exception))
            self.assertEqual(cm.exception.code, USAGE)

    def test_a_block_printed_by_bash(self):   # the contract with rs_bound: %q values, sha256 of the bound lines
        tricky = ["it's", "a b", "line\nbreak", "tab\there", "$HOME", "", "naïve"]
        sh = ("w() { local s; s=$(printf ' %q' \"$@\"); printf %s \"${s# }\"; }\n"
              "b=$(printf 'kind=nohup\\ntarget=%q\\nname=%s\\ngpus_req=%s\\nexclude=%s\\nnice=%s\\npayload=%q\\n"
              "env_kind=%q\\nenv_name=%q\\n' box exp--a01 n=2 '' '' \"$1\" uv '')\n"
              "h=$(printf '%s\\n' \"$b\" | sha256sum | cut -d' ' -f1)\n"
              "printf '@@plan v1\\napi=3\\n%s\\ninfo_gpus=0,1\\nextra_words=%s\\nwarnings=0\\nbound_hash=%s\\n@@end\\n' "
              "\"$b\" \"$(shift; w \"$@\")\" \"$h\"\n")
        for loc in ("C", "C.UTF-8"):                    # the C locale prints non-ASCII as $'\ooo' bytes
            done = subprocess.run(["bash", "-c", sh, "_", "python -c 'print(1)' > out.txt", *tricky],
                                  capture_output=True, env={**os.environ, "LC_ALL": loc})
            if done.returncode != 0 or b"bound_hash=" not in done.stdout:
                self.skipTest(f"bash/sha256sum unavailable: {done.stderr[:100]!r}")
            p = G.parse_plan(done.stdout.decode("utf-8"))
            self.assertEqual(G.unq(p["payload"]), "python -c 'print(1)' > out.txt")
            self.assertEqual(G.qwords(p["extra_words"]), tricky, loc)
            self.assertEqual((p["exclude"], G.unq(p["env_name"]), G.facts(p).gpus), ("", "", 2))

    def test_bash_q_values(self):   # the forms `printf %q` prints (bash 5.2), decoded without evaluating anything
        self.assertEqual(G.qwords("python\\ a.py --x 1"), ["python a.py", "--x", "1"])
        self.assertEqual(G.qwords("$'a\\nb' c"), ["a\nb", "c"])
        self.assertEqual(G.qwords("x$'\\t'y"), ["x\ty"])
        self.assertEqual(G.qwords("''"), [""])
        self.assertEqual(G.qwords("a\\$HOME \\;rm"), ["a$HOME", ";rm"])
        self.assertEqual(G.qwords("$'\\101\\x42'"), ["AB"])
        self.assertEqual(G.qwords("$'na\\303\\257ve'"), ["naïve"])           # bash %q in the C locale: UTF-8 bytes
        self.assertEqual(G.unq("gpu"), "gpu")
        with self.assertRaises(RskError):
            G.unq("a b")
        with self.assertRaises(RskError):
            G.qwords("$'open")

    def test_facts(self):
        f = G.facts(plan())
        self.assertEqual((f.gpu_type, f.gpus, f.cpus, f.mem_gb, f.time_s, f.cls, f.run),
                         ("gt-a", 2, 16, 64.0, 86400, "train", "exp--train--base--scratch--s0"))
        self.assertEqual(G.facts(plan(gres="gpu:4")).gpu_type, "any")
        self.assertEqual((G.facts(plan(gres="")).gpu_type, G.facts(plan(gres="")).gpus), ("", 0))
        self.assertEqual(G.facts(plan(gres="--gres=gpu:gt-b:8")).gpus, 8)
        self.assertEqual(G.facts({**plan(), "class": "smoke"}).cls, "train")       # the name's class wins
        self.assertEqual(G.facts({**plan(), "class": "smoke"}).classes, ("train", "smoke"))
        self.assertEqual(G.facts({**plan(name="exp-plain--a01"), "class": "smoke"}).cls, "smoke")   # a label
        self.assertEqual(G.facts(plan(gres="gpu:x:y")).unreadable, ("gres",))
        box = G.facts({"kind": "nohup", "target": "box", "name": "e", "gpus_req": "ids=0,2", "warnings": "0"})
        self.assertEqual((box.gpus, box.time_s, box.partition), (2, math.inf, None))
        self.assertEqual(G.facts({"kind": "nohup", "gpus_req": "n=3"}).gpus, 3)

    def test_slurm_units(self):   # sbatch(1) --time / --mem forms
        for t, s in (("30", 1800), ("30:15", 1815), ("2:00:00", 7200), ("1-12", 129600), ("1-00:30", 88200),
                     ("2-00:00:00", 172800)):
            self.assertEqual(G.slurm_seconds(t), s, t)
        self.assertEqual(G.slurm_seconds("UNLIMITED"), math.inf)
        with self.assertRaises(ValueError):
            G.slurm_seconds("1h")
        self.assertEqual([G.slurm_mem_gb(m) for m in ("2048", "512M", "64G", "1T")], [2.0, 0.5, 64.0, 1024.0])
        self.assertEqual(G.slurm_mem_gb("0"), math.inf)


class Records(unittest.TestCase):
    def test_a_standing_grant_states_all_three_limits(self):
        g = grant()                                                 # all three none: stated, not omitted
        self.assertEqual(g["limits"], {"max_live": None, "max_launches": None, "expires": None})
        for k in G.GRANT_LIMITS:
            bad = json.loads(json.dumps(g))
            del bad["limits"][k]
            with self.assertRaises(RskError) as cm:
                G.validate(bad)
            self.assertIn(f"limits.{k} is required", str(cm.exception))

    def test_validation_errors(self):
        g = grant()
        for change, why in (({"quote": 5}, "quote"), ({"kind": "maybe"}, "kind"), ({"extra": 1}, "unknown key"),
                            ({"actions": ["launch", "fly"]}, "actions"), ({"actions": ["cancel"]}, "cancel_own"),
                            ({"scope": {"max_gpus": -1}}, "max_gpus"), ({"scope": {"color": ["x"]}}, "scope key"),
                            ({"limits": {"max_live": 0, "max_launches": None, "expires": None}}, "max_live"),
                            ({"limits": {"max_live": None, "max_launches": None, "expires": "soon"}}, "expires"),
                            ({"created_via": "import", "source": ""}, "source"),
                            ({"revoked": {"at": "x"}}, "revoked")):
            with self.assertRaises(RskError) as cm:
                G.validate({**g, **change})
            self.assertIn(why, str(cm.exception), change)
        with self.assertRaises(RskError) as cm:
            G.new_deny({"max_gpus": 4})
        self.assertIn("a deny takes", str(cm.exception))
        with self.assertRaises(RskError):
            G.validate({**approval("ok", [plan()]), "scope": {}})
        with self.assertRaises(RskError):
            G.validate({**old_cancel_ap("fx", ["5"]), "scope": {"targets": ["fx"]}})
        for words in ({}, {"quote": ""}, {"quote": "the user's words, as an older rsk kept them"}):   # S4: optional
            rec = {k: v for k, v in g.items() if k != "quote"}
            self.assertEqual(G.valid({**rec, **words}), "", words)
        self.assertNotIn("quote", g)                                         # S4: never written
        self.assertEqual(G.valid({**g, "revoked": {"at": L.now()}}), "")     # a revocation needs no words
        missing = dict(g)
        del missing["source"]
        with self.assertRaises(RskError):
            G.validate(missing)


class Covers(unittest.TestCase):
    def test_deny_wins(self):
        st = state(grant({"targets": ["fx"]}), approval("yes", [plan()]),
                   G.new_deny({"partitions": ["gpu"]}))
        d = G.check(st, "launch", plan=plan())
        self.assertFalse(d.covered)
        self.assertTrue(d.denied)
        self.assertEqual(d.code, REFUSED)
        self.assertEqual(d.reasons[0], f"denied by {st.grants[2]['id']}")          # S4: no words recorded
        self.assertEqual(d.needs, "")
        older = {**st.grants[2], "quote": "never on gpu"}                          # an older record's words: shown
        self.assertIn('"never on gpu"', G.check(state(older), "launch", plan=plan()).reasons[0])
        other = G.check(st, "launch", plan=plan(partition="part-c"))   # outside the deny: the grant
        self.assertEqual((other.covered, other.record["kind"]), (True, "grant"))
        st2 = state(grant(), G.new_deny({"gpu_types": ["gt-b"]}))
        self.assertTrue(G.check(st2, "launch", plan=plan(gres="gpu:4")).denied)     # any type may land on gt-b
        self.assertTrue(G.check(st2, "launch", plan=plan()).covered)                # gt-a is not gt-b
        self.assertFalse(G.check(state(grant(), G.new_deny({"names": ["exp*"]}, ["cancel"])), "launch",
                                 plan=plan()).denied)                               # a deny of other actions

    def test_grant_scope(self):
        g = grant({"targets": ["fx"], "partitions": ["gpu"], "gpu_types": ["GT-A"], "max_gpus": 2, "max_cpus": 16,
                   "max_mem_gb": 64, "max_time_s": 86400, "classes": ["train"], "names": ["exp--*"]})
        st = state(g)
        self.assertTrue(G.check(st, "launch", plan=plan()).covered)
        for kv, why in (({"target": "other"}, "target other"), ({"partition": "part-b"}, "partition part-b"),
                        ({"gres": "gpu:gt-b:2"}, "GPU type gt-b"), ({"gres": "gpu:gt-a:4"}, "4 GPUs > 2"),
                        ({"gres": "gpu:2"}, "not requested"), ({"cpus": "32"}, "32 CPUs > 16"),
                        ({"mem": "128G"}, "128 GB memory > 64"), ({"time": "2-00:00:00"}, "time"),
                        ({"mem": "0"}, "unlimited GB"), ({"name": "exp--eval--x--none--s0--a01"}, "class eval"),
                        ({"name": "other--train--x--scratch--s0"}, "matches none")):
            d = G.check(st, "launch", plan=plan(**kv))
            self.assertFalse(d.covered, kv)
            self.assertEqual(d.code, NEEDS_USER)
            self.assertIn(why, " ".join(d.reasons), kv)
            self.assertTrue(d.needs.startswith("approval"))
        self.assertFalse(G.check(st, "relaunch", plan=plan(), run="exp").covered)    # action not granted

    def test_warnings_are_never_covered_by_default(self):
        warned = plan(warnings="1")
        d = G.check(state(grant()), "launch", plan=warned)
        self.assertFalse(d.covered)
        self.assertIn("warning", " ".join(d.reasons))
        self.assertTrue(G.check(state(grant({"allow_warnings": True})), "launch", plan=warned).covered)   # true = any
        self.assertFalse(G.check(state(approval("ok", [warned])), "launch", plan=warned).covered)
        self.assertTrue(G.check(state(approval("ok", [warned], allow_warnings=True)), "launch",
                                plan=warned).covered)

    def test_none_limits_are_unlimited_and_numbers_are_budgets(self):
        g = grant(max_live=None, max_launches=None, expires=None)
        g["used"] = [{"nonce": f"n{i}", "action": "launch", "hash": "", "job": "", "at": L.now()} for i in range(500)]
        runs = {"r": {"run": "r", "attempts": {f"a{i:02d}": {"target": "fx", "request": {"grant": g["id"]},
                                                              "submissions": [{"submit": "submitted"}]}
                                               for i in range(1, 60)}}}
        self.assertTrue(G.check(state(g, runs=runs), "launch", plan=plan()).covered)
        capped = grant(max_live=2, max_launches=3, expires=None)
        capped["used"] = g["used"][:3]
        self.assertIn("used 3 of 3 launches", " ".join(G.check(state(capped), "launch", plan=plan()).reasons))
        capped["used"] = g["used"][:1]
        runs2 = {"r": {"run": "r", "attempts": {k: {**a, "request": {"grant": capped["id"]}} for k, a in
                                                list(runs["r"]["attempts"].items())[:2]}}}
        self.assertIn("2 of 2 live runs", " ".join(G.check(state(capped, runs=runs2), "launch", plan=plan()).reasons))
        ended = {"r": {"run": "r", "attempts": {k: {**a, "result": {"state": "COMPLETED"}} for k, a in
                                                runs2["r"]["attempts"].items()}}}
        self.assertTrue(G.check(state(capped, runs=ended), "launch", plan=plan()).covered)
        cancel_uses = [{"nonce": "c1", "action": "cancel_own", "hash": "", "job": "9", "at": L.now()}] * 1
        mixed = grant(actions=("launch", "cancel_own"), max_live=None, max_launches=1, expires=None)
        mixed["used"] = cancel_uses
        self.assertTrue(G.check(state(mixed), "launch", plan=plan()).covered)          # a cancel is not a launch

    def test_expiry_and_revocation(self):
        g = grant(max_live=None, max_launches=None, expires="2026-01-31")
        self.assertTrue(G.check(state(g, now=time.mktime((2026, 1, 31, 23, 0, 0, 0, 0, -1))), "launch",
                                plan=plan()).covered)                               # through the end of that day
        self.assertIn("expired", G.check(state(g, now=time.mktime((2026, 2, 1, 0, 30, 0, 0, 0, -1))), "launch",
                                         plan=plan()).reasons[0])
        r = grant()
        r["revoked"] = {"at": L.now(), "quote": "stop that"}
        self.assertFalse(G.check(state(r), "launch", plan=plan()).covered)
        d = G.new_deny({})
        d["revoked"] = {"at": L.now(), "quote": "ok again"}
        self.assertTrue(G.check(state(d, grant()), "launch", plan=plan()).covered)

    def test_sweep_approval_is_consumed_per_hash(self):
        p1, p2 = plan(), plan(name="exp--train--base--scratch--s1--a01")
        H1 = p1["bound_hash"]
        ap = approval("run both seeds", [p1, p2])
        st = state(ap)
        self.assertTrue(G.check(st, "launch", plan=p1).covered)
        self.assertFalse(G.check(st, "launch", plan=plan(name="exp--train--base--scratch--s2--a01")).covered)
        ap["used"].append({"nonce": "n1", "action": "launch", "hash": H1, "job": "", "at": L.now()})
        self.assertIn("used 1 time", " ".join(G.check(st, "launch", plan=p1).reasons))
        self.assertTrue(G.check(st, "launch", plan=p2).covered)
        chain = approval("a chain of 3", [p1], actions=("launch", "chain"), launches=3)
        chain["used"] = [{"nonce": f"c{i}", "action": "chain", "hash": H1, "job": "", "at": L.now()} for i in range(2)]
        self.assertTrue(G.check(state(chain), "chain", plan=p1).covered)
        chain["used"].append({"nonce": "c9", "action": "chain", "hash": H1, "job": "", "at": L.now()})
        self.assertFalse(G.check(state(chain), "chain", plan=p1).covered)
        self.assertTrue(G.check(state(approval("x", [p1])), "launch", plan=p1).record["kind"] == "approval")

    def test_relaunch_needs_the_original_configuration(self):
        orig = plan()
        att = {"name": "exp--train--base--scratch--s0--a01", "target": "fx", "kind": "slurm",
               "request": {"action": "launch", "plan": "p-1", "bound_hash": orig["bound_hash"], "bound": G.bound(orig)},
               "submissions": [{"nonce": "n1", "submit": "submitted", "job": "5"}], "result": {"state": "PREEMPTED"}}
        runs = {"exp--train--base--scratch--s0": {"run": "exp--train--base--scratch--s0", "attempts": {"a01": att}}}
        g = grant(actions=("relaunch",))         # relaunch without launch: an infrastructure end, the same config
        g["actions"].append("resubmit")          # (a record from before `rsk grant add` refused it: still valid)
        st = state(g, runs=runs)
        again = plan(name="exp--train--base--scratch--s0--a02")   # the name is bound: a new hash
        self.assertNotEqual(again["bound_hash"], orig["bound_hash"])
        self.assertTrue(G.check(st, "relaunch", plan=again, run="exp--train--base--scratch--s0").covered)
        changed = plan(name="exp--train--base--scratch--s0--a02", payload="python train.py --lr 1")
        d = G.check(st, "relaunch", plan=changed, run="exp--train--base--scratch--s0")
        self.assertFalse(d.covered)
        self.assertIn("not the configuration of a01 it resumes: payload", " ".join(d.reasons))
        more = plan(name="exp--train--base--scratch--s0--a02", gres="gpu:gt-a:4")
        self.assertIn("gres", " ".join(G.check(st, "resubmit", plan=more, run="exp--train--base--scratch--s0").reasons))
        self.assertTrue(G.check(state(g, approval("yes, with lr 1", [changed]), runs=runs), "launch",
                                plan=changed).covered)                              # the user approved the change
        adopted = {"r": {"run": "r", "attempts": {"a01": {**att, "request": {"action": "adopted"}}}}}
        self.assertIn("no recorded plan", " ".join(G.check(state(g, runs=adopted), "relaunch",
                                                           plan=plan(name="r--a02"), run="r").reasons))

    def test_s5_a_cancel_needs_no_record_for_a_live_ledger_run_and_the_users_ok_otherwise(self):
        own = {"name": "exp--a01", "target": "fx", "kind": "slurm",
               "request": {"action": "launch", "plan": "p-1", "bound": {"partition": "gpu"}},
               "submissions": [{"nonce": "n1", "submit": "submitted", "job": "7"}]}
        adopted = {**own, "request": {"action": "adopted"}, "submissions": [{"nonce": "x", "submit": "adopted", "job": "8"}]}
        ended = {**own, "submissions": [{"nonce": "e", "submit": "submitted", "job": "9", "end": {"state": "FAILED"}}],
                 "result": {"state": "FAILED"}}
        runs = {"exp": {"run": "exp", "attempts": {"a01": own, "a02": adopted, "a03": ended}}}
        st = state(runs=runs)                                          # no record at all
        for job in ("7", "8"):                                          # launched by rsk, or adopted: the agent's own
            d = G.check(st, "cancel", job=job, run="exp")
            self.assertEqual((d.covered, d.record, d.code), (True, None, 0), job)
        d = G.check(st, "cancel", job="9", run="exp")                    # the ledger shows it ended: the user's call
        self.assertEqual((d.covered, d.denied, d.code), (False, False, NEEDS_USER))
        self.assertIn("--approve", d.needs)
        d = G.check(st, "cancel", job="123", plan={"target": "fx"})     # a job the ledger does not know
        self.assertEqual((d.covered, d.code), (False, NEEDS_USER))
        self.assertIn("a job the ledger does not know", " ".join(d.reasons))
        self.assertTrue(G.check(st, "cancel", job="123", plan={"target": "fx"}, approved=True).covered)
        self.assertTrue(G.check(st, "cancel", job="9", run="exp", approved=True).covered)
        for deny in (G.new_deny({}, ["cancel"]), G.new_deny({"names": ["exp*"]}, ["cancel"])):
            for job, ok in (("7", False), ("123", True)):               # a deny of cancel: always, approved or not
                d = G.check(state(deny, runs=runs), "cancel", job=job, run="exp" if job == "7" else "",
                            plan={"target": "fx"}, approved=ok)
                self.assertTrue(d.denied, (deny["scope"], job))
                self.assertEqual(d.code, REFUSED)
        own_deny = G.new_deny({}, ["cancel_own"])                      # the agent's own discretion is off …
        d = G.check(state(own_deny, runs=runs), "cancel", job="7", run="exp")
        self.assertTrue(d.denied)
        self.assertIn("only the user's OK", " ".join(d.reasons))
        self.assertTrue(G.check(state(own_deny, runs=runs), "cancel", job="7", run="exp", approved=True).covered)
        g = grant({"targets": ["fx"]}, actions=("launch", "cancel_own"), max_launches=1)   # still valid, not needed
        self.assertEqual(G.valid(g), "")
        self.assertIn("launches 0/1", G.balance(g, state(g)))
        self.assertNotIn("cancels", G.balance(g, state(g)))
        old = old_cancel_ap("fx", ["123"])                             # an older cancel approval: valid, never read
        self.assertEqual(G.valid(old), "")
        self.assertFalse(G.check(state(old), "cancel", job="123", plan={"target": "fx"}).covered)
        self.assertIn("cancel of job(s) 123", G.describe(old))
        with self.assertRaises(RskError):
            G.covers({"target": "fx"}, "cancel", state())              # covers() is for launches only
        bad = grant()
        bad["limits"]["expires"] = "someday"                           # a hand-edited file: invalid, covers nothing
        d = G.check(state(bad), "launch", plan=plan())
        self.assertFalse(d.covered)
        self.assertIn("INVALID record covers nothing", d.reasons[0])

    def test_after_deny_flag(self):
        d = G.new_deny({"partitions": ["gpu"]})
        g = grant({"partitions": ["gpu", "part-c"]})
        self.assertIn(f"after deny {d['id']}", G.after_deny(g, [d])[0])
        self.assertEqual(G.after_deny(grant({"partitions": ["part-c"]}), [d]), [])          # disjoint
        old = {**d, "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 7200))}
        self.assertEqual(G.after_deny(g, [old]), [])
        old["revoked"] = {"at": L.now(), "quote": "fine"}
        self.assertIn("was revoked", G.after_deny(g, [old])[0])
        self.assertEqual(G.after_deny(d, [d]), [])
        self.assertEqual(G.after_deny(g, [g, d]), [])                 # the deny came after it
        self.assertTrue(G.after_deny(g, [d, g]))

    def test_describe_says_what_it_covers(self):
        self.assertEqual(G.describe(grant({"targets": ["fx"], "max_gpus": 4, "max_time_s": 7200})),
                         "launch: targets fx; <= 4 GPUs; <= 2:00:00; no plan with warnings; a relaunch after any end "
                         "too, judged as a launch (never while an earlier attempt may be live)")
        self.assertIn("2 approved plan(s)", G.describe(approval("ok", [plan(), plan(name="x--a01")])))
        self.assertIn("cancel of job(s) 5", G.describe(old_cancel_ap("fx", ["5"])))
        self.assertEqual(G.describe(G.new_deny({"names": ["x*"]})), "DENY every action: names x*")
        self.assertEqual(G.describe(G.new_deny({}, ["cancel"])), "DENY cancel: anything")
        self.assertIn("no limit (user's words)", G.balance(grant(), state()))


class ReviewFixes(unittest.TestCase):
    """The P3 review findings, each pinned (H2 H3 M1 M2 M5 L1 L5 and `resubmit` in a new grant)."""

    def test_h2_s3_sbatch_extra_time_is_capped_and_its_other_words_are_covered(self):
        f = G.facts(plan(extra="--time=7-00:00:00 --qos=normal -t 2:00:00"))
        self.assertEqual((f.time_s, f.time_extra, f.extra_res),     # time: the bound field (D1: the words decide)
                         (86400, "2:00:00", ("--time=7-00:00:00", "-t", "2:00:00")))
        f = G.facts(plan(extra="--nodes=8 --gpus-per-node=4 --mem-per-c=2G -N2 --exclude=n1 --mem=9G -n 4"))
        self.assertEqual(f.extra_res, ("--nodes=8", "--gpus-per-node=4", "--mem-per-c=2G", "-N2", "--mem=9G", "-n", "4"))
        self.assertEqual(G.facts(plan(extra="--tim=5")).extra_res, ("--tim=5",))         # an abbreviation: anything else
        capped = grant({"max_time_s": 3600, "max_gpus": 2}, max_live=None, max_launches=None, expires=None)
        d = G.check(state(capped), "launch", plan=plan(time="30", extra="--time=7-00:00:00"))
        self.assertFalse(d.covered)
        self.assertIn("7-00:00:00 time > 1:00:00", " ".join(d.reasons))   # max_time_s: every limit sbatch could read
        open_ = grant({"targets": ["fx"]})                          # S3: the extra words are the grant's call too
        self.assertTrue(G.check(state(open_), "launch", plan=plan(extra="--nodes=8 --gpus-per-node=4")).covered)
        p = plan(extra="--nodes=8")
        self.assertTrue(G.check(state(approval("yes, 8 nodes", [p])), "launch", plan=p).covered)   # the user saw it
        self.assertTrue(G.check(state(open_), "launch", plan=plan(extra="--qos=normal --exclude=n1")).covered)

    def test_h3_the_names_class_decides_and_a_deny_matches_either(self):
        smoke = grant({"classes": ["smoke"]})
        train_name = {**plan(), "class": "smoke"}                   # name exp--train--…, labelled smoke
        d = G.check(state(smoke), "launch", plan=train_name)
        self.assertFalse(d.covered)
        self.assertIn("class train not in smoke", " ".join(d.reasons))
        deny = G.new_deny({"classes": ["train"]})
        self.assertTrue(G.check(state(smoke, deny), "launch", plan=train_name).denied)
        labelled = {**plan(name="exp-plain--a01"), "class": "train"}
        self.assertTrue(G.check(state(grant(), deny), "launch", plan=labelled).denied)     # the label alone
        self.assertFalse(G.check(state(grant(), deny), "launch",
                                 plan={**plan(name="exp--smoke--x--a01")}).denied)

    def test_m1_a_deny_of_launch_stops_every_way_of_starting_a_run(self):
        deny = G.new_deny({"targets": ["fx"]}, ["launch"])
        g = grant(actions=("launch", "chain", "relaunch"))
        g["actions"].append("resubmit")
        for action in ("launch", "chain", "relaunch", "resubmit"):
            self.assertTrue(G.check(state(g, deny), action, plan=plan(), run="exp").denied, action)
        self.assertFalse(G.check(state(g, deny), "cancel", job="5", plan={"target": "fx"}).denied)
        only_chain = G.new_deny({}, ["chain"])
        self.assertFalse(G.check(state(g, only_chain), "launch", plan=plan()).denied)

    def test_m2_deny_names_match_the_run_id_grants_the_name_only(self):
        deny = G.new_deny({"names": ["exp--train--big"]})
        for name in ("exp--train--big", "exp--train--big--a01", "exp--train--big--a02"):
            for action in ("launch", "relaunch"):
                self.assertTrue(G.check(state(grant(actions=("launch", "relaunch")), deny), action,
                                        plan=plan(name=name), run="exp--train--big").denied, (name, action))
        g = grant({"names": ["exp--train--big"]})
        self.assertFalse(G.check(state(g), "launch", plan=plan(name="exp--train--big--a01")).covered)   # fails closed
        self.assertTrue(G.check(state(grant({"names": ["exp--train--big*"]})), "launch",
                                plan=plan(name="exp--train--big--a01")).covered)

    def test_m5_an_approval_names_its_plans_and_expires_with_them(self):
        p = plan(plan_id="p-1")
        ap = approval("yes run it", [p])
        self.assertEqual(ap["scope"]["plans"], ["p-1"])
        self.assertTrue(G.check(state(ap), "launch", plan=p).covered)
        again = {**p, "plan_id": "p-2"}                              # the same configuration, planned later
        d = G.check(state(ap), "launch", plan=again)
        self.assertFalse(d.covered)
        self.assertIn("not one of the approved plans (p-2 not in p-1)", " ".join(d.reasons))
        self.assertFalse(G.check(state(ap, now=time.time() + G.APPROVAL_TTL_S + 60), "launch", plan=p).covered)
        old = {k: v for k, v in ap.items()}
        old["scope"] = {k: v for k, v in ap["scope"].items() if k != "plans"}
        old["limits"] = {**ap["limits"], "expires": None}            # an approval from before plan scoping
        self.assertIn("scope.plans", G.valid(old))
        self.assertFalse(G.check(state(old), "launch", plan=p).covered)

    def test_l1_an_invalid_record_covers_nothing_an_invalid_deny_matches_everything(self):
        quoteless = {"id": "g-x", "kind": "grant", "scope": {"targets": ["fx"]}, "actions": ["launch"], "used": [],
                     "revoked": None}
        d = G.check(state(quoteless), "launch", plan=plan())
        self.assertFalse(d.covered)
        self.assertIn("INVALID record covers nothing", d.reasons[0])
        bad_deny = {"id": "d-x", "kind": "deny", "quote": "never", "scope": {"targets": ["elsewhere"]},
                    "actions": ["launch"]}                           # malformed (keys missing): matches everything
        d = G.check(state(grant(), bad_deny), "launch", plan=plan())
        self.assertTrue(d.denied)
        self.assertIn("matches everything", d.reasons[0])
        self.assertTrue(any("INVALID" in ln for ln in G.lines(state(grant(), bad_deny))))

    def test_l5_a_chain_segment_does_not_count_its_own_attempt_against_max_live(self):
        g = grant(actions=("chain",), max_live=1, max_launches=10, expires=None)
        runs = {"r": {"run": "r", "attempts": {"a01": {"target": "fx", "request": {"grant": g["id"]},
                                                      "submissions": [{"nonce": "n1", "submit": "submitted"}]}}}}
        self.assertFalse(G.check(state(g, runs=runs), "chain", plan=plan()).covered)
        self.assertTrue(G.check(state(g, runs=runs), "chain", plan=plan(), extending=("r", "a01")).covered)
        self.assertFalse(G.check(state(g, runs=runs), "chain", plan=plan(), extending=("r", "a02")).covered)

    def test_resubmit_is_not_a_new_standing_grants_action(self):
        with self.assertRaises(RskError) as c:
            grant(actions=("launch", "resubmit"))
        self.assertIn("'resubmit' is not a standing grant's action", str(c.exception))
        self.assertIn("resubmit", G.new_deny({}, ["resubmit"])["actions"])


class Round3(unittest.TestCase):
    """The round-2 findings on grants.py, each pinned (grants#1 grants#2 grants#3 grants#7 grants#8 grants#10 grants#11, r1-2 r1-4 r1-5 r1-6,
    g3-flow-1) and the round-3 decisions D1 D2 D3 D5 D6."""

    def test_d1_conf_extra_allowlist_exact_grammar(self):
        ok = ("--qos=x -q x -qx --account a -A a -Aa --exclude n1 -x n1 --constraint c -C c --reservation r "
              "--signal B:USR1@300 --mail-type END --mail-user u@x --comment hi --dependency=singleton "
              "--dependency singleton -d singleton -dsingleton --requeue --no-requeue --nice --nice=5")
        self.assertEqual(G.conf_extra_bad(ok.split()), [])
        for words, bad in ((["--comment", "-t1"], []),                       # the value word, whatever it is (grants#1)
                           (["--mail-user", "-t5"], []),
                           (["--time=7-00:00:00", "--comment", "-t1"], ["--time=7-00:00:00"]),
                           (["--core-spec=1"], ["--core-spec=1"]), (["-S", "1"], ["-S", "1"]),       # grants#3
                           (["--thread-spec=1"], ["--thread-spec=1"]), (["--exclusive"], ["--exclusive"]),
                           (["-L", "lic"], ["-L", "lic"]), (["--clusters=c"], ["--clusters=c"]),
                           (["--qo=normal"], ["--qo=normal"]), (["--dep=singleton"], ["--dep=singleton"]),  # abbrevs
                           (["-d", "afterok:5"], ["-d afterok:5"]), (["--dependency=after:1"], ["--dependency=after:1"]),
                           (["--requeue=1"], ["--requeue=1"]), (["--nice", "5"], ["5"]),   # --nice never takes a word
                           (["--nice=x"], ["--nice=x"]), (["--qos"], ["--qos (no value)"]), (["-q"], ["-q (no value)"]),
                           (["bare"], ["bare"]), (["--nodes=2"], ["--nodes=2"]), (["-N2"], ["-N2"])):
            self.assertEqual(G.conf_extra_bad(words), bad, words)

    def test_d1_s3_conf_extra_words_are_covered_and_only_time_is_capped(self):
        open_ = grant({"targets": ["fx"], "max_time_s": 3600})
        d = G.check(state(open_), "launch", plan=plan(time="30", extra="--time=7-00:00:00 --comment -t1"))
        self.assertFalse(d.covered)
        self.assertIn("time > 1:00:00", " ".join(d.reasons))
        for extra in ("--thread-spec=1", "-S 1", "--core-spec=1", "--exclusive", "--nodes=2"):
            p = plan(time="30", extra=extra)
            self.assertTrue(G.facts(p).extra_res, extra)                  # the card still NOTEs them
            self.assertTrue(G.check(state(open_), "launch", plan=p).covered, extra)
            self.assertTrue(G.check(state(approval("yes, as shown", [p])), "launch", plan=p).covered)  # the card
        self.assertTrue(G.check(state(open_), "launch", plan=plan(time="30", extra="--comment -t1")).covered)
        pinned = plan(time="30", extra="--nodelist=n1", conf_extra="")     # a site policy's SB_ARGS word (grants#8)
        self.assertTrue(G.check(state(open_), "launch", plan=pinned).covered)
        old = plan(time="30", conf_extra=None)                               # a block from before conf_extra
        self.assertNotIn("conf_extra", old)
        self.assertTrue(G.check(state(open_), "launch", plan=old).covered)

    def test_d2_g2_2_r1_5_a_zero_time_is_unlimited(self):
        for t in ("0", "0:0", "00:00:00", "0-0", "0-00:00:00", "UNLIMITED", "infinite"):
            self.assertEqual(G.slurm_seconds(t), math.inf, t)
        capped = grant({"max_time_s": 3600})
        for t in ("0", "0:0", "00:00:00", "0-0"):
            d = G.check(state(capped), "launch", plan=plan(time=t))
            self.assertFalse(d.covered, t)
            self.assertIn("unlimited time > 1:00:00", " ".join(d.reasons), t)
        self.assertEqual(G.slurm_seconds("0:30"), 30)

    def test_a_policy_time_is_held_to_max_time_too(self):
        """A site policy's --time (in extra, never in conf_extra: no D1 word) comes after the harness's and wins in
        sbatch: a grant's max_time_s holds for it (and for every other time sbatch could read), fail closed."""
        capped = grant({"max_time_s": 3600})
        self.assertTrue(G.check(state(capped), "launch", plan=plan(time="30", extra="", conf_extra="")).covered)
        for extra in ("--time=7-00:00:00", "-t 2:00:00", "-t2:00:00", "--tim=0", "--comment -t2:00:00 --time=30"):
            p = plan(time="30", extra=extra, conf_extra="")            # the policy's words alone
            d = G.check(state(capped), "launch", plan=p)
            self.assertFalse(d.covered, extra)
            self.assertIn("time > 1:00:00", " ".join(d.reasons), extra)
            self.assertTrue(G.check(state(approval("yes, as the card shows", [p])), "launch", plan=p).covered)
        p = plan(time="30", extra="--time=45 --comment=x", conf_extra="")
        self.assertEqual((G.facts(p).time_s, G.facts(p).time_max_s), (1800, 2700))
        self.assertTrue(G.check(state(capped), "launch", plan=p).covered)  # within the cap: still the grant's call
        d = G.check(state(capped), "launch", plan=plan(time="30", extra="--time=soon", conf_extra=""))
        self.assertFalse(d.covered)
        self.assertIn("unreadable plan field(s): extra", " ".join(d.reasons))

    def test_d3_r1_4_allow_warnings_kinds(self):
        avail = plan(warnings="1", warnings_avail="1")
        policy = plan(warnings="2", warnings_avail="1")           # + a charged-partition gate of the policy
        only_policy = plan(warnings="1", warnings_avail="0")
        a = state(grant({"allow_warnings": "availability"}))
        self.assertTrue(G.check(a, "launch", plan=avail).covered)
        for p in (policy, only_policy):
            d = G.check(a, "launch", plan=p)
            self.assertFalse(d.covered)
            self.assertIn("the scope allows only the availability gate's", " ".join(d.reasons))
        for aw in ("any", True):                                   # a stored true reads as any
            for p in (avail, policy, only_policy):
                self.assertTrue(G.check(state(grant({"allow_warnings": aw})), "launch", plan=p).covered)
        self.assertFalse(G.check(state(grant({"allow_warnings": False})), "launch", plan=avail).covered)
        self.assertIn("allow_warnings must be one of", G.valid({**grant(), "scope": {"allow_warnings": "maybe"}}))
        self.assertIn("only warnings are the availability gate's", G.describe(grant({"allow_warnings": "availability"})))
        self.assertIn("policy gates included", G.describe(grant({"allow_warnings": "any"})))
        nowid = plan(warnings="1")
        self.assertFalse(G.check(state(grant({"allow_warnings": "availability"})), "launch",
                                 plan={k: v for k, v in nowid.items() if k != "warnings_avail"}).covered)

    def _runs(self, end: str | None, live: bool = False) -> dict:
        orig = plan()
        att = {"name": "exp--train--base--scratch--s0--a01", "target": "fx", "kind": "slurm",
               "request": {"action": "launch", "plan": "p-1", "bound_hash": orig["bound_hash"], "bound": G.bound(orig),
                           "class": "train"},
               "submissions": [{"nonce": "n1", "submit": "submitted", "job": "5"}],
               "result": None if live else {"state": end}}
        return {"exp--train--base--scratch--s0": {"run": "exp--train--base--scratch--s0", "attempts": {"a01": att}}}

    def test_d5_r1_2_a_relaunch_only_grant_resumes_only_an_infrastructure_end(self):
        g = grant(actions=("relaunch",))
        again = plan(name="exp--train--base--scratch--s0--a02", plan_id="p-2")
        run = "exp--train--base--scratch--s0"
        for end in ("PREEMPTED", "NODE_FAIL", "BOOT_FAIL", "REBOOT"):
            self.assertTrue(G.check(state(g, runs=self._runs(end)), "relaunch", plan=again, run=run).covered, end)
        for end in ("CANCELLED", "COMPLETED", "FAILED", "TIMEOUT", "OUT_OF_MEMORY", "ENDED", ""):
            d = G.check(state(g, runs=self._runs(end)), "relaunch", plan=again, run=run)
            self.assertFalse(d.covered, end)
            self.assertIn("a relaunch grant resumes only an infrastructure end", " ".join(d.reasons), end)
        d = G.check(state(g, runs=self._runs(None, live=True)), "relaunch", plan=again, run=run)
        self.assertIn("is live or its end is unknown", " ".join(d.reasons))
        ap = approval("yes, run it again", [again], actions=("relaunch",))   # an approval of the plan covers any end
        self.assertTrue(G.check(state(ap, runs=self._runs("CANCELLED")), "relaunch", plan=again, run=run).covered)
        self.assertIn("only after an infrastructure end", G.describe(g))

    def test_s1_a_launch_grant_covers_a_relaunch_after_any_end_but_never_beside_a_live_attempt(self):
        run = "exp--train--base--scratch--s0"
        fresh = {**plan(name=f"{run}--a02", plan_id="p-2", payload="python train.py --fixed"), "info_prior": "1",
                 "plan_age_s": 5}                                   # a fixed command: another configuration
        for acts in (("launch",), ("launch", "relaunch")):
            g = grant({"targets": ["fx"]}, actions=acts)
            for end in ("FAILED", "CANCELLED", "COMPLETED", "TIMEOUT", "OUT_OF_MEMORY", "PREEMPTED"):
                d = G.check(state(g, runs=self._runs(end)), "relaunch", plan=fresh, run=run)
                self.assertTrue(d.covered, (acts, end, d.reasons))
            g["scope"]["relaunch_after"] = "infra"                       # a stored "infra" no longer narrows it
            if "relaunch" in acts:
                self.assertEqual(G.valid(g), "")
                self.assertTrue(G.check(state(g, runs=self._runs("FAILED")), "relaunch", plan=fresh, run=run).covered)
            g["scope"].pop("relaunch_after")
            d = G.check(state(g, runs=self._runs(None, live=True)), "relaunch", plan=fresh, run=run)
            self.assertFalse(d.covered)                                  # KEEP: never a second copy beside a live one
            self.assertIn("may still be live", " ".join(d.reasons))
            more = {**fresh, "info_prior": "2"}                          # one only the target's journal shows
            self.assertIn("one it never saw", " ".join(G.check(state(g, runs=self._runs("FAILED")), "relaunch",
                                                              plan=more, run=run).reasons))
            stale = {**fresh, "plan_age_s": G.ANY_PLAN_MAX_AGE_S + 60}
            self.assertIn("min old", " ".join(G.check(state(g, runs=self._runs("FAILED")), "relaunch", plan=stale,
                                                      run=run).reasons))
            scoped = grant({"targets": ["fx"], "max_gpus": 1}, actions=acts)   # judged as a launch: its caps hold
            self.assertIn("GPUs > 1", " ".join(G.check(state(scoped, runs=self._runs("FAILED")), "relaunch",
                                                      plan=fresh, run=run).reasons))
            done = grant({"targets": ["fx"]}, actions=acts, max_launches=1)
            done["used"].append({"nonce": "u1", "action": "launch", "hash": "", "job": "", "at": L.now()})
            self.assertIn("used 1 of 1", " ".join(G.check(state(done, runs=self._runs("FAILED")), "relaunch",
                                                         plan=fresh, run=run).reasons))
            deny = G.new_deny({"names": [run]}, ["relaunch"])
            self.assertTrue(G.check(state(g, deny, runs=self._runs("FAILED")), "relaunch", plan=fresh, run=run).denied)

    def test_d5_g2_4_g2_6_every_derived_action_is_checked(self):
        run = "exp--train--base--scratch--s0"
        deny = G.new_deny({"names": [run]}, ["relaunch"])
        p = plan(name=run)                                           # a plain launch of a run that has attempts
        d = G.check(state(grant(actions=("launch", "relaunch")), deny, runs=self._runs("PREEMPTED")), "relaunch",
                    plan=p, run=run)
        self.assertTrue(d.denied)
        chain_deny = G.new_deny({}, ["chain"])
        p = plan(chain="1", extra="--dependency=singleton")
        self.assertTrue(G.check(state(grant(actions=("launch", "chain")), chain_deny), "chain", plan=p).denied)
        d = G.check(state(grant(actions=("launch",))), "chain", plan=p)
        self.assertIn("action chain not in launch", " ".join(d.reasons))
        both = G.check(state(grant(actions=("relaunch",)), runs=self._runs("PREEMPTED")), "relaunch",
                       plan=plan(name=run, chain="1"), run=run, also=("chain",))
        self.assertIn("action chain not in relaunch", " ".join(both.reasons))      # a record must allow all of them
        self.assertTrue(G.check(state(grant(actions=("launch",)), chain_deny), "launch", plan=plan(), also=("chain",)
                                ).denied)

    def test_g2_5_recorded_classes_are_denied_too(self):
        deny = G.new_deny({"classes": ["train"]})
        relabelled = {**plan(name="bigrun--a02"), "class": "smoke", "classes_recorded": ["train"]}
        self.assertTrue(G.check(state(grant(actions=("launch", "relaunch")), deny), "launch", plan=relabelled).denied)

    def test_g2_7_g2_10_damaged_records_deny_until_fixed_or_revoked(self):
        g = grant()
        valid_deny = G.new_deny({"partitions": ["debug"]})
        for change in ({"kind": "Deny"}, {"kind": None}, {"extra_key": 1}):
            bad = {**valid_deny, **change}
            if change.get("kind", "x") is None:
                del bad["kind"]
            d = G.check(state(g, bad), "launch", plan=plan())
            self.assertTrue(d.denied, change)
            self.assertIn("matches everything", d.reasons[0])
            self.assertTrue(any("taken as a deny: matches EVERYTHING" in ln for ln in G.lines(state(g, bad))), change)
            bad["revoked"] = {"at": L.now(), "quote": "drop that deny"}                     # grants#7: revoking ends it
            self.assertTrue(G.check(state(g, bad), "launch", plan=plan()).covered, change)
            self.assertTrue(any("revoked: matches nothing" in ln for ln in G.lines(state(g, bad))), change)
        as_grant = {**grant(), "id": "d-20260101-abcdef"}                                    # a d- id, kind grant
        self.assertTrue(G.check(state(g, as_grant), "launch", plan=plan()).denied)
        self.assertTrue(G.check(state(g, "not a record"), "launch", plan=plan()).denied)
        broken_grant = {**grant(), "quote": 5}                       # an invalid grant still covers nothing, no deny
        d = G.check(state(broken_grant), "launch", plan=plan())
        self.assertEqual((d.covered, d.denied), (False, False))

    def test_g2_11_same_config_empty_equals_quoted_empty_equals_absent(self):
        orig = plan()
        b = {k: v for k, v in G.bound(orig).items() if k not in ("env_hook", "venv_dir", "uv_sync_args", "conf_extra")}
        self.assertEqual(G.same_config({"target": "fx", "kind": "slurm", "bound": b},
                                       plan(name="exp--train--base--scratch--s0--a02")), [])
        self.assertTrue(G.same_config({"target": "fx", "kind": "slurm", "bound": b},
                                      plan(name="exp--train--base--scratch--s0--a02", venv_dir="/v")))

    def test_d8_deny_match_with_an_unknown_job_fails_closed(self):
        deny = G.new_deny({"jobs": ["9"]}, ["cancel"])
        row = {"target": "fx", "kind": "slurm", "name": "a", "warnings": "0"}
        self.assertIsNotNone(G.deny_match(row, ("cancel",), state(deny), job=None)[0])
        self.assertIsNone(G.deny_match(row, ("cancel",), state(deny), job="8")[0])
        self.assertIsNone(G.deny_match(row, ("launch",), state(deny), job=None)[0])
        own = G.new_deny({}, ["cancel_own"])
        d, _, o = G.deny_match(row, ("cancel",), state(own), job=None)
        self.assertEqual((d, o["id"]), (None, own["id"]))


class Round4(unittest.TestCase):
    """The round-4 decisions on grants.py, each pinned with the round-3 recheck's reproduction (R4-1 R4-2 R4-3 R4-6
    R4-10 R4-15)."""

    RUN = "exp--smoke--a--s0"

    def _att(self, p: dict, aid: str, end: str | None, job: str, plan_id: str, cls: str = "smoke") -> dict:
        return {"name": G.unq(p["name"]), "target": "fx", "kind": "slurm",
                "request": {"action": "launch", "plan": plan_id, "bound_hash": p["bound_hash"], "bound": G.bound(p),
                            "class": cls},
                "submissions": [{"nonce": f"n-{aid}", "submit": "submitted", "job": job,
                                 **({"end": {"state": end}} if end else {})}],
                "result": {"state": end} if end else None}

    def test_r4_1_a_deny_of_a_plan_matches_what_cannot_show_its_hash(self):
        """NEW-deny-run-failopen / N2: `rsk grant deny --run H` matched rsk launch only — a cancel (no plan) and a
        run-watch row (no hash) slipped past it; an unknown bound hash / plan id now matches (fail closed)."""
        p = plan(name=f"{self.RUN}--a01")
        deny = G.new_deny({"runs": [p["bound_hash"]]})
        own = grant({"targets": ["fx"]}, actions=("launch", "cancel_own"))
        runs = {self.RUN: {"run": self.RUN, "attempts": {"a01": self._att(p, "a01", None, "101", "p-1")}}}
        self.assertTrue(G.check(state(own, deny), "launch", plan=p).denied)                 # as before
        d = G.check(state(own, deny, runs=runs), "cancel", job="101", run=self.RUN, plan={"target": "fx"})
        self.assertTrue(d.denied, d.reasons)                                                 # the ledger's hash: it
        self.assertTrue(G.check(state(own, deny), "cancel", job="555", plan={"target": "fx"}).denied)   # no plan
        row = {"target": "fx", "kind": "slurm", "name": "a", "partition": "gpu", "warnings": "0"}      # a watch row
        self.assertIsNotNone(G.deny_match(row, ("launch",), state(deny), job=None)[0])
        other = plan(name=f"{self.RUN}--a01", payload="python other.py")
        runs2 = {self.RUN: {"run": self.RUN, "attempts": {"a01": self._att(other, "a01", None, "101", "p-1")}}}
        self.assertTrue(G.check(state(own, deny, runs=runs2), "cancel", job="101", run=self.RUN,
                                plan={"target": "fx"}).covered)                          # another plan: not that one
        pdeny = G.new_deny({"plans": ["p-1"]})
        self.assertIsNotNone(G.deny_match(row, ("launch",), state(pdeny), job=None)[0])  # no plan id: may be it
        self.assertIsNone(G.deny_match({**row, "plan_id": "p-2"}, ("launch",), state(pdeny), job=None)[0])

    def test_r4_2_a_relaunch_grant_repeats_the_attempt_whose_end_it_relies_on(self):
        """NEW-relaunch-orig: a01 (--lr 1) was CANCELLED by the user, a02 (--lr 0.1) PREEMPTED; a plan named after a01
        with a01's configuration rode on a02's preemption. The configuration is now a02's, the one that ran last."""
        run = "exp--train--lr--s0"
        a01 = plan(name=f"{run}--a01", payload="python train.py --lr 1")
        a02 = plan(name=f"{run}--a02", payload="python train.py --lr 0.1")
        runs = {run: {"run": run, "attempts": {"a01": self._att(a01, "a01", "CANCELLED", "101", "p-1", "train"),
                                               "a02": self._att(a02, "a02", "PREEMPTED", "102", "p-2", "train")}}}
        g = grant({"names": [f"{run}*"]}, actions=("relaunch",))
        back = plan("p-3", name=f"{run}--a01", payload="python train.py --lr 1")
        d = G.check(state(g, runs=runs), "relaunch", plan=back, run=run)
        self.assertFalse(d.covered)
        self.assertIn("not the configuration of a02 it resumes: payload", " ".join(d.reasons))
        resume = plan("p-4", name=f"{run}--a03", payload="python train.py --lr 0.1")
        self.assertTrue(G.check(state(g, runs=runs), "relaunch", plan=resume, run=run).covered)
        flipped = {run: {"run": run, "attempts": {"a01": self._att(a01, "a01", "PREEMPTED", "101", "p-1", "train"),
                                                  "a02": self._att(a02, "a02", "CANCELLED", "102", "p-2", "train")}}}
        d = G.check(state(g, runs=flipped), "relaunch", plan=back, run=run)   # a01's end is not the latest one's
        self.assertFalse(d.covered)
        self.assertIn("previous attempt a02 ended CANCELLED", " ".join(d.reasons))

    def test_r4_3_a_run_whose_first_attempt_had_no_class_has_none(self):
        """NEW-class-unlabelled: a label given at a later attempt never makes a class-scoped grant cover the run, and a
        class deny matches it (the first attempt's class is unknown)."""
        relabelled = {**plan(name="bigrun--a02"), "class": "smoke", "classes_recorded": ["", "smoke"]}
        f = G.facts(relabelled)
        self.assertEqual((f.cls, f.class_unknown), (None, True))
        self.assertFalse(G.check(state(grant({"classes": ["smoke"]}, actions=("launch", "relaunch"))), "launch",
                                 plan=relabelled).covered)
        self.assertTrue(G.check(state(grant(), G.new_deny({"classes": ["train"]})), "launch",
                                plan=relabelled).denied)
        labelled = {**plan(name="bigrun--a02"), "class": "smoke", "classes_recorded": ["smoke"]}
        self.assertTrue(G.check(state(grant({"classes": ["smoke"]})), "launch", plan=labelled).covered)
        self.assertEqual(G.run_classes({"attempts": {"a02": {"request": {"class": ""}, "name": "x--a02"},
                                                     "a01": {"request": {}, "name": "x--smoke--a01"}}}), ["smoke", ""])

    def test_r4_6_s3_a_plan_with_policy_flags_is_covered_by_a_grant(self):
        """S3: the block binds flags= (the card lists them, with a NOTE); a covering grant covers a plan with policy
        flags like the rest of it (R4-6 kept them out of every grant: no longer)."""
        g = grant({"targets": ["fx"], "max_gpus": 2})
        flagged = plan(flags="--whole-node")
        self.assertEqual(G.facts(flagged).flags, ("--whole-node",))
        self.assertTrue(G.check(state(g), "launch", plan=flagged).covered)
        self.assertTrue(G.check(state(g), "launch", plan=plan()).covered)
        self.assertTrue(G.check(state(g, approval("yes, the whole node", [flagged])), "launch", plan=flagged).covered)
        self.assertFalse(G.check(state(g, G.new_deny({"targets": ["fx"]})), "launch", plan=flagged).covered)
        old = plan(flags=None)                       # a deploy from before flags= was bound
        self.assertFalse(G.facts(old).flags_known)
        self.assertTrue(G.check(state(g), "launch", plan=old).covered)
        self.assertIn("flags", G.NEEDED["slurm"])
        self.assertEqual(G.SLURM_BOUND[-2:], ("flags", "chain"))   # immediately before chain=, as submit.sh prints it

    def test_r4_10_an_attempt_the_ledger_shows_ended_is_not_the_agents_own(self):
        """N1-cancel-job-ended-pid: the ledger's ended submission of a pid the box has since reused made the cancel
        'own'; only a live submission is (S5: then no record is needed)."""
        p = plan(name=f"{self.RUN}--a01")
        g = grant({"targets": ["fx"]}, actions=("launch",))
        live = {self.RUN: {"run": self.RUN, "attempts": {"a01": self._att(p, "a01", None, "101", "p-1")}}}
        ended = {self.RUN: {"run": self.RUN, "attempts": {"a01": self._att(p, "a01", "ENDED", "101", "p-1")}}}
        self.assertTrue(G.check(state(g, runs=live), "cancel", job="101", run=self.RUN).covered)
        d = G.check(state(g, runs=ended), "cancel", job="101", run=self.RUN)
        self.assertFalse(d.covered)
        self.assertIn("not one this project's rsk launched or adopted", " ".join(d.reasons))
        seen = {self.RUN: {"run": self.RUN, "attempts": {"a01": {**self._att(p, "a01", None, "101", "p-1"),
                                                                 "submissions": [{"nonce": "n", "submit": "submitted",
                                                                                  "job": "101", "seen": {"state": "COMPLETED"}}]}}}}
        self.assertFalse(G.check(state(g, runs=seen), "cancel", job="101", run=self.RUN).covered)

    def test_r4_15_unreadable_grants_refuse_never_act_as_if_no_deny(self):
        """N7: a grants.json that does not parse (no good .prev) read as 'no records' — no deny. Now every check is
        exit 6 'grants unreadable', and deny_match matches everything."""
        st = state(grant())
        st.grants_unreadable = "grants.json: not JSON; grants.json.prev: missing"
        with self.assertRaises(RskError) as c:
            G.check(st, "launch", plan=plan())
        self.assertEqual(c.exception.code, CONFLICT)
        self.assertIn("grants unreadable — rsk grant recount / restore", str(c.exception))
        with self.assertRaises(RskError):
            G.check(st, "cancel", job="1", plan={"target": "fx"})
        self.assertIsNotNone(G.deny_match(plan(), ("launch",), st, job=None)[0])


class Round5(unittest.TestCase):
    """The round-5 decisions on grants.py (R5-1 R5-8), each pinned with the round-4 recheck's reproduction."""

    RUN = "exp--train--a"

    def test_r5_1_a_deny_by_job_id_is_for_cancels_only(self):
        """V4-jobdeny: `rsk grant deny --job 101 --action relaunch` was stored, listed `DENY relaunch: jobs 101`, and
        matched no launch (a launch has no job id), so a relaunch grant resubmitted job 101's run. Such a record is now
        invalid — and an invalid deny matches everything (fail closed)."""
        p = plan(name=f"{self.RUN}--a02")
        att = {"name": f"{self.RUN}--a01", "target": "fx", "kind": "slurm",
               "request": {"action": "launch", "plan": "p-1", "bound_hash": p["bound_hash"], "bound": G.bound(p)},
               "submissions": [{"nonce": "n1", "submit": "submitted", "job": "101", "end": {"state": "PREEMPTED"}}],
               "result": {"state": "PREEMPTED"}}
        runs = {self.RUN: {"run": self.RUN, "attempts": {"a01": att}}}
        g = grant({"targets": ["fx"]}, actions=("relaunch",))
        self.assertTrue(G.check(state(g, runs=runs), "relaunch", plan=p, run=self.RUN).covered)   # the setup
        for acts in (["relaunch"], list(G.ACTIONS), ["cancel", "launch"]):
            with self.assertRaises(RskError) as c:
                G.new_deny({"jobs": ["101"]}, acts)
            self.assertEqual(c.exception.code, USAGE)
            self.assertIn("a deny by job id (scope.jobs) is for cancels only", str(c.exception))
            stored = {"id": "d-20261105-aaaaaa", "kind": "deny", "quote": "job 101 is broken: do not resubmit it",
                      "created_at": L.now(), "created_via": "cli", "source": "", "scope": {"jobs": ["101"]},
                      "actions": acts, "limits": {}, "used": [], "revoked": None}
            self.assertTrue(G.fail_closed(stored), acts)
            d = G.check(state(g, stored, runs=runs), "relaunch", plan=p, run=self.RUN)
            self.assertTrue(d.denied, (acts, d.reasons))               # it was covered (exit 0) before
            self.assertIn("matches everything", " ".join(d.reasons))
            revoked = {**stored, "revoked": {"at": L.now(), "quote": "recorded wrongly"}}
            self.assertTrue(G.check(state(g, revoked, runs=runs), "relaunch", plan=p, run=self.RUN).covered)
        ok = G.new_deny({"jobs": ["101"]}, ["cancel", "cancel_own"])   # cancels: as before
        self.assertEqual(G.valid(ok), "")
        self.assertTrue(G.check(state(g, ok, runs=runs), "relaunch", plan=p, run=self.RUN).covered)
        byname = G.new_deny({"names": [self.RUN]}, ["relaunch"])
        self.assertTrue(G.check(state(g, byname, runs=runs), "relaunch", plan=p, run=self.RUN).denied)

    def test_r5_8_a_deny_compares_normalised_target_names(self):
        """WATCH-target-spelling-evades-deny: a run-watch row on `fx-slurm/` (the same profile dir, the same deploy)
        never matched `-T fx-slurm`. A deny now compares grants.target_key names; a spelling that is not one plain
        name may be any target (it matches)."""
        deny = G.new_deny({"targets": ["fx-slurm"]})
        row = {"kind": "slurm", "name": "a", "warnings": "0"}
        for t in ("fx-slurm", "fx-slurm/", "fx-slurm/.", "fx-slurm//", "./fx-slurm", "FX-SLURM", "a/b", "..", "-x"):
            self.assertIsNotNone(G.deny_match({**row, "target": t}, ("launch",), state(deny), job=None)[0], t)
        for t in ("fx-other", "fx-slurm-2"):
            self.assertIsNone(G.deny_match({**row, "target": t}, ("launch",), state(deny), job=None)[0], t)
        self.assertEqual([G.target_key(t) for t in ("fx/", "./FX", "a/b", "", "x y")], ["fx", "fx", None, None, None])
        g = grant({"targets": ["fx-slurm"]})                           # a grant stays exact: `fx-slurm/` is not it
        self.assertFalse(G.check(state(g), "launch", plan=plan(target="fx-slurm/")).covered)
        self.assertTrue(G.check(state(g), "launch", plan=plan(target="fx-slurm")).covered)


class Round6(unittest.TestCase):
    """The round-6 decisions on grants.py (R6-1), each pinned with the round-5 recheck's reproduction."""

    def test_r6_1_a_relaunch_deny_that_names_a_run_stops_every_launch_of_it(self):
        """V5-prior-xtarget / NF-relaunch-deny-history-elsewhere: run-watch ran `a` on fx (never in the ledger), the
        user said "do not relaunch a, it is broken", and `rsk launch -T fx2 -n a` was a plain launch (fx2's journal
        has no receipt of a) that a launch grant on fx2 covered. A deny that names a run and lists relaunch or
        resubmit now matches every launch-type action of that run id — launch included — on any target in its scope;
        a deny naming no run keeps the derived action."""
        g = grant({"targets": ["fx", "fx2"], "names": ["a*"]})
        for acts in (["relaunch"], ["resubmit"], ["relaunch", "resubmit"]):
            d = G.new_deny({"names": ["a"]}, acts)
            for tgt in ("fx", "fx2"):
                for name, action in (("a", "launch"), ("a--a03", "launch"), ("a", "chain")):
                    dec = G.check(state(g, d), action, plan=plan(name=name, target=tgt))
                    self.assertTrue(dec.denied, (acts, tgt, name, action, dec.reasons))
                    self.assertIn(f"denied by {d['id']}", dec.reasons[0])
                    self.assertIn("rsk cannot see every earlier attempt", dec.reasons[0])
            self.assertTrue(G.check(state(g, d), "launch", plan=plan(name="a2", target="fx2")).covered)   # another run
            self.assertIsNone(G.deny_match(plan(name="a"), ("cancel",), state(d), job="1")[0])   # cancels: untouched
            self.assertIn("every launch of it too", G.describe(d))
            self.assertTrue(G.run_deny(d))
        scoped = G.new_deny({"names": ["a"], "targets": ["fx"]}, ["relaunch"])
        self.assertTrue(G.check(state(g, scoped), "launch", plan=plan(name="a", target="fx")).denied)
        self.assertTrue(G.check(state(g, scoped), "launch", plan=plan(name="a", target="fx2")).covered)   # its scope
        unnamed = G.new_deny({"targets": ["fx2"]}, ["relaunch"])
        self.assertFalse(G.run_deny(unnamed))                         # names no run: the derived action decides
        self.assertTrue(G.check(state(g, unnamed), "launch", plan=plan(name="a", target="fx2")).covered)
        self.assertNotIn("every launch of it too", G.describe(unnamed))
        d = G.new_deny({"names": ["a"]}, ["relaunch"])
        later = grant({"targets": ["fx2"], "names": ["a*"]})            # a launch grant right after it: flagged
        self.assertTrue(G.after_deny(later, [d, later]))
        self.assertEqual(G.after_deny(later, [unnamed, later]), [])      # an unnamed relaunch deny: launches untouched
        launch_deny = G.new_deny({"names": ["a"]}, ["launch"])
        dec = G.check(state(g, launch_deny), "launch", plan=plan(name="a", target="fx2"))
        self.assertTrue(dec.denied)
        self.assertNotIn("rsk cannot see every earlier attempt", dec.reasons[0])   # a launch deny needs no widening


class Round7(unittest.TestCase):
    """The round-7 decisions on grants.py (R7-1), each pinned with the round-6 recheck's reproduction."""

    def test_r7_1_a_deny_written_with_an_attempts_name_stands_for_the_whole_run(self):
        """N6-deny-attempt-name / NF6-deny-attempt-name: "do not relaunch exp--smoke--p--a02" (the job name squeue and
        sacct show) was recorded as `--name exp--smoke--p--a02`; deny matching compared that glob with the plan's name
        (`…--a03`) and run id (`exp--smoke--p`) — neither — so a standing relaunch grant submitted the attempt the user
        forbade. A deny's glob is also matched with its own trailing --aNN (two or more digits) removed against the
        plan's run id: every attempt of that run, launches and cancels alike, on rsk launch and rsk watch rows (a row is
        its run id). R6-1's "names a run" uses that stripped form too."""
        run = "exp--smoke--p"
        g = grant({"targets": ["fx"], "names": ["exp--smoke--*"]}, actions=("launch", "relaunch"))
        for acts in (["relaunch"], ["launch"], ["resubmit"]):
            d = G.new_deny({"names": [f"{run}--a02"]},
                           acts)
            for name, action in ((f"{run}--a03", "relaunch"), (run, "launch"), (f"{run}--a02", "launch"),
                                 (f"{run}--a10", "chain")):
                hit, why, _ = G.deny_match(plan(name=name, target="fx"), (action,), state(g, d))
                self.assertIsNotNone(hit, (acts, name, action))
                self.assertIn(f"denied by {d['id']}", why)
            dec = G.check(state(g, d), "relaunch", plan=plan(name=f"{run}--a03", target="fx"), run=run)
            self.assertTrue(dec.denied, (acts, dec.reasons))
            row = {"target": "fx", "kind": "slurm", "name": run, "warnings": "0"}       # a run-watch row: its run id
            self.assertIsNotNone(G.deny_match(row, ("resubmit",), state(d), job=None)[0], acts)
            self.assertIsNone(G.deny_match(plan(name="exp--smoke--q--a03"), ("relaunch",), state(d))[0])   # another run
            self.assertIsNone(G.deny_match(plan(name=f"{run}x--a03"), ("relaunch",), state(d))[0])
        cancel = G.new_deny({"names": [f"{run}--a02"]}, ["cancel"])
        self.assertIsNotNone(G.deny_match(plan(name=f"{run}--a03"), ("cancel",), state(cancel), job="1")[0])
        globbed = G.new_deny({"names": ["exp--smoke--*--a02"]},
                             ["relaunch"])
        self.assertIsNotNone(G.deny_match(plan(name="exp--smoke--z--a05"), ("relaunch",), state(globbed))[0])
        self.assertEqual(G.run_globs([f"{run}--a02", "r--a1", "r", "x--a0*", "x--a123"]), [run, "x"])
        one = G.new_deny({"names": ["r--a1"]}, ["launch"])    # one digit: not an attempt suffix
        self.assertIsNone(G.deny_match(plan(name="r--a03"), ("launch",), state(one))[0])
        d = G.new_deny({"names": [f"{run}--a02"]}, ["relaunch"])
        self.assertIn(f"(= run {run}: every attempt of it)", G.describe(d))
        later = grant({"names": [run]}, actions=("launch",))                # a grant of the run right after it: flagged
        self.assertTrue(G.after_deny(later, [d, later]))

    def test_r7_1_a_deny_glob_over_attempt_names_stands_for_the_run(self):
        """R7-1's open edge (integration): a deny written as a glob over a run's attempt names — `x--a*`, `x--a0?`,
        `x--a[0-9][0-9]` ("do not relaunch any attempt of x") — matched only attempt names, never the run id x, so a
        fresh `rsk launch -n x` under a standing grant went out. A glob whose --a suffix can match an attempt's (two or
        more digits) now stands for its run, as a literal --aNN does; one that cannot (`x--a?`: one character,
        `x--a[!0-9]*`: no digit first) keeps its plain meaning."""
        g = grant({"targets": ["fx"], "names": ["*"]}, actions=("launch", "relaunch"))
        for glob in ("exp--smoke--p--a*", "exp--smoke--p--a0?", "exp--smoke--p--a[0-9][0-9]", "exp--smoke--p--a1*"):
            d = G.new_deny({"names": [glob]}, ["relaunch"])
            for name, action in (("exp--smoke--p", "launch"), ("exp--smoke--p--a03", "relaunch")):
                hit, why, _ = G.deny_match(plan(name=name, target="fx"), (action,), state(g, d))
                self.assertIsNotNone(hit, (glob, name, action))
            dec = G.check(state(g, d), "launch", plan=plan(name="exp--smoke--p", target="fx"))
            self.assertTrue(dec.denied, (glob, dec.reasons))
            row = {"target": "fx", "kind": "slurm", "name": "exp--smoke--p", "warnings": "0"}   # a run-watch row
            self.assertIsNotNone(G.deny_match(row, ("launch",), state(d), job=None)[0], glob)
            self.assertIsNone(G.deny_match(plan(name="exp--smoke--q"), ("launch",), state(d))[0], glob)  # another run
            self.assertIn("(= run exp--smoke--p: every attempt of it)", G.describe(d))
            self.assertEqual(G.attempt_name_notes([glob]),
                             [f"NOTE: name {glob} matches attempts' names (--aNN): the deny stands for run "
                              "exp--smoke--p — every attempt of it, the next one included (an attempt is launched "
                              "once)"])
        for glob in ("x--a?", "x--a[!0-9]*", "x--a[0-9]", "--a*"):             # cannot match an attempt suffix
            self.assertEqual(G.run_globs([glob]), [], glob)
            d = G.new_deny({"names": [glob]}, ["launch"])
            self.assertIsNone(G.deny_match(plan(name="x"), ("launch",), state(d))[0], glob)
            self.assertEqual(G.attempt_name_notes([glob]), [], glob)
        self.assertEqual(G.run_globs(["x--a02", "x--a0*", "y--a*"]), ["x", "y"])   # once each


class Round8(unittest.TestCase):
    """R8-1 on grants.py: list arguments split on commas and stripped; whitespace inside an item (or an empty item) is
    exit 2; a STORED list item with whitespace makes the record invalid (an invalid deny matches everything)."""

    def test_r8_1_split_strips_comma_items_and_refuses_empty_or_spaced_ones(self):
        """NF7-split-space / NF7-deny-list-whitespace: _split kept ' b2' (from 'b1, b2') and '101 102' as entries that
        never match: the user's deny was not enforced."""
        self.assertEqual(G._split(["b1, b2", " b3 "], "--name"), ["b1", "b2", "b3"])
        self.assertEqual(G._split([" 101 ,102"], "--job"), ["101", "102"])
        self.assertEqual(G._split([], "--name"), [])
        for v, why in (("101 102", "item '101 102' holds whitespace"), ("a,,b", "an empty item"),
                       ("a,", "an empty item"), ("", "an empty item"), (" , ", "an empty item"),
                       ("exp\ta", "holds whitespace"), ("a\u00a0b", "holds whitespace")):
            with self.assertRaises(RskError) as c:
                G._split(["ok", v], "--name")
            self.assertEqual(c.exception.code, USAGE, v)
            self.assertIn(why, str(c.exception))
            self.assertIn("--name", str(c.exception))
            self.assertIn("nothing recorded", str(c.exception))

    def test_r8_1_a_stored_item_with_whitespace_is_invalid_and_a_deny_then_matches_everything(self):
        base = {"id": "d-20261105-bbbbbb", "kind": "deny", "quote": "never cancel jobs 101 or 102", "created_at": L.now(),
                "created_via": "import", "source": "a note", "actions": ["cancel", "cancel_own"], "limits": {},
                "used": [], "revoked": None}
        g = grant({"targets": ["fx"]}, actions=("launch", "cancel_own"))
        for key, items in (("jobs", ["101", " 102"]), ("jobs", ["101 102"]), ("names", ["b1", " b2"]),
                           ("names", ["b2 "]), ("partitions", ["cpu", " preempt"]), ("gpu_types", ["a100 h100"]),
                           ("targets", [" fx"]), ("classes", ["smoke "])):
            rec = {**base, "scope": {key: items}}
            if key != "jobs":
                rec["actions"] = ["launch"]
            why = G.valid(rec)
            self.assertIn("whitespace in a scope item", why, (key, items))
            self.assertTrue(G.fail_closed(rec), (key, items))
            if key == "jobs":
                d = G.check(state(g, rec), "cancel", job="102", run="sw2",
                            plan={"target": "fx", "kind": "slurm", "name": "sw2--a01", "warnings": "0"})
            else:
                d = G.check(state(g, rec), "launch", plan=plan(target="fx", name="b2"))
            self.assertTrue(d.denied, (key, items, d.reasons))           # fail closed: it was "covered" before
            self.assertIn("matches everything", " ".join(d.reasons))
        ok = {**base, "scope": {"jobs": ["101", "102"]}}
        self.assertEqual(G.valid(ok), "")
        bad_grant = grant({"names": ["b1"]})
        bad_grant["scope"]["names"] = [" b1"]
        self.assertFalse(G.check(state(bad_grant), "launch", plan=plan(name="b1")).covered)   # a grant: covers nothing
        self.assertEqual(G.fail_closed(bad_grant), "")
        ap = old_cancel_ap("fx", ["101"])                     # an older cancel identity holds the WorkDir:
        ap["scope"]["idents"] = [json.dumps(["slurm", "fx", "101", "exp--a01", "/r/my proj"])]   # a space there is fine
        self.assertEqual(G.valid(ap), "")


def nplan(plan_id: str = "p-box", **kv: str | None) -> dict:
    """A workstation plan as remote/launch.sh prints it (bound kind= … env_name=; envelope warnings, warnings_avail,
    warnings_gpu, warnings_id; a key given as None is left out: an older launch.sh's block)."""
    base: dict[str, str | None] = {
        "kind": "nohup", "target": "ws", "name": "d1", "gpus_req": "n=1", "exclude": "", "nice": "", "launch_cfg": "",
        "busy_ok": "", "payload": "deepspeed\\ --num_gpus\\ 4\\ train.py", "env_kind": "none", "env_hook": "''",
        "venv_dir": "''", "uv_sync_args": "''", "env_name": "''", "warnings": "1", "warnings_avail": "0",
        "warnings_gpu": "1", "warnings_id": "e" * 64}
    base.update(kv)
    bound = [f"{k}={base[k]}" for k in ("kind", "target", *G.NOHUP_BOUND)]
    h = hashlib.sha256(("\n".join(bound) + "\n").encode()).hexdigest()
    env = "".join(f"{k}={base[k]}\n" for k in ("warnings_avail", "warnings_gpu", "warnings_id", "warnings")
                  if base[k] is not None)
    return {**G.parse_plan("@@plan v1\napi=3\n" + "".join(ln + "\n" for ln in bound) + "info_launchers=checked\n" + env
                           + f"bound_hash={h}\n@@end\n"), "plan_id": plan_id}


class Round9(unittest.TestCase):
    """NF8-any-grant-box-launchers: launch.sh counts its launcher / container / env-dropping WARNINGs apart
    (warnings_gpu=N); no standing grant covers a workstation plan with one — whatever its allow_warnings kind — and a
    block without the count (an older launch.sh) is unknown, so uncovered too. An approval of the card still is."""

    def test_nf8_no_grant_covers_a_box_plan_with_launcher_warnings_whatever_its_kind(self):
        """box-any.sh: a '<= 1 GPU' ws grant with --allow-warnings any covered `deepspeed --num_gpus 4 …` (four GPUs),
        `docker run --gpus all …` (any GPU, another user's too) and `ssh otherbox …` — §U: more resources and a GPU
        another user uses are the user's call."""
        p = nplan()
        self.assertEqual((G.facts(p).warnings, G.facts(p).warnings_gpu), (1, 1))
        for aw in ("any", True, "availability", None):
            g = grant({"targets": ["ws"], "max_gpus": 1, **({"allow_warnings": aw} if aw is not None else {})})
            d = G.check(state(g), "launch", plan=p)
            self.assertFalse(d.covered, aw)
            self.assertIn("1 of its warning(s) a launcher / container / env-dropping tool's", " ".join(d.reasons))
            self.assertIn("no standing grant covers that, whatever its --allow-warnings", " ".join(d.reasons))
        ap = approval("yes, deepspeed on four GPUs is fine", [p], allow_warnings=True)   # the user saw the card
        self.assertTrue(G.check(state(ap), "launch", plan=p).covered)
        g = grant({"targets": ["ws"], "allow_warnings": "any"}, actions=("launch", "relaunch"))
        self.assertIn("never a workstation's launcher / container warnings", G.describe(g))

    def test_nf8_warnings_gpu_zero_is_the_grants_call_and_missing_is_unknown(self):
        g = grant({"targets": ["ws"], "allow_warnings": "any"})
        self.assertTrue(G.check(state(g), "launch", plan=nplan(warnings="0", warnings_gpu="0",
                                                               payload="python\\ t.py")).covered)
        self.assertTrue(G.check(state(g), "launch", plan=nplan(warnings_gpu="0")).covered)   # another kind: as before
        self.assertFalse(G.check(state(grant({"targets": ["ws"]})), "launch", plan=nplan(warnings_gpu="0")).covered)
        for w in ("0", "1"):                                       # an older launch.sh: no warnings_gpu= at all
            old = nplan(warnings=w, warnings_gpu=None)
            self.assertIsNone(G.facts(old).warnings_gpu)
            d = G.check(state(g), "launch", plan=old)
            self.assertFalse(d.covered, w)
            self.assertIn("no warnings_gpu=: a launch.sh older than this rsk — rsk sync", " ".join(d.reasons))
            self.assertTrue(G.check(state(approval("go", [old], allow_warnings=w == "1")), "launch", plan=old).covered)
        self.assertTrue(G.check(state(grant({"targets": ["fx"]})), "launch", plan=plan()).covered)   # Slurm: unchanged
        with self.assertRaises(RskError) as c:
            nplan(warnings_gpu="x")
        self.assertIn("warnings_gpu='x' is not a count", str(c.exception))


class Store(ScratchHome):
    def setUp(self) -> None:
        super().setUp()
        for name, prof in (("fx", "T_KIND=slurm; T_HOST=fxhost\n"), ("ws", "T_KIND=nohup; T_HOST=wshost\n")):
            d = self.home / "cfg" / "targets" / name             # the fixture targets (RS_USER_DIR = home/cfg)
            d.mkdir(parents=True)
            (d / "profile.sh").write_text(prof)
        self.proj = self.home / "proj"
        self.proj.mkdir()
        (self.proj / ".hpc.conf").write_text("REMOTE_DIR=/r\n")
        self.led = L.Ledger(self.proj)

    def test_use_is_idempotent_by_nonce_and_refund(self):
        g = G.add(self.led, grant(max_launches=2))
        self.assertTrue(G.use(self.led, g["id"], "n1", "launch"))
        self.assertFalse(G.use(self.led, g["id"], "n1", "launch"))
        self.assertTrue(G.use(self.led, g["id"], "n2", "launch"))
        d = G.check(self.led, "launch", plan=plan())
        self.assertIn("used 2 of 2", " ".join(d.reasons))
        self.assertTrue(G.refund(self.led, g["id"], "n2", "verdict refused"))
        self.assertFalse(G.refund(self.led, g["id"], "n2", "again"))
        self.assertTrue(G.check(self.led, "launch", plan=plan()).covered)
        events = [a["event"] for a in self.led.read_audit()[0]]
        self.assertEqual(events.count("grant_used"), 2)

    def test_recovered_grants_mean_budgets_unknown_until_recount(self):
        g = G.add(self.led, grant(max_launches=2))
        G.use(self.led, g["id"], "n1", "launch")
        G.use(self.led, g["id"], "n2", "launch")                    # .prev holds n1 only
        (self.led.dir / "grants.json").write_text("{torn")
        d = G.check(self.led, "launch", plan=plan())
        self.assertFalse(d.covered)
        self.assertIn("budgets unknown", " ".join(d.reasons))
        rc, text = run("grant", "list", "-C", str(self.proj))
        self.assertIn("BUDGETS UNKNOWN", text)
        self.assertIn("launches ?/2", text)
        fresh = G.add(self.led, grant({"targets": ["fx"]}))           # a record made after it is not affected
        self.assertEqual(G.check(self.led, "launch", plan=plan()).record["id"], fresh["id"])
        G.revoke(self.led, fresh["id"], "stop")
        self.assertIn("1 use(s) restored", G.recount(self.led))      # n2 comes back from the audit
        self.assertEqual(self.led.state().budgets_unknown, "")
        d = G.check(self.led, "launch", plan=plan())
        self.assertIn("used 2 of 2", " ".join(d.reasons))

    def test_n7_a_deny_lost_with_grants_json_still_counts_and_recount_puts_it_back(self):
        """N7 case 2 (round 4 not_fixed): grants.json damaged, .prev = the file before the last write — a deny made in
        that write was gone (rsk launch --approve submitted), and `rsk grant recount` wrote the .prev data back for
        good. Now audit.jsonl (written first) brings the deny back meanwhile, and recount restores it; a revoke lost
        the same way never resurrects a grant."""
        fresh = G.add(self.led, grant({"targets": ["fx"]}))
        G.add(self.led, G.new_deny({"targets": ["fx"]}))   # .prev: without it
        (self.led.dir / "grants.json").write_text('{"version": 1, "records": [')
        d = G.check(self.led, "launch", plan=plan())
        self.assertEqual(d.code, REFUSED, d.reasons)
        self.assertIn("denied by d-", " ".join(d.reasons))
        G.add(self.led, grant({"targets": ["fx"]}))                    # a write in the recovered state: still there
        self.assertEqual(G.check(self.led, "launch", plan=plan()).code, REFUSED)
        self.assertIn("restored from the audit", G.recount(self.led))
        self.assertEqual(self.led.state().budgets_unknown, "")
        self.assertEqual(G.check(self.led, "launch", plan=plan()).code, REFUSED)   # in grants.json for good now
        self.assertTrue(any(r["kind"] == "deny" for r in json.loads((self.led.dir / "grants.json").read_text())["records"]))
        self.assertNotIn(fresh["id"], G.recount(self.led))            # recount again: nothing more to restore
        for f in ("grants.json", "grants.json.prev"):                   # R4-15's remedy: both moved aside …
            (self.led.dir / f).rename(self.led.dir / (f + ".aside"))
        self.assertEqual(G.check(self.led, "launch", plan=plan()).code, REFUSED)   # … the deny counts all the same
        self.assertIn("restored from the audit", G.recount(self.led))
        self.assertEqual(G.check(self.led, "launch", plan=plan()).code, REFUSED)
        # a revoke lost the same way (another project's ledger): the grant stays revoked after recount
        (self.home / "p2").mkdir()
        (self.home / "p2" / ".hpc.conf").write_text("REMOTE_DIR=/r2\n")
        led = L.Ledger(self.home / "p2")
        g = G.add(led, grant({"targets": ["fx"]}))
        self.assertTrue(G.check(led, "launch", plan=plan()).covered)
        G.revoke(led, g["id"])                                          # .prev: g not revoked
        (led.dir / "grants.json").write_text("{torn")
        d = G.check(led, "launch", plan=plan())
        self.assertFalse(d.covered)
        self.assertIn("budgets unknown", " ".join(d.reasons))          # meanwhile: .prev's records cover nothing
        self.assertIn(f"revocation(s) of {g['id']} restored", G.recount(led))
        self.assertEqual(led.state().budgets_unknown, "")
        d = G.check(led, "launch", plan=plan())
        self.assertFalse(d.covered, d.reasons)
        self.assertNotIn("budgets unknown", " ".join(d.reasons))       # revoked, not merely unknown

    def test_r4_15_a_corrupt_grants_json_without_prev_is_unreadable(self):
        G.add(self.led, G.new_deny({"targets": ["fx"]}))
        (self.led.dir / "grants.json").write_text('{"version": 1, "records": [')     # torn, and its .prev …
        (self.led.dir / "grants.json.prev").unlink(missing_ok=True)                   # … gone too
        self.assertIn("grants.json", self.led.state().grants_unreadable)
        with self.assertRaises(RskError) as c:
            G.check(self.led, "launch", plan=plan())
        self.assertEqual(c.exception.code, CONFLICT)
        rc, text = run("grant", "list", "-C", str(self.proj))
        self.assertIn("BUDGETS UNKNOWN", text)                                        # rsk grant list still reads

    def test_cli_add_list_deny_revoke(self):
        base = ("grant", "add", "-C", str(self.proj), "--quote", "submit the seeds yourself", "--action", "launch",
                "-T", "fx", "--max-gpus", "2")
        rc, text = run(*base, "--max-live", "2", "--max-launches", "none")
        self.assertEqual(rc, USAGE)                                  # --expires missing: argparse refuses
        rc, text = run(*base, "--max-live", "2", "--max-launches", "none", "--expires", "none")
        self.assertEqual(rc, OK, text)
        gid = text.split()[0]
        rec = next(r for r in self.led.state().grants if r["id"] == gid)
        self.assertEqual(rec["limits"], {"max_live": 2, "max_launches": None, "expires": None})
        rc, text = run(*base, "--max-live", "0", "--max-launches", "none", "--expires", "none")
        self.assertEqual(rc, USAGE)
        rc, text = run("grant", "deny", "-C", str(self.proj), "--quote", "never the part-b queue", "--partition", "part-b")
        self.assertEqual(rc, OK, text)
        rc, text = run(*base, "--partition", "part-b,gpu", "--max-live", "1", "--max-launches", "1", "--expires",
                       "2099-01-01")
        self.assertIn("FLAG: created", text)
        rc, text = run("grant", "list", "-C", str(self.proj))
        self.assertEqual(rc, OK)
        self.assertIn("covers: launch: targets fx; <= 2 GPUs; no plan with warnings", text)
        self.assertIn("live 0/2", text)
        self.assertIn("launches 0/no limit (user's words)", text)
        self.assertNotIn("quote:", text)                             # S4: --quote accepted, never recorded
        self.assertNotIn("never the part-b queue", text)
        self.assertNotIn("never the part-b queue", (self.led.dir / "audit.jsonl").read_text())
        self.assertIn("FLAG:", text)
        rc, text = run("grant", "revoke", gid, "-C", str(self.proj), "--quote", "enough")
        self.assertEqual(rc, OK, text)
        rc, text = run("grant", "deny", "-C", str(self.proj), "--partition", "part-c", "--unlisted-partition")
        self.assertEqual(rc, OK, text)                               # S4: no --quote needed at all
        did = text.split()[0]
        self.assertEqual(run("grant", "revoke", did, "-C", str(self.proj))[0], OK)
        self.assertNotIn(gid, run("grant", "list", "-C", str(self.proj))[1])
        self.assertIn("REVOKED", run("grant", "list", "-C", str(self.proj), "--all")[1])
        doc = json.loads(run("grant", "list", "-C", str(self.proj), "--json")[1])
        self.assertTrue(all("covers" in r for r in doc["records"]))
        self.assertEqual(run("grant", "add", "-C", str(self.proj), "--quote", "x", "--max-live", "1",
                             "--max-launches", "1", "--expires", "none")[0], USAGE)          # no --action

    def test_grant_add_and_import_refuse_resubmit(self):
        rc, text = run("grant", "add", "-C", str(self.proj), "--quote", "retry them", "--action", "launch,resubmit",
                       "--max-live", "none", "--max-launches", "none", "--expires", "none")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("'resubmit' is not a standing grant's action", text)
        f = self.home / "g.json"
        f.write_text(json.dumps([{"kind": "grant", "quote": "q", "source": "a note", "scope": {},
                                  "actions": ["resubmit"], "limits": {"max_live": None, "max_launches": None,
                                                                      "expires": None}}]))
        rc, text = run("grant", "import", "-C", str(self.proj), str(f))
        self.assertEqual(rc, USAGE, text)
        rc, text = run("grant", "deny", "-C", str(self.proj), "--quote", "no resubmits", "--action", "resubmit")
        self.assertEqual(rc, OK, text)

    def test_import(self):
        good = {"kind": "grant", "quote": "no need to check with me, submit them yourself", "source": "memory note 2026-10-01",
                "scope": {"targets": ["fx"]}, "actions": ["launch"],
                "limits": {"max_live": None, "max_launches": None, "expires": None}}
        f = self.home / "auth.json"
        f.write_text(json.dumps([good, {**good, "limits": {"max_live": None, "max_launches": None}}]))
        rc, text = run("grant", "import", str(f), "-C", str(self.proj))
        self.assertEqual(rc, USAGE)
        self.assertIn("limits.expires is required", text)
        self.assertEqual(self.led.state().grants, [])                # all or nothing
        f.write_text(json.dumps([{**good, "source": ""}]))
        self.assertEqual(run("grant", "import", str(f), "-C", str(self.proj))[0], USAGE)
        f.write_text(json.dumps([{**good, "created_via": "cli"}]))
        self.assertEqual(run("grant", "import", str(f), "-C", str(self.proj))[0], USAGE)
        f.write_text(json.dumps([good]))
        rc, text = run("grant", "import", str(f), "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        rec = self.led.state().grants[0]
        self.assertEqual(rec["created_via"], "import")
        self.assertNotIn("quote", rec)                                # S4: the words are never recorded
        self.assertNotIn(good["quote"], (self.led.dir / "audit.jsonl").read_text())
        self.assertTrue(G.check(self.led, "launch", plan=plan()).covered)   # works as stated: no limit
        f.write_text(json.dumps([{**good, "id": rec["id"]}]))
        self.assertEqual(run("grant", "import", str(f), "-C", str(self.proj))[0], USAGE)    # id clash

    def test_r5_9_a_target_the_harness_does_not_know_is_refused(self):
        """DENY-unknown-target-silently-inert: `rsk grant deny -T fx-slrum` was stored and matched nothing, so a grant
        on fx covered what the user forbade. Every -T of add / deny and every scope target of import must be a target
        the harness knows: exit 2 'unknown target', nothing recorded."""
        deny = ("grant", "deny", "-C", str(self.proj), "--quote", "never launch anything on fx again")
        add = ("grant", "add", "-C", str(self.proj), "--quote", "launch on fx", "--action", "launch", "--max-live", "1",
               "--max-launches", "1", "--expires", "none")
        for argv in ((*deny, "-T", "fx-slrum"), (*deny, "-T", "fx,fx-slrum"), (*add, "-T", "fx-slrum"),
                     (*deny, "-T", "fx/"), (*deny, "-T", "FX")):
            rc, text = run(*argv)
            self.assertEqual(rc, USAGE, (argv, text))
            self.assertIn("unknown target", text)
            self.assertIn("the harness knows fx, ws", text)
        self.assertIn("'fx/' is spelled fx here", run(*deny, "-T", "fx/")[1])
        self.assertEqual(self.led.state().grants, [])                    # nothing recorded
        self.assertFalse((self.led.dir / "audit.jsonl").exists() and "grant_" in (self.led.dir / "audit.jsonl").read_text())
        f = self.home / "auth.json"
        rec = {"kind": "deny", "quote": "never on fx", "source": "a note", "scope": {"targets": ["fx-slrum"]},
               "actions": ["launch"], "limits": {}}
        f.write_text(json.dumps([rec]))
        rc, text = run("grant", "import", str(f), "-C", str(self.proj))
        self.assertEqual(rc, USAGE, text)
        self.assertIn("unknown target 'fx-slrum' (scope.targets in", text)
        self.assertEqual(self.led.state().grants, [])
        self.assertEqual(run(*deny, "-T", "fx")[0], OK)                 # a known one: as before
        f.write_text(json.dumps([{**rec, "scope": {"targets": ["ws"]}}]))
        self.assertEqual(run("grant", "import", str(f), "-C", str(self.proj))[0], OK)
        self.assertEqual(run(*deny, "--name", "x")[0], OK)              # no target at all: nothing to check

    def test_r5_1_rsk_grant_deny_job_with_a_launch_action_is_a_usage_error(self):
        """V4-jobdeny: the CLI accepted `--job 101 --action relaunch` (and `--job 101` = every action). Now exit 2
        naming the run to deny by name; `--job J --action cancel` stays."""
        self.led.record_attempt(name="exp--train--a--a01", target="fx", kind="slurm", nonce="n1", submit="submitted",
                                job="101", plan_id="p-1", action="launch")
        base = ("grant", "deny", "-C", str(self.proj), "--quote", "job 101 is broken: do not resubmit it", "--job", "101")
        for extra in (("--action", "relaunch"), (), ("--action", "cancel,launch")):
            rc, text = run(*base, *extra)
            self.assertEqual(rc, USAGE, (extra, text))
            self.assertIn("a deny of a run's launches names the run: --name 'exp--train--a'", text)
        rc, text = run("grant", "deny", "-C", str(self.proj), "--quote", "q", "--job", "999", "--action", "launch")
        self.assertIn("--name '<run>'", text)                            # a job the ledger does not know
        self.assertEqual(self.led.state().grants, [])
        rc, text = run(*base, "--action", "cancel")
        self.assertEqual(rc, OK, text)
        self.assertIn("DENY cancel: jobs 101", text)
        rc, text = run("grant", "deny", "-C", str(self.proj), "--quote", "job 101 is broken: do not resubmit it",
                       "--name", "exp--train--a", "--action", "relaunch")
        self.assertEqual(rc, OK, text)

    def fxp(self) -> None:
        """A third fixture target whose profile lists its partitions (T_PARTITIONS)."""
        d = self.home / "cfg" / "targets" / "fxp"
        d.mkdir(parents=True)
        (d / "profile.sh").write_text("T_KIND=slurm; T_HOST=fxhost; T_PARTITIONS='gpu paid'\n")

    def fxdbg(self, parts: str = "gpu") -> None:
        """fx-dbg: a profile whose T_PARTITIONS is a DISPLAY list (the shipped template: 'policy.sh is the authority')
        — its policy (not read by rsk grant) accepts debug too."""
        d = self.home / "cfg" / "targets" / "fx-dbg"
        d.mkdir(parents=True)
        (d / "profile.sh").write_text(f"T_KIND=slurm; T_HOST=fxhost; T_PARTITIONS='{parts}'\n")
        (d / "policy.sh").write_text('t_partition() { case "$1" in gpu|debug) P_GPUS=1-4 ;; *) return 1 ;; esac; }\n')

    def test_r7_2_a_partition_the_profile_does_not_list_is_recorded_with_a_note(self):
        """N6-partition-authority / NF6-tpartitions-not-authority: R6-5 refused `rsk grant deny -T fx-dbg --partition
        debug` (exit 2 'unknown partition') because fx-dbg's T_PARTITIONS lists only gpu — but T_PARTITIONS is a display
        list and policy.sh accepts debug: the user's deny was lost and a standing grant then covered `-p debug`. Since
        R8-3 such a partition is recorded with --unlisted-partition (import: "unlisted_ok": true), and a NOTE says it is
        not in the profile's display list; without it, exit 2 (test_r8_3_…). The recorded deny matches a plan on that
        partition. No check where a scoped Slurm target lists no T_PARTITIONS, or on a workstation: the NOTE only."""
        self.fxp()
        self.fxdbg()
        deny = ("grant", "deny", "-C", str(self.proj), "--quote", "never use the debug partition, it is for the admins")
        rc, text = run(*deny, "-T", "fx-dbg", "--partition", "debug", "--unlisted-partition")
        self.assertEqual(rc, OK, text)
        self.assertNotIn("unknown partition", text)
        self.assertIn("NOTE: partition debug is not in the profile's display list (T_PARTITIONS of fx-dbg: gpu) — "
                      "recorded as given: policy.sh, not the profile, decides which partitions exist", text)
        d = next(r for r in self.led.state().grants if r["kind"] == "deny")
        self.assertEqual(d["scope"]["partitions"], ["debug"])
        g = grant({"targets": ["fx-dbg"]})
        dec = G.check(state(g, d), "launch", plan=plan(target="fx-dbg", partition="debug"))
        self.assertTrue(dec.denied, dec.reasons)                          # the user's deny is enforced
        self.assertTrue(G.check(state(g, d), "launch", plan=plan(target="fx-dbg", partition="gpu")).covered)
        add = ("grant", "add", "-C", str(self.proj), "--quote", "run the sweep on fxp, charges are fine", "--action",
               "launch", "--max-live", "1", "--max-launches", "1", "--expires", "none")
        for argv, note in (((*add, "-T", "fxp", "--partition", "gpu,piad", "--unlisted-partition"), "partition piad is "
                            "not in the profile's display list (T_PARTITIONS of fxp: gpu, paid)"),
                           ((*deny, "-T", "ws", "--partition", "paid"), "(ws: a workstation has no partitions — no "
                            "launch there names one)"),
                           ((*deny, "--partition", "piad"), "fx: none")):
            rc, text = run(*argv)
            self.assertEqual(rc, OK, (argv, text))
            self.assertIn(note, text)
            self.assertNotIn("unknown partition", text)
        rc, text = run(*deny, "-T", "fxp", "--partition", "paid")        # listed: no NOTE
        self.assertEqual(rc, OK, text)
        self.assertNotIn("NOTE", text)
        f = self.home / "auth.json"
        rec = {"kind": "deny", "quote": "never the debug partition", "source": "a note",
               "scope": {"targets": ["fx-dbg"], "partitions": ["debug"]}, "actions": ["launch"], "limits": {},
               "unlisted_ok": True}
        f.write_text(json.dumps([rec]))
        rc, text = run("grant", "import", str(f), "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertIn("NOTE: partition debug (scope.partitions of #0 in", text)
        self.assertNotIn("unlisted_ok", self.led.state().grants[-1])          # the file's flag, never stored
        rc, text = run(*deny, "-T", "fxp", "--gpu-type", "gt-zz")
        self.assertEqual(rc, OK, text)
        self.assertIn("NOTE: GPU type gt-zz is not checked", text)
        rc, text = run(*deny, "-T", "fx-slrum", "--partition", "debug")  # a target is still checked (R5-9)
        self.assertEqual(rc, USAGE, text)
        self.assertIn("unknown target 'fx-slrum'", text)

    def test_r7_2_t_partitions_splits_on_commas_and_whitespace(self):
        """NF6-tpartitions-commas: harness.Target.partitions split T_PARTITIONS on whitespace only, so 'gpu,preempt'
        (run-avail hands `sinfo -p` a comma list) was one partition and every partition of the target got a NOTE (R6-5:
        a refusal). Commas and whitespace both separate now."""
        self.fxdbg("gpu,preempt  cpu")
        t = next(x for x in G.harness_targets() if x.name == "fx-dbg")
        self.assertEqual(t.partitions, ("gpu", "preempt", "cpu"))
        self.assertEqual(harness.split_partitions(" gpu, preempt\tcpu ,"), ("gpu", "preempt", "cpu"))
        self.assertIsNone(harness.split_partitions(" , "))
        rc, text = run("grant", "deny", "-C", str(self.proj), "--quote", "never preempt on fx-dbg", "-T", "fx-dbg",
                       "--partition", "preempt")
        self.assertEqual(rc, OK, text)
        self.assertNotIn("NOTE", text)
        rc, text = run("grant", "list", "-C", str(self.proj))
        self.assertNotIn("WARNING", text)
        self.assertNotIn("NOTE", text)

    def test_r7_2_r6_9_list_status_and_doctor_flag_only_unknown_targets(self):
        """NF-stored-deny-unknown-target (R6-9), narrowed by R7-2: `rsk grant list` and `rsk doctor` flag an active
        record whose TARGETS the harness does not know ("never matches — fix or revoke"); a partition the profiles do
        not list is never "never matches" (the deny does match a plan on it) — list shows a NOTE instead, doctor
        nothing."""
        self.fxp()
        typo = G.add(self.led, G.new_deny({"targets": ["fx-slrum"]}))
        part = G.add(self.led, G.new_deny({"targets": ["fx", "fx-old"]}))
        fine = G.add(self.led, G.new_deny({"targets": ["FX"]}))       # a deny compares FX as fx
        piad = G.add(self.led, G.new_deny({"targets": ["fxp"], "partitions": ["piad"]}))
        old = G.add(self.led, grant({"targets": ["fx-gone"]}))
        gone = G.add(self.led, G.new_deny({"targets": ["fx-slrum"]}))
        G.revoke(self.led, gone["id"], "recorded wrongly")                 # revoked: nothing to flag
        rc, text = run("grant", "list", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        warn = [ln.strip() for ln in text.splitlines() if "WARNING:" in ln]
        self.assertEqual(len(warn), 3, text)
        self.assertIn(f"WARNING: {typo['id']} (deny): target fx-slrum is not one the harness knows (fx, fxp, ws) — "
                      "never matches (the user's deny is not enforced there) — fix or revoke", text)
        self.assertIn(f"WARNING: {part['id']} (deny): target fx-old is not one the harness knows", text)
        self.assertIn("never matches there", next(w for w in warn if part["id"] in w))        # fx still counts
        self.assertIn(f"WARNING: {old['id']} (grant): target fx-gone", text)
        self.assertIn("(it covers nothing there)", next(w for w in warn if old["id"] in w))
        self.assertNotIn(piad["id"], " ".join(warn))                       # R7-2: a partition is a NOTE
        self.assertIn("NOTE: partition piad is not in the profile's display list (T_PARTITIONS of fxp: gpu, paid)",
                      text)
        self.assertNotIn(fine["id"] + " (deny)", " ".join(warn))
        self.assertNotIn(gone["id"], " ".join(warn))
        doc = json.loads(run("grant", "list", "-C", str(self.proj), "--json")[1])
        probs = {r.get("id"): r.get("scope_problems") for r in doc["records"]}
        self.assertEqual(probs[fine["id"]], [])
        self.assertEqual(probs[piad["id"]], [])
        self.assertTrue(probs[typo["id"]])
        self.assertTrue(next(r for r in doc["records"] if r.get("id") == piad["id"])["scope_notes"])
        rc, text = run("doctor")
        for r in (typo, part, old):
            self.assertRegex(text, rf"WARN .*{self.proj}: {r['id']} \((deny|grant)\): .* never matches")
        self.assertNotIn(piad["id"], text)
        self.assertNotIn(fine["id"] + " (deny)", text)
        # R7-6: rsk status prints the grants block through the same lines(): the same WARNING and NOTE
        body = "\n".join(G.lines(self.led.state(), known=G.harness_targets()))
        self.assertIn(f"WARNING: {typo['id']} (deny): target fx-slrum", body)
        self.assertIn("NOTE: partition piad", body)

    def test_r8_1_rsk_grant_lists_split_on_commas_stripped_whitespace_inside_is_exit_2(self):
        """NF7-split-space / NF7-deny-list-whitespace: `--job '101, 102'` stored ' 102' and `--job '101 102'` one entry,
        neither matching job 102 — a cancel_own grant then cancelled what the user forbade; the same for --name,
        --partition, --gpu-type. Every list argument of add / deny is now split on commas and stripped (the deny matches),
        an item with whitespace inside or an empty item is exit 2 naming it, and import refuses a spaced item."""
        self.fxp()
        deny = ("grant", "deny", "-C", str(self.proj), "--quote", "never cancel jobs 101 or 102")
        rc, text = run(*deny, "--job", "101, 102", "--action", "cancel, cancel_own")
        self.assertEqual(rc, OK, text)
        self.assertIn("DENY cancel, cancel_own: jobs 101, 102", text)
        d = self.led.state().grants[-1]
        self.assertEqual((d["scope"]["jobs"], d["actions"]), (["101", "102"], ["cancel", "cancel_own"]))
        self.assertIsNotNone(G.deny_match({"target": "fx", "kind": "slurm", "name": "sw2", "warnings": "0"},
                                          ("cancel",), state(d), job="102")[0])
        n = len(self.led.state().grants)
        for argv, why in (((*deny, "--job", "101 102", "--action", "cancel"), "--job '101 102': item '101 102' holds "
                           "whitespace"),
                          ((*deny, "--job", "101,", "--action", "cancel"), "--job '101,': an empty item"),
                          ((*deny, "--job", "j101", "--action", "cancel"), "--job j101: a Slurm job id"),
                          ((*deny, "--name", "b1 b2"), "--name 'b1 b2': item 'b1 b2' holds whitespace"),
                          ((*deny, "--name", "b1,,b2"), "an empty item"),
                          ((*deny, "--gpu-type", "a100 h100"), "--gpu-type 'a100 h100'"),
                          ((*deny, "--partition", "gpu paid", "-T", "fxp"), "--partition 'gpu paid'"),
                          ((*deny, "-T", "fx ws"), "-T 'fx ws'"),
                          ((*deny, "--class", "smoke train"), "--class 'smoke train'"),
                          ((*deny, "--action", "launch relaunch"), "--action 'launch relaunch'"),
                          ((*deny, "--run", "a b"), "--run 'a b'"),
                          (("grant", "add", "-C", str(self.proj), "--quote", "q", "--action", "launch", "--name", "a b",
                            "--max-live", "1", "--max-launches", "1", "--expires", "none"), "--name 'a b'")):
            rc, text = run(*argv)
            self.assertEqual(rc, USAGE, (argv, text))
            self.assertIn(why, text)
        self.assertEqual(len(self.led.state().grants), n)                 # nothing recorded by any of them
        rc, text = run(*deny, "--name", "b1, b2", "--gpu-type", " gt-a ,gt-b", "-T", " fxp", "--class", "smoke, train",
                       "--partition", "gpu, paid", "--action", "launch")
        self.assertEqual(rc, OK, text)
        sc = self.led.state().grants[-1]["scope"]
        self.assertEqual((sc["names"], sc["gpu_types"], sc["targets"], sc["classes"], sc["partitions"]),
                         (["b1", "b2"], ["gt-a", "gt-b"], ["fxp"], ["smoke", "train"], ["gpu", "paid"]))
        self.assertNotIn("NOTE: partition", text)                        # (was: ' paid', not in the display list)
        d = self.led.state().grants[-1]
        self.assertTrue(G.deny_match(plan(target="fxp", name="exp--smoke--b2", partition="paid"), ("launch",),
                                     state(d))[0] is None)               # (names b1, b2: exp--smoke--b2 is neither)
        self.assertIsNotNone(G.deny_match(plan(target="fxp", name="b2", partition="paid", gres="gpu:gt-b:1"),
                                          ("launch",), state(d))[0])
        f = self.home / "auth.json"
        rec = {"kind": "deny", "quote": "never b", "source": "a note", "scope": {"names": [" b"]}, "actions": ["launch"],
               "limits": {}}
        f.write_text(json.dumps([rec]))
        rc, text = run("grant", "import", str(f), "-C", str(self.proj))
        self.assertEqual(rc, USAGE, text)
        self.assertIn("scope.names: ' b': whitespace in a scope item", text)
        self.assertEqual(len(self.led.state().grants), n + 1)

    def test_r8_3_a_partition_the_display_list_lacks_is_exit_2_unless_unlisted_partition(self):
        """NF7-deny-partition-typo: R7-2 recorded `rsk grant deny -T fx-dbg --partition dbug` (a typo for debug) with
        the same NOTE as a real unlisted partition, and the deny never matched: the grant covered `-p debug`. Now a
        partition no scoped target's T_PARTITIONS lists is exit 2 naming it — the caller confirms a real one with
        --unlisted-partition (import: "unlisted_ok": true) and it is recorded with the NOTE. A scoped Slurm target
        without T_PARTITIONS, or a workstation: no check."""
        self.fxp()
        self.fxdbg()
        deny = ("grant", "deny", "-C", str(self.proj), "--quote", "never use the debug partition, it is for the admins")
        add = ("grant", "add", "-C", str(self.proj), "--quote", "run the sweep on fxp", "--action", "launch",
               "--max-live", "1", "--max-launches", "1", "--expires", "none")
        for argv, bad, lists in (((*deny, "-T", "fx-dbg", "--partition", "dbug"), "dbug", "fx-dbg: gpu"),
                                 ((*deny, "-T", "fx-dbg", "--partition", "debug"), "debug", "fx-dbg: gpu"),
                                 ((*add, "-T", "fxp", "--partition", "gpu,piad"), "piad", "fxp: gpu, paid"),
                                 ((*deny, "-T", "fxp,fx-dbg", "--partition", "debug"), "debug",
                                  "fx-dbg: gpu; fxp: gpu, paid"),
                                 ((*deny, "-T", "fxp,ws", "--partition", "gpu,piad"), "piad", "fxp: gpu, paid")):
            rc, text = run(*argv)
            self.assertEqual(rc, USAGE, (argv, text))
            self.assertIn(f"partition {bad} is not in the profile's display list (T_PARTITIONS of {lists}) — nothing "
                          "recorded", text)
            self.assertIn("record it again with --unlisted-partition", text)
        self.assertEqual(self.led.state().grants, [])
        rc, text = run(*deny, "-T", "fx-dbg", "--partition", "debug", "--unlisted-partition")
        self.assertEqual(rc, OK, text)
        self.assertIn("NOTE: partition debug is not in the profile's display list (T_PARTITIONS of fx-dbg: gpu)", text)
        d = self.led.state().grants[-1]
        g = grant({"targets": ["fx-dbg"]})
        self.assertTrue(G.check(state(g, d), "launch", plan=plan(target="fx-dbg", partition="debug")).denied)
        for argv in ((*deny, "-T", "fx-dbg", "--partition", "gpu"),          # listed
                     (*deny, "--partition", "dbug"),                         # fx (in scope) lists none: no check
                     (*deny, "-T", "fx,fx-dbg", "--partition", "dbug"),
                     (*deny, "-T", "ws", "--partition", "dbug")):            # a workstation: no T_PARTITIONS
            rc, text = run(*argv)
            self.assertEqual(rc, OK, (argv, text))
        f = self.home / "auth.json"
        rec = {"kind": "deny", "quote": "never the debug partition", "source": "a note",
               "scope": {"targets": ["fx-dbg"], "partitions": ["dbug"]}, "actions": ["launch"], "limits": {}}
        n = len(self.led.state().grants)
        f.write_text(json.dumps([{**rec, "scope": {"targets": ["fx-dbg"], "partitions": ["gpu"]}}, rec]))
        rc, text = run("grant", "import", str(f), "-C", str(self.proj))
        self.assertEqual(rc, USAGE, text)
        self.assertIn("partition dbug (scope.partitions of #1 in", text)
        self.assertIn('record it again with "unlisted_ok": true in record #1', text)
        self.assertEqual(len(self.led.state().grants), n)                     # all or nothing
        f.write_text(json.dumps([{**rec, "unlisted_ok": "yes"}]))
        rc, text = run("grant", "import", str(f), "-C", str(self.proj))
        self.assertEqual(rc, USAGE, text)
        self.assertIn("unlisted_ok must be true or false", text)
        f.write_text(json.dumps([{**rec, "unlisted_ok": True}]))
        rc, text = run("grant", "import", str(f), "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertIn("NOTE: partition dbug (scope.partitions of #0 in", text)
        self.assertEqual(len(self.led.state().grants), n + 1)

    def test_r7_1_rsk_grant_deny_with_an_attempt_name_says_it_stands_for_the_run(self):
        """N6-deny-attempt-name: the deny is recorded as given (a NOTE says the attempt's name stands for its run, and
        the record's description names the run), and it matches the run's next attempt."""
        rc, text = run("grant", "deny", "-C", str(self.proj), "--quote", "do not relaunch exp--train--lr--s0--a02",
                       "--name", "exp--train--lr--s0--a02", "--action", "relaunch")
        self.assertEqual(rc, OK, text)
        self.assertIn("NOTE: name exp--train--lr--s0--a02 is an attempt's name (--aNN): the deny stands for run "
                      "exp--train--lr--s0 — every attempt of it", text)
        self.assertIn("names exp--train--lr--s0--a02 (= run exp--train--lr--s0: every attempt of it)", text)
        d = self.led.state().grants[0]
        self.assertEqual(d["scope"]["names"], ["exp--train--lr--s0--a02"])
        g = grant({"names": ["exp--train--*"]}, actions=("launch", "relaunch"))
        self.assertTrue(G.deny_match(plan(name="exp--train--lr--s0--a03"), ("relaunch",), state(g, d))[0])
        rc, text = run("grant", "deny", "-C", str(self.proj), "--quote", "never launch run r", "--name", "r")
        self.assertNotIn("attempt's name", text)
        rc, text = run("grant", "deny", "-C", str(self.proj), "--quote", "no attempt of exp--train--lr--s1, ever",
                       "--name", "exp--train--lr--s1--a*", "--action", "relaunch")
        self.assertEqual(rc, OK, text)                                 # a glob over its attempt names: the run too
        self.assertIn("NOTE: name exp--train--lr--s1--a* matches attempts' names (--aNN): the deny stands for run "
                      "exp--train--lr--s1 — every attempt of it", text)
        d2 = self.led.state().grants[-1]
        self.assertTrue(G.deny_match(plan(name="exp--train--lr--s1"), ("launch",), state(g, d2))[0])


if __name__ == "__main__":
    unittest.main()
