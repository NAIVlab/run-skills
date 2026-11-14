"""rsk cancel --wait S (I1: after an accepted scancel, the read rsk status makes, again until the job's end is seen or S
s pass — `ended: …` / `not ended yet: …` + exit 5, the accounting unchanged) and the hung-mount probe of the cancel
bodies (I8: a project dir whose filesystem gives no answer within FS_WAIT ends the call before @@start — nothing read,
nothing sent). A stub ssh runs the bodies locally; the stub squeue answers the cancel's
identity read and rsk status's read (told apart by their columns) from files the tests write."""

import contextlib
import io
import os
import shutil
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

from helpers import ScratchHome

from remote_run import cancel as C
from remote_run import cli, observe
from remote_run import ledger as L
from remote_run.errors import OK, UNKNOWN, USAGE

SSH = """#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
echo "$1" >> "$STUB/ssh.log"; shift
if [ -n "${SSH_THEN_255:-}" ]; then bash -c "$*"; exit 255; fi   # all the body printed arrived, then ssh's own 255
exec bash -c "$*"
"""
# the cancel's identity read: JobID|Name|UserName|WorkDir|State| ($STUB/queue); rsk status's read (its -O names Reason):
# JobID|Name|State|Reason|RestartCnt|StartTime|WorkDir| — $STUB/obs.live, from read END_AT on $STUB/obs.end
SQUEUE = """#!/usr/bin/env bash
echo "$*" >> "$STUB/squeue.log"
case " $* " in
  *" -j "*) exit 0 ;;
  *Reason*) [ -z "${OBS_FAIL:-}" ] || exit 1
    n=$(( $(cat "$STUB/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB/reads"
    if [ "$n" -ge "${END_AT:-999}" ]; then cat "$STUB/obs.end" 2>/dev/null; else cat "$STUB/obs.live" 2>/dev/null; fi
    exit 0 ;;
esac
cat "$STUB/queue" 2>/dev/null; exit 0
"""
SACCT = '#!/usr/bin/env bash\ncat "$STUB/sacct" 2>/dev/null; exit 0\n'
SCANCEL = ('#!/usr/bin/env bash\necho "$*" >> "$STUB/scancel.log"; [ -z "${SC_ERR:-}" ] || echo "$SC_ERR" >&2\n'
           'exit ${SC_RC:-0}\n')
ME = os.environ.get("USER") or subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()


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
        for name, text in (("ssh", SSH), ("squeue", SQUEUE), ("sacct", SACCT), ("scancel", SCANCEL)):
            self.tool(name, text)
        os.environ["STUB"] = str(self.stub)
        os.environ["PATH"] = f"{self.stub / 'bin'}{os.pathsep}{os.environ['PATH']}"
        os.environ["USER"] = ME
        for k in ("SSH_THEN_255", "OBS_FAIL", "END_AT", "SC_RC", "SC_ERR"):
            os.environ.pop(k, None)
        for name, prof in (("fx", "T_KIND=slurm; T_HOST=fxhost\n"), ("ws", "T_KIND=nohup; T_HOST=wshost\n")):
            d = Path(os.environ["RS_USER_DIR"]) / "targets" / name
            d.mkdir(parents=True)
            (d / "profile.sh").write_text(prof)
        self.remote = self.home / "remote" / "proj"
        self.remote.mkdir(parents=True)
        self.proj = self.home / "proj"
        self.proj.mkdir()
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={self.remote}\n")
        (self.proj / ".ws.conf").write_text(f"WS_REMOTE_DIR={self.remote}\n")
        self.led = L.Ledger(self.proj)
        self._every = mock.patch.object(C, "WAIT_EVERY", 0.2)
        self._every.start()

    def tearDown(self) -> None:
        self._every.stop()
        super().tearDown()

    def tool(self, name: str, text: str) -> None:
        p = self.stub / "bin" / name
        p.write_text(text)
        p.chmod(0o755)

    def hang_stat(self, d: Path) -> None:
        """A hung mount: every stat of D blocks (a sleep that keeps the probe's pipe open, as a D-state stat does) —
        tests/py/test_status.py's stub."""
        real = shutil.which("stat")
        self.tool("stat", f'#!/usr/bin/env bash\ncase " $* " in *" {d} "*) exec sleep 8 ;; esac\nexec {real} "$@"\n')

    def cancel(self, *argv: str) -> tuple[int, str]:
        return run("cancel", "-C", str(self.proj), *argv)

    def write(self, name: str, *rows: str) -> None:
        (self.stub / name).write_text("".join(r + "\n" for r in rows))

    def log(self, name: str) -> str:
        f = self.stub / name
        return f.read_text() if f.exists() else ""

    def launched(self, name: str, job: str, nonce: str = "n1", **kw) -> None:
        self.led.record_attempt(name=name, target=kw.pop("target", "fx"), kind=kw.pop("kind", "slurm"), nonce=nonce,
                                submit=kw.pop("submit", "submitted"), job=job, plan_id=kw.pop("plan_id", "p-1"),
                                action=kw.pop("action", "launch"), **kw)

    def sub(self, run: str = "exp", aid: str = "a01") -> dict:
        return self.led.read_run(run).data["attempts"][aid]["submissions"][0]


class SlurmWait(Base):
    def setUp(self) -> None:
        super().setUp()
        self.launched("exp--a01", "101")
        self.write("queue", f"101|exp--a01|{ME}|{self.remote}|RUNNING|")

    def test_wait_follows_the_read_until_the_end_is_seen(self):
        self.write("obs.live", f"101|exp--a01|COMPLETING|None|0|1700000000|{self.remote}|")
        self.write("obs.end", f"101|exp--a01|CANCELLED|None|0|1700000000|{self.remote}|")
        os.environ["END_AT"] = "3"                          # read 1 (at once) and 2 still completing, read 3 ended
        rc, text = self.cancel("exp", "--approve", "cancel the exp run", "--wait", "30")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.log("scancel.log"), "101\n")
        self.assertIn("cancelled: job 101 (exp a01) on fx — scancel accepted", text)
        self.assertIn("ended: job 101 (exp a01) on fx: CANCELLED (squeue)", text)
        self.assertNotIn("not ended yet", text)
        self.assertEqual(self.log("reads"), "3\n")          # stopped at the read that saw the end
        att = self.led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual((L.attempt_state(att), self.sub()["end"]["state"]), ("CANCELLED", "CANCELLED"))
        self.assertFalse(L.is_live(att))
        self.assertEqual(self.log("ssh.log"), "fxhost\n" * 4)   # the cancel + three reads

    def test_an_end_only_sacct_shows(self):
        self.write("sacct", f"101|exp--a01|CANCELLED by 1000|0:15|1700000600|{self.remote}")
        rc, text = self.cancel("exp", "--wait", "30")
        self.assertEqual(rc, OK, text)
        self.assertIn("ended: job 101 (exp a01) on fx: CANCELLED (sacct)", text)              # the cancel's use, kept: it was cancelled

    def test_wait_passing_first_is_exit_5_and_the_ledger_keeps_cancelling(self):
        t0 = time.monotonic()
        rc, text = self.cancel("exp", "--wait", "1")        # no read lists the job: absence is no end
        took = time.monotonic() - t0
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("not ended yet: job 101 (exp a01) on fx: CANCELLING — the cancel was accepted; rsk status shows "
                      "its end", text)
        self.assertNotIn("ended: job", text)
        self.assertGreaterEqual(int(self.log("reads")), 2)  # at once, then again before S passed
        self.assertGreaterEqual(took, 1.0)
        self.assertEqual(self.sub()["seen"]["state"], "CANCELLING")
        self.assertTrue(L.is_live(self.led.read_run("exp").data["attempts"]["a01"]))

    def test_the_state_a_read_saw_is_the_one_reported(self):
        self.write("obs.live", f"101|exp--a01|COMPLETING|None|0|1700000000|{self.remote}|")
        rc, text = self.cancel("exp", "--approve", "cancel exp", "--wait", "1")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("not ended yet: job 101 (exp a01) on fx: COMPLETING — the cancel was accepted", text)

    def test_a_read_that_fails_changes_nothing_and_is_said_once(self):
        os.environ["OBS_FAIL"] = "1"
        rc, text = self.cancel("exp", "--approve", "cancel exp", "--wait", "1")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertEqual(text.count("NOTE: fx could not be read now (squeue)"), 1, text)
        self.assertIn("not ended yet: job 101 (exp a01) on fx: CANCELLING", text)
        self.assertEqual(self.sub()["seen"]["state"], "CANCELLING")
        self.assertGreaterEqual(self.log("ssh.log").count("fxhost"), 3)   # the cancel + at least two reads

    def test_wait_0_is_todays_cancel(self):
        self.launched("w0--a01", "201", nonce="n2")
        self.write("queue", f"101|exp--a01|{ME}|{self.remote}|RUNNING|", f"201|w0--a01|{ME}|{self.remote}|RUNNING|")
        self.write("obs.end", f"101|exp--a01|CANCELLED|None|0|1700000000|{self.remote}|",
                   f"201|w0--a01|CANCELLED|None|0|1700000000|{self.remote}|")
        os.environ["END_AT"] = "1"                           # a read would see the end at once: none is made
        for run, argv in (("exp", ()), ("w0", ("--wait", "0"))):
            rc, text = self.cancel(run, "--approve", f"cancel {run}", *argv)
            self.assertEqual(rc, OK, (argv, text))
            self.assertIn("scancel accepted", text)
            self.assertNotIn("ended: job", text)
            self.assertNotIn("not ended yet", text)
            self.assertEqual(self.log("reads"), "", "no read after the cancel")
            self.assertEqual(self.led.read_run(run).data["attempts"]["a01"]["observed"]["state"], "CANCELLING")
        self.assertEqual(self.log("ssh.log"), "fxhost\n" * 2)

    def test_nothing_to_wait_for_when_scancel_was_not_accepted(self):
        os.environ["SC_RC"] = "1"                            # unknown outcome: CANCELLING?, exit 5 — no wait
        os.environ["SC_ERR"] = "scancel: error: Kill job error on job id 101: Socket timed out on send/recv operation"
        rc, text = self.cancel("exp", "--approve", "cancel exp", "--wait", "30")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertNotIn("not ended yet", text)
        os.environ["SC_ERR"] = "scancel: error: Kill job error on job id 101: Job/step already completing or completed"
        rc, text = self.cancel("exp", "--approve", "cancel exp again", "--wait", "30")   # moot: nothing to wait for
        self.assertEqual(rc, OK, text)
        self.assertIn("nothing to cancel", text)
        self.write("queue")                                  # gone from squeue: nothing to cancel, no wait
        self.launched("gone--a01", "102", nonce="n2")
        rc, text = self.cancel("gone", "--approve", "cancel gone", "--wait", "30")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.log("reads"), "", "no read: --wait follows only an accepted scancel")

    def test_a_job_the_ledger_does_not_know_is_followed_in_the_read(self):
        self.write("queue", f"555|stray|{ME}|{self.remote}|PENDING|")
        self.write("obs.end", f"555|stray|CANCELLED|None|0|0|{self.remote}|")
        os.environ["END_AT"] = "2"
        rc, text = self.cancel("--job", "555", "-T", "fx", "--approve", "cancel job 555", "--wait", "30")
        self.assertEqual(rc, OK, text)
        self.assertIn("ended: job 555 on fx: CANCELLED (squeue)", text)
        self.write("queue", f"556|stray2|{ME}|{self.remote}|PENDING|")
        rc, text = self.cancel("--job", "556", "-T", "fx", "--approve", "cancel job 556", "--wait", "1")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("not ended yet: job 556 on fx: CANCELLING — the cancel was accepted", text)

    def test_a_cancel_accepted_earlier_is_only_waited_for(self):
        """I4 points a relaunch blocked by CANCELLING at `rsk cancel RUN --wait S`: that must not send scancel again
        nor need the user's OK again — only the read."""
        rc, text = self.cancel("exp", "--approve")
        self.assertEqual(rc, OK, text)
        self.write("obs.end", f"101|exp--a01|CANCELLED|None|0|1700000000|{self.remote}|")
        os.environ["END_AT"] = "2"
        rc, text = self.cancel("exp", "--wait", "30")      # no --approve: nothing is asked for, nothing used
        self.assertEqual(rc, OK, text)
        self.assertIn("already cancelled: job 101 (exp a01) on fx — an earlier rsk cancel's scancel was accepted", text)
        self.assertIn("ended: job 101 (exp a01) on fx: CANCELLED (squeue)", text)
        self.assertNotIn("needs user", text)
        self.assertEqual(self.log("scancel.log"), "101\n", "scancel sent once")
        self.assertEqual(self.led.state().grants, [])

    def test_a_read_since_that_wrote_over_cancelling_still_counts(self):
        rc, text = self.cancel("exp")
        self.assertEqual(rc, OK, text)
        self.led.observe("exp", "a01", "101", "COMPLETING", "squeue")   # an rsk status read after the cancel
        rc, text = self.cancel("exp", "--wait", "1")       # from the cancel's audit line
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("already cancelled: job 101 (exp a01)", text)
        self.assertIn("not ended yet: job 101 (exp a01) on fx: COMPLETING — the cancel was accepted", text)
        self.assertEqual(self.log("scancel.log"), "101\n")
        rc, text = self.cancel("exp")                       # without --wait: sent again, as before (scancel: moot)
        self.assertEqual(self.log("scancel.log"), "101\n101\n", text)

    def test_usage(self):
        for bad in ("-1", str(C.WAIT_MAX_S + 1)):          # review: S is bounded, as --check-after is
            rc, text = self.cancel("exp", "--approve", "cancel exp", "--wait", bad)
            self.assertEqual(rc, USAGE, (bad, text))
        self.assertEqual(self.log("ssh.log"), "")
        self.assertEqual([r for r in self.led.state().grants if r["kind"] == "approval"], [])

    def test_a_requeued_job_is_cancelled_again_not_only_waited_for(self):
        """review #0: a read since the accepted cancel that shows the job live in a state but COMPLETING (a requeue)
        drops the marker — --wait sends scancel again, authorised as a new cancel, never 'already cancelled'."""
        rc, text = self.cancel("exp")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.sub()["cancel"]["state"], "CANCELLING")      # the marker rsk cancel leaves
        self.led.observe("exp", "a01", "101", "PENDING", "squeue")          # requeued: live again, not ending
        self.assertEqual(L.cancel_pending(self.led.read_run("exp").data["attempts"]["a01"]), ("", ""))
        rc, text = self.cancel("exp", "--wait", "1")
        self.assertNotIn("already cancelled", text)
        self.assertEqual(self.log("scancel.log"), "101\n101\n", text)

    def test_an_unconfirmed_cancel_is_sent_again_under_wait(self):
        """review #1/#6: after CANCELLING? (scancel's answer unclear) --wait does not skip the scancel."""
        os.environ["SC_RC"] = "1"
        os.environ["SC_ERR"] = "scancel: error: Socket timed out on send/recv operation"
        rc, text = self.cancel("exp")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertEqual(self.sub()["seen"]["state"], "CANCELLING?")
        os.environ.pop("SC_RC"); os.environ.pop("SC_ERR")
        rc, text = self.cancel("exp", "--wait", "1")
        self.assertNotIn("already cancelled", text)
        self.assertEqual(self.log("scancel.log"), "101\n101\n", text)

    def test_wait_still_runs_after_another_item_failed(self):
        """review #9: one item's non-zero code never skips the wait for the jobs that were accepted."""
        self.launched("exp--a02", "102", nonce="n2")      # a second attempt whose WorkDir is not this project's
        self.write("queue", f"101|exp--a01|{ME}|{self.remote}|RUNNING|", f"102|exp--a02|{ME}|/elsewhere|RUNNING|")
        self.write("obs.end", f"101|exp--a01|CANCELLED|None|0|1700000000|{self.remote}|")
        os.environ["END_AT"] = "1"
        rc, text = self.cancel("exp", "--approve", "cancel the exp run", "--wait", "5")
        self.assertNotEqual(rc, OK, text)                   # 102's identity mismatch keeps the worse code
        self.assertEqual(self.log("scancel.log"), "101\n", text)
        self.assertIn("ended: job 101 (exp a01) on fx: CANCELLED (squeue)", text)


class Hung(Base):
    """I8: the cancel's ssh body probes the project dir first (observe's rs_dir); a hung mount ends it before @@start."""

    def test_a_hung_read_ends_the_wait_at_once(self):
        """review #3: each hung read leaves a stuck stat on the login node — --wait stops at the first one."""
        self.launched("exp--a01", "101")
        self.write("queue", f"101|exp--a01|{ME}|{self.remote}|RUNNING|")
        rc, text = self.cancel("exp", "--approve", "cancel the exp run")
        self.assertEqual(rc, OK, text)
        self.hang_stat(self.remote)
        with mock.patch.object(observe, "FS_WAIT", 1):
            rc, text = self.cancel("exp", "--wait", "60")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("not reading it again now (a hung mount", text)
        self.assertIn("not ended yet: job 101 (exp a01) on fx", text)
        self.assertEqual(self.log("ssh.log").count("fxhost"), 2, "the cancel, then ONE read")

    def hung_cancel(self, *argv: str) -> tuple[int, str, float]:
        self.hang_stat(self.remote)
        t0 = time.monotonic()
        with mock.patch.object(observe, "FS_WAIT", 1):
            rc, text = self.cancel(*argv)
        return rc, text, time.monotonic() - t0

    def test_slurm_a_hung_dir_is_nothing_sent(self):
        self.launched("exp--a01", "101")
        self.write("queue", f"101|exp--a01|{ME}|{self.remote}|RUNNING|")
        rc, text, took = self.hung_cancel("exp", "--wait", "30")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn(f"[fx] {self.remote}: its filesystem gave no answer within 1 s (a hung mount?) — nothing was "
                      "sent, nothing was cancelled", text)
        self.assertLess(took, 6, "the session waited for the stuck probe, or the full ssh deadline")
        self.assertEqual((self.log("squeue.log"), self.log("scancel.log")), ("", ""), "nothing read, nothing sent")
        att = self.led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual(L.attempt_state(att), "SUBMITTED")  # no CANCELLING: nothing was sent
        audit = [a for a in self.led.read_audit()[0] if a.get("event") == "cancel"]
        self.assertEqual((audit[-1]["outcome"], audit[-1]["sent"]), ("unobservable", "no"))

    def test_slurm_an_approved_cancel_too(self):
        self.launched("exp--a01", "101")
        rc, text, _ = self.hung_cancel("exp", "--approve")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("nothing was sent", text)
        self.assertEqual(self.led.state().grants, [])

    def test_the_fail_proves_it_even_when_ssh_then_exits_255(self):
        """sent_maybe(): an @@fail is printed only on a path that returns before any identity or signal — so its
        arrival proves nothing was sent, also from an ssh that then ended with its own 255 (no remote status)."""
        self.launched("exp--a01", "101")
        os.environ["SSH_THEN_255"] = "1"
        rc, text, _ = self.hung_cancel("exp")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("nothing was sent", text)

    def test_a_readable_dir_goes_on_as_before(self):   # only `h` is decided before @@start
        self.launched("exp--a01", "101")
        self.write("queue", f"101|exp--a01|{ME}|{self.remote}|RUNNING|")
        rc, text = self.cancel("exp", "--approve", "cancel exp")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.log("scancel.log"), "101\n")
        gone = self.home / "unmounted" / "proj"           # no dir, no readable parent: cd's own @@fail after @@start
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={gone}\n")
        self.launched("exp2--a01", "102", nonce="n2")
        rc, text = self.cancel("exp2", "--approve", "cancel exp2")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn(f"cd {gone} — nothing was cancelled", text)


def pstart(pid: int) -> str:
    s = Path(f"/proc/{pid}/stat").read_text()
    return s[s.rfind(")") + 2:].split()[19]


@unittest.skipUnless(sys.platform.startswith("linux") and Path("/proc/self/stat").exists(), "nohup identity uses /proc")
class Nohup(Base):
    def setUp(self) -> None:
        super().setUp()
        self.procs: list[subprocess.Popen] = []
        self.boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()

    def tearDown(self) -> None:
        for p in self.procs:
            if p.poll() is None:
                with contextlib.suppress(OSError):
                    os.killpg(p.pid, 9)
                p.wait()
        super().tearDown()

    def spawn(self, nonce: str = "n1", name: str = "r") -> subprocess.Popen:
        p = subprocess.Popen(["bash", "-c", "sleep 30"], start_new_session=True)
        self.procs.append(p)
        time.sleep(0.2)
        log = f"logs/{name}-20261104-120000.log"
        a = self.remote / ".rs" / "attempts" / nonce
        a.mkdir(parents=True)
        (a / "receipt").write_text(f"pid={p.pid}\npgid={p.pid}\nstart={pstart(p.pid)}\nboot_id={self.boot}\n"
                                   f"log={log}\nname={name}\nnonce={nonce}\n")
        (a / "gate").symlink_to("go")
        self.led.record_attempt(name=name, target="ws", kind="nohup", nonce=nonce, submit="submitted", plan_id="p-1",
                                action="launch", proc={"pid": str(p.pid), "pgid": str(p.pid), "start": "", "boot_id": "",
                                                       "log": log, "gpu_ids": "0"})
        return p

    def test_wait_is_accepted_and_changes_nothing(self):
        p = self.spawn()
        t0 = time.monotonic()
        rc, text = self.cancel("r", "--approve", "stop r", "--grace", "5", "--wait", "30")
        self.assertEqual(rc, OK, text)
        self.assertLess(time.monotonic() - t0, 15)
        self.assertIn(f"cancelled: pid {p.pid} (r a01) on ws — TERM, its group is gone", text)
        self.assertNotIn("ended: ", text)
        self.assertNotIn("not ended yet", text)
        self.assertEqual(self.log("ssh.log"), "wshost\n", "one ssh: the cancel, no read after it")
        self.assertEqual(L.attempt_state(self.led.read_run("r").data["attempts"]["a01"]), "CANCELLED")

    def test_a_hung_dir_signals_nothing(self):
        p = self.spawn()
        self.hang_stat(self.remote)
        t0 = time.monotonic()
        with mock.patch.object(observe, "FS_WAIT", 1):
            rc, text = self.cancel("r", "--grace", "1")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertLess(time.monotonic() - t0, 6)
        self.assertIn(f"[ws] {self.remote}: its filesystem gave no answer within 1 s (a hung mount?) — nothing was sent",
                      text)
        time.sleep(0.2)
        self.assertIsNone(p.poll(), "never signalled")


if __name__ == "__main__":
    unittest.main()
