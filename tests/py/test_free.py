"""F1, the free rule (grants.free_misses / check): a launch on what the target's profile declares free (T_FREE) needs no
grant and no approval — a deny still wins; a policy -y gate, a workstation warning,
an undeclared partition or target, and a relaunch beside a live attempt still go to the user; nothing is recorded but
an audit line; harness.targets reads T_FREE; launch.check_plan hands it to check()."""

import unittest
from unittest import mock

from helpers import ScratchHome
from test_grants import grant, nplan, plan, state

from remote_run import grants as G
from remote_run import harness
from remote_run import launch as LA
from remote_run import ledger as L
from remote_run.errors import NEEDS_USER, OK, REFUSED


def free(p: dict, fl: str) -> dict:
    return {**p, "free": fl}


class FreeRule(unittest.TestCase):
    def test_a_declared_free_partition_needs_nothing(self):
        d = G.check(state(), "launch", plan=free(plan(), "gpu"))
        self.assertTrue(d.covered)
        self.assertEqual(d.record["id"], G.FREE_ID)
        self.assertEqual(d.code, OK)
        self.assertIn("partition gpu costs nothing", d.reasons[0])

    def test_star_frees_every_partition_and_commas_separate(self):
        self.assertTrue(G.check(state(), "launch", plan=free(plan(partition="other"), "*")).covered)
        self.assertTrue(G.check(state(), "launch", plan=free(plan(), "cpu,gpu")).covered)

    def test_nothing_declared_or_another_partition_needs_the_user(self):
        for fl, why in (("", "declares nothing free"), ("cpu", "partition gpu is not one")):
            d = G.check(state(), "launch", plan=free(plan(), fl))
            self.assertFalse(d.covered)
            self.assertEqual(d.code, NEEDS_USER)
            self.assertIn(why, " ".join(d.reasons))
        self.assertFalse(G.check(state(), "launch", plan=plan()).covered)     # no "free" key at all

    def test_a_deny_still_wins(self):
        deny = G.new_deny({"targets": ["fx"]}, ["launch"])
        d = G.check(state(deny), "launch", plan=free(plan(), "*"))
        self.assertTrue(d.denied)
        self.assertEqual(d.code, REFUSED)

    def test_a_policy_gate_needs_the_user_availability_alone_does_not(self):
        d = G.check(state(), "launch", plan=free(plan(warnings="1", warnings_avail="0"), "gpu"))
        self.assertFalse(d.covered)
        self.assertIn("policy -y gate", " ".join(d.reasons))
        self.assertTrue(G.check(state(), "launch", plan=free(plan(warnings="1", warnings_avail="1"), "gpu")).covered)

    def test_the_confs_own_qos_or_account_is_the_users_choice(self):
        for extra in ("--qos=priority", "--account=lab --exclude=n1"):
            self.assertTrue(G.check(state(), "launch", plan=free(plan(extra=extra), "*")).covered, extra)

    def test_a_policy_flag_or_another_cluster_needs_the_user(self):
        for kv, why in (({"flags": "--pi-user-asked"}, "policy flag"), ({"flags": None}, "rsk sync"),
                        ({"extra": "--clusters=other"}, "another cluster"), ({"extra": "-M other"}, "another cluster"),
                        ({"extra": "--clu=other"}, "another cluster")):
            d = G.check(state(), "launch", plan=free(plan(**kv), "*"))
            self.assertFalse(d.covered, kv)
            self.assertIn(why, " ".join(d.reasons), kv)

    def test_the_id_free_is_reserved(self):
        rec = grant()
        rec["id"] = G.FREE_ID
        with self.assertRaises(Exception):
            G.validate(rec)
        self.assertTrue(G.valid(rec))

    def test_a_workstation_needs_star_and_no_warning(self):
        clean = nplan(warnings="0", warnings_gpu="0", payload="python\\ train.py")
        self.assertTrue(G.check(state(), "launch", plan=free(clean, "*")).covered)
        self.assertFalse(G.check(state(), "launch", plan=free(clean, "gpu")).covered)
        d = G.check(state(), "launch", plan=free(nplan(), "*"))          # a launcher warning (warnings_gpu=1)
        self.assertFalse(d.covered)
        self.assertIn("workstation", " ".join(d.reasons))
        old = nplan(warnings="0", warnings_gpu=None)
        self.assertFalse(G.check(state(), "launch", plan=free(old, "*")).covered)

    def test_free_comes_before_a_grant_so_no_budget_is_spent(self):
        g = grant(max_launches=1)
        d = G.check(state(g), "launch", plan=free(plan(), "*"))
        self.assertEqual(d.record["id"], G.FREE_ID)
        d = G.check(state(g), "launch", plan=free(plan(), "cpu"))       # not free: the grant covers it
        self.assertEqual(d.record["id"], g["id"])

    def test_a_relaunch_never_beside_a_live_attempt(self):
        runs = {"exp--train--base--scratch--s0": {"attempts": {"a01": {
            "target": "fx", "kind": "slurm", "submissions": [{"nonce": "n1", "submit": "submitted", "job": "1"}],
            "request": {}}}}}
        p = free({**plan(name="exp--train--base--scratch--s0--a02"), "info_prior": "1"}, "*")
        d = G.check(state(runs=runs), "relaunch", plan=p, run="exp--train--base--scratch--s0")
        self.assertFalse(d.covered)
        self.assertIn("may still be live", " ".join(d.reasons))
        runs["exp--train--base--scratch--s0"]["attempts"]["a01"]["result"] = {"state": "FAILED"}
        runs["exp--train--base--scratch--s0"]["attempts"]["a01"]["submissions"][0]["end"] = {"state": "FAILED"}
        d = G.check(state(runs=runs), "relaunch", plan=p, run="exp--train--base--scratch--s0")
        self.assertTrue(d.covered, d.reasons)

    def test_cancel_is_not_the_free_rules(self):
        self.assertEqual(G.free_misses(plan(), ("cancel",), state()), ["not a launch"])

    def test_describe(self):
        self.assertIn("T_FREE", G.describe(G.FREE_RECORD))


class FreeStore(ScratchHome):
    def setUp(self) -> None:
        super().setUp()
        for name, prof in (("fx", "T_KIND=slurm; T_HOST=fxhost; T_FREE='gpu, cpu'\n"),
                           ("ws", "T_KIND=nohup; T_HOST=wshost; T_FREE='*'\n"),
                           ("pay", "T_KIND=slurm; T_HOST=payhost\n")):
            d = self.home / "cfg" / "targets" / name
            d.mkdir(parents=True)
            (d / "profile.sh").write_text(prof)
        self.proj = self.home / "proj"
        self.proj.mkdir()
        self.led = L.Ledger(self.proj)

    def test_harness_reads_t_free(self):
        from remote_run import paths
        got = {t.name: t.free for t in harness.targets(paths.harness_src())}
        self.assertEqual(got["fx"], "gpu, cpu")
        self.assertEqual(got["ws"], "*")
        self.assertEqual(got["pay"], "")
        self.assertEqual(G.free_list(got["fx"]), ("gpu", "cpu"))

    def test_check_plan_hands_t_free_to_check(self):
        with mock.patch.object(LA, "_FREE", None):
            rec = {"id": "p-1", "run": "r", "target": "fx", "block": plan()}
            self.assertEqual(LA.check_plan(rec)["free"], "gpu, cpu")
            self.assertEqual(LA.check_plan({**rec, "target": "pay"})["free"], "")
            self.assertEqual(LA.check_plan({**rec, "target": "nope"})["free"], "")

    def test_use_and_refund_store_nothing_but_an_audit_line(self):
        self.assertTrue(G.use(self.led, G.FREE_ID, "n1", "launch", hash="h"))
        self.assertFalse(G.refund(self.led, G.FREE_ID, "n1", "refused"))
        doc, _ = G.load(self.led)
        self.assertEqual([r for r in doc.get("records", []) if r.get("id") == G.FREE_ID], [])
        events = [a["event"] for a in self.led.read_audit()[0]]
        self.assertIn("free_launch", events)
        self.assertNotIn("grant_used", events)


if __name__ == "__main__":
    unittest.main()
