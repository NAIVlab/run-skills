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
from pathlib import Path

from helpers import ScratchHome

from remote_run import cli
from remote_run import ledger as L
from remote_run import watch as Wt
from remote_run.errors import CONFLICT, LEASE_ENDED, OK, USAGE, RskError


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


if __name__ == "__main__":
    unittest.main()
