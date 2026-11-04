"""rsk adopt against the stub ssh of test_status (the remote script runs locally): the identity checks for --job and
--log, and every refusal of --not-submitted (receipt, comment, process, too recent, an unledgered twin, unreadable)."""

import os
import subprocess
import sys
import unittest
from pathlib import Path

from test_status import Base, run

from remote_run import grants as G
from remote_run import ledger as L
from remote_run.errors import CONFLICT, OK, UNKNOWN, USAGE

OLD = "2026-01-01T00:00:00Z"
SQUEUE = """#!/usr/bin/env bash
case "$*" in *Comment*) [ -z "${CM_FAIL:-}" ] || exit 1; cat "$STUB/comments.out" 2>/dev/null ;;
  *) cat "$STUB/squeue.out" ;; esac
"""


def age_out(path: Path) -> None:
    for p in [path, *path.rglob("*")]:
        os.utime(p, (1_700_000_000, 1_700_000_000), follow_symlinks=False)


class SlurmAdopt(Base):
    def setUp(self) -> None:
        super().setUp()
        self.target("fx-slurm", "T_KIND=slurm; T_HOST=fxhost\n")
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={self.remote}\n")
        here = str(self.remote)
        (self.stub / "squeue.out").write_text(f"101|exp--a01|RUNNING|None|0|1700000000|{here}|\n"
                                              f"999|exp--a01|RUNNING|None|0|1700000000|/elsewhere|\n")
        (self.stub / "sacct.out").write_text(f"90|old--a01|COMPLETED|0:0|1700000500|{here}\n")
        (self.stub / "comments.out").write_text("")
        self.tool("squeue", SQUEUE)
        self.tool("sacct", '#!/usr/bin/env bash\ncat "$STUB/sacct.out"\n')
        os.environ.pop("CM_FAIL", None)
        self.led = L.Ledger(self.proj)

    def adopt(self, *argv: str) -> tuple[int, str]:
        return run("adopt", "-C", str(self.proj), "-T", "fx-slurm", *argv)

    def test_job_is_adopted_after_its_identity_checks(self):
        a = self.remote / ".rs/attempts/nonce-101"
        a.mkdir(parents=True)
        (a / "receipt").write_text("job=101\nname=exp--a01\nnonce=nonce-101\n")
        rc, text = self.adopt("--job", "101", "--as", "exp")
        self.assertEqual(rc, OK, text)
        self.assertIn("adopted job 101 (exp--a01, RUNNING) as run exp a01 — nonce nonce-101", text)
        att = self.led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual((att["submissions"][0]["submit"], att["observed"]["state"]), ("adopted", "RUNNING"))
        self.assertEqual(att["request"]["action"], "adopted")
        self.assertIn("already", self.adopt("--job", "101", "--as", "exp")[1])
        self.assertEqual(len(self.led.read_run("exp").data["attempts"]), 1)
        self.assertIn("adopt", [e["event"] for e in self.led.read_audit()[0]])

    def test_identity_mismatches_adopt_nothing(self):
        rc, text = self.adopt("--job", "101", "--as", "other")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("named 'exp--a01'", text)
        rc, text = self.adopt("--job", "999", "--as", "exp")          # another dir (or another user's)
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("not among your jobs", text)
        self.assertEqual(self.led.runs(), {})
        for argv in (("--job", "101"), ("--job", "x1", "--as", "exp"), ("--job", "101", "--as", "exp", "--approve", "y"),
                     ("--log", "logs/x-20260101-000000.log", "--as", "x"), ()):
            self.assertEqual(self.adopt(*argv)[0], USAGE, argv)
        os.environ["SSH_FAIL"] = "1"
        self.assertEqual(self.adopt("--job", "101", "--as", "exp")[0], UNKNOWN)

    def _unknown(self, mtime_old: bool = True, grant: bool = False) -> str:
        gid = ""
        if grant:
            g = G.add(self.led, G.new_grant("go", {}, ["launch"], max_live=None, max_launches=1, expires=None))
            gid = g["id"]
            G.use(self.led, gid, "nz", "launch")
        self.led.record_attempt(name="lost--a01", target="fx-slurm", kind="slurm", nonce="nz", submit="unknown",
                                grant=gid, at=OLD)
        a = self.remote / ".rs/attempts/nz"
        a.mkdir(parents=True)
        (a / "stage").write_text("sbatch\n")
        (a / "result").write_text("stage=sbatch rc=1 verdict=unknown at=1700000000\n")
        if mtime_old:
            age_out(a)
        return gid

    def test_not_submitted_marks_it_and_gives_the_use_back(self):
        gid = self._unknown(grant=True)
        self.assertEqual(self.adopt("--not-submitted", "nz")[0], USAGE)        # the user's words are required
        rc, text = self.adopt("--not-submitted", "nz", "--approve", "that one never went out")
        self.assertEqual(rc, OK, text)
        self.assertIn("NOT_SUBMITTED", text)
        att = self.led.read_run("lost").data["attempts"]["a01"]
        self.assertEqual(L.attempt_state(att), "NOT_SUBMITTED")
        self.assertEqual(att["submissions"][0]["quote"], "that one never went out")
        g = next(r for r in self.led.state().grants if r["id"] == gid)
        self.assertEqual(g["used"], [])
        self.assertIn("recorded as not submitted already", self.adopt("--not-submitted", "nz", "--approve", "x")[1])

    def test_not_submitted_refuses_what_may_have_happened(self):
        self._unknown()
        (self.stub / "comments.out").write_text("555|policy note rs=nz|\n")
        rc, text = self.adopt("--not-submitted", "nz", "--approve", "never went out")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("job 555 carries rs=nz", text)
        (self.stub / "comments.out").write_text("")
        os.environ["CM_FAIL"] = "1"
        self.assertEqual(self.adopt("--not-submitted", "nz", "--approve", "never went out")[0], UNKNOWN)
        os.environ.pop("CM_FAIL")
        with open(self.stub / "squeue.out", "a") as f:
            f.write(f"777|lost--a01|PENDING|Priority|0|0|{self.remote}|\n")
        rc, text = self.adopt("--not-submitted", "nz", "--approve", "never went out")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("job 777", text)
        (self.stub / "squeue.out").write_text("")
        holder = subprocess.Popen(["sh", "-c", "sleep 30", "x", "--rs-attempt", "nz"])
        try:
            rc, text = self.adopt("--not-submitted", "nz", "--approve", "never went out")
        finally:
            holder.kill()
            holder.wait()
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("a process still names attempt nz", text)
        (self.remote / ".rs/attempts/nz/receipt").write_text("job=888\nname=lost--a01\n")
        rc, text = self.adopt("--not-submitted", "nz", "--approve", "never went out")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("receipt (job 888)", text)
        self.assertEqual(L.attempt_state(self.led.read_run("lost").data["attempts"]["a01"]), "SUBMIT_UNKNOWN")

    def test_not_submitted_waits_for_a_recent_attempt(self):
        self._unknown(mtime_old=False)
        rc, text = self.adopt("--not-submitted", "nz", "--approve", "never went out")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("may still be running", text)

    def test_not_submitted_of_an_unledgered_nonce_needs_a_run(self):
        a = self.remote / ".rs/attempts/stray"
        a.mkdir(parents=True)
        (a / "stage").write_text("policy\n")
        age_out(a)
        self.assertEqual(self.adopt("--not-submitted", "stray", "--approve", "drop it")[0], USAGE)
        rc, text = self.adopt("--not-submitted", "stray", "--approve", "drop it", "--as", "stray-run")
        self.assertEqual(rc, OK, text)
        self.assertEqual(L.attempt_state(self.led.read_run("stray-run").data["attempts"]["a01"]), "NOT_SUBMITTED")


@unittest.skipUnless(sys.platform.startswith("linux"), "nohup identity reads /proc (the targets' Linux)")
class NohupAdopt(Base):
    LOG = "logs/exp--a01-20261103-120000.log"

    def setUp(self) -> None:
        super().setUp()
        self.target("fx-box", "T_KIND=nohup; T_HOST=fxbox\n")
        (self.proj / ".ws.conf").write_text(f"WS_REMOTE_DIR={self.remote}\n")
        (self.remote / "logs").mkdir()
        self.proc = subprocess.Popen(["sleep", "60"], cwd=self.remote)
        self.addCleanup(lambda: (self.proc.kill(), self.proc.wait()))
        (self.remote / self.LOG).write_text("step 1\n")
        (self.remote / f"{self.LOG}.pid").write_text(f"{self.proc.pid}\n")
        self.led = L.Ledger(self.proj)

    def adopt(self, *argv: str) -> tuple[int, str]:
        return run("adopt", "-C", str(self.proj), "-T", "fx-box", *argv)

    def _receipt(self, start: str = "") -> None:
        s = Path(f"/proc/{self.proc.pid}/stat").read_text()
        f = s[s.rfind(")") + 2:].split()
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        a = self.remote / ".rs/attempts/n-box"
        a.mkdir(parents=True)
        (a / "receipt").write_text(f"pid={self.proc.pid}\npgid={f[2]}\nstart={start or f[19]}\nboot_id={boot}\n"
                                   f"gpus=GPU-x\nlog={self.LOG}\nname=exp--a01\nnonce=n-box\nat=1\ngpu_ids=0\n")
        (a / "gate").symlink_to("go")

    def test_by_receipt_triple(self):
        self._receipt()
        rc, text = self.adopt("--log", str(self.remote / self.LOG), "--as", "exp")
        self.assertEqual(rc, OK, text)
        self.assertIn("ALIVE — receipt triple", text)
        sub = self.led.read_run("exp").data["attempts"]["a01"]["submissions"][0]
        self.assertEqual((sub["nonce"], sub["proc"]["pid"], sub["proc"]["gpu_ids"]), ("n-box", str(self.proc.pid), "0"))
        self.assertIn("already", self.adopt("--log", self.LOG, "--as", "exp")[1])

    def test_a_receipt_whose_pid_was_reused_is_adopted_as_ended(self):
        self._receipt(start="1")
        rc, text = self.adopt("--log", self.LOG, "--as", "exp")
        self.assertEqual(rc, OK, text)
        self.assertIn("ENDED (the pid now belongs to another process", text)
        self.assertFalse(L.is_live(self.led.read_run("exp").data["attempts"]["a01"]))

    def test_without_a_receipt_by_proc(self):
        rc, text = self.adopt("--log", self.LOG, "--as", "exp")
        self.assertEqual(rc, OK, text)
        self.assertIn("ALIVE — /proc (owner, cwd, older than the .pid file)", text)

    def test_ended_with_rc_and_mismatches(self):
        (self.remote / f"{self.LOG}.rc").write_text("rc=3 term=0 at=1700000000\n")
        self.assertEqual(self.adopt("--log", self.LOG, "--as", "other")[0], CONFLICT)
        self.assertEqual(self.adopt("--log", "logs/../x-20261103-120000.log", "--as", "x")[0], USAGE)
        self.assertEqual(self.adopt("--log", "logs/gone-20261103-120000.log", "--as", "gone")[0], USAGE)
        rc, text = self.adopt("--log", self.LOG, "--as", "exp")
        self.assertEqual(rc, OK, text)
        self.assertIn("ENDED rc=3", text)
        att = self.led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual((att["result"]["state"], att["result"]["rc"]), ("ENDED", "3"))


if __name__ == "__main__":
    unittest.main()
