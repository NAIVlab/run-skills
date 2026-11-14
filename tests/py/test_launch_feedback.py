"""rsk launch / rsk cancel feedback (2026-11: three agent tabs on several clusters for two days). Agents wrapped rsk in
scripts that grepped its output and lost every refusal: one verdict line, always stdout's last. A word-splitting slip
gave run names a space that rsk accepted: exit 2 before anything is planned. An immediate relaunch after rsk cancel met
the duplicate guard with a --same-name-ok hint while the cancel was not confirmed: the refusal now says so. A hung
project mount held the plan ssh to its 180 s deadline: the call asks the dir's filesystem first (observe's rs_dir) and
ends within FS_WAIT, nothing run. The fake remote (launch.call replaced) is test_launch's Fixture; the hung mount runs
the real bodies through a stub ssh, with stat stubbed to hang (as test_status does)."""

import contextlib
import io
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from unittest import mock

from helpers import ScratchHome
from test_launch import Fixture

from remote_run import cli, observe
from remote_run import grants as G
from remote_run import launch as X
from remote_run.errors import CONFLICT, EXIT_CODES, NEEDS_USER, OK, REFUSED, UNKNOWN, USAGE, RskError

RUN = "exp--train--a--scratch--s0"


def run3(*argv: str) -> tuple[int, str, str]:
    """(exit, stdout, stderr) of cli.main, kept apart: the verdict line is stdout's."""
    o, e = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
        rc = cli.main(list(argv))
    return rc, o.getvalue(), e.getvalue()


def last(text: str) -> str:
    lines = text.rstrip("\n").splitlines()
    return lines[-1] if lines else ""


class Verdict(Fixture):
    def cli3(self, *argv: str) -> tuple[int, str, str]:
        return run3(argv[0], "-C", str(self.proj), *argv[1:])

    def test_needs_user_success_refusal_conflict_each_end_with_the_line(self):
        self.answers = [self.plan_reply()]
        rc, o, e = self.cli3("launch", "-T", "fx", "-n", f"{RUN}--a01", "--", "python", "t.py")
        self.assertEqual((rc, last(o)), (NEEDS_USER, "rsk launch: exit 4 (needs the user's decision)"), o + e)
        self.assertEqual(o.count("rsk launch: exit"), 1)
        self.answers = [self.submitted()]
        rc, o, e = self.cli3("launch", "--plan", self.plan_id(o), "--approve", "go")
        self.assertEqual((rc, last(o)), (OK, "rsk launch: exit 0 (ok)"), o + e)
        self.assertIn(f"submitted: {RUN} a01 job 101", o)
        rc, o, e = self.cli3("launch", "-T", "fx", "-n", f"{RUN}--a02", "--", "python", "t.py")   # a01 is live
        self.assertEqual(rc, CONFLICT, o + e)
        self.assertTrue(last(o).startswith(f"rsk launch: exit 6 (conflict with existing state) — run {RUN} is live "
                                           "on fx in the ledger"), last(o))
        self.assertIn(f"rsk: run {RUN} is live on fx", e)                  # the error still goes to stderr as before
        G.add(self.led, G.new_deny({"targets": ["fx"]}, ["launch", "relaunch"]))
        self.answers = [self.plan_reply(name="exp--train--b--scratch--s0--a01")]
        rc, o, e = self.cli3("launch", "-T", "fx", "-n", "exp--train--b--scratch--s0--a01", "--", "python", "t.py")
        self.assertEqual(rc, REFUSED, o + e)
        self.assertRegex(last(o), r"^rsk launch: exit 3 \(refused: a site policy or a deny \(final\)\) — denied by d-")

    def test_the_line_comes_after_stderrs_in_a_merged_capture(self):
        rc, text = self.cli("launch", "-T", "fx", "-n", "x y")             # run(): stdout and stderr in one buffer
        self.assertEqual(rc, USAGE)
        self.assertTrue(last(text).startswith("rsk launch: exit 2 (usage, config or setup problem) — rsk launch: -n:"))
        self.assertLess(text.index("rsk: rsk launch: -n:"), text.index("rsk launch: exit 2"))

    def test_the_message_is_its_first_line_cut_to_240(self):
        long = "x" * 500 + "\nsecond line"
        with mock.patch.object(X, "cmd_launch", side_effect=RskError(long, CONFLICT)):
            rc, o, e = run3("launch", "-T", "fx")
        self.assertEqual(rc, CONFLICT)
        self.assertEqual(last(o), "rsk launch: exit 6 (conflict with existing state) — " + "x" * 240)
        self.assertIn("second line", e)                                     # stderr keeps the whole message
        self.assertEqual(cli.verdict_line("cancel", 9), "rsk cancel: exit 9 (not a listed code)")
        for code, meaning in EXIT_CODES.items():
            self.assertEqual(cli.verdict_line("launch", code), f"rsk launch: exit {code} ({meaning})")

    def test_a_timeout_is_exit_5_with_the_line(self):
        with mock.patch.object(X, "cmd_launch", side_effect=subprocess.TimeoutExpired(["ssh", "h", "bash -s"], 9)):
            rc, o, e = run3("launch", "-T", "fx")
        self.assertEqual((rc, last(o)), (UNKNOWN, "rsk launch: exit 5 (unknown or unreachable) — timed out: ssh h "
                                                  "bash -s"))
        self.assertIn("rsk: timed out: ssh h bash -s", e)

    def test_no_line_after_help_a_broken_pipe_or_an_interrupt(self):
        rc, o, _e = run3("launch", "-h")
        self.assertEqual(rc, OK)
        self.assertNotIn("rsk launch: exit", o)
        with mock.patch.object(X, "cmd_launch", side_effect=KeyboardInterrupt()):
            self.assertEqual(run3("launch", "-T", "fx")[:2], (130, ""))
        child = ("import os, sys; sys.path[:0] = sys.argv[1:2]; from remote_run import cli\n"   # `rsk launch … | head`
                 "r, w = os.pipe(); os.close(r); os.dup2(w, 1)\n"
                 "sys.exit(cli.main(['launch', '-C', sys.argv[2], '-T', 'fx', '-n', 'a b']))")
        done = subprocess.run([sys.executable, "-I", "-c", child, str(Path(cli.__file__).parent.parent),
                               str(self.proj)], capture_output=True, text=True, env=os.environ)
        self.assertEqual(done.returncode, 141, done.stderr)               # the line met a closed pipe: no traceback
        self.assertNotIn("Traceback", done.stderr)
        self.assertIn("rsk: rsk launch: -n:", done.stderr)

    def test_rsk_cancel_ends_with_its_line_and_other_commands_do_not(self):
        self.led.record_attempt(name=f"{RUN}--a01", target="fx", kind="slurm", nonce="n-1", submit="submitted", job="7")
        self.led.observe(RUN, "a01", "7", "COMPLETED", "sacct", end={"state": "COMPLETED", "rc": "0:0"})
        rc, o, _e = self.cli3("cancel", RUN)
        self.assertEqual((rc, last(o)), (OK, "rsk cancel: exit 0 (ok)"), o)
        self.assertIn("has nothing live in the ledger", o)
        rc, o, _e = self.cli3("cancel", "nothing--here")
        self.assertEqual((rc, last(o)), (USAGE, "rsk cancel: exit 2 (usage, config or setup problem) — no ledger run "
                                                "'nothing--here' (rsk status lists them; a job the ledger does not "
                                                "know: --job J -T T)"), o)
        rc, o, e = self.cli3("cancel")
        self.assertEqual((rc, last(o)), (USAGE, "rsk cancel: exit 2 (usage, config or setup problem) — rsk cancel RUN "
                                                "| --job J -T T"), o + e)
        rc, o, _e = run3("grant", "list", "-C", str(self.proj))
        self.assertEqual(rc, OK)
        self.assertNotIn(": exit 0 (ok)", o)


class Names(Fixture):
    def test_whitespace_or_a_control_character_is_exit_2_before_any_ssh(self):
        seen = mock.Mock(return_value=[])
        with mock.patch.object(observe, "observe", seen), mock.patch.object(observe, "run") as ssh:
            for argv in (["-T", "fx", "-n", f"{RUN} ref--a01"], ["-T", "fx", "-n", f"{RUN}\t--a01"],
                         ["-T", "ws", "-N", "box--train--r--scratch--s0 x"], ["-T", "fx", "-n", "a\x07b"],
                         ["-T", "fx", "-n", f"{RUN}\u00a0x"], ["--relaunch", f"{RUN} x"]):
                rc, text = self.cli("launch", *argv, "--", "python", "t.py")
                self.assertEqual(rc, USAGE, text)
                bad = argv[-1]
                self.assertIn(f"a run name never holds whitespace or a control character: {bad!r} (a word-splitting "
                              "slip? quote the name / pass flags as an array)", text)
        self.assertEqual(self.calls, [])                                    # no plan, no submit
        seen.assert_not_called()                                            # not even the refresh read
        ssh.assert_not_called()
        self.assertEqual(self.led.plans(), [])

    def test_a_name_the_plan_resolves_is_checked_too(self):
        self.answers = [self.plan_reply(name="my\\ proj")]                 # no -n: the conf / dir name, %q-printed
        rc, text = self.cli("launch", "-T", "fx", "--", "python", "t.py")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("the plan names the run 'my proj' (the conf's JOB_NAME, else the remote dir's name): a run name "
                      "never holds whitespace", text)
        self.assertEqual(self.led.plans(), [])

    def test_a_stored_plan_with_such_a_name_is_never_submitted(self):   # planned by an rsk that let it through
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "-n", f"{RUN}--a01", "--", "python", "t.py")
        rec = dict(self.led.read_plan(self.plan_id(text)).data, name=f"{RUN} x--a01")
        self.assertEqual(X.plan_state(self.led, rec), f"plan {rec['id']} names the run '{RUN} x--a01': a run name "
                                                      "never holds whitespace or a control character")

    def test_other_characters_are_no_refusal(self):
        self.answers = [self.plan_reply(name="exp--train--\u00e4--scratch--s0")]   # outside §2: a NOTE, launched as named
        rc, text = self.cli("launch", "-T", "fx", "-n", "exp--train--\u00e4--scratch--s0", "--", "python", "t.py")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertNotIn("never holds", text)
        self.assertFalse(X.unsafe_name("a-b_c.d--a01"))
        self.assertTrue(all(X.unsafe_name(f"a{c}b") for c in " \t\n\r\x0b\x0c\x00\x1b\x7f\x85\u2003"))


class Cancelling(Fixture):
    def cancelled(self, state: str = "CANCELLING", aid: str = "a01", job: str = "101", run: str = RUN) -> None:
        self.led.record_attempt(name=f"{run}--{aid}", target="fx", kind="slurm", nonce=f"n-{run}-{aid}",
                                submit="submitted", job=job)
        self.led.observe(run, aid, job, state, "rsk cancel (scancel rc=0)")

    def test_a_cancel_not_confirmed_points_at_the_wait_never_at_same_name_ok(self):
        for i, state in enumerate(("CANCELLING", "CANCELLING?")):
            with self.subTest(state=state):
                run = f"exp--train--c{i}--scratch--s0"
                self.cancelled(state, run=run)
                rc, text = self.cli("launch", "-T", "fx", "-n", f"{run}--a02", "--", "python", "t.py")
                self.assertEqual(rc, CONFLICT, text)
                self.assertIn(f"run {run} is live on fx in the ledger: a01 ({state}) — the cancel of {run} a01 (job 101 "
                              "on fx) is not confirmed", text)
                self.assertIn("fx is not readable now", text)
                if state == "CANCELLING":   # accepted: --wait only waits
                    self.assertIn(f"scancel accepted it; fx is not readable now — rsk cancel {run} --wait S waits for "
                                  "its end (nothing is sent again), or rsk status shows it", text)
                else:                       # unclear: never promise that nothing is sent again (review #1/#6)
                    self.assertIn(f"rsk status shows whether it ends; rsk cancel {run} would send it again (a new "
                                  "cancel, authorised as one)", text)
                    self.assertNotIn("nothing is sent again", text)
                self.assertNotIn("--same-name-ok", text)
                self.assertEqual(self.calls, [])                            # refused before the plan

    def test_read_but_not_ended_and_a_mix_with_a_running_attempt(self):
        self.cancelled("CANCELLING")
        with self.assertRaises(RskError) as c:
            X.duplicate(self.led, "fx", f"{RUN}--a03", False, 0, set())    # the target was read: no end in it yet
        self.assertIn("no read of fx has shown its end since", str(c.exception))
        self.assertNotIn("--same-name-ok", str(c.exception))
        self.cancelled("RUNNING", aid="a02", job="102")
        with self.assertRaises(RskError) as c:
            X.duplicate(self.led, "fx", f"{RUN}--a03", False, 0, {"fx"})
        msg = str(c.exception)
        self.assertEqual(c.exception.code, CONFLICT)
        self.assertIn("a01 (CANCELLING), a02 (RUNNING) — follow it (rsk status), or --same-name-ok when both are "
                      "wanted", msg)                                        # a02 runs: both may be wanted
        self.assertIn(f"; the cancel of {RUN} a01 (job 101 on fx) is not confirmed yet: sent", msg)
        self.assertIn("fx is not readable now", msg)

    def test_a_completing_read_keeps_the_cancel_said_as_that(self):
        """review #5: a read in the job's COMPLETING phase writes over CANCELLING; the marker rsk cancel left keeps the
        refusal saying the cancel's end is unseen (never --same-name-ok); a read showing it live otherwise drops it."""
        self.cancelled("CANCELLING")
        self.led.observe(RUN, "a01", "101", "COMPLETING", "squeue")
        with self.assertRaises(RskError) as c:
            X.duplicate(self.led, "fx", f"{RUN}--a02", False, 0, set())
        self.assertIn("a01 (COMPLETING) — the cancel of", str(c.exception))
        self.assertNotIn("--same-name-ok", str(c.exception))
        self.led.observe(RUN, "a01", "101", "RUNNING", "squeue", at="2099-01-01T00:00:00Z")   # requeued since: live
        with self.assertRaises(RskError) as c:
            X.duplicate(self.led, "fx", f"{RUN}--a02", False, 0, set())
        self.assertIn("--same-name-ok when both are wanted", str(c.exception))
        self.assertNotIn("the cancel of", str(c.exception))

    def test_another_target_is_a_note_never_a_refusal(self):
        """review #7: the run live (or its cancel unseen) on another target: launching elsewhere prints a NOTE (a
        second copy beside it), nothing refused — moving off a target that cannot be read is the user's call."""
        self.cancelled("CANCELLING")
        X.duplicate(self.led, "other", f"{RUN}--a02", False, 0, {"fx"})     # not refused on another target
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            X.elsewhere(self.led, "other", f"{RUN}--a02", {"fx"})
        self.assertIn(f"NOTE: the cancel of {RUN} a01 (job 101 on fx) is not confirmed yet", buf.getvalue())
        self.assertIn("fx is not readable now", buf.getvalue())
        self.assertIn("a launch on other starts a second copy beside it", buf.getvalue())
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            X.elsewhere(self.led, "fx", f"{RUN}--a02", set())               # the same target: duplicate() speaks
        self.assertEqual(buf.getvalue(), "")


class StoppedSubmit(Fixture):
    def test_a_submit_the_probe_stopped_is_not_submitted_and_the_plan_free_again(self):
        self.answers = [self.plan_reply()]
        rc, text = self.cli("launch", "-T", "fx", "-n", f"{RUN}--a01", "--", "python", "t.py")
        pid = self.plan_id(text)
        why = "/r/proj: its filesystem gave no answer within 15 s (a hung mount?)"
        self.answers = [X.Reply(69, f"@@fail {why}\n", fail=why)]
        rc, text = self.cli("launch", "--plan", pid, "--approve", "go")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn(f"not submitted: {RUN} a01 — {why} — the call stopped before anything ran: nothing was sent to "
                      "fx", text)
        self.assertIn(f"plan {pid} is free again", text)
        att = self.led.read_run(RUN).data["attempts"]["a01"]
        self.assertEqual(att["submissions"][0]["submit"], "not_submitted")
        self.answers = [self.submitted()]
        self.assertEqual(self.cli("launch", "--plan", pid)[0], OK)        # retried under the same approval

    def test_the_marker_counts_only_before_anything_ran(self):
        r = X.parse_slurm(subprocess.CompletedProcess([], 69, "@@fail /d: its filesystem gave no answer\n", ""))
        self.assertEqual((r.fail, r.api), ("/d: its filesystem gave no answer", None))
        r = X.parse_slurm(subprocess.CompletedProcess([], 1, "@@api api=3\n@@fail printed by submit.sh\n@@rc 1\n", ""))
        self.assertEqual(r.fail, "")
        self.assertIn(observe._DIRPROBE, X.SLURM_BODY)
        self.assertLess(X.SLURM_BODY.index('rs_dir "$RDIR"'), X.SLURM_BODY.index("grep"))


SSH = """#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
echo "$1" >> "$STUB/ssh.log"; shift
exec bash -c "$*"
"""


class Hung(ScratchHome):
    """The real plan bodies through a stub ssh that runs them here; stat of the remote dir hangs (a hung mount)."""

    def setUp(self) -> None:
        super().setUp()
        self.stub = self.home / "stub"
        (self.stub / "bin").mkdir(parents=True)
        self.tool("ssh", SSH)
        os.environ["STUB"] = str(self.stub)
        os.environ["PATH"] = f"{self.stub / 'bin'}{os.pathsep}{os.environ['PATH']}"
        self.remote = self.home / "remote" / "proj"
        (self.remote / ".fx").mkdir(parents=True)
        self.ran = self.home / "submit.ran"                                 # the deployed submit.sh, never reached
        (self.remote / ".fx" / "submit.sh").write_text(f"# rs-api=3\ntouch {self.ran}\nexit 2\n")
        for name, prof in (("fx", "T_KIND=slurm; T_HOST=fxhost\n"), ("ws", "T_KIND=nohup; T_HOST=wshost\n")):
            d = Path(os.environ["RS_USER_DIR"]) / "targets" / name
            d.mkdir(parents=True)
            (d / "profile.sh").write_text(prof)
        self.proj = self.home / "proj"
        self.proj.mkdir()
        (self.proj / ".hpc.conf").write_text(f"REMOTE_DIR={self.remote}\n")
        (self.proj / ".ws.conf").write_text(f"WS_REMOTE_DIR={self.remote}\n")

    def tool(self, name: str, text: str) -> None:
        p = self.stub / "bin" / name
        p.write_text(text)
        p.chmod(0o755)

    def hang(self) -> None:
        real = shutil.which("stat")
        self.tool("stat", f'#!/usr/bin/env bash\ncase " $* " in *" {self.remote} "*) exec sleep 8 ;; esac\n'
                          f'exec {real} "$@"\n')

    def launch(self, *argv: str) -> tuple[int, str, str, float]:
        t0 = time.monotonic()
        with mock.patch.object(observe, "FS_WAIT", 1):
            rc, o, e = run3("launch", "-C", str(self.proj), *argv)
        return rc, o, e, time.monotonic() - t0

    def test_a_hung_mount_ends_the_slurm_plan_within_fs_wait_nothing_run(self):
        self.hang()
        rc, o, e, took = self.launch("-T", "fx", "-n", f"{RUN}--a01", "--", "python", "t.py")
        self.assertEqual(rc, UNKNOWN, o + e)
        want = f"[fx] {self.remote}: its filesystem gave no answer within 1 s (a hung mount?) — nothing was planned"
        self.assertIn(want, e)
        self.assertEqual(last(o), f"rsk launch: exit 5 (unknown or unreachable) — {want} (rsk status reads the "
                                  "target again)")
        self.assertLess(took, 6, "the session waited for the stuck probe")
        self.assertFalse(self.ran.exists(), "submit.sh ran behind a hung mount")
        self.assertNotIn("needs: sync", o)

    def test_a_hung_mount_ends_a_box_plan_before_run_launch(self):
        self.hang()
        with mock.patch.object(X, "call_nohup") as rl:
            rc, o, e, took = self.launch("-T", "ws", "-N", "box--train--r--scratch--s0", "--", "python", "t.py")
        self.assertEqual(rc, UNKNOWN, o + e)
        self.assertIn(f"[ws] {self.remote}: its filesystem gave no answer within 1 s (a hung mount?) — nothing was "
                      "planned", e)
        rl.assert_not_called()
        self.assertLess(took, 6)

    def test_a_dir_that_answers_goes_on(self):
        with mock.patch.object(X, "call_nohup", return_value=X.Reply(2, err="ERROR: usage")) as rl:
            rc, o, e, _t = self.launch("-T", "ws", "-N", "box--train--r--scratch--s0", "--", "python", "t.py")
        self.assertEqual(rc, USAGE, o + e)
        rl.assert_called_once()                                             # after the probe: run-launch's own reply
        rc, o, e, _t = self.launch("-T", "fx", "-n", f"{RUN}--a01", "--", "python", "t.py")
        self.assertTrue(self.ran.exists(), o + e)                           # the dir answered: submit.sh ran (exit 2)
        self.assertEqual(rc, USAGE, o + e)
