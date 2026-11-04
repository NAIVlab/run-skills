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
from remote_run.errors import NEEDS_USER, OK, REFUSED, USAGE, RskError

SLURM_BOUND = ("kind", "target", "partition", "gres", "cpus", "mem", "time", "account", "name", "extra", "payload",
               "env_kind", "env_name", "wandb_mode", "chain")


def block(**kv: str) -> str:
    """A Slurm plan reply as remote/submit.sh prints it (values %q; bound_hash over kind= … chain=)."""
    base = {"kind": "slurm", "target": "fx", "partition": "gpu", "gres": "gpu:gt-a:2", "cpus": "16", "mem": "64G",
            "time": "1-00:00:00", "account": "''", "name": "exp--train--base--scratch--s0--a01", "extra": "",
            "payload": "python train.py --lr 0.1", "env_kind": "uv", "env_name": "''", "wandb_mode": "online",
            "chain": "0", "warnings": "0"}
    base.update(kv)
    bound = [f"{k}={base[k]}" for k in SLURM_BOUND]
    h = kv.get("bound_hash") or hashlib.sha256(("\n".join(bound) + "\n").encode()).hexdigest()
    return ("attempt: .rs/attempts/n\n@@plan v1\napi=3\n" + "".join(ln + "\n" for ln in bound)
            + f"info_avail=''\nwarnings={base['warnings']}\nbound_hash={h}\n@@end\n")


def plan(**kv: str) -> dict:
    return G.parse_plan(block(**kv))


def state(*recs: dict, runs: dict | None = None, now: float | None = None) -> L.LedgerState:
    return L.LedgerState(grants=list(recs), runs=runs or {}, now=now)


def grant(scope: dict | None = None, actions=("launch",), **lim) -> dict:
    lim = {"max_live": None, "max_launches": None, "expires": None, **lim}
    return G.new_grant("you can submit these yourself", scope or {}, list(actions), **lim)


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
        self.assertEqual(G.facts({**plan(), "class": "smoke"}).cls, "smoke")
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
            G.validate({**G.new_approval("ok", [plan()]), "scope": {}})
        with self.assertRaises(RskError):
            G.validate({**G.new_cancel_approval("stop it", "fx", ["5"]), "scope": {"targets": ["fx"]}})
        missing = dict(g)
        del missing["source"]
        with self.assertRaises(RskError):
            G.validate(missing)


class Covers(unittest.TestCase):
    def test_deny_wins(self):
        st = state(grant({"targets": ["fx"]}), G.new_approval("yes", [plan()]),
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
        self.assertTrue(G.check(state(grant({"allow_warnings": True})), "launch", plan=warned).covered)
        self.assertFalse(G.check(state(G.new_approval("ok", [warned])), "launch", plan=warned).covered)
        self.assertTrue(G.check(state(G.new_approval("ok", [warned], allow_warnings=True)), "launch",
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
        ap = G.new_approval("run both seeds", [p1, p2])
        st = state(ap)
        self.assertTrue(G.check(st, "launch", plan=p1).covered)
        self.assertFalse(G.check(st, "launch", plan=plan(name="exp--train--base--scratch--s2--a01")).covered)
        ap["used"].append({"nonce": "n1", "action": "launch", "hash": H1, "job": "", "at": L.now()})
        self.assertIn("used 1 time", " ".join(G.check(st, "launch", plan=p1).reasons))
        self.assertTrue(G.check(st, "launch", plan=p2).covered)
        chain = G.new_approval("a chain of 3", [p1], actions=("launch", "chain"), launches=3)
        chain["used"] = [{"nonce": f"c{i}", "action": "chain", "hash": H1, "job": "", "at": L.now()} for i in range(2)]
        self.assertTrue(G.check(state(chain), "chain", plan=p1).covered)
        chain["used"].append({"nonce": "c9", "action": "chain", "hash": H1, "job": "", "at": L.now()})
        self.assertFalse(G.check(state(chain), "chain", plan=p1).covered)
        self.assertTrue(G.check(state(G.new_approval("x", [p1])), "launch", plan=p1).record["kind"] == "approval")

    def test_relaunch_needs_the_original_configuration(self):
        orig = plan()
        att = {"name": "exp--train--base--scratch--s0--a01", "target": "fx", "kind": "slurm",
               "request": {"action": "launch", "plan": "p-1", "bound_hash": orig["bound_hash"], "bound": G.bound(orig)},
               "submissions": [{"nonce": "n1", "submit": "submitted", "job": "5"}], "result": {"state": "FAILED"}}
        runs = {"exp--train--base--scratch--s0": {"run": "exp--train--base--scratch--s0", "attempts": {"a01": att}}}
        g = grant(actions=("launch", "relaunch", "resubmit"))
        st = state(g, runs=runs)
        again = plan(name="exp--train--base--scratch--s0--a02")   # the name is bound: a new hash
        self.assertNotEqual(again["bound_hash"], orig["bound_hash"])
        self.assertTrue(G.check(st, "relaunch", plan=again, run="exp--train--base--scratch--s0").covered)
        changed = plan(name="exp--train--base--scratch--s0--a02", payload="python train.py --lr 1")
        d = G.check(st, "relaunch", plan=changed, run="exp--train--base--scratch--s0")
        self.assertFalse(d.covered)
        self.assertIn("not the original configuration: payload", " ".join(d.reasons))
        more = plan(name="exp--train--base--scratch--s0--a02", gres="gpu:gt-a:4")
        self.assertIn("gres", " ".join(G.check(st, "resubmit", plan=more, run="exp--train--base--scratch--s0").reasons))
        self.assertTrue(G.check(state(g, G.new_approval("yes, with lr 1", [changed]), runs=runs), "launch",
                                plan=changed).covered)                              # the user approved the change
        adopted = {"r": {"run": "r", "attempts": {"a01": {**att, "request": {"action": "adopted"}}}}}
        self.assertIn("no recorded plan", " ".join(G.check(state(g, runs=adopted), "relaunch",
                                                           plan=plan(name="r--a02"), run="r").reasons))

    def test_cancel_approval_names_its_jobs_and_cancel_own_its_runs(self):
        ap = G.new_cancel_approval("cancel job 123", "fx", ["123"])
        st = state(ap)
        self.assertTrue(G.check(st, "cancel", job="123", plan={"target": "fx"}).covered)
        self.assertFalse(G.check(st, "cancel", job="124", plan={"target": "fx"}).covered)
        ap["used"].append({"nonce": "k1", "action": "cancel", "hash": "", "job": "123", "at": L.now()})
        self.assertFalse(G.check(st, "cancel", job="123", plan={"target": "fx"}).covered)
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
                                plan={"target": "fx"}).covered is False)
        named = G.new_cancel_approval("cancel job 7", "fx", ["7"])     # the user's named cancel beats cancel_own's deny
        d = G.check(state(g, named, G.new_deny("only I stop runs", {}, ["cancel_own"]), runs=runs), "cancel", job="7",
                    run="exp")
        self.assertEqual((d.covered, d.record["id"]), (True, named["id"]))
        d = G.check(state(g, G.new_deny("only I stop runs", {}, ["cancel_own"]), runs=runs), "cancel", job="7", run="exp")
        self.assertIn("cancel_own is denied", " ".join(d.reasons))
        bad = grant()
        bad["limits"]["expires"] = "someday"                           # a hand-edited file: expired, not open
        self.assertIn("expired", G.check(state(bad), "launch", plan=plan()).reasons[0])

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
        self.assertIn("2 approved plan(s)", G.describe(G.new_approval("ok", [plan(), plan(name="x--a01")])))
        self.assertIn("cancel of job(s) 5", G.describe(G.new_cancel_approval("stop 5", "fx", ["5"])))
        self.assertEqual(G.describe(G.new_deny("no", {"names": ["x*"]})), "DENY every action: names x*")
        self.assertEqual(G.describe(G.new_deny("no", {}, ["cancel"])), "DENY cancel: anything")
        self.assertIn("no limit (user's words)", G.balance(grant(), state()))


class Store(ScratchHome):
    def setUp(self) -> None:
        super().setUp()
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


if __name__ == "__main__":
    unittest.main()
