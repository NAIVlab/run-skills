"""rsk exec: the read-only, secret-safe allowlist, and commands run through the stub ssh of test_status (which runs the
"remote" body locally, from the project's remote dir): output decoding and one exit code per outcome."""

import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

from test_status import Base, run

from remote_run import cli, remote_exec
from remote_run.errors import FAILED, OK, UNKNOWN, USAGE, RskError


class Allowlist(unittest.TestCase):
    def refused(self, *argvs: list[str]) -> None:
        for argv in argvs:
            with self.subTest(argv=argv):
                with self.assertRaises(RskError) as e:
                    remote_exec.check(argv)
                self.assertEqual(e.exception.code, USAGE)

    def test_everyday_reads_pass(self):
        for argv in (["squeue", "--me", "-h", "-o", "%i %T"], ["squeue", "-j", "101", "--start"],
                     ["sacct", "-j", "90", "-X", "-P", "-o", "JobID,State,ExitCode"], ["sacct", "-S", "now-2days"],
                     ["sinfo", "-p", "gpu", "-o", "%P %G"], ["sshare", "-U"], ["sprio", "-j", "1"],
                     ["scontrol", "show", "job", "101"], ["scontrol", "-o", "show", "partition"],
                     ["nvidia-smi"], ["nvidia-smi", "-L"], ["nvidia-smi", "--query-gpu=index,memory.used", "--format=csv"],
                     ["nvidia-smi", "-q", "-d", "MEMORY", "-i", "0"], ["nvidia-smi", "topo", "-m"],
                     ["ps", "-ef"], ["ps", "aux"], ["ps", "-u", "me", "-o", "pid,etime,args"], ["ps", "axo", "pid,args"],
                     ["ps", "-eo", "pid,args", "--sort=-pcpu"], ["ps", "-fp", "123"], ["ps", "123,456"],
                     ["df", "-h", "."], ["ls", "-la", "logs"], ["stat", "-c", "%s %y", "ckpts"], ["wc", "-l", "a.log"],
                     ["free", "-g"], ["uptime"], ["nproc", "--all"], ["hostname", "-s"], ["id", "-un"], ["quota", "-s"],
                     ["date", "+%s"], ["date", "-u", "-d", "yesterday", "+%F"], ["date", "--iso-8601=seconds"],
                     ["head", "-c", "10", "logs/a.log"], ["tail", "-c", "100", "./logs/b.out", "c.txt"]):
            with self.subTest(argv=argv):
                remote_exec.check(argv)

    def test_nvidia_smi_queries_only(self):         # -f writes its output to a file; subcommands set, reset or write
        self.refused(["nvidia-smi", "-f", "train.py"], ["nvidia-smi", "--filename=x"], ["nvidia-smi", "-q", "-f", "x"],
                     ["nvidia-smi", "-qf", "x"], ["nvidia-smi", "dmon", "-f", "x"], ["nvidia-smi", "pmon"],
                     ["nvidia-smi", "drain", "-p", "0"], ["nvidia-smi", "mig", "-dgi"], ["nvidia-smi", "--gom=0"],
                     ["nvidia-smi", "-cc", "1"], ["nvidia-smi", "-pm", "1"], ["nvidia-smi", "-r"],
                     ["nvidia-smi", "topo", "-m", "-f", "x"])

    def test_date_never_sets_the_clock_nor_reads_a_file(self):   # -f/--file echo each line of the file in errors
        self.refused(["date", "-s", "now"], ["date", "--set=now"], ["date", "--se=now"], ["date", "-f", "x"],
                     ["date", "--file=x"], ["date", "--fi=x"], ["date", "0101"], ["date", "-u", "0101", "+%s"],
                     ["date", "-r", "x"], ["date", "-Idate", "0101"])

    def test_hostname_never_sets_it(self):
        self.refused(["hostname", "newname"], ["hostname", "-F", "f"], ["hostname", "--file=f"], ["hostname", "-b"],
                     ["hostname", "-s", "x"])

    def test_wc_never_reads_a_file_list(self):          # --files0-from=F prints F's content in its error messages
        self.refused(["wc", "--files0-from=f"], ["wc", "--files0-from", "f"], ["wc", "--files0=f"])

    def test_ps_never_prints_environments(self):        # BSD `e` appends each process's environment
        self.refused(["ps", "e"], ["ps", "eww", "-u", "me"], ["ps", "auxe"], ["ps", "-o", "pid", "e"],
                     ["ps", "-o", "-e"], ["ps", "-oe"], ["ps", "--environ"], ["ps", "--", "e"])

    def test_sacct_never_prints_scripts_or_environments(self):
        self.refused(["sacct", "--env-vars", "-j", "1"], ["sacct", "--batch-script", "-j", "1"],
                     ["sacct", "-B", "-j", "1"], ["sacct", "--env", "-j", "1"], ["sacct", "--batch=1"],
                     ["sacct", "--json"], ["sacct", "-j", "--env-vars"], ["sacct", "-oB"], ["sacct", "-j"])

    def test_reads_stay_in_the_project_and_off_credentials(self):
        self.refused(["head", "-c", "4096", ".wandb_env"], ["head", "-c", "9", "sub/.netrc"],
                     ["tail", "-c", "9", ".ssh/id_ed25519"], ["head", "-c", "9", ".config/gh/hosts.yml"],
                     ["head", "-c", "9", ".git-credentials"], ["head", "-c", "9", ".cache/huggingface/token"],
                     ["head", "-c", "9", ".env"], ["head", "-c", "9", "/etc/passwd"], ["head", "-c", "9", "/home/u/.ssh/x"],
                     ["tail", "-c", "9", "../../.netrc"], ["tail", "-c", "9", "logs/../../x"], ["head", "-c", "9", "~/x"],
                     ["head", "-c", "9", "-"], ["head", "-c", "9", "."], ["tail", "-c", "+9", "f"],
                     ["head", "-c", "²", "f"], ["tail", "-n", "100", "f"], ["head", "-c", str(1 << 30), "f"])

    def test_unlisted_options_and_operands_are_refused(self):
        self.refused(["squeue", "--bogus"], ["squeue", "-i", "5"], ["sinfo", "-p"], ["free", "x"], ["nproc", "4"],
                     ["scontrol", "update", "JobId=1"], ["scontrol", "show", "config"], ["scontrol", "write", "x"],
                     ["ls", "-D"], ["stat", "--cached=never", "f"])


class Exec(Base):
    def setUp(self) -> None:
        super().setUp()
        self.target("fx-slurm", "T_KIND=slurm; T_HOST=fxhost\n")
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={self.remote}\n")

    def exec(self, *argv: str, deadline: str = "60") -> tuple[int, str]:
        return run("exec", "-C", str(self.proj), "-T", "fx-slurm", "--deadline", deadline, "--", *argv)

    def test_exec_runs_an_allowed_read_in_the_project_dir(self):
        (self.remote / "marker.txt").write_text("hello")
        rc, text = self._cli("exec", "-C", str(self.proj), "-T", "fx-slurm", "--", "ls", "marker.txt")
        self.assertEqual(rc, OK, text)
        self.assertIn("marker.txt", text)
        rc, text = self._cli("exec", "-C", str(self.proj), "-T", "fx-slurm", "--", "head", "-c", "3", "marker.txt")
        self.assertEqual((rc, text.strip()), (OK, "hel"))

    def test_exec_refuses_writes_chains_and_unbounded_reads(self):
        for argv in (["rm", "-rf", "x"], ["scancel", "101"], ["scontrol", "update", "JobId=1"], ["ls", "a;rm b"],
                     ["ls", "$(id)"], ["tail", "-n", "100", "f"], ["head", "-c", str(1 << 30), "f"],
                     ["nvidia-smi", "-pm", "1"], ["python", "train.py"], []):
            rc, text = run("exec", "-C", str(self.proj), "-T", "fx-slurm", "--", *argv)
            self.assertEqual(rc, USAGE, (argv, text))
        self.assertFalse((self.stub / "ssh.log").exists())   # nothing reached the target

    def test_output_that_is_not_utf8_is_replaced_not_a_crash(self):
        (self.remote / "bin.dat").write_bytes(b"ok\xff\xfe\n")
        (self.remote / "bar.log").write_text("█" * 10)             # a tail window that starts mid-character
        rc, text = self.exec("head", "-c", "10", "bin.dat")
        self.assertEqual(rc, OK, text)
        self.assertIn("ok�", text)
        rc, text = self.exec("tail", "-c", "4", "bar.log")
        self.assertEqual((rc, text.strip()), (OK, "�█"))

    def test_output_cut_at_the_cap_is_ok(self):          # the cut closes the pipe: SIGPIPE (141) is not a failure
        self.tool("squeue", "#!/usr/bin/env bash\nexec yes 0123456789abcdef\n")
        rc, text = self.exec("squeue")
        self.assertEqual(rc, OK, text[-300:])
        self.assertIn(f"[rsk exec: output cut at {remote_exec.CAP} bytes]", text)
        self.assertNotIn("remote exit", text)

    def test_sigpipe_without_a_cut_is_a_failure(self):
        self.tool("squeue", "#!/usr/bin/env bash\necho partial\nkill -PIPE $$\n")
        rc, text = self.exec("squeue")
        self.assertEqual(rc, FAILED, text)
        self.assertIn("rsk exec: remote exit 141", text)

    def test_a_failed_remote_command_is_failed_with_its_code(self):   # never passed through as an rsk exit code
        rc, text = self.exec("ls", "missing")
        self.assertEqual(rc, FAILED, text)
        self.assertIn("rsk exec: remote exit 2", text)
        for code in (3, 4, 6, 66, 70):
            self.tool("nvidia-smi", f"#!/usr/bin/env bash\necho failing\nexit {code}\n")
            rc, text = self.exec("nvidia-smi", "-L")
            self.assertEqual(rc, FAILED, (code, text))
            self.assertIn(f"rsk exec: remote exit {code}", text)

    def test_no_remote_dir_is_usage(self):
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={self.home / 'gone'}\n")
        rc, text = self.exec("ls")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("cannot cd", text)

    def test_ssh_failure_is_unknown(self):
        os.environ["SSH_FAIL"] = "1"
        rc, text = self.exec("ls")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("ssh failed", text)

    def test_the_deadline_is_unknown_and_never_zero(self):   # `timeout 0` would disable it: 0.5 s rounds up to 1 s
        self.tool("squeue", "#!/usr/bin/env bash\nsleep 4\necho finished\n")
        rc, text = self.exec("squeue", deadline="0.5")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("stopped at the 1s deadline", text)
        self.assertNotIn("finished", text)
        real = subprocess.run

        def no_answer(cmd, *a, **kw):                    # only ssh hangs; the local harness calls still run
            if cmd[0] == "ssh":
                raise subprocess.TimeoutExpired(cmd, 1)
            return real(cmd, *a, **kw)
        with mock.patch.object(remote_exec.subprocess, "run", side_effect=no_answer):
            rc, text = self.exec("ls")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("no answer from fxhost", text)

    def _cli(self, *argv: str) -> tuple[int, str]:   # ssh output goes to the real stdout: capture at the fd level
        done = subprocess.run([sys.executable, "-I", "-c", "import sys; sys.path[:0]=sys.argv[1:2]; from remote_run import cli;"
                               " sys.exit(cli.main(sys.argv[2:]))", str(Path(cli.__file__).parent.parent), *argv],
                              capture_output=True, text=True, env=os.environ)
        return done.returncode, done.stdout + done.stderr


if __name__ == "__main__":
    unittest.main()
