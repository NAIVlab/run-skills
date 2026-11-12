"""rsk sync|bootstrap|pull|avail: the harness's bin/run-* exec'd with cwd = the project and TARGET set, every other
argument passed on unchanged, the script's own exit code; a non-passthrough command still refuses unknown arguments."""

import argparse
import contextlib
import io
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

from helpers import ScratchHome

from remote_run import cli, paths, wrappers
from remote_run.errors import USAGE

FAKE = '#!/usr/bin/env bash\necho "T=${TARGET:-} V=${RS_VIA_RSK:-} C=${CLUSTER:-} H=$RS_HOME PWD=$PWD ARGS=$*"\nexit 7\n'


def parse(*argv: str) -> argparse.Namespace:
    p = cli.build_parser()
    args, extra = p.parse_known_args(list(argv))
    args.extra = extra
    return args


class Wrappers(ScratchHome):
    def setUp(self) -> None:
        super().setUp()
        self.proj = self.home / "proj"
        self.proj.mkdir()
        (self.proj / ".hpc.conf").write_text("REMOTE_DIR=/r\n")
        self.src = self.home / "harness-src"
        (self.src / "bin").mkdir(parents=True)
        for name in wrappers.SCRIPTS.values():
            (self.src / "bin" / name).write_text(FAKE)
        os.environ["CLUSTER"] = "inherited"

    def test_plan(self):
        with mock.patch.object(paths, "harness_src", return_value=self.src):
            argv, env, cwd = wrappers.plan(parse("sync", "-C", str(self.proj), "-T", "fx", "-n", "--also", "data/x"))
            self.assertEqual(argv, ["bash", str(self.src / "bin/run-sync"), "-n", "--also", "data/x"])
            self.assertEqual((env["TARGET"], env["RS_VIA_RSK"], env["RS_HOME"]), ("fx", "1", str(self.src)))
            self.assertNotIn("CLUSTER", env)
            self.assertEqual(cwd, self.proj.resolve())
            argv, env, _ = wrappers.plan(parse("pull", "-C", str(self.proj), "-T", "fx", "--", "-n", "logs/a"))
            self.assertEqual(argv[2:], ["-n", "logs/a"])
            argv, env, _ = wrappers.plan(parse("bootstrap", "-C", str(self.proj), "-T", "fx", "--job", "-p", "part-c"))
            self.assertEqual(argv[1:], [str(self.src / "bin/run-bootstrap"), "--job", "-p", "part-c"])
            argv, env, cwd = wrappers.plan(parse("avail", "-T", "a", "-T", "b", "--type", "GT-A", "--min", "2"))
            self.assertEqual(argv[1:], [str(self.src / "bin/run-avail"), "--type", "GT-A", "--min", "2", "a", "b"])
            self.assertNotIn("TARGET", env)
            self.assertEqual(cwd, Path.cwd())
            with self.assertRaises(Exception):
                wrappers.plan(parse("sync", "-C", str(self.home), "-T", "fx"))   # no conf there

    def _rsk(self, *argv: str) -> subprocess.CompletedProcess:
        code = ("import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; from remote_run import cli, "
                "paths; paths.harness_src = lambda: Path(sys.argv[2]); sys.exit(cli.main(sys.argv[3:]))")
        return subprocess.run([sys.executable, "-I", "-c", code, str(Path(cli.__file__).parent.parent), str(self.src),
                               *argv], capture_output=True, text=True, env=os.environ, cwd=self.home)

    def test_exec_hands_over_to_the_script(self):
        done = self._rsk("sync", "-C", str(self.proj), "-T", "fx", "--take-over", "--also", "x")
        self.assertEqual(done.returncode, 7, done.stderr)               # the script's own exit code
        self.assertIn(f"T=fx V=1 C= H={self.src} PWD={self.proj.resolve()} ARGS=--take-over --also x", done.stdout)

    def test_sync_delete_and_bootstrap_job_need_the_users_words(self):
        from remote_run import ledger as L
        for argv in (("sync", "-T", "fx", "-D"), ("sync", "-T", "fx", "--delete", "--take-over"),
                     ("bootstrap", "-T", "fx", "--job", "-p", "cpu")):
            done = self._rsk(argv[0], "-C", str(self.proj), *argv[1:])
            self.assertEqual(done.returncode, 4, (argv, done.stderr))
            self.assertIn("needs user: approval (", done.stdout)
            self.assertNotIn("ARGS=", done.stdout)                      # the script never ran
        self.assertEqual(self._rsk("sync", "-C", str(self.proj), "-T", "fx", "-D", "--approve", " ").returncode, USAGE)
        done = self._rsk("sync", "-C", str(self.proj), "-T", "fx", "-n", "-D")    # a dry run deletes nothing
        self.assertEqual(done.returncode, 7, done.stderr)
        done = self._rsk("sync", "-C", str(self.proj), "-T", "fx", "-D", "--approve", "yes, delete what I removed")
        self.assertEqual(done.returncode, 7, done.stderr)
        self.assertIn("ARGS=-D", done.stdout)                           # --approve is rsk's, never the script's
        done = self._rsk("bootstrap", "-C", str(self.proj), "-T", "fx", "--job", "-p", "cpu", "--approve", "build it")
        self.assertEqual(done.returncode, 7, done.stderr)
        self.assertIn("ARGS=--job -p cpu", done.stdout)
        recs = [a for a in L.Ledger(self.proj).read_audit()[0] if a["event"] == "approved_command"]
        self.assertEqual([(a["command"], a["argv"], a["quote"]) for a in recs],
                         [("sync", ["-D"], "yes, delete what I removed"), ("bootstrap", ["--job", "-p", "cpu"], "build it")])
        self.assertEqual(self._rsk("bootstrap", "-C", str(self.proj), "-T", "fx").returncode, 7)   # plain: unchanged

    def test_d7_g3_flow_3_the_gate_reads_run_syncs_grammar(self):
        self.assertEqual(wrappers.sync_modes(["-D", "--also", "-n"]), (False, True))     # -n is --also's PATH
        self.assertEqual(wrappers.sync_modes(["-D", "--also", "--dry-run"]), (False, True))
        self.assertEqual(wrappers.sync_modes(["--also", "-D"]), (False, False))           # -D is a path here
        self.assertEqual(wrappers.sync_modes(["-n", "--also", "x", "-D"]), (True, True))
        self.assertEqual(wrappers.sync_modes(["--also=-n", "--delete"]), (False, True))
        for argv in (("-D", "--also", "-n"), ("-D", "--also", "--dry-run"), ("--delete", "--also", "-n")):
            done = self._rsk("sync", "-C", str(self.proj), "-T", "fx", *argv)
            self.assertEqual(done.returncode, 4, (argv, done.stdout, done.stderr))
            self.assertIn("needs user: approval (remote deletion", done.stdout)
            self.assertNotIn("ARGS=", done.stdout)
        done = self._rsk("sync", "-C", str(self.proj), "-T", "fx", "--also", "-D")      # no deletion: runs
        self.assertEqual(done.returncode, 7, done.stderr)
        done = self._rsk("bootstrap", "-C", str(self.proj), "-T", "fx", "-p", "cpu", "--job")   # any --job: gated
        self.assertEqual(done.returncode, 4, done.stderr)

    def test_root_push_is_no_deletion_and_takes_the_next_word(self):
        # run-sync --root PATH (and --root=PATH) consumes the next word like --also: `--root -n` and `--root -D` are paths;
        # a root push alone needs no --approve; a -D next to it is still read as one (run-sync refuses the pair itself)
        self.assertEqual(wrappers.sync_modes(["--root", "ckpts/r1"]), (False, False))
        self.assertEqual(wrappers.sync_modes(["--root", "-n"]), (False, False))             # -n is --root's PATH
        self.assertEqual(wrappers.sync_modes(["-D", "--root", "-n"]), (False, True))
        self.assertEqual(wrappers.sync_modes(["--root", "-D"]), (False, False))             # -D is a path here
        self.assertEqual(wrappers.sync_modes(["--root=-D", "-n", "--root", "x"]), (True, False))
        for argv in (("--root", "ckpts/r1"), ("--root", "-D"), ("-n", "--root=ckpts/r1", "--root", "res")):
            done = self._rsk("sync", "-C", str(self.proj), "-T", "fx", *argv)
            self.assertEqual(done.returncode, 7, (argv, done.stdout, done.stderr))      # ran: no --approve needed
            self.assertIn("ARGS=" + " ".join(argv), done.stdout)
        done = self._rsk("sync", "-C", str(self.proj), "-T", "fx", "-D", "--root", "-n")
        self.assertEqual(done.returncode, 4, done.stderr)
        self.assertNotIn("ARGS=", done.stdout)
        with mock.patch.object(paths, "harness_src", return_value=self.src):
            argv, _, _ = wrappers.plan(parse("pull", "-C", str(self.proj), "-T", "fx", "--root", "-n", "ckpts/r1"))
            self.assertEqual(argv[2:], ["--root", "-n", "ckpts/r1"])                    # rsk pull passes --root through
            argv, _, _ = wrappers.plan(parse("sync", "-C", str(self.proj), "-T", "fx", "--root", "-n", "--root=x"))
            self.assertEqual(argv[2:], ["--root", "-n", "--root=x"])
        done = self._rsk("pull", "-C", str(self.proj), "-T", "fx", "--root", "ckpts/r1")
        self.assertEqual(done.returncode, 7, done.stderr)
        self.assertIn("ARGS=--root ckpts/r1", done.stdout)

    def test_unknown_arguments_still_refused_elsewhere(self):
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf), self.assertRaises(SystemExit) as cm:
            cli.main(["config", "--bogus"])
        self.assertEqual(cm.exception.code, USAGE)
        self.assertIn("unrecognized arguments: --bogus", buf.getvalue())
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            cli.main(["sync", "-n"])                                    # -T is required


if __name__ == "__main__":
    unittest.main()
