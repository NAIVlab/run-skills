"""Multi-node Slurm plans (rsk launch --nodes K): parsing, the words sent (--nodes K only when K > 1), a workstation's
refusal, the bound nodes= of the plan block (an older block without it = 1; another K = exit 6), the card's nodes row,
the ledger's record, and grants: max_nodes (absent = 1) and the caps compared to the plan's totals (per node × K)."""

import json
import math
import unittest

from helpers import ScratchHome
from test_grants import grant, plan, state
from test_grants import run as grun
from test_launch import Fixture, block

from remote_run import grants as G
from remote_run import launch as X
from remote_run import ledger as L
from remote_run.errors import CONFLICT, NEEDS_USER, OK, USAGE, RskError

NAME = "exp--train--a--scratch--s0--a01"


class Parse(unittest.TestCase):
    def test_nodes_is_a_long_option_1_to_64(self):
        self.assertEqual(X.parse(["-T", "fx", "--nodes", "2", "--", "c"]).nodes, "2")
        self.assertEqual(X.parse(["-T", "fx", "--nodes=64", "--", "c"]).nodes, "64")
        self.assertIsNone(X.parse(["-T", "fx", "--", "c"]).nodes)
        for bad in ("0", "65", "two", "-1", "2.0", "", "0002"):
            with self.assertRaises(RskError, msg=bad) as c:
                X.parse(["-T", "fx", f"--nodes={bad}", "--", "c"])
            self.assertEqual(c.exception.code, USAGE)

    def test_only_k_above_1_sends_words(self):
        self.assertEqual(X.nodes_words(1), [])
        self.assertEqual(X.nodes_words(3), ["--nodes", "3"])

    def test_a_relaunch_from_the_bound_fields_asks_for_the_same_nodes(self):
        f, _, _ = X._from_bound("slurm", {"gres": "gpu:a100:4", "nodes": "2", "cpus": "8"}, "r--a02")
        self.assertEqual(f[f.index("--nodes"):f.index("--nodes") + 2], ["--nodes", "2"])
        f, _, _ = X._from_bound("slurm", {"gres": "gpu:4", "cpus": "8"}, "r--a02")        # an older attempt: 1 node
        self.assertNotIn("--nodes", f)
        self.assertNotIn("--nodes", X._from_bound("slurm", {"gres": "gpu:4", "nodes": "1"}, "r--a02")[0])
        with self.assertRaises(RskError):
            X._from_bound("slurm", {"gres": "gpu:4", "nodes": "x"}, "r--a02")

    def test_the_card_row(self):
        self.assertEqual(X.nodes_text({"gres": "gpu:a100:4", "nodes": "2"}),
                         "2 × gpu:a100:4 (total 8 GPUs; gres / cpus / mem per node)")
        self.assertEqual(X.nodes_text({"gres": "gpu:4", "nodes": "1"}), "1 × gpu:4 (total 4 GPUs)")
        self.assertIn("older submit.sh", X.nodes_text({"gres": "gpu:4"}))
        self.assertIn("UNREADABLE", X.nodes_text({"gres": "gpu:4", "nodes": "x"}))

    def test_extra_allow_never_holds_a_node_or_task_word(self):
        for w in ("-N", "--nodes", "-n", "--ntasks", "--ntasks-per-node", "--nodefile", "-F", "-w", "--nodelist"):
            self.assertNotIn(f" {w} ", f" {G.EXTRA_ALLOW} ", w)
        for words in (["--nodes=2"], ["-N", "2"], ["--ntasks-per-node=4"], ["-w", "a,b"]):
            self.assertTrue(G.conf_extra_bad(words), words)        # outside the allowlist: never a silent word


class Alloc(unittest.TestCase):
    """F2: an SBATCH_EXTRA (conf_extra) word that changes the allocation the caps check is never grant-covered."""

    def test_alloc_words_spellings(self):
        for words, want in ((["--exclusive"], ["--exclusive"]), (["--exclusive=user"], ["--exclusive=user"]),
                            (["--excl"], ["--excl"]), (["--gres=gpu:4"], ["--gres=gpu:4"]), (["--gres", "gpu:4"], ["--gres"]),
                            (["-G", "2"], ["-G"]), (["-G3"], ["-G3"]), (["--gpus=2"], ["--gpus=2"]),
                            (["--gpus-per-n=1"], ["--gpus-per-n=1"]), (["--cpus-per-task=4"], ["--cpus-per-task=4"]),
                            (["-c4"], ["-c4"]), (["-c", "4"], ["-c"]), (["-Oc4"], ["-Oc4"]), (["-vs"], ["-vs"]),
                            (["--mem=1T"], ["--mem=1T"]), (["--mem-per-c=2G"], ["--mem-per-c=2G"]),
                            (["--mincpus=64"], ["--mincpus=64"]), (["--oversubscribe"], ["--oversubscribe"]),
                            (["-O"], ["-O"]), (["-S", "2"], ["-S"]), (["--thread-spec=1"], ["--thread-spec=1"]),
                            (["--hint=nomultithread"], ["--hint=nomultithread"]), (["--tmp=500G"], ["--tmp=500G"]),
                            (["--threads-per-core=2"], ["--threads-per-core=2"]), (["-B", "2:4"], ["-B"]),
                            (["--tres-per-task=gres/gpu:2"], ["--tres-per-task=gres/gpu:2"]),
                            (["--co=x"], ["--co=x"]),                       # ambiguous: core-spec among them
                            (["--qos", "x", "--hint=compute_bound"], ["--hint=compute_bound"])):
            self.assertEqual(G.alloc_words(words), want, words)
        for words in (["--comment", "--exclusive"], ["--comment=--exclusive"], ["-J", "-c"], ["-Jfoo-c"],
                      ["-L", "fs:1"], ["--licenses=fs:1"], ["--qos=high", "--account=a"], ["-kc"],
                      ["--mail-type=END"], ["--begin=now"], ["--constraint", "--gres=x"]):
            self.assertEqual(G.alloc_words(words), [], words)

    def test_cpu_only_gres_in_extra_is_not_covered(self):
        # P_CPU_ONLY=1: bound gres empty, the caps count 0 GPUs — SBATCH_EXTRA --gres=gpu:4 must not ride along
        cap = grant({"max_gpus": 1, "max_cpus": 64})
        p = plan(gres="''", extra="--gres=gpu:4")
        d = G.check(state(cap), "launch", plan=p)
        self.assertFalse(d.covered)
        self.assertIn("NO GRANT: --gres=gpu:4 changes the allocation the caps check", " ".join(d.reasons))
        self.assertTrue(G.check(state(G.new_approval([p], plan_ids=["p-test"])), "launch", plan=p).covered)

    def test_policy_words_and_licenses_stay_coverable(self):
        open_ = grant()
        self.assertTrue(G.check(state(open_), "launch", plan=plan(extra="--exclusive", conf_extra="")).covered)
        self.assertTrue(G.check(state(open_), "launch", plan=plan(extra="--licenses=fs:2")).covered)
        self.assertEqual(G.facts(plan(extra="--licenses=fs:2 --exclusive")).extra_alloc, ("--exclusive",))


class Layout(unittest.TestCase):
    """F3: layout words beside nodes= — a policy's SB_ARGS+=(--nodes=2) must not slip past max_nodes."""

    def test_layout_words_beside_nodes(self):
        self.assertEqual(G.layout_words(["--nodes=2"], 1), ["--nodes=2"])
        self.assertEqual(G.layout_words(["--nodes=2"], 2), [])
        self.assertEqual(G.layout_words(["--nodes", "2", "-N2", "-N", "2"], 2), [])
        self.assertEqual(G.layout_words(["--nodes", "3"], 2), ["--nodes 3"])
        self.assertEqual(G.layout_words(["--ntasks-per-node=1"], 2), [])
        self.assertEqual(G.layout_words(["--ntasks-per-node=1"], 1), ["--ntasks-per-node=1"])
        self.assertEqual(G.layout_words(["--tasks-per-node", "1"], 3), [])
        self.assertEqual(G.layout_words(["--ntasks=8"], 2), ["--ntasks=8"])
        self.assertEqual(G.layout_words(["--comment", "--nodes=3"], 2), [])           # a value, never an option
        self.assertEqual(G.layout_words(["-w", "n1,n2"], 2), ["-w n1,n2"])
        self.assertEqual(G.layout_words(["-w", "n1"], 2), [])
        self.assertEqual(G.layout_words(["--nodes=1"], None), ["--nodes=1"])          # no nodes=: every one counts

    def test_short_clusters_read_as_getopt(self):
        # sbatch's getopt: a no-value letter goes on to the next (-vN2 = -v -N2), a value letter takes the rest or the next word
        self.assertEqual(G.layout_words(["-vN2"], 1), ["-vN2"])
        self.assertEqual(G.layout_words(["-vN2"], 2), [])                              # the harness's own K
        self.assertEqual(G.layout_words(["-HvN", "3"], 2), ["-HvN 3"])
        self.assertEqual(G.layout_words(["-vN"], 1), ["-vN (no value)"])
        self.assertEqual(G.layout_words(["-vn8"], 2), ["-vn8"])
        self.assertEqual(G.layout_words(["-VF", "h"], 1), ["-VF h"])
        self.assertEqual(G.layout_words(["-vB2:4:1"], 1), ["-vB2:4:1"])
        self.assertEqual(G.layout_words(["-Ow", "n[1-2]"], 1), ["-Ow n[1-2]"])
        self.assertEqual(G.layout_words(["-vwn1"], 1), [])
        self.assertEqual(G.layout_words(["-qN2"], 1), [])                               # -q's value
        self.assertEqual(G.layout_words(["-vq", "-N2"], 1), [])                         # -q's separate value
        self.assertEqual(G.layout_words(["--comment", "-vN2"], 1), [])
        self.assertEqual(G.layout_words(["--node=2"], 2), ["--node=2"])                 # ambiguous: counted
        self.assertEqual(G.layout_words(["--extra=x", "--extra-n=2"], 1), ["--extra-n=2"])

    def test_a_policy_node_count_is_never_covered(self):
        big = grant({"max_nodes": 8})
        for extra, nodes in (("--nodes=2", "1"), ("--ntasks=8", "2"), ("--nodes=3", "2"), ("-N 4", "1"), ("-vN2", "1"),
                             ("-vN 2", "1")):
            p = plan(nodes=nodes, extra=extra, conf_extra="")      # the policy's SB_ARGS words, nodes= present
            f = G.facts(p)
            self.assertIsNone(f.nodes, extra)
            self.assertIn("nodes", f.unreadable)
            self.assertFalse(G.check(state(big), "launch", plan=p).covered, extra)
        for extra, nodes in (("--nodes=2 --ntasks-per-node=1", "2"), ("--nodes=1", "1"), ("--qos=x", "2")):
            p = plan(nodes=nodes, extra=extra, conf_extra="")
            self.assertEqual(G.facts(p).nodes, int(nodes), extra)
            self.assertTrue(G.check(state(big), "launch", plan=p).covered, extra)


class Grants(unittest.TestCase):
    def test_facts_nodes_absent_is_1_and_unreadable_is_unknown(self):
        self.assertEqual(G.facts(plan()).nodes, 1)                 # an older deploy's block
        self.assertEqual(G.facts(plan(nodes="1")).nodes, 1)
        self.assertEqual(G.facts(plan(nodes="3")).nodes, 3)
        f = G.facts(plan(nodes="x"))
        self.assertIsNone(f.nodes)
        self.assertIn("nodes", f.unreadable)

    def test_old_block_with_layout_extra_is_unknown(self):
        # a block without nodes= from a submit.sh that let SBATCH_EXTRA set the node count: never read as one node
        for x in ("--nodes=2", "-N2", "--ntasks=4", "-B2:2:1", "-w n1,n2", "--nodelist=n[1-2]"):
            f = G.facts(plan(extra=x))
            self.assertIsNone(f.nodes, x)
            self.assertFalse(G.check(state(grant({"max_nodes": 8})), "launch",
                                     plan=plan(extra=x)).covered, x)
        for x in ("--qos=high", "--nodelist=n1", "-wn1", "--exclude=n1,n2", "--comment -N2",
                  "--nodelist=n1 --exclude=n2,n3", "--nice --exclusive --extra=x"):
            self.assertEqual(G.facts(plan(extra=x)).nodes, 1, x)
        self.assertEqual(G.facts(plan(nodes="2", extra="--qos=high")).nodes, 2)

    def test_old_block_layout_extra_needs_sync(self):
        place = type("P", (), {"target": "fx", "kind": "slurm"})()
        X.check_nodes(place, G.parse_plan(block(extra="--qos=high")), 1)
        with self.assertRaises(RskError) as e:
            X.check_nodes(place, G.parse_plan(block(extra="--nodes=2")), 1)
        self.assertEqual(e.exception.code, CONFLICT)

    def test_max_nodes_absent_is_1(self):
        self.assertTrue(G.check(state(grant()), "launch", plan=plan(nodes="1")).covered)
        self.assertTrue(G.check(state(grant()), "launch", plan=plan()).covered)            # no nodes= at all
        d = G.check(state(grant()), "launch", plan=plan(nodes="2"))
        self.assertFalse(d.covered)
        self.assertEqual(d.code, NEEDS_USER)
        self.assertIn("2 nodes > 1 (no --max-nodes", " ".join(d.reasons))
        self.assertFalse(G.check(state(grant({"max_nodes": 1})), "launch", plan=plan(nodes="2")).covered)
        self.assertTrue(G.check(state(grant({"max_nodes": 2})), "launch", plan=plan(nodes="2")).covered)
        self.assertFalse(G.check(state(grant({"max_nodes": 2})), "launch", plan=plan(nodes="3")).covered)
        self.assertFalse(G.check(state(grant({"max_nodes": 8})), "launch", plan=plan(nodes="x")).covered)

    def test_caps_compare_totals(self):
        p = plan(nodes="2")                                         # gpu:gt-a:2, 16 cpus, 64G per node
        self.assertTrue(G.check(state(grant({"max_nodes": 2, "max_gpus": 4, "max_cpus": 32, "max_mem_gb": 128})),
                                "launch", plan=p).covered)
        for cap, why in (({"max_gpus": 3}, "4 GPUs in total (2 nodes) > 3"),
                         ({"max_cpus": 31}, "32 CPUs in total (2 nodes) > 31"),
                         ({"max_mem_gb": 100}, "128 GB memory in total (2 nodes) > 100")):
            d = G.check(state(grant({"max_nodes": 2, **cap})), "launch", plan=p)
            self.assertFalse(d.covered, cap)
            self.assertIn(why, " ".join(d.reasons))
        d = G.check(state(grant({"max_nodes": 2, "max_mem_gb": 100})), "launch", plan=plan(nodes="2", mem="0"))
        self.assertIn("unlimited GB memory", " ".join(d.reasons))                     # --mem=0: inf × 2
        self.assertEqual(G.facts(plan(nodes="2", mem="0")).total(math.inf), math.inf)
        d = G.check(state(grant({"max_gpus": 2})), "launch", plan=plan())             # one node: as before
        self.assertTrue(d.covered)

    def test_an_approval_covers_its_card_whatever_the_nodes(self):
        p = plan(nodes="4")
        ap = G.new_approval([p], plan_ids=["p-test"])
        self.assertTrue(G.check(state(ap), "launch", plan=p).covered)

    def test_records_validate_max_nodes(self):
        self.assertEqual(grant({"max_nodes": 2})["scope"]["max_nodes"], 2)
        for bad in (0, -1, 1.5, "2", True):
            with self.assertRaises(RskError, msg=bad):
                grant({"max_nodes": bad})
        with self.assertRaises(RskError):                           # a deny takes no caps
            G.new_deny({"max_nodes": 2})
        self.assertIn("<= 2 nodes", G.describe(grant({"max_nodes": 2})))

    def test_same_config_reads_a_missing_nodes_as_1(self):
        orig = {"target": "fx", "kind": "slurm", "bound": {k: v for k, v in G.bound(plan()).items() if k != "nodes"}}
        self.assertEqual(G.same_config(orig, plan(nodes="1")), [])
        self.assertTrue(any(d.startswith("nodes") for d in G.same_config(orig, plan(nodes="2"))))


class GrantCli(ScratchHome):
    def setUp(self) -> None:                     # test_grants.Store's fixture (its tests are not inherited here)
        super().setUp()
        for name, prof in (("fx", "T_KIND=slurm; T_HOST=fxhost\n"), ("ws", "T_KIND=nohup; T_HOST=wshost\n")):
            d = self.home / "cfg" / "targets" / name
            d.mkdir(parents=True)
            (d / "profile.sh").write_text(prof)
        self.proj = self.home / "proj"
        self.proj.mkdir()
        (self.proj / ".hpc.conf").write_text("REMOTE_DIR=/r\n")
        self.led = L.Ledger(self.proj)

    def test_add_list_and_import_max_nodes(self):
        base = ("grant", "add", "-C", str(self.proj), "--action", "launch", "-T", "fx", "--max-live", "none",
                "--max-launches", "none", "--expires", "none")
        rc, text = grun(*base, "--max-nodes", "2", "--max-gpus", "8")
        self.assertEqual(rc, OK, text)
        rec = next(r for r in self.led.state().grants if r["id"] == text.split()[0])
        self.assertEqual((rec["scope"]["max_nodes"], rec["scope"]["max_gpus"]), (2, 8))
        self.assertIn("<= 8 GPUs; <= 2 nodes", grun("grant", "list", "-C", str(self.proj))[1])
        self.assertEqual(grun(*base, "--max-nodes", "0")[0], USAGE)
        self.assertEqual(grun(*base, "--max-nodes", "two")[0], USAGE)
        good = {"kind": "grant", "source": "a note", "scope": {"targets": ["fx"], "max_nodes": 4},
                "actions": ["launch"], "limits": {"max_live": None, "max_launches": None, "expires": None}}
        f = self.home / "g.json"
        for bad in (0, "4", 2.5):
            f.write_text(json.dumps([{**good, "scope": {"targets": ["fx"], "max_nodes": bad}}]))
            self.assertEqual(grun("grant", "import", str(f), "-C", str(self.proj))[0], USAGE, bad)
        f.write_text(json.dumps([good]))
        rc, text = grun("grant", "import", str(f), "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertTrue(any((r.get("scope") or {}).get("max_nodes") == 4 for r in self.led.state().grants))


class Flow(Fixture):
    def test_nodes_2_plan_card_approve_submit_and_the_ledger(self):
        self.answers = [self.plan_reply(nodes="2", gres="gpu:4")]
        rc, text = self.cli("launch", "-T", "fx", "-n", NAME, "--nodes", "2", "-g", "4", "--", "python", "t.py")
        self.assertEqual(rc, NEEDS_USER, text)
        w = self.calls[0]
        self.assertEqual(w[w.index("--nodes"):w.index("--nodes") + 2], ["--nodes", "2"])
        self.assertLess(w.index("--nodes"), w.index("--"))
        self.assertIn("nodes      2 × gpu:4 (total 8 GPUs", text)
        pid = self.plan_id(text)
        self.answers = [self.submitted("301")]
        rc, text = self.cli("launch", "--plan", pid, "--approve")
        self.assertEqual(rc, OK, text)
        w = self.calls[1]
        self.assertEqual(w[2], "--rs-expect")
        self.assertEqual(w[w.index("--nodes"):w.index("--nodes") + 2], ["--nodes", "2"])
        att = self.led.read_run("exp--train--a--scratch--s0").data["attempts"]["a01"]
        self.assertEqual(att["request"]["bound"]["nodes"], "2")

    def test_k_1_sends_no_word(self):
        for extra in ((), ("--nodes", "1")):
            self.calls.clear()
            self.answers = [self.plan_reply(nodes="1")]
            rc, text = self.cli("launch", "-T", "fx", "-n", NAME, *extra, "--", "c")
            self.assertEqual(rc, NEEDS_USER, text)
            self.assertNotIn("--nodes", self.calls[0])
            self.assertIn("nodes      1 × gpu:1 (total 1 GPUs)", text)

    def test_an_older_block_without_nodes_is_one_node(self):
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "-n", NAME, "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "-n", NAME, "--nodes", "2", "--", "c")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("needs: sync", text)
        self.assertIn("no nodes=", text)

    def test_an_older_parser_stopping_at_k_needs_a_sync(self):
        self.answers = [X.Reply(2, "@@api api=3\n", "NOTE: passing '--nodes' through to policy.sh (not an sbatch "
                                "flag)\nERROR: unknown arg '2' (flags: -p -g -G -t -m -c -n -y [--<policy-flag>], then "
                                "-- <cmd>)", api="api=3")]
        rc, text = self.cli("launch", "-T", "fx", "-n", NAME, "--nodes", "2", "--", "c")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("needs: sync", text)

    def test_another_k_in_the_block_is_a_conflict(self):
        for asked, shown in ((("--nodes", "2"), "3"), ((), "2"), (("--nodes", "2"), "x")):
            self.answers = [self.plan_reply(nodes=shown)]
            rc, text = self.cli("launch", "-T", "fx", "-n", NAME, *asked, "--", "c")
            self.assertEqual(rc, CONFLICT, (asked, shown, text))
            self.assertIn("the plan block says nodes=", text)

    def test_a_workstation_is_one_host(self):
        for k in ("2", "1"):
            rc, text = self.cli("launch", "-T", "ws", "--nodes", k, "--", "c")
            self.assertEqual(rc, USAGE, text)
            self.assertIn("a workstation is one host", text)
        self.assertEqual(self.calls, [])

    def test_a_grant_covers_nodes_only_within_max_nodes(self):
        G.add(self.led, G.new_grant({"targets": ["fx"], "max_gpus": 8}, ["launch"], max_live=None, max_launches=None,
                                    expires=None))
        self.answers = [self.plan_reply(nodes="2", gres="gpu:4")]
        rc, text = self.cli("launch", "-T", "fx", "-n", NAME, "--nodes", "2", "-g", "4", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)                     # no max_nodes: one node only
        self.assertIn("2 nodes > 1", text)
        G.add(self.led, G.new_grant({"targets": ["fx"], "max_gpus": 8, "max_nodes": 2}, ["launch"], max_live=None,
                                    max_launches=None, expires=None))
        self.answers = [self.plan_reply(nodes="2", gres="gpu:4"), self.submitted("302")]
        rc, text = self.cli("launch", "-T", "fx", "-n", NAME, "--nodes", "2", "-g", "4", "--", "c")
        self.assertEqual(rc, OK, text)
        self.assertIn("covered by g-", text)

    def test_an_allocation_word_in_sbatch_extra_is_never_grant_covered(self):
        G.add(self.led, G.new_grant({"targets": ["fx"], "max_gpus": 8}, ["launch"], max_live=None, max_launches=None,
                                    expires=None))
        self.answers = [self.plan_reply(nodes="1", extra="--exclusive")]
        rc, text = self.cli("launch", "-T", "fx", "-n", NAME, "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("  NO GRANT   --exclusive changes the allocation the caps check", text)
        self.assertIn("NO GRANT: --exclusive changes the allocation the caps check", text)
        pid = self.plan_id(text)
        self.answers = [self.submitted("303")]
        rc, text = self.cli("launch", "--plan", pid, "--approve")              # the user's approval of the card
        self.assertEqual(rc, OK, text)

    def test_a_layout_word_beside_nodes_needs_a_sync(self):
        for extra, conf in (("--ntasks=8", ""), ("--qos=x --nodes=3", "--qos=x"), ("-N3", "-N3")):
            self.answers = [self.plan_reply(nodes="2", gres="gpu:4", extra=extra, conf_extra=conf)]
            rc, text = self.cli("launch", "-T", "fx", "-n", NAME, "--nodes", "2", "-g", "4", "--", "c")
            self.assertEqual(rc, CONFLICT, (extra, text))
            self.assertIn("needs: sync", text)
            self.assertIn("node / task layout beside nodes=", text)
        self.answers = [self.plan_reply(nodes="2", gres="gpu:4", extra="--nodes=2 --ntasks-per-node=1", conf_extra="")]
        rc, text = self.cli("launch", "-T", "fx", "-n", NAME, "--nodes", "2", "-g", "4", "--", "c")
        self.assertEqual(rc, NEEDS_USER, text)                     # equal in effect to the harness's own: the card

    def test_plan_with_nodes_beside_it_is_usage(self):
        self.assertEqual(self.cli("launch", "--plan", "p-x", "--nodes", "2")[0], USAGE)


if __name__ == "__main__":
    unittest.main()
