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

from remote_run import cli
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
    return G.new_approval(quote, plans, plan_ids=[p.get("plan_id", "p-test") for p in plans], **kw)


def state(*recs: dict, runs: dict | None = None, now: float | None = None) -> L.LedgerState:
    return L.LedgerState(grants=list(recs), runs=runs or {}, now=now)


def grant(scope: dict | None = None, actions=("launch",), **lim) -> dict:
    lim = {"max_live": None, "max_launches": None, "expires": None, **lim}
    return G.new_grant("you can submit these yourself", scope or {}, list(actions), **lim)


def cancel_ap(quote: str, target: str, jobs: list[str], **kw) -> dict:
    """A cancel approval as rsk cancel records it: each job bound to its identity (Slurm: job, name, WorkDir)."""
    return G.new_cancel_approval(quote, target, jobs, idents=[ident(target, j) for j in jobs], **kw)


def ident(target: str, job: str, name: str = "", workdir: str = "/r/proj") -> str:
    return G.cancel_ident("slurm", target, job, name, workdir)


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
        for change, why in (({"quote": "  "}, "quote"), ({"kind": "maybe"}, "kind"), ({"extra": 1}, "unknown key"),
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
            G.new_deny("never there", {"max_gpus": 4})
        self.assertIn("a deny takes", str(cm.exception))
        with self.assertRaises(RskError):
            G.validate({**approval("ok", [plan()]), "scope": {}})
        with self.assertRaises(RskError):
            G.validate({**cancel_ap("stop it", "fx", ["5"]), "scope": {"targets": ["fx"]}})
        missing = dict(g)
        del missing["source"]
        with self.assertRaises(RskError):
            G.validate(missing)


class Covers(unittest.TestCase):
    def test_deny_wins(self):
        st = state(grant({"targets": ["fx"]}), approval("yes", [plan()]),
                   G.new_deny("never on gpu", {"partitions": ["gpu"]}))
        d = G.check(st, "launch", plan=plan())
        self.assertFalse(d.covered)
        self.assertTrue(d.denied)
        self.assertEqual(d.code, REFUSED)
        self.assertIn('"never on gpu"', d.reasons[0])
        self.assertEqual(d.needs, "")
        other = G.check(st, "launch", plan=plan(partition="part-c"))   # outside the deny: the grant
        self.assertEqual((other.covered, other.record["kind"]), (True, "grant"))
        st2 = state(grant(), G.new_deny("not that type", {"gpu_types": ["gt-b"]}))
        self.assertTrue(G.check(st2, "launch", plan=plan(gres="gpu:4")).denied)     # any type may land on gt-b
        self.assertTrue(G.check(st2, "launch", plan=plan()).covered)                # gt-a is not gt-b
        self.assertFalse(G.check(state(grant(), G.new_deny("x", {"names": ["exp*"]}, ["cancel"])), "launch",
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
        d = G.new_deny("no", {})
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
        g = grant(actions=("launch", "relaunch"))
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

    def test_cancel_approval_names_its_jobs_and_cancel_own_its_runs(self):
        ap = cancel_ap("cancel job 123", "fx", ["123"])
        st = state(ap)
        self.assertTrue(G.check(st, "cancel", job="123", plan={"target": "fx"}, ident=ident("fx", "123")).covered)
        self.assertFalse(G.check(st, "cancel", job="124", plan={"target": "fx"}, ident=ident("fx", "124")).covered)
        ap["used"].append({"nonce": "k1", "action": "cancel", "hash": "", "job": "123", "at": L.now()})
        self.assertFalse(G.check(st, "cancel", job="123", plan={"target": "fx"}, ident=ident("fx", "123")).covered)
        own = {"name": "exp--a01", "target": "fx", "kind": "slurm",
               "request": {"action": "launch", "plan": "p-1", "bound": {"partition": "gpu"}},
               "submissions": [{"nonce": "n1", "submit": "submitted", "job": "7"}]}
        theirs = {**own, "request": {"action": "adopted"}, "submissions": [{"nonce": "x", "submit": "adopted", "job": "8"}]}
        runs = {"exp": {"run": "exp", "attempts": {"a01": own, "a02": theirs}}}
        g = grant({"targets": ["fx"]}, actions=("launch", "cancel_own"))
        st = state(g, runs=runs)
        self.assertTrue(G.check(st, "cancel", job="7", run="exp").covered)
        d = G.check(st, "cancel", job="8", run="exp")
        self.assertFalse(d.covered)
        self.assertIn("not one rsk launched", " ".join(d.reasons))
        self.assertFalse(G.check(state(grant({"targets": ["fx"]}), runs=runs), "cancel", job="7", run="exp").covered)
        self.assertTrue(G.check(state(g, G.new_deny("never cancel", {}, ["cancel"]), runs=runs), "cancel", job="7",
                                run="exp").denied)
        self.assertFalse(G.check(state(g, G.new_deny("only I stop runs", {}, ["cancel_own"]), runs=runs), "cancel",
                                 job="7", run="exp").covered)
        self.assertTrue(G.check(state(ap, G.new_deny("only I stop runs", {}, ["cancel_own"])), "cancel", job="124",
                                plan={"target": "fx"}, ident=ident("fx", "124")).covered is False)
        named = G.new_cancel_approval("cancel job 7", "fx", ["7"], idents=[ident("fx", "7", "exp--a01")])
        d = G.check(state(g, named, G.new_deny("only I stop runs", {}, ["cancel_own"]), runs=runs), "cancel", job="7",
                    run="exp", ident=ident("fx", "7", "exp--a01"))   # the user's named cancel beats cancel_own's deny
        self.assertEqual((d.covered, d.record["id"]), (True, named["id"]))
        d = G.check(state(g, G.new_deny("only I stop runs", {}, ["cancel_own"]), runs=runs), "cancel", job="7", run="exp")
        self.assertIn("cancel_own is denied", " ".join(d.reasons))
        bad = grant()
        bad["limits"]["expires"] = "someday"                           # a hand-edited file: invalid, covers nothing
        d = G.check(state(bad), "launch", plan=plan())
        self.assertFalse(d.covered)
        self.assertIn("INVALID record covers nothing", d.reasons[0])

    def test_after_deny_flag(self):
        d = G.new_deny("not on gpu", {"partitions": ["gpu"]})
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
                         "launch: targets fx; <= 4 GPUs; <= 2:00:00; no plan with warnings")
        self.assertIn("2 approved plan(s)", G.describe(approval("ok", [plan(), plan(name="x--a01")])))
        self.assertIn("cancel of job(s) 5", G.describe(cancel_ap("stop 5", "fx", ["5"])))
        self.assertEqual(G.describe(G.new_deny("no", {"names": ["x*"]})), "DENY every action: names x*")
        self.assertEqual(G.describe(G.new_deny("no", {}, ["cancel"])), "DENY cancel: anything")
        self.assertIn("no limit (user's words)", G.balance(grant(), state()))


class ReviewFixes(unittest.TestCase):
    """The P3 review findings, each pinned (H2 H3 M1 M2 M5 L1 L5 and `resubmit` in a new grant)."""

    def test_h2_sbatch_extra_time_and_resources_are_never_a_grants_call(self):
        f = G.facts(plan(extra="--time=7-00:00:00 --qos=normal -t 2:00:00"))
        self.assertEqual((f.time_s, f.time_extra, f.extra_res),     # time: the bound field (D1: the words decide)
                         (86400, "2:00:00", ("--time=7-00:00:00", "-t", "2:00:00")))
        f = G.facts(plan(extra="--nodes=8 --gpus-per-node=4 --mem-per-c=2G -N2 --exclude=n1 --mem=9G -n 4"))
        self.assertEqual(f.extra_res, ("--nodes=8", "--gpus-per-node=4", "--mem-per-c=2G", "-N2", "--mem=9G", "-n", "4"))
        self.assertEqual(G.facts(plan(extra="--tim=5")).extra_res, ("--tim=5",))         # an abbreviation: anything else
        capped = grant({"max_time_s": 3600, "max_gpus": 2}, max_live=None, max_launches=None, expires=None)
        d = G.check(state(capped), "launch", plan=plan(time="30", extra="--time=7-00:00:00"))
        self.assertFalse(d.covered)
        self.assertIn("SBATCH_EXTRA word(s) no standing grant covers (--time=7-00:00:00)", " ".join(d.reasons))
        open_ = grant({"targets": ["fx"]})                          # no caps at all: still the user's call
        d = G.check(state(open_), "launch", plan=plan(extra="--nodes=8 --gpus-per-node=4"))
        self.assertFalse(d.covered)
        self.assertIn("(--nodes=8, --gpus-per-node=4)", " ".join(d.reasons))
        p = plan(extra="--nodes=8")
        self.assertTrue(G.check(state(approval("yes, 8 nodes", [p])), "launch", plan=p).covered)   # the user saw it
        self.assertTrue(G.check(state(open_), "launch", plan=plan(extra="--qos=normal --exclude=n1")).covered)

    def test_h3_the_names_class_decides_and_a_deny_matches_either(self):
        smoke = grant({"classes": ["smoke"]})
        train_name = {**plan(), "class": "smoke"}                   # name exp--train--…, labelled smoke
        d = G.check(state(smoke), "launch", plan=train_name)
        self.assertFalse(d.covered)
        self.assertIn("class train not in smoke", " ".join(d.reasons))
        deny = G.new_deny("no train runs this week", {"classes": ["train"]})
        self.assertTrue(G.check(state(smoke, deny), "launch", plan=train_name).denied)
        labelled = {**plan(name="exp-plain--a01"), "class": "train"}
        self.assertTrue(G.check(state(grant(), deny), "launch", plan=labelled).denied)     # the label alone
        self.assertFalse(G.check(state(grant(), deny), "launch",
                                 plan={**plan(name="exp--smoke--x--a01")}).denied)

    def test_m1_a_deny_of_launch_stops_every_way_of_starting_a_run(self):
        deny = G.new_deny("stop launching anything on fx today", {"targets": ["fx"]}, ["launch"])
        g = grant(actions=("launch", "chain", "relaunch"))
        g["actions"].append("resubmit")
        for action in ("launch", "chain", "relaunch", "resubmit"):
            self.assertTrue(G.check(state(g, deny), action, plan=plan(), run="exp").denied, action)
        self.assertFalse(G.check(state(g, deny), "cancel", job="5", plan={"target": "fx"}).denied)
        only_chain = G.new_deny("no chains", {}, ["chain"])
        self.assertFalse(G.check(state(g, only_chain), "launch", plan=plan()).denied)

    def test_m2_deny_names_match_the_run_id_grants_the_name_only(self):
        deny = G.new_deny("never run exp--train--big again", {"names": ["exp--train--big"]})
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
        self.assertIn("resubmit", G.new_deny("no resubmits", {}, ["resubmit"])["actions"])


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

    def test_d1_g2_1_g2_3_g2_8_coverage_reads_conf_extra_only(self):
        open_ = grant({"targets": ["fx"], "max_time_s": 3600})
        for extra in ("--time=7-00:00:00 --comment -t1", "--thread-spec=1", "-S 1", "--core-spec=1", "--exclusive"):
            d = G.check(state(open_), "launch", plan=plan(time="30", extra=extra))
            self.assertFalse(d.covered, extra)
            self.assertIn("SBATCH_EXTRA word(s) no standing grant covers", " ".join(d.reasons), extra)
            p = plan(time="30", extra=extra)
            self.assertTrue(G.check(state(approval("yes, as shown", [p])), "launch", plan=p).covered)  # the card
        self.assertTrue(G.check(state(open_), "launch", plan=plan(time="30", extra="--comment -t1")).covered)
        pinned = plan(time="30", extra="--nodelist=n1", conf_extra="")     # a site policy's SB_ARGS word (grants#8)
        self.assertTrue(G.check(state(open_), "launch", plan=pinned).covered)
        old = plan(time="30", conf_extra=None)                               # a block from before conf_extra
        self.assertNotIn("conf_extra", old)
        d = G.check(state(open_), "launch", plan=old)
        self.assertFalse(d.covered)
        self.assertIn("no conf_extra", " ".join(d.reasons))

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

    def test_d5_r1_2_a_relaunch_grant_resumes_only_an_infrastructure_end(self):
        g = grant(actions=("launch", "relaunch"))
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

    def test_d5_g2_4_g2_6_every_derived_action_is_checked(self):
        run = "exp--train--base--scratch--s0"
        deny = G.new_deny("do not relaunch it, it is broken", {"names": [run]}, ["relaunch"])
        p = plan(name=run)                                           # a plain launch of a run that has attempts
        d = G.check(state(grant(actions=("launch", "relaunch")), deny, runs=self._runs("PREEMPTED")), "relaunch",
                    plan=p, run=run)
        self.assertTrue(d.denied)
        chain_deny = G.new_deny("never chain jobs", {}, ["chain"])
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
        deny = G.new_deny("no more train runs", {"classes": ["train"]})
        relabelled = {**plan(name="bigrun--a02"), "class": "smoke", "classes_recorded": ["train"]}
        self.assertTrue(G.check(state(grant(actions=("launch", "relaunch")), deny), "launch", plan=relabelled).denied)

    def test_g2_7_g2_10_damaged_records_deny_until_fixed_or_revoked(self):
        g = grant()
        valid_deny = G.new_deny("never on the debug partition", {"partitions": ["debug"]})
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
        broken_grant = {**grant(), "quote": ""}                      # an invalid grant still covers nothing, no deny
        d = G.check(state(broken_grant), "launch", plan=plan())
        self.assertEqual((d.covered, d.denied), (False, False))

    def test_g2_11_same_config_empty_equals_quoted_empty_equals_absent(self):
        orig = plan()
        b = {k: v for k, v in G.bound(orig).items() if k not in ("env_hook", "venv_dir", "uv_sync_args", "conf_extra")}
        self.assertEqual(G.same_config({"target": "fx", "kind": "slurm", "bound": b},
                                       plan(name="exp--train--base--scratch--s0--a02")), [])
        self.assertTrue(G.same_config({"target": "fx", "kind": "slurm", "bound": b},
                                      plan(name="exp--train--base--scratch--s0--a02", venv_dir="/v")))

    def test_d6_g3_flow_1_cancel_approvals_bind_identity_and_expire(self):
        ap = G.new_cancel_approval("kill pid 20331 on the box", "ws", ["20331"],
                                   idents=[G.cancel_ident("nohup", "ws", "20331", "111", "boot-a")])
        st = state(ap)
        mine = G.cancel_ident("nohup", "ws", "20331", "111", "boot-a")
        other = G.cancel_ident("nohup", "ws", "20331", "999", "boot-a")      # the pid came round to another run
        self.assertTrue(G.check(st, "cancel", job="20331", plan={"target": "ws"}, ident=mine).covered)
        d = G.check(st, "cancel", job="20331", plan={"target": "ws"}, ident=other)
        self.assertFalse(d.covered)
        self.assertIn("the user's words were for that one", " ".join(d.reasons))
        self.assertFalse(G.check(st, "cancel", job="20331", plan={"target": "ws"}).covered)    # no identity: no
        later = state(ap, now=time.time() + G.CANCEL_TTL_S + 60)
        self.assertFalse(G.check(later, "cancel", job="20331", plan={"target": "ws"}, ident=mine).covered)
        old = {**ap, "scope": {"jobs": ["20331"], "targets": ["ws"]}, "limits": {**ap["limits"], "expires": None}}
        self.assertIn("scope.idents", G.valid(old))                  # from before identity binding: covers nothing
        self.assertFalse(G.check(state(old), "cancel", job="20331", plan={"target": "ws"}, ident=mine).covered)
        self.assertIn("bound to pid 20331 on ws", G.describe(ap))

    def test_r1_6_cancel_own_counts_its_uses(self):
        g = grant({"classes": ["smoke"]}, actions=("cancel_own",), max_live=None, max_launches=1, expires=None)
        own = {"name": "exp--smoke--a--a01", "target": "fx", "kind": "slurm",
               "request": {"action": "launch", "plan": "p-1", "bound": {"partition": "gpu"}},
               "submissions": [{"nonce": "n1", "submit": "submitted", "job": "7"}]}
        runs = {"exp--smoke--a": {"run": "exp--smoke--a", "attempts": {"a01": own}}}
        self.assertTrue(G.check(state(g, runs=runs), "cancel", job="7", run="exp--smoke--a").covered)
        self.assertIn("uses 0/1", G.balance(g, state(g)))
        g["used"].append({"nonce": "c1", "action": "cancel", "hash": "", "job": "6", "at": L.now()})
        d = G.check(state(g, runs=runs), "cancel", job="7", run="exp--smoke--a")
        self.assertFalse(d.covered)
        self.assertIn("used 1 of 1", " ".join(d.reasons))
        self.assertIn("uses 1/1", G.balance(g, state(g)))
        mixed = grant(actions=("launch", "cancel_own"), max_launches=2)
        self.assertIn("cancels 0/2", G.balance(mixed, state(mixed)))

    def test_d8_deny_match_with_an_unknown_job_fails_closed(self):
        deny = G.new_deny("never cancel job 9", {"jobs": ["9"]}, ["cancel"])
        row = {"target": "fx", "kind": "slurm", "name": "a", "warnings": "0"}
        self.assertIsNotNone(G.deny_match(row, ("cancel",), state(deny), job=None)[0])
        self.assertIsNone(G.deny_match(row, ("cancel",), state(deny), job="8")[0])
        self.assertIsNone(G.deny_match(row, ("launch",), state(deny), job=None)[0])
        own = G.new_deny("only I stop runs", {}, ["cancel_own"])
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
        deny = G.new_deny("do not touch that run, whatever happens", {"runs": [p["bound_hash"]]})
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
        pdeny = G.new_deny("never that plan", {"plans": ["p-1"]})
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
        self.assertTrue(G.check(state(grant(), G.new_deny("no more train runs", {"classes": ["train"]})), "launch",
                                plan=relabelled).denied)
        labelled = {**plan(name="bigrun--a02"), "class": "smoke", "classes_recorded": ["smoke"]}
        self.assertTrue(G.check(state(grant({"classes": ["smoke"]})), "launch", plan=labelled).covered)
        self.assertEqual(G.run_classes({"attempts": {"a02": {"request": {"class": ""}, "name": "x--a02"},
                                                     "a01": {"request": {}, "name": "x--smoke--a01"}}}), ["smoke", ""])

    def test_r4_6_a_plan_with_policy_flags_is_never_a_grants_call(self):
        """NEW-policy-flag: a policy flag the agent chose (`--whole-node` → the policy adds --exclusive) rode on a
        1-GPU grant. The block binds flags=; no standing grant covers a plan with any (the card lists them)."""
        g = grant({"targets": ["fx"], "max_gpus": 2})
        flagged = plan(flags="--whole-node")
        self.assertEqual(G.facts(flagged).flags, ("--whole-node",))
        d = G.check(state(g), "launch", plan=flagged)
        self.assertFalse(d.covered)
        self.assertIn("policy flag(s) --whole-node", " ".join(d.reasons))
        self.assertTrue(G.check(state(g), "launch", plan=plan()).covered)
        self.assertTrue(G.check(state(g, approval("yes, the whole node", [flagged])), "launch", plan=flagged).covered)
        old = plan(flags=None)                       # a deploy from before flags= was bound
        self.assertFalse(G.facts(old).flags_known)
        self.assertIn("does not name its policy flags", " ".join(G.check(state(g), "launch", plan=old).reasons))
        self.assertIn("flags", G.NEEDED["slurm"])
        self.assertEqual(G.SLURM_BOUND[-2:], ("flags", "chain"))   # immediately before chain=, as submit.sh prints it

    def test_r4_10_cancel_own_never_covers_an_attempt_the_ledger_shows_ended(self):
        """N1-cancel-job-ended-pid: the ledger's ended submission of a pid the box has since reused made the cancel
        'own'; only a live submission is."""
        p = plan(name=f"{self.RUN}--a01")
        g = grant({"targets": ["fx"]}, actions=("cancel_own",))
        live = {self.RUN: {"run": self.RUN, "attempts": {"a01": self._att(p, "a01", None, "101", "p-1")}}}
        ended = {self.RUN: {"run": self.RUN, "attempts": {"a01": self._att(p, "a01", "ENDED", "101", "p-1")}}}
        self.assertTrue(G.check(state(g, runs=live), "cancel", job="101", run=self.RUN).covered)
        d = G.check(state(g, runs=ended), "cancel", job="101", run=self.RUN)
        self.assertFalse(d.covered)
        self.assertIn("not one rsk launched", " ".join(d.reasons))
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
                G.new_deny("job 101 is broken: do not resubmit it", {"jobs": ["101"]}, acts)
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
        ok = G.new_deny("never cancel job 101", {"jobs": ["101"]}, ["cancel", "cancel_own"])   # cancels: as before
        self.assertEqual(G.valid(ok), "")
        self.assertTrue(G.check(state(g, ok, runs=runs), "relaunch", plan=p, run=self.RUN).covered)
        byname = G.new_deny("job 101 is broken: do not resubmit it", {"names": [self.RUN]}, ["relaunch"])
        self.assertTrue(G.check(state(g, byname, runs=runs), "relaunch", plan=p, run=self.RUN).denied)

    def test_r5_8_a_deny_compares_normalised_target_names(self):
        """WATCH-target-spelling-evades-deny: a run-watch row on `fx-slurm/` (the same profile dir, the same deploy)
        never matched `-T fx-slurm`. A deny now compares grants.target_key names; a spelling that is not one plain
        name may be any target (it matches)."""
        deny = G.new_deny("never launch anything on fx-slurm any more", {"targets": ["fx-slurm"]})
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
            d = G.new_deny("do not relaunch a, it is broken", {"names": ["a"]}, acts)
            for tgt in ("fx", "fx2"):
                for name, action in (("a", "launch"), ("a--a03", "launch"), ("a", "chain")):
                    dec = G.check(state(g, d), action, plan=plan(name=name, target=tgt))
                    self.assertTrue(dec.denied, (acts, tgt, name, action, dec.reasons))
                    self.assertIn("do not relaunch a, it is broken", dec.reasons[0])
                    self.assertIn("rsk cannot see every earlier attempt", dec.reasons[0])
            self.assertTrue(G.check(state(g, d), "launch", plan=plan(name="a2", target="fx2")).covered)   # another run
            self.assertIsNone(G.deny_match(plan(name="a"), ("cancel",), state(d), job="1")[0])   # cancels: untouched
            self.assertIn("every launch of it too", G.describe(d))
            self.assertTrue(G.run_deny(d))
        scoped = G.new_deny("do not relaunch a on fx", {"names": ["a"], "targets": ["fx"]}, ["relaunch"])
        self.assertTrue(G.check(state(g, scoped), "launch", plan=plan(name="a", target="fx")).denied)
        self.assertTrue(G.check(state(g, scoped), "launch", plan=plan(name="a", target="fx2")).covered)   # its scope
        unnamed = G.new_deny("never relaunch anything on fx2", {"targets": ["fx2"]}, ["relaunch"])
        self.assertFalse(G.run_deny(unnamed))                         # names no run: the derived action decides
        self.assertTrue(G.check(state(g, unnamed), "launch", plan=plan(name="a", target="fx2")).covered)
        self.assertNotIn("every launch of it too", G.describe(unnamed))
        d = G.new_deny("do not relaunch a, it is broken", {"names": ["a"]}, ["relaunch"])
        later = grant({"targets": ["fx2"], "names": ["a*"]})            # a launch grant right after it: flagged
        self.assertTrue(G.after_deny(later, [d, later]))
        self.assertEqual(G.after_deny(later, [unnamed, later]), [])      # an unnamed relaunch deny: launches untouched
        launch_deny = G.new_deny("never launch a", {"names": ["a"]}, ["launch"])
        dec = G.check(state(g, launch_deny), "launch", plan=plan(name="a", target="fx2"))
        self.assertTrue(dec.denied)
        self.assertNotIn("rsk cannot see every earlier attempt", dec.reasons[0])   # a launch deny needs no widening


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
        G.add(self.led, G.new_deny("never launch anything on fx", {"targets": ["fx"]}))   # .prev: without it
        (self.led.dir / "grants.json").write_text('{"version": 1, "records": [')
        d = G.check(self.led, "launch", plan=plan())
        self.assertEqual(d.code, REFUSED, d.reasons)
        self.assertIn("never launch anything on fx", " ".join(d.reasons))
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
        G.revoke(led, g["id"], "stop that")                             # .prev: g not revoked
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
        G.add(self.led, G.new_deny("never on fx", {"targets": ["fx"]}))
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
        self.assertIn('quote: "never the part-b queue"', text)
        self.assertIn("FLAG:", text)
        rc, text = run("grant", "revoke", gid, "-C", str(self.proj), "--quote", "enough")
        self.assertEqual(rc, OK, text)
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
        self.assertEqual((rec["created_via"], rec["quote"]), ("import", good["quote"]))
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

    def test_r6_5_a_partition_no_scoped_target_lists_is_refused(self):
        """V5-deny-partition-typo: `rsk grant deny -T fx-paid --partition piad` was stored and matched nothing, so a
        grant that allows the paid partition covered it. A partition is now checked against the scoped targets'
        T_PARTITIONS when every scoped Slurm target lists them (exit 2 'unknown partition', nothing recorded); else a
        NOTE says it is not checked there. A GPU type has no list: echoed in a NOTE."""
        self.fxp()
        deny = ("grant", "deny", "-C", str(self.proj), "--quote", "never use the paid partition again")
        add = ("grant", "add", "-C", str(self.proj), "--quote", "run the sweep on fxp, charges are fine", "--action",
               "launch", "--max-live", "1", "--max-launches", "1", "--expires", "none")
        for argv in ((*deny, "-T", "fxp", "--partition", "piad"), (*add, "-T", "fxp", "--partition", "gpu,piad"),
                     (*deny, "-T", "ws", "--partition", "paid")):
            rc, text = run(*argv)
            self.assertEqual(rc, USAGE, (argv, text))
            self.assertIn("unknown partition", text)
        self.assertIn("fxp list gpu, paid (T_PARTITIONS)", run(*deny, "-T", "fxp", "--partition", "piad")[1])
        self.assertIn("none (a workstation has no partitions)", run(*deny, "-T", "ws", "--partition", "paid")[1])
        self.assertEqual(self.led.state().grants, [])                    # nothing recorded
        f = self.home / "auth.json"
        rec = {"kind": "deny", "quote": "never the paid partition", "source": "a note",
               "scope": {"targets": ["fxp"], "partitions": ["piad"]}, "actions": ["launch"], "limits": {}}
        f.write_text(json.dumps([rec]))
        rc, text = run("grant", "import", str(f), "-C", str(self.proj))
        self.assertEqual(rc, USAGE, text)
        self.assertIn("unknown partition 'piad' (scope.partitions of #0 in", text)
        self.assertEqual(self.led.state().grants, [])
        rc, text = run(*deny, "-T", "fxp", "--partition", "paid")       # spelled as the profile lists it
        self.assertEqual(rc, OK, text)
        self.assertNotIn("NOTE", text)
        rc, text = run(*deny, "--partition", "piad")                    # every target: fx lists none — not checked
        self.assertEqual(rc, OK, text)
        self.assertIn("NOTE: partition piad is not checked on fx (its profile lists no T_PARTITIONS)", text)
        rc, text = run(*deny, "-T", "fxp", "--gpu-type", "gt-zz")
        self.assertEqual(rc, OK, text)
        self.assertIn("NOTE: GPU type gt-zz is not checked", text)
        f.write_text(json.dumps([{**rec, "scope": {"targets": ["fxp"], "partitions": ["paid"]}}]))
        self.assertEqual(run("grant", "import", str(f), "-C", str(self.proj))[0], OK)

    def test_r6_9_list_and_doctor_flag_a_stored_record_naming_what_the_harness_does_not_know(self):
        """NF-stored-deny-unknown-target: a deny stored before R5-9 with a misspelt target (or a target removed since)
        matched nothing, and neither `rsk grant list` nor `rsk doctor` said so. Both now flag every active record
        whose targets — or partitions, where the profiles list them — the harness does not know."""
        self.fxp()
        typo = G.add(self.led, G.new_deny("never launch anything on fx again", {"targets": ["fx-slrum"]}))
        part = G.add(self.led, G.new_deny("never launch on fx or fx-old", {"targets": ["fx", "fx-old"]}))
        fine = G.add(self.led, G.new_deny("never on FX", {"targets": ["FX"]}))       # a deny compares FX as fx
        piad = G.add(self.led, G.new_deny("never the paid partition", {"targets": ["fxp"], "partitions": ["piad"]}))
        old = G.add(self.led, grant({"targets": ["fx-gone"]}))
        gone = G.add(self.led, G.new_deny("never on fx-slrum", {"targets": ["fx-slrum"]}))
        G.revoke(self.led, gone["id"], "recorded wrongly")                 # revoked: nothing to flag
        rc, text = run("grant", "list", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        warn = [ln.strip() for ln in text.splitlines() if "WARNING:" in ln]
        self.assertEqual(len(warn), 4, text)
        self.assertIn(f"WARNING: {typo['id']} (deny): target fx-slrum is not one the harness knows (fx, fxp, ws) — "
                      "never matches (the user's deny is not enforced there) — fix or revoke", text)
        self.assertIn(f"WARNING: {part['id']} (deny): target fx-old is not one the harness knows", text)
        self.assertIn("never matches there", next(w for w in warn if part["id"] in w))        # fx still counts
        self.assertIn(f"WARNING: {piad['id']} (deny): partition piad is not one fxp lists (T_PARTITIONS: gpu, paid) "
                      "— never matches", text)
        self.assertIn(f"WARNING: {old['id']} (grant): target fx-gone", text)
        self.assertIn("(it covers nothing there)", next(w for w in warn if old["id"] in w))
        self.assertNotIn(fine["id"] + " (deny)", " ".join(warn))
        self.assertNotIn(gone["id"], " ".join(warn))
        doc = json.loads(run("grant", "list", "-C", str(self.proj), "--json")[1])
        probs = {r.get("id"): r.get("scope_problems") for r in doc["records"]}
        self.assertEqual(probs[fine["id"]], [])
        self.assertTrue(probs[typo["id"]])
        rc, text = run("doctor")
        for r in (typo, part, piad, old):
            self.assertRegex(text, rf"WARN .*{self.proj}: {r['id']} \((deny|grant)\): .* never matches")
        self.assertNotIn(fine["id"] + " (deny)", text)


if __name__ == "__main__":
    unittest.main()
