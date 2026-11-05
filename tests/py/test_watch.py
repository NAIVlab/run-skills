"""rsk watch: the lease is taken before run-watch starts (another live holder: exit 6, nothing run), held while it
runs, released however it ends (a signal is passed on to run-watch first); run-watch's exit 3 is rsk's 7."""

import contextlib
import io
import json
import os
import signal
import socket
import subprocess
import threading
import time
import unittest
from unittest import mock
from pathlib import Path

from helpers import ScratchHome

from remote_run import cli
from remote_run import grants as G
from remote_run import ledger as L
from remote_run import watch as Wt
from remote_run.errors import CONFLICT, LEASE_ENDED, OK, REFUSED, USAGE, RskError


def run(*argv: str) -> tuple[int, str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        rc = cli.main(list(argv))
    return rc, buf.getvalue()


class Lease(ScratchHome):
    def setUp(self) -> None:
        super().setUp()
        self.proj = self.home / "proj"
        self.proj.mkdir()
        (self.proj / ".hpc.conf").write_text("REMOTE_DIR=/r\n")
        self.led = L.Ledger(self.proj)
        self.seen = self.home / "seen"

    def child(self, script: str) -> list[str]:
        return ["bash", "-c", script, "rw", str(self.led.dir / "watch.lease"), str(self.seen)]

    def test_until_follows_run_watchs_own_lease(self):
        self.assertEqual(Wt.until_of(["t"], 0), Wt.FOR_DEFAULT + Wt.EVERY_DEFAULT + Wt.SLACK)
        self.assertEqual(Wt.until_of(["t", "--for", "600", "--every", "60"], 0), 600 + 60 + Wt.SLACK)
        self.assertEqual(Wt.until_of(["t", "--once"], 0), Wt.SLACK + Wt.EVERY_DEFAULT)
        self.assertEqual(Wt.until_of(["t", "--approve", "ok"], 0), 300)

    def test_numbers_are_read_as_run_watch_reads_them(self):
        """Base 10, leading zeros dropped, <= 9 significant digits (run-watch's dec10); anything else (a non-ASCII
        digit included, which int() would crash on or misread) is run-watch's usage error: the default here."""
        self.assertEqual(Wt.last(["--every", "0060"], "--every", 300), 60)
        self.assertEqual(Wt.last(["--for", "000999999999"], "--for", 7200), 999999999)
        for bad in ("1234567890", "\u00b2", "\u0664\u0662", "0x10", "-5", "+5", ""):
            self.assertEqual(Wt.last(["--for", bad], "--for", 7200), 7200, repr(bad))
        self.assertEqual(Wt.until_of(["t", "--for", "0600", "--every", "060"], 0), 600 + 60 + Wt.SLACK)

    def test_l8_the_last_for_wins_and_the_lease_moves_forward_while_it_runs(self):
        self.assertEqual(Wt.until_of(["t", "--for", "60", "--for", "86400"], 0), 86400 + Wt.EVERY_DEFAULT + Wt.SLACK)
        self.assertEqual(Wt.until_of(["t", "--every", "60", "--every", "600", "--for", "60"], 0), 60 + 600 + Wt.SLACK)
        seen = self.home / "untils"
        with mock.patch.object(Wt, "REFRESH_S", 0.2):
            rc = Wt.run_watch(self.led, ["t.table", "--for", "1", "--every", "60"], str(self.proj), dict(os.environ),
                              ["bash", "-c", 'for i in 1 2 3 4 5 6 7 8; do sed -n \'s/.*"until": \\([0-9.]*\\).*/\\1/p\' '
                                             '"$1" >> "$2"; sleep 0.3; done', "rw", str(self.led.dir / "watch.lease"),
                               str(seen)])
        self.assertEqual(rc, OK)
        u = [float(x) for x in seen.read_text().split()]
        self.assertGreater(u[-1], u[0])                                # refreshed while run-watch ran
        self.assertGreaterEqual(u[-1], time.time() - 3 + 60 + Wt.SLACK)   # now + one round + the slack
        self.assertIsNone(self.led.lease().data)

    def test_held_while_it_runs_released_after_and_3_is_lease_ended(self):
        rc = Wt.run_watch(self.led, ["t.table", "--once"], str(self.proj), dict(os.environ),
                          self.child('cp "$1" "$2"; exit 3'))
        self.assertEqual(rc, LEASE_ENDED)
        lease = json.loads(self.seen.read_text())
        self.assertEqual((lease["pid"], lease["host"], lease["argv"]), (os.getpid(), socket.gethostname(),
                                                                         ["t.table", "--once"]))
        self.assertIsNone(self.led.lease().data)
        for code in (0, 2, 4):
            self.assertEqual(Wt.run_watch(self.led, [], str(self.proj), dict(os.environ), ["bash", "-c", f"exit {code}"]),
                             code)
        self.assertEqual([a["event"] for a in self.led.read_audit()[0]].count("lease_release"), 4)

    def test_another_live_holder_is_a_conflict_and_nothing_runs(self):
        other = subprocess.Popen(["sleep", "30"])
        try:
            self.led.ensure()
            L.write_json(self.led.dir / "watch.lease", {"pid": other.pid, "pid_start": L._pid_start(other.pid),
                                                        "host": socket.gethostname(), "boot_id": L.boot_id(),
                                                        "started": L.now(), "until": time.time() + 600, "argv": []})
            with self.assertRaises(RskError) as c:
                Wt.run_watch(self.led, [], str(self.proj), dict(os.environ), self.child('touch "$2"'))
            self.assertEqual(c.exception.code, CONFLICT)
            self.assertIn(f"pid {other.pid}", str(c.exception))
            self.assertFalse(self.seen.exists())
            rc, text = run("watch", "-C", str(self.proj), "t.table", "--once")
            self.assertEqual(rc, CONFLICT, text)
        finally:
            other.kill()
            other.wait()
        self.assertEqual(Wt.run_watch(self.led, [], str(self.proj), dict(os.environ), ["true"]), OK)   # dead: replaced

    def test_a_signal_is_passed_on_and_the_lease_still_released(self):
        t = threading.Timer(0.5, lambda: os.kill(os.getpid(), signal.SIGTERM))
        t.start()
        try:
            rc = Wt.run_watch(self.led, [], str(self.proj), dict(os.environ),
                              self.child('trap \'echo term > "$2"; exit 0\' TERM; sleep 10 & wait'))
        finally:
            t.cancel()
        self.assertEqual(rc, OK)
        self.assertEqual(self.seen.read_text().strip(), "term")
        self.assertIsNone(self.led.lease().data)
        self.assertIs(signal.getsignal(signal.SIGTERM), signal.SIG_DFL)

    def test_rsk_watch_runs_the_harness_run_watch_with_the_same_args(self):
        rc, text = self._cli("watch", "-C", str(self.proj))          # no table: run-watch's own usage error
        self.assertEqual(rc, USAGE, text)
        self.assertIn("usage: run-watch TABLE", text)
        self.assertIsNone(self.led.lease().data)

    def _cli(self, *argv: str) -> tuple[int, str]:   # run-watch writes to the real fds: capture at the process level
        done = subprocess.run([__import__("sys").executable, "-I", "-c", "import sys; sys.path[:0]=sys.argv[1:2]; "
                               "from remote_run import cli; sys.exit(cli.main(sys.argv[2:]))",
                               str(Path(cli.__file__).parent.parent), *argv], capture_output=True, text=True,
                              env=os.environ)
        return done.returncode, done.stdout + done.stderr


class Denies(ScratchHome):
    """D8 / r1-policy-docs-1: a deny binds rsk watch --act (before it starts, and on every refresh) and --approve;
    G4-5: an orphaned run-watch's lock refuses a second watcher (exit 6)."""

    TABLE = ("#@ run-watch v1\n#@ allow launch preempt=2\n#@ ok 2026-11-05 sum=1 \"go\"\n"
             "a fx-slurm - -p gpu -g 1 -t 1:00:00 -- python train.py\n"
             "exp--smoke--b fx-slurm - -p gpu -G gt-a -g 2 -- python b.py\n")

    def setUp(self) -> None:
        super().setUp()
        self.proj = self.home / "proj"
        self.proj.mkdir()
        (self.proj / ".hpc.conf").write_text("REMOTE_DIR=/r\n")
        (self.proj / "t.tsv").write_text(self.TABLE)
        self.led = L.Ledger(self.proj)
        self.kinds = {"fx-slurm": "slurm"}

    def guard(self):
        return lambda: Wt.deny_hit(self.led, self.proj, ["t.tsv", "--act"], self.kinds)

    def test_table_rows_and_actions(self):
        acts, rows = Wt.table_rows(self.proj / "t.tsv", self.kinds)
        self.assertEqual(acts, {"launch", "resubmit", "relaunch"})
        self.assertEqual([(r["name"], r.get("partition"), r.get("gres"), r.get("time")) for r in rows],
                         [("a", None, "gpu:1", "1:00:00"), ("exp--smoke--b", None, "gpu:2", None)])   # R4-4: no
        self.assertEqual(rows[1]["asked_gtype"], "gt-a")      # GPU type is certain here (the partition may force one)
        self.assertEqual(rows[1]["asked_partition"], "gpu")   # nor partition (t_policy may rewrite -p)
        self.assertEqual(Wt.tables(["t.tsv", "--every", "60", "--act", "u.tsv", "--release", "x"]), ["t.tsv", "u.tsv"])

    def test_a_deny_stops_act_before_anything_starts(self):
        self.assertEqual(self.guard()(), "")
        G.add(self.led, G.new_deny("never launch anything on fx-slurm any more", {"targets": ["fx-slurm"]}))
        seen = self.home / "seen"
        with self.assertRaises(RskError) as c:
            Wt.run_watch(self.led, ["t.tsv", "--act"], str(self.proj), dict(os.environ),
                         ["bash", "-c", f"touch {seen}"], guard=self.guard())
        self.assertEqual(c.exception.code, REFUSED)
        self.assertIn("never launch anything on fx-slurm", str(c.exception))
        self.assertFalse(seen.exists())
        self.assertIsNone(self.led.lease().data)

    def test_r4_4_a_deny_matches_a_row_for_every_action_whatever_the_allow_line(self):
        """NEW-watch-actions / N1-release-bypasses-deny: the guard used to check only what `#@ allow` lets run-watch
        do — a --release (launch / resubmit outside it) or an SBATCH_EXTRA singleton (a chain) slipped past."""
        G.add(self.led, G.new_deny("leave the b smoke alone", {"names": ["exp--smoke--b"]}, ["cancel"]))
        self.assertIn("row exp--smoke--b on fx-slurm (cancel)", self.guard()())   # no fail-stop line: checked anyway
        self.led.write_grants({"version": 1, "records": [], "budgets_unknown": None})
        G.add(self.led, G.new_deny("never chain jobs", {}, ["chain"]))
        self.assertIn("(chain)", self.guard()())                     # a conf singleton makes any launch a chain
        (self.proj / "w.tsv").write_text("#@ run-watch v1\n#@ allow launch\nw ws-box - -g 1 -- python w.py\n")
        self.assertEqual(Wt.deny_hit(self.led, self.proj, ["w.tsv", "--act"], {"ws-box": "nohup"}), "")  # never
        self.assertIn("(chain)", Wt.deny_hit(self.led, self.proj, ["w.tsv", "--act"], {}))   # a chain / unknown kind
        self.led.write_grants({"version": 1, "records": [], "budgets_unknown": None})
        (self.proj / "t.tsv").write_text("#@ run-watch v1\n#@ ok 2026-11-05 sum=1 \"go\"\n"
                                         "a fx-slurm - -p gpu -g 1 -- python train.py\n")     # no `#@ allow` at all
        G.add(self.led, G.new_deny("do not run a again", {"names": ["a"]}, ["resubmit", "relaunch"]))
        why = Wt.deny_hit(self.led, self.proj, ["t.tsv", "--act", "--release", "a"], self.kinds)
        self.assertIn("row a on fx-slurm (relaunch)", why)          # --release a: a resubmit of a run that ran
        self.assertIn("do not run a again", why)

    def test_r4_4_a_gpu_type_deny_matches_every_row_of_its_target(self):
        """N3-forced-gpu-type-evades-watch-deny: `-G a100` on a partition whose policy forces h100 is submitted as
        h100; rsk cannot see the policy, so a GPU-type deny matches every row of its target, and says why."""
        G.add(self.led, G.new_deny("never use the gt-z GPUs", {"targets": ["fx-slurm"], "gpu_types": ["gt-z"]}))
        why = self.guard()()
        self.assertIn("row a on fx-slurm (launch)", why)
        self.assertIn("GPU type is not certain here", why)
        self.led.write_grants({"version": 1, "records": [], "budgets_unknown": None})
        G.add(self.led, G.new_deny("never gt-z elsewhere", {"targets": ["other"], "gpu_types": ["gt-z"]}))
        self.assertEqual(self.guard()(), "")                         # another target's deny: not these rows

    def test_a_partition_deny_matches_every_row_of_its_target(self):
        """not_fixed (round 4, R4-4 partitions): a row's -p was taken as certain, but the policy.sh API lets t_policy
        rewrite PART — `-p gpu` may go out on the denied partition. Like a GPU type: a partition deny matches every
        Slurm row of its target, and says why."""
        G.add(self.led, G.new_deny("never the vip partition", {"targets": ["fx-slurm"], "partitions": ["vip"]}))
        why = self.guard()()
        self.assertIn("row a on fx-slurm (launch)", why)
        self.assertIn("it asks -p gpu, but the target's policy may rewrite it", why)
        self.led.write_grants({"version": 1, "records": [], "budgets_unknown": None})
        G.add(self.led, G.new_deny("never vip elsewhere", {"targets": ["other"], "partitions": ["vip"]}))
        self.assertEqual(self.guard()(), "")                         # another target's deny: not these rows
        (self.proj / "w.tsv").write_text("#@ run-watch v1\n#@ allow launch\nw ws-box - -g 1 -- python w.py\n")
        self.led.write_grants({"version": 1, "records": [], "budgets_unknown": None})
        G.add(self.led, G.new_deny("never vip on the box", {"targets": ["ws-box"], "partitions": ["vip"]}))
        self.assertEqual(Wt.deny_hit(self.led, self.proj, ["w.tsv", "--act"], {"ws-box": "nohup"}), "")  # no -p there

    def test_r5_8_a_row_target_spelled_otherwise_is_compared_as_its_name(self):
        """WATCH-target-spelling-evades-deny: a row on `fx-slurm/` (rs_target_dir finds the same profile, the deploy dir
        is the same) passed a `-T fx-slurm` deny — rsk compared the raw string. Now a normalised name; a spelling that
        is not one plain name may be any target."""
        G.add(self.led, G.new_deny("never launch anything on fx-slurm any more", {"targets": ["fx-slurm"]}))
        for t in ("fx-slurm/", "fx-slurm/.", "fx-slurm//", "./fx-slurm", "FX-SLURM", "x/../fx-slurm"):
            (self.proj / "s.tsv").write_text(f"#@ run-watch v1\n#@ allow launch\na {t} - -p gpu -g 1 -- python a.py\n")
            why = Wt.deny_hit(self.led, self.proj, ["s.tsv", "--act"], self.kinds)
            self.assertIn(f"row a on {t} (launch)", why, t)
            self.assertIn("never launch anything on fx-slurm any more", why)
            self.assertIn(f"the row's target {t!r} is not a target name as spelled", why)
        self.assertEqual(Wt.kind_of(self.kinds, "fx-slurm/"), "slurm")              # chain is checked as for fx-slurm
        self.assertEqual(Wt.kind_of(self.kinds, "a/b"), "")
        self.assertEqual(Wt.kind_of({"ab": "slurm", "AB": "nohup"}, "Ab"), "")       # ambiguous: unknown
        (self.proj / "s.tsv").write_text("#@ run-watch v1\n#@ allow launch\na fx-other - -p gpu -g 1 -- python a.py\n")
        self.assertEqual(Wt.deny_hit(self.led, self.proj, ["s.tsv", "--act"], {**self.kinds, "fx-other": "slurm"}), "")

    def test_r4_1_a_deny_of_a_plan_matches_every_row_in_its_scope(self):
        """N2-run-hash-deny-never-matches-watch-rows: a row has no bound hash — a deny of plans matches it."""
        G.add(self.led, G.new_deny("never run this exact configuration", {"runs": ["a" * 64]}))
        why = self.guard()()
        self.assertIn("row a on fx-slurm (launch)", why)
        self.assertIn("a deny of plans matches every row", why)

    def test_r4_1_an_unknown_class_matches_a_class_deny(self):
        G.add(self.led, G.new_deny("leave the smokes alone", {"classes": ["smoke"]}, ["cancel"]))
        self.assertIn("row a on fx-slurm (cancel)", self.guard()())   # `a` carries no class: it may be a smoke
        self.led.write_grants({"version": 1, "records": [], "budgets_unknown": None})
        G.add(self.led, G.new_deny("no train runs", {"classes": ["train"]}))
        self.assertIn("row a on fx-slurm", self.guard()())
        self.led.write_grants({"version": 1, "records": [], "budgets_unknown": None})
        G.add(self.led, G.new_deny("no train b", {"classes": ["train"], "names": ["exp--smoke--b"]}))
        self.assertEqual(self.guard()(), "")                         # b's name says smoke: not train

    def test_r4_15_unreadable_grants_are_exit_6_before_and_during(self):
        """N7-damaged-grants-drop-denies: a grants.json that does not parse (no .prev) acted as 'no deny'."""
        G.add(self.led, G.new_deny("never on fx-slurm", {"targets": ["fx-slurm"]}))
        (self.led.dir / "grants.json").write_text('{"version": 1, "records": [')
        (self.led.dir / "grants.json.prev").unlink(missing_ok=True)
        seen = self.home / "seen"
        with self.assertRaises(RskError) as c:
            Wt.run_watch(self.led, ["t.tsv", "--act"], str(self.proj), dict(os.environ),
                         ["bash", "-c", f"touch {seen}"], guard=self.guard())
        self.assertEqual(c.exception.code, CONFLICT)
        self.assertIn("grants unreadable", str(c.exception))
        self.assertFalse(seen.exists())
        self.assertIsNone(self.led.lease().data)
        rc, text = run("watch", "-C", str(self.proj), "t.tsv", "--approve", "ok")
        self.assertEqual(rc, CONFLICT, text)
        self.assertEqual((self.proj / "t.tsv").read_text(), self.TABLE)
        self.led.write_grants({"version": 1, "records": [], "budgets_unknown": None})

        def later():
            time.sleep(0.4)
            (self.led.dir / "grants.json").write_text("{torn")
            (self.led.dir / "grants.json.prev").unlink(missing_ok=True)
        t = threading.Thread(target=later)
        t.start()
        try:
            with mock.patch.object(Wt, "REFRESH_S", 0.2), self.assertRaises(RskError) as c:
                Wt.run_watch(self.led, ["t.tsv", "--act"], str(self.proj), dict(os.environ),
                             ["bash", "-c", "trap 'exit 0' TERM; sleep 20 & wait"], guard=self.guard())
        finally:
            t.join()
        self.assertEqual(c.exception.code, CONFLICT)
        self.assertIn("run-watch was stopped (TERM)", str(c.exception))

    def test_r4_7_run_watch_gets_rs_via_rsk_and_its_parent_pid(self):
        """NEW-watch-direct / N4-orphaned-run-watch: rsk watch tells run-watch it runs under rsk and which pid to
        watch (run-watch --act stops acting once that pid is gone)."""
        seen = self.home / "env"
        with mock.patch.object(Wt, "run_watch", lambda led, argv, cwd, env, guard=None: [seen.write_text(
                f"{env.get('RS_VIA_RSK')} {env.get('RS_WATCH_PARENT')}"), 0][1]):
            rc, text = run("watch", "-C", str(self.proj), "t.tsv", "--once")
        self.assertEqual(rc, OK, text)
        self.assertEqual(seen.read_text(), f"1 {os.getpid()}")

    def test_a_new_deny_terms_run_watch_and_exits_3(self):
        def later():
            time.sleep(0.4)
            G.add(self.led, G.new_deny("stop now", {"names": ["a"]}))
        t = threading.Thread(target=later)
        t.start()
        try:
            with mock.patch.object(Wt, "REFRESH_S", 0.2), self.assertRaises(RskError) as c:
                Wt.run_watch(self.led, ["t.tsv", "--act"], str(self.proj), dict(os.environ),
                             ["bash", "-c", "trap 'exit 0' TERM; sleep 20 & wait"], guard=self.guard())
        finally:
            t.join()
        self.assertEqual(c.exception.code, REFUSED)
        self.assertIn("run-watch was stopped (TERM)", str(c.exception))
        self.assertIsNone(self.led.lease().data)

    def test_approve_refuses_rows_a_deny_matches(self):
        G.add(self.led, G.new_deny("never launch a", {"names": ["a"]}, ["launch"]))
        rc, text = run("watch", "-C", str(self.proj), "t.tsv", "--approve", "ok")
        self.assertEqual(rc, REFUSED, text)
        self.assertIn("never launch a", text)
        self.assertEqual((self.proj / "t.tsv").read_text(), self.TABLE)

    def test_g4_5_an_orphaned_run_watch_lock_is_a_conflict(self):
        lock = self.proj / "logs" / "run-watch" / ".lock"
        lock.mkdir(parents=True)
        other = subprocess.Popen(["sleep", "30"])
        try:
            (lock / "pid").write_text(f"{other.pid}\n")
            (lock / "info").write_text(f"{os.uname().nodename} 2026-11-05T00:00:00+0000 1\n")
            with self.assertRaises(RskError) as c:
                Wt.run_watch(self.led, ["t.tsv", "--once"], str(self.proj), dict(os.environ), ["true"])
            self.assertEqual(c.exception.code, CONFLICT)
            self.assertIn(f"pid {other.pid}", str(c.exception))
            self.assertIn("an orphan", str(c.exception))
            self.assertIsNone(self.led.lease().data)
        finally:
            other.kill()
            other.wait()
        self.assertEqual(Wt.run_watch(self.led, ["t.tsv", "--once"], str(self.proj), dict(os.environ), ["true"]), OK)
        (lock / "info").write_text("elsewhere 2026-11-05T00:00:00+0000 1\n")    # another host: run-watch decides
        self.assertIsNone(Wt.lock_holder(self.proj)["alive"])


if __name__ == "__main__":
    unittest.main()
