"""rsk status / rsk logs against a stub ssh that runs the "remote" script locally (stub squeue/sacct on PATH)."""

import contextlib
import io
import json
import os
import subprocess
import sys
import time
import unittest
from pathlib import Path

from helpers import ScratchHome

from remote_run import cli, harness, observe, paths
from remote_run import status as status_mod
from remote_run import grants as G
from remote_run import ledger as L
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
        self.slurm_fixture()

    def slurm_fixture(self) -> None:
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


class Ledgered(Base):
    """status with a ledger: runs, observations recorded (a failed read changes none), UNLEDGERED, SUBMIT_UNKNOWN
    reconciled from the remote journal and squeue comments, grants, the lease, needs-user lines."""

    def setUp(self) -> None:
        super().setUp()
        Slurm.slurm_fixture(self)
        self.tool("squeue", '#!/usr/bin/env bash\ncase "$*" in *Comment*) cat "$STUB/comments.out" 2>/dev/null ;; '
                            '*) [ -z "${SQ_FAIL:-}" ] || exit 1; cat "$STUB/squeue.out" ;; esac\n')
        (self.stub / "comments.out").write_text("")
        self.led = L.Ledger(self.proj)
        self.led.record_attempt(name="exp--a01", target="fx-slurm", kind="slurm", nonce="n-a", submit="submitted",
                                job="101", grant="g-x")

    def journal(self, nonce: str, **files: str) -> Path:
        a = self.remote / ".rs" / "attempts" / nonce
        a.mkdir(parents=True)
        for k, v in files.items():
            (a / k).write_text(v)
        for q in [a, *a.iterdir()]:
            os.utime(q, (1_700_000_000, 1_700_000_000))
        return a

    def test_ledger_runs_and_unledgered_jobs(self):
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertRegex(text, r"RUNNING\s+job 101\s+exp--a01  up \S+  restarts 1\n")      # ledgered: no tag
        self.assertRegex(text, r"PENDING\s+job 102\s+exp--b01  \(Priority\)  UNLEDGERED")
        self.assertIn("rsk adopt -T fx-slurm --job <id> --as <run>", text)
        self.assertRegex(text, r"  exp\s+a01  RUNNING\s+\[fx-slurm\] job 101  squeue, \d+s ago  under g-x")
        att = self.led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual((att["observed"]["state"], att["observed"]["source"]), ("RUNNING", "squeue"))
        seen_at = att["observed"]["at"]
        os.environ["SSH_FAIL"] = "1"
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, UNKNOWN)
        self.assertIn("(target UNOBSERVABLE now", text)
        self.assertEqual(self.led.read_run("exp").data["attempts"]["a01"]["observed"]["at"], seen_at)
        self.assertIn("watch lease: none", text)
        self.assertIn("== grants ==\n  none recorded", text)

    def test_run_watchs_and_bootstraps_own_submits_are_not_unledgered(self):
        self.journal("rw-20261105T000000Z-1-1", receipt="job=102\nname=exp--b01\nnonce=rw-20261105T000000Z-1-1\n",
                     result="stage=done rc=0 verdict=submitted at=1\n")
        self.journal("rw-20261105T000000Z-1-2", stage="sbatch\n")               # its submit still open
        argv = (f"sbatch --job-name=proj-bootstrap --chdir={self.remote} {self.remote}/.fx-slurm/job.sbatch bash "
                f"{self.remote}/.fx-slurm/bootstrap.sh")
        self.journal("20261105T000000Z-9-1", receipt=f"job=103\nname=proj-bootstrap\nnonce=x\nargv={argv}\n",
                     result="stage=done rc=0 verdict=submitted at=1\n")
        with (self.stub / "squeue.out").open("a") as f:
            f.write(f"103|proj-bootstrap|RUNNING|None|0|1700000000|{self.remote}|\n")
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertRegex(text, r"PENDING\s+job 102\s+exp--b01  \(Priority\)  \(run-watch's\)")
        self.assertRegex(text, r"RUNNING\s+job 103\s+proj-bootstrap.*  \(bootstrap's\)")
        self.assertIn("run-watch attempt rw-20261105T000000Z-1-2  open", text)
        self.assertNotIn("UNLEDGERED", text)
        self.assertNotIn("rsk adopt", text)                                       # nothing to adopt
        doc = json.loads(run("status", "-C", str(self.proj), "--json")[1])
        self.assertEqual({u["by"] for u in doc["unledgered"]}, {"run-watch", "bootstrap"})

    def test_g3_flow_4_a_bootstrap_is_known_by_its_receipts_payload_not_its_name(self):
        argv = f"sbatch --job-name=resnet--eval--ci-bootstrap {self.remote}/.fx-slurm/job.sbatch python eval.py --bootstrap 1000"
        self.journal("20261105T000000Z-9-2", receipt=f"job=104\nname=resnet--eval--ci-bootstrap\nnonce=y\nargv={argv}\n",
                     result="stage=done rc=0 verdict=submitted at=1\n")
        with (self.stub / "squeue.out").open("a") as f:
            f.write(f"104|resnet--eval--ci-bootstrap|RUNNING|None|0|1700000000|{self.remote}|\n")
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertRegex(text, r"RUNNING\s+job 104\s+resnet--eval--ci-bootstrap.*UNLEDGERED")
        self.assertNotIn("(bootstrap's)", text)
        self.assertIn("rsk adopt -T fx-slurm", text)
        self.assertFalse(status_mod.is_bootstrap("python eval.py --bootstrap 1000", ".fx-slurm"))
        self.assertTrue(status_mod.is_bootstrap(r"x/job.sbatch bash /r/my\ proj/.fx-slurm/bootstrap.sh", ".fx-slurm"))
        self.assertFalse(status_mod.is_bootstrap("bash /r/p/.other/bootstrap.sh", ".fx-slurm"))

    def test_e_status_an_unwritable_ledger_is_a_warning_not_a_crash(self):
        self.led.record_attempt(name="exp--b01", target="fx-slurm", kind="slurm", nonce="n-b", submit="unknown")
        self.journal("n-b", receipt="job=102\nname=exp--b01\nnonce=n-b\n", result="stage=done rc=0 verdict=submitted\n")
        from unittest import mock
        with mock.patch.object(L.Ledger, "locked", side_effect=PermissionError(13, "Permission denied", "lock")):
            rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertIn("WARNING: ledger not updated (read-only view)", text)
        self.assertIn("== grants ==", text)                                      # the rest is still printed

    def test_d8_a_live_run_watch_lock_is_shown(self):
        lock = self.proj / "logs" / "run-watch" / ".lock"
        lock.mkdir(parents=True)
        (lock / "pid").write_text(f"{os.getpid()}\n")
        (lock / "info").write_text(f"{os.uname().nodename} 2026-11-05T00:00:00+0000 1\n")
        rc, text = run("status", "-C", str(self.proj))
        self.assertIn(f"run-watch lock: pid {os.getpid()} since 2026-11-05T00:00:00+0000 act=1 — alive on this host — no "
                      "live rsk watch lease holds it (an orphan", text)

    def test_submit_unknown_reconciled_from_the_journal(self):
        self.led.record_attempt(name="exp--b01", target="fx-slurm", kind="slurm", nonce="n-b", submit="unknown")
        self.journal("n-b", receipt="job=102\nname=exp--b01\nnonce=n-b\n", result="stage=done rc=0 verdict=submitted\n")
        self.led.record_attempt(name="exp--c01", target="fx-slurm", kind="slurm", nonce="n-c", submit="unknown")
        (self.stub / "comments.out").write_text("90|rs=n-c|\n")
        g = G.add(self.led, G.new_grant("go", {}, ["launch"], max_live=None, max_launches=5, expires=None))
        G.use(self.led, g["id"], "n-d", "launch")
        self.led.record_attempt(name="exp--d01", target="fx-slurm", kind="slurm", nonce="n-d", submit="unknown",
                                grant=g["id"])
        self.journal("n-d", stage="policy\n", result="stage=policy rc=3 verdict=refused at=1\n")
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertIn("exp--b01 a01: SUBMIT_UNKNOWN -> submitted (remote receipt (reconciled))", text)
        self.assertIn("exp--c01 a01: SUBMIT_UNKNOWN -> submitted (squeue comment rs=n-c (reconciled))", text)
        self.assertIn(f"exp--d01 a01: use of {g['id']} given back", text)
        b = self.led.read_run("exp--b01").data["attempts"]["a01"]
        self.assertEqual((b["submissions"][0]["job"], L.attempt_state(b)), ("102", "PENDING"))
        c = self.led.read_run("exp--c01").data["attempts"]["a01"]
        self.assertEqual((c["submissions"][0]["job"], L.attempt_state(c)), ("90", "FAILED"))
        self.assertEqual(L.attempt_state(self.led.read_run("exp--d01").data["attempts"]["a01"]), "NOT_SUBMITTED")
        self.assertEqual(next(r for r in self.led.state().grants if r["id"] == g["id"])["used"], [])
        self.assertNotIn("UNLEDGERED", text.split("== ledger")[0].split("PENDING")[1].split("\n")[0])

    def test_an_open_unknown_is_a_needs_user_line_without_a_ready_approval(self):
        self.led.record_attempt(name="exp--z01", target="fx-slurm", kind="slurm", nonce="n-z", submit="unknown",
                                at="2026-01-01T00:00:00Z")
        self.journal("n-z", stage="sbatch\n", result="stage=sbatch rc=1 verdict=unknown at=1\n")
        self.journal("stray", stage="avail\n")                       # another tool's attempt, outcome open
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertRegex(text, r"exp--z01\s+a01  SUBMIT_UNKNOWN")
        need = [ln for ln in text.splitlines() if ln.startswith("needs user:")]
        self.assertEqual(len(need), 1, text)
        self.assertIn("SUBMIT_UNKNOWN (nonce n-z: stage sbatch, result verdict=unknown, no receipt", need[0])
        self.assertIn("rsk adopt --not-submitted, with their words", need[0])
        self.assertNotIn("--approve", text)
        self.assertRegex(text, r"UNLEDGERED attempt stray  open  stage avail")
        self.assertEqual(L.attempt_state(self.led.read_run("exp--z01").data["attempts"]["a01"]), "SUBMIT_UNKNOWN")
        doc = json.loads(run("status", "-C", str(self.proj), "--json")[1])
        self.assertEqual(len(doc["needs_user"]), 1)
        self.assertEqual(doc["unledgered"][0]["nonce"], "stray")
        self.assertTrue(next(j for j in doc["targets"][0]["jobs"] if j["id"] == "101")["ledgered"])

    def test_grants_lease_and_after_deny_flags(self):
        G.add(self.led, G.new_deny("not on gpu", {"partitions": ["gpu"]}))
        G.add(self.led, G.new_grant("ok, gpu then", {"partitions": ["gpu"]}, ["launch"], max_live=1,
                                    max_launches=None, expires="2099-12-31"))
        self.led.take_lease(time.time() + 600)
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertIn("covers: launch: partitions gpu; no plan with warnings", text)
        self.assertIn("launches 0/no limit (user's words) · live 0/1 · expires 2099-12-31", text)
        self.assertIn("DENY", text)
        self.assertRegex(text, r"watch lease: live — pid \d+ on ")
        self.assertRegex(text, r"needs user: grant g-\S+ \(cli\): created \d+s after deny d-")


    def test_r7_6_status_flags_a_stored_record_naming_a_target_the_harness_does_not_know(self):
        """NF6-status-no-stale-flag: R6-9's WARNING appeared in `rsk grant list` and `rsk doctor` but not in `rsk
        status`, the read the skill tells agents to run first — an agent never saw that the user's deny was not
        enforced. status's grants block now carries the same WARNING (and R7-2's NOTE for an unlisted partition)."""
        typo = G.add(self.led, G.new_deny("never launch anything on fx-slurm again", {"targets": ["fx-slrum"]}))
        part = G.add(self.led, G.new_deny("never the debug partition", {"targets": ["fx-slurm"],
                                                                        "partitions": ["debug"]}))
        self.target("fx-listed", "T_KIND=slurm; T_HOST=fxhost; T_PARTITIONS='gpu,paid'\n")
        listed = G.add(self.led, G.new_deny("never debug on fx-listed", {"targets": ["fx-listed"],
                                                                        "partitions": ["debug"]}))
        rc, text = run("status", "-C", str(self.proj), "-T", "fx-slurm")
        self.assertEqual(rc, OK, text)
        grants_block = text.split("== grants ==", 1)[1]
        self.assertIn(f"WARNING: {typo['id']} (deny): target fx-slrum is not one the harness knows", grants_block)
        self.assertIn("never matches (the user's deny is not enforced there) — fix or revoke", grants_block)
        self.assertNotIn(f"WARNING: {part['id']}", grants_block)            # fx-slurm lists none: nothing to say
        self.assertIn("NOTE: partition debug is not in the profile's display list (T_PARTITIONS of fx-listed: gpu, "
                      "paid)", grants_block)
        self.assertNotIn(f"WARNING: {listed['id']}", grants_block)          # R7-2: a partition is never "never matches"
        doc = json.loads(run("status", "-C", str(self.proj), "-T", "fx-slurm", "--json")[1])
        probs = {g["id"]: g["scope_problems"] for g in doc["grants"]}
        self.assertTrue(probs[typo["id"]])
        self.assertEqual(probs[listed["id"]], [])
        notes = {g["id"]: g["scope_notes"] for g in doc["grants"]}       # --json says what the text says (as grant
        self.assertIn("is not in the profile's display list", notes[listed["id"]][0])   # list --json does)
        self.assertEqual(notes[typo["id"]], [])

    def test_r8_7_status_never_crashes_on_a_damaged_grants_record(self):
        """NF7-status-json-damaged / NF7-status-json-invalid-record: `rsk status --json` called describe(),
        scope_problems() and scope_notes() on every record, valid or not — a hand-damaged one (scope.targets: 5,
        [5, "fx-slurm"], partitions: 7, scope: "x", a bare string) crashed the whole JSON view (TypeError, exit 1).
        Text and --json now list an invalid record as invalid with the validation message and whether it fails closed,
        as `rsk grant list --json` does; a grant made right after such a deny is still flagged."""
        G.add(self.led, G.new_deny("never use preempt on fx-slurm", {"targets": ["fx-slurm"], "partitions": ["gpu"]}))
        f = self.led.dir / "grants.json"
        doc = json.loads(f.read_text())
        good = doc["records"][0]
        damaged = [{**good, "id": f"d-20261105-00000{i}", "scope": sc} for i, sc in enumerate((
            {"targets": 5}, {"partitions": 7}, {"targets": [5, "fx-slurm"], "partitions": [None, "gpu"]}, "notadict",
            {"names": [" b2"]}, {"targets": "fx-slurm"}))]
        damaged += [{**good, "id": "d-20261105-00000a", "actions": "launch"},
                    {**good, "id": "d-20261105-00000b", "revoked": "yes"}, "junk", 5, None]
        doc["records"] = damaged + doc["records"]
        f.write_text(json.dumps(doc))
        (self.led.dir / "grants.json.prev").unlink(missing_ok=True)
        G.add(self.led, G.new_grant("ok, gpu then", {"partitions": ["gpu"]}, ["launch"], max_live=1, max_launches=None,
                                    expires="2099-12-31"))
        self.target("fx-listed", "T_KIND=slurm; T_HOST=fxhost; T_PARTITIONS='gpu,paid'\n")
        rc, text = run("status", "-C", str(self.proj), "-T", "fx-slurm")
        self.assertEqual(rc, OK, text)
        self.assertNotIn("Traceback", text)
        block = text.split("== grants ==", 1)[1]
        self.assertEqual(block.count("INVALID"), len(damaged), block)
        rc, out = run("status", "-C", str(self.proj), "-T", "fx-slurm", "--json")
        self.assertEqual(rc, OK, out)
        doc = json.loads(out)
        bad = [g for g in doc["grants"] if "invalid" in g]
        self.assertEqual(len(bad), len(damaged))
        self.assertTrue(all(g["invalid"] and g["fail_closed"] for g in bad), bad)
        self.assertEqual([g["record"] for g in bad], damaged)
        self.assertTrue(any("whitespace in a scope item" in g["invalid"] for g in bad))
        fine = [g for g in doc["grants"] if "invalid" not in g]
        self.assertEqual(sorted(g["kind"] for g in fine), ["deny", "grant"])
        self.assertTrue(all("covers" in g and "scope_notes" in g for g in fine))
        self.assertTrue(any("created" in n and "after deny d-20261105-00000" in n for n in doc["needs_user"]),
                        doc["needs_user"])                      # a damaged deny matches everything: flagged too
        for argv in (("grant", "list", "--json"), ("grant", "list", "--all"), ("grant", "recount")):   # (and the
            rc, out = run(*argv, "-C", str(self.proj))                         # writers around it: never a traceback)
            self.assertEqual(rc, OK, (argv, out))
        self.assertEqual(json.loads((self.led.dir / "grants.json").read_text())["records"][:len(damaged)], damaged)
        self.assertEqual(G.scope_notes({"kind": "deny", "scope": {"partitions": 7, "targets": 5}}, G.harness_targets()),
                         [])
        self.assertEqual(G.scope_problems({"kind": "deny", "scope": {"targets": 5}}, G.harness_targets()), ([], False))


@unittest.skipUnless(sys.platform.startswith("linux"), "the nohup probe uses GNU stat and procps (the targets' Linux)")
class LedgeredNohup(Base):
    def test_rc_ends_a_ledger_run(self):
        self.target("fx-box", "T_KIND=nohup; T_HOST=fxbox\n")
        (self.proj / ".ws.conf").write_text(f"WS_REMOTE_DIR={self.remote}\n")
        logs = self.remote / "logs"
        logs.mkdir()
        log = "logs/exp--a01-20261103-120000.log"
        (self.remote / log).write_text("done\n")
        (self.remote / f"{log}.pid").write_text("999999999\n")
        (self.remote / f"{log}.rc").write_text("rc=2 term=1 at=1700000000\n")
        (self.remote / "logs/other--a01-20261103-110000.log").write_text("x\n")
        led = L.Ledger(self.proj)
        led.record_attempt(name="exp--a01", target="fx-box", kind="nohup", nonce="n1", submit="submitted",
                           proc={"pid": "999999999", "pgid": "999999999", "start": "1", "boot_id": "b", "log": log,
                                 "gpu_ids": "0"})
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        self.assertRegex(text, r"ENDED\s+exp--a01  rc 2 after TERM \(.rc\); ended \S+ ago")
        self.assertRegex(text, r"  exp\s+a01  ENDED rc=2\s+\[fx-box\] pid 999999999  logs/exp--a01-20261103-120000.log.rc "
                               r"term=1, \d+s ago")
        att = led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual((att["result"]["state"], att["result"]["rc"]), ("ENDED", "2"))

    def test_d5_a_run_of_another_boot_ended_with_a_reboot(self):
        self.target("fx-box", "T_KIND=nohup; T_HOST=fxbox\n")
        (self.proj / ".ws.conf").write_text(f"WS_REMOTE_DIR={self.remote}\n")
        (self.remote / "logs").mkdir()
        led = L.Ledger(self.proj)
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        for name, was in (("old", "another-boot"), ("same", boot)):
            log = f"logs/{name}--a01-20261103-120000.log"
            (self.remote / log).write_text("x\n")
            (self.remote / f"{log}.pid").write_text("999999999\n")              # gone, no .rc
            led.record_attempt(name=f"{name}--a01", target="fx-box", kind="nohup", nonce=f"n-{name}",
                               submit="submitted", proc={"pid": "999999999", "pgid": "999999999", "start": "1",
                                                         "boot_id": was, "log": log, "gpu_ids": "0"})
        rc, text = run("status", "-C", str(self.proj))
        self.assertEqual(rc, OK, text)
        old = led.read_run("old").data["attempts"]["a01"]
        self.assertEqual(old["result"]["state"], "REBOOT")
        self.assertIn("the box's boot_id is", old["result"]["evidence"])
        self.assertEqual(led.read_run("same").data["attempts"]["a01"]["result"]["state"], "ENDED")


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
