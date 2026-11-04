"""rsk status / rsk logs against a stub ssh that runs the "remote" script locally (stub squeue/sacct on PATH)."""

import contextlib
import io
import os
import subprocess
import sys
import unittest
from pathlib import Path

from helpers import ScratchHome

from remote_run import cli, harness, observe, paths
from remote_run.errors import FAILED, OK, UNKNOWN, USAGE

SSH = """#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
echo "$1" >> "$STUB/ssh.log"; shift
[ -z "${SSH_FAIL:-}" ] || { echo "ssh: connect to host: Connection timed out" >&2; exit 255; }
[ -z "${SSH_ANSWER:-}" ] || { cat > /dev/null; cat "$SSH_ANSWER"; exit 0; }
exec bash -c "$*"
"""


def run(*argv: str) -> tuple[int, str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        rc = cli.main(list(argv))
    return rc, buf.getvalue()


class Base(ScratchHome):
    def setUp(self) -> None:
        super().setUp()
        self.stub = self.home / "stub"
        (self.stub / "bin").mkdir(parents=True)
        self.tool("ssh", SSH)
        os.environ["STUB"] = str(self.stub)
        os.environ["PATH"] = f"{self.stub / 'bin'}{os.pathsep}{os.environ['PATH']}"
        for k in ("SSH_FAIL", "SSH_ANSWER"):
            os.environ.pop(k, None)
        self.remote = self.home / "remote" / "proj"
        self.remote.mkdir(parents=True)
        self.proj = self.home / "proj"
        self.proj.mkdir()

    def tool(self, name: str, text: str) -> None:
        p = self.stub / "bin" / name
        p.write_text(text)
        p.chmod(0o755)

    def target(self, name: str, profile: str) -> None:
        d = Path(os.environ["RS_USER_DIR"]) / "targets" / name
        d.mkdir(parents=True)
        (d / "profile.sh").write_text(profile)


class Slurm(Base):
    def setUp(self) -> None:
        super().setUp()
        self.target("fx-slurm", "T_KIND=slurm; T_HOST=fxhost; T_MAXTIME=1-00:00:00\n")
        self.target("fx-other", "T_KIND=slurm; T_HOST=fxother; T_REMOTE_DIR_REQUIRED=1\n")
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={self.remote}\n")
        here, other = str(self.remote), "/elsewhere/proj"
        (self.stub / "squeue.out").write_text(
            f"101|exp--a01|RUNNING|None|1|1700000000|{here}|\n"
            f"102|exp--b01|PENDING|Priority|0|0|{here}|\n"
            f"999|not-mine|RUNNING|None|0|1700000000|{other}|\n")
        (self.stub / "sacct.out").write_text(
            f"90|exp--c01|FAILED|1:0|1700000500|{here}\n"
            f"91|exp--d01|COMPLETED|0:0|1700000600|{here}\n"
            f"101|exp--a01|RUNNING|0:0|Unknown|{here}\n"
            f"98|elsewhere|FAILED|1:0|1700000600|{other}\n")
        self.tool("squeue", '#!/usr/bin/env bash\n[ -z "${SQ_FAIL:-}" ] || exit 1\ncat "$STUB/squeue.out"\n')
        self.tool("sacct", '#!/usr/bin/env bash\ncat "$STUB/sacct.out"\n')
        os.environ.pop("SQ_FAIL", None)

    def test_jobs_of_this_dir_only(self):
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertIn("[fx-slurm] fxhost:", text)
        self.assertRegex(text, r"RUNNING\s+job 101\s+exp--a01")
        self.assertIn("(Priority)", text)
        self.assertRegex(text, r"FAILED\s+job 90\s+exp--c01\s+rc 1:0")
        self.assertIn("ended in 2d: 1 COMPLETED, 1 FAILED", text)
        self.assertNotIn("not-mine", text)
        self.assertNotIn("elsewhere", text)
        self.assertNotIn("fx-other", text)          # T_REMOTE_DIR_REQUIRED and no FXOTHER_REMOTE_DIR: not this project's
        self.assertIn("digest: rsk logs -T fx-slurm", text)

    def test_unreachable_is_unobservable_not_empty(self):
        os.environ["SSH_FAIL"] = "1"
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, UNKNOWN)
        self.assertIn("UNOBSERVABLE", text)
        self.assertIn("unknown, not 'none'", text)

    def test_failed_squeue_is_unobservable(self):
        os.environ["SQ_FAIL"] = "1"
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, UNKNOWN)
        self.assertIn("UNOBSERVABLE: squeue", text)

    def test_a_dir_never_synced_is_not_unobservable(self):
        gone = self.home / "remote" / "gone"            # the parent exists, the dir does not
        with open(self.stub / "squeue.out", "a") as f:
            f.write(f"103|exp--e01|RUNNING|None|0|1700000000|{gone}|\n")   # a job whose dir was deleted since
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={gone}\n")
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertIn(f"not synced here: {gone} does not exist on fxhost (jobs above ran there)", text)
        self.assertRegex(text, r"RUNNING\s+job 103\s+exp--e01")
        self.assertNotIn("exp--a01", text)
        self.assertIn('"synced": false', run("status", "-C", str(self.proj), "--json")[1])

    def test_a_missing_parent_is_unobservable(self):   # e.g. an unmounted filesystem: say nothing about its runs
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={self.home / 'unmounted' / 'proj'}\n")
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("UNOBSERVABLE: cd", text)
        self.assertNotIn("not synced", text)

    def test_unknown_target_and_missing_conf(self):
        self.assertEqual(run("status", "-C", str(self.proj), "-T", "fx-other")[0], USAGE)
        self.assertEqual(run("status", "-C", str(self.home))[0], USAGE)

    def test_json(self):
        rc, text = run("status", "-C", str(self.proj), "--json")
        self.assertEqual(rc, OK)
        self.assertIn('"id": "101"', text)

    def test_logs_runs_the_deployed_digest(self):
        (self.remote / ".fx-slurm").mkdir()
        (self.remote / ".fx-slurm" / "status.sh").write_text('echo "digest args: $*"\n')
        rc, text = self._logs("-T", "fx-slurm", "-n", "40", "101")
        self.assertEqual(rc, OK, text)
        self.assertIn("digest args: -n 40 101", text)

    def test_logs_without_a_deployed_digest(self):
        rc, text = self._logs("-T", "fx-slurm", "101")
        self.assertEqual(rc, USAGE)
        self.assertIn("not deployed", text)
        # the procedure's rail: a sync pushes local code into the dir a running job reads, so never "sync first"
        self.assertIn("rsk exec -T fx-slurm -- tail -c 20000 <log>", text)
        self.assertIn("re-sync only with the user's OK", text)
        self.assertNotIn("sync the project first", text)

    def test_logs_exit_codes_keep_one_meaning(self):
        (self.remote / ".fx-slurm").mkdir()
        sh = self.remote / ".fx-slurm" / "status.sh"
        sh.write_text('echo "ERROR: a nohup target takes the log path" >&2; exit 2\n')   # status.sh's own usage error
        self.assertEqual(self._logs("-T", "fx-slurm", "101")[0], USAGE)
        sh.write_text("exit 3\n")                       # it ran and failed: not 'refused', not 'unreachable'
        rc, text = self._logs("-T", "fx-slurm", "101")
        self.assertEqual(rc, FAILED, text)
        self.assertIn("rsk logs: status.sh exit 3", text)

    def test_remote_host_is_not_per_target(self):   # bin/run-watch refuses the same: every Slurm target -> one host
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={self.remote}\nFXOTHER_REMOTE_DIR={self.remote}\n"
                                             "REMOTE_HOST=fxhost\n")
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, USAGE, text)
        self.assertIn("REMOTE_HOST in the conf is not per target", text)
        self.assertEqual(run("status", "-C", str(self.proj), "-T", "fx-slurm", "-T", "fx-other")[0], USAGE)
        self.assertFalse((self.stub / "ssh.log").exists())
        rc, text = run("status", "-C", str(self.proj), "-T", "fx-other")   # one Slurm target named: read on REMOTE_HOST
        self.assertEqual(rc, OK, text)
        self.assertIn("[fx-other] fxhost:", text)
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={self.remote}\nREMOTE_HOST=fxhost\n")   # one resolves
        self.assertEqual(run("status", "-C", str(self.proj))[0], OK)

    def test_a_profile_that_does_not_load_is_unobservable(self):
        self.target("fx-broken", "T_KIND=slurmm; T_HOST=fxbroken\n")
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, UNKNOWN, text)
        self.assertRegex(text, r"\[fx-broken\]  UNOBSERVABLE: its profile does not load: .*T_KIND must be slurm\|nohup "
                               r"\(got 'slurmm'\)")
        self.assertRegex(text, r"RUNNING\s+job 101")          # the others are still read
        self.assertEqual(run("status", "-C", str(self.proj), "-T", "fx-slurm")[0], OK)
        for argv in (("logs", "-T", "fx-broken", "101"), ("exec", "-T", "fx-broken", "--", "ls")):
            rc, text = run(argv[0], "-C", str(self.proj), *argv[1:])
            self.assertEqual(rc, USAGE, text)
            self.assertIn("fx-broken: its profile does not load", text)
        self.assertNotIn("fxbroken", (self.stub / "ssh.log").read_text())

    def test_a_conf_that_does_not_source_is_usage(self):
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={self.remote} extra\n")
        for argv in (("status",), ("logs", "-T", "fx-slurm", "101"), ("exec", "-T", "fx-slurm", "--", "ls")):
            rc, text = run(argv[0], "-C", str(self.proj), *argv[1:])
            self.assertEqual(rc, USAGE, text)
            self.assertIn(".hpc.conf does not source", text)
        self.assertFalse((self.stub / "ssh.log").exists())

    def test_a_just_ended_job_shows_its_own_outcome(self):   # squeue keeps ended jobs for MinJobAge, without End/rc
        here = str(self.remote)
        (self.stub / "squeue.out").write_text(f"201|exp--x01|FAILED|NonZeroExitCode|0|1700090000|{here}|\n"
                                              f"202|exp--y01|FAILED|NonZeroExitCode|0|1700090000|{here}|\n")
        (self.stub / "sacct.out").write_text(f"200|exp--x01|TIMEOUT|0:0|1700000000|{here}\n"
                                             f"201|exp--x01|FAILED|1:0|1700099000|{here}\n"
                                             f"202|exp--y01|RUNNING|0:0|Unknown|{here}\n")   # sacct lags squeue
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertRegex(text, r"FAILED\s+job 201\s+exp--x01\s+rc 1:0")
        self.assertNotIn("job 200", text)
        self.assertRegex(text, r"FAILED\s+job 202\s+exp--y01")
        self.assertNotIn("RUNNING", text)
        self.assertIn("ended in 2d: 2 FAILED, 1 TIMEOUT", text)   # 201 once, not twice

    def test_a_bar_in_a_job_name_does_not_shift_workdir(self):
        here = str(self.remote)
        (self.stub / "squeue.out").write_text(f"101|a|b|RUNNING|None|0|1700000000|{here}|\n")
        (self.stub / "sacct.out").write_text(f"90|c|d|FAILED|1:0|1700000500|{here}\n")
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertRegex(text, r"RUNNING\s+job 101\s+a\|b")
        self.assertRegex(text, r"FAILED\s+job 90\s+c\|d\s+rc 1:0")

    def test_bytes_that_are_not_utf8_do_not_crash_the_read(self):
        (self.stub / "squeue.out").write_bytes(f"101|exp-\xff\xfe|RUNNING|None|0|1700000000|{self.remote}|\n"
                                               .encode("latin-1"))
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertRegex(text, "RUNNING\\s+job 101\\s+exp-\ufffd\ufffd")

    def test_an_unreadable_answer_is_unobservable_not_a_traceback(self):
        self.target("fx-box", "T_KIND=nohup; T_HOST=fxbox\n")
        (self.proj / ".ws.conf").write_text(f"WS_REMOTE_DIR={self.remote}\n")
        answer = self.stub / "answer"
        answer.write_text("@@start\n@@now 1700000000\n@@pwd /p|/p\n@@ws\n"
                          "logs/x-20261103-120000.log 1 2 alive:7\n@@end\n")   # alive:<up>:<pid> lost a field
        os.environ["SSH_ANSWER"] = str(answer)
        rc, text = run("status", "-C", str(self.proj), "-T", "fx-box")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("[fx-box] fxbox:", text)
        self.assertIn("UNOBSERVABLE: unreadable answer", text)

    def _logs(self, *argv: str) -> tuple[int, str]:
        return self._cli("logs", "-C", str(self.proj), *argv)

    def _cli(self, *argv: str) -> tuple[int, str]:   # ssh output goes to the real stdout: capture at the fd level
        done = subprocess.run([sys.executable, "-I", "-c", "import sys; sys.path[:0]=sys.argv[1:2]; from remote_run import cli;"
                               " sys.exit(cli.main(sys.argv[2:]))", str(Path(cli.__file__).parent.parent), *argv],
                              capture_output=True, text=True, env=os.environ)
        return done.returncode, done.stdout + done.stderr


@unittest.skipUnless(sys.platform.startswith("linux"), "the nohup probe uses GNU stat and procps (the targets' Linux)")
class Nohup(Base):
    def test_alive_and_ended_runs(self):
        self.target("fx-box", "T_KIND=nohup; T_HOST=fxbox\n")
        (self.proj / ".ws.conf").write_text(f"WS_REMOTE_DIR={self.remote}\n")
        logs = self.remote / "logs"
        logs.mkdir()
        live = subprocess.Popen(["sleep", "30"])
        try:
            (logs / "exp--a01-20261103-120000.log").write_text("step 1\n")
            (logs / "exp--a01-20261103-120000.log.pid").write_text(f"{live.pid}\n")
            dead = subprocess.run(["sh", "-c", "echo $$"], capture_output=True, text=True).stdout.strip()
            (logs / "exp--b01-20261103-110000.log").write_text("done\n")
            (logs / "exp--b01-20261103-110000.log.pid").write_text(f"{dead}\n")
            rc, text = run("status", "-C", str(self.proj))
        finally:
            live.kill()
            live.wait()
        self.assertEqual(rc, OK, text)
        self.assertRegex(text, rf"ALIVE\s+pid {live.pid}\s+exp--a01")
        self.assertRegex(text, r"ENDED\s+exp--b01\s+pid gone")

    def test_a_box_the_project_was_never_synced_to(self):
        self.target("fx-box", "T_KIND=nohup; T_HOST=fxbox\n")
        (self.proj / ".ws.conf").write_text(f"WS_REMOTE_DIR={self.home / 'remote' / 'never'}\n")
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertIn("not synced here", text)
        self.assertNotIn("UNOBSERVABLE", text)


class Parse(unittest.TestCase):
    def test_a_note_inside_the_ws_section_does_not_end_it(self):   # a log deleted between `ls -1t` and `stat`
        box = harness.Place("fx-box", "nohup", "fxbox", "/p", ".ws")
        o = observe.parse(box, "@@start\n@@now 1700000100\n@@pwd /p|/p\n@@ws\n@@partial stat\n"
                               "logs/exp--a01-20261103-120000.log 1700000000 9 alive:60:4242\n@@end\n", 0, "")
        self.assertTrue(o.ok)
        self.assertEqual(o.partial, ["stat"])
        self.assertEqual([(j.name, j.state, j.pid) for j in o.jobs], [("exp--a01", "ALIVE", "4242")])


class Env(ScratchHome):
    def test_rs_python_is_rsks_own_interpreter_in_a_clone_too(self):   # tests/90-py.sh: python3 may be < 3.11
        os.environ.pop("RS_PYTHON", None)
        src = paths.harness_src()
        self.assertEqual(harness.env(src)["RS_PYTHON"], sys.executable)
        os.environ["RS_PYTHON"] = "/opt/py/bin/python3"
        self.assertEqual(harness.env(src)["RS_PYTHON"], "/opt/py/bin/python3")


if __name__ == "__main__":
    unittest.main()
