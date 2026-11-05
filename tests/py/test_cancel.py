"""rsk cancel: who may stop what (the user's words → a cancel approval naming the job; the agent's own judgment → a
cancel_own grant over its own runs only; a deny wins), and the identity check in the same ssh as the action — Slurm
(name, user, WorkDir logical or physical, via a stub squeue) and nohup (receipt pid + /proc start + boot_id, owner,
process group; real processes here: TERM, the grace, KILL). Uses are given back when nothing was cancelled."""

import contextlib
import io
import os
import subprocess
import sys
import time
import unittest
from pathlib import Path

from helpers import ScratchHome

from remote_run import cancel as C
from remote_run import cli
from remote_run import grants as G
from remote_run import ledger as L
from remote_run.errors import CONFLICT, FAILED, NEEDS_USER, OK, REFUSED, UNKNOWN, USAGE

SSH = """#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
echo "$1" >> "$STUB/ssh.log"; shift
[ -z "${SSH_FAIL:-}" ] || { echo "${SSH_FAIL_MSG:-ssh: connect to host fxhost port 22: Connection timed out}" >&2; exit 255; }
if [ -n "${SSH_FALLBACK:-}" ]; then  # a ProxyCommand's first route refused, the second connected: the body ran there,
  echo "$SSH_FALLBACK" >&2; bash -c "$*" > /dev/null 2>&1; exit 255; fi   # then the link died before anything came back
if [ -n "${SSH_HANG:-}" ]; then  # the body arrives and runs there, but nothing comes back before the deadline
  cat > "$STUB/hang.body"; ( bash "$STUB/hang.body" > "$STUB/hang.out" 2>&1 & ); sleep "$SSH_HANG"; exit 0; fi
if [ -n "${SSH_CUT:-}" ]; then   # the connection dies once the remote printed a line matching SSH_CUT (it ran to the end)
  bash -c "$*" > "$STUB/full.out" 2>&1; sed "/$SSH_CUT/,\\$d" "$STUB/full.out"; exit 255; fi
exec bash -c "$*"
"""
SQUEUE = """#!/usr/bin/env bash
case " $* " in
  *" -j "*) j=""; while [ $# -gt 0 ]; do [ "$1" = -j ] && j=$2; shift; done; grep "^$j|" "$STUB/others" 2>/dev/null; exit 0 ;;
esac
[ -z "${SQ_FAIL:-}" ] || exit 1
cat "$STUB/queue" 2>/dev/null; exit 0
"""
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
        for name, text in (("ssh", SSH), ("squeue", SQUEUE),
                           ("scancel", '#!/usr/bin/env bash\n[ -z "${SC_SLEEP:-}" ] || sleep "$SC_SLEEP"\n'
                                       'echo "$*" >> "$STUB/scancel.log"; [ -z "${SC_ERR:-}" ] || echo "$SC_ERR" >&2\n'
                                       'exit ${SC_RC:-0}\n')):
            (self.stub / "bin" / name).write_text(text)
            (self.stub / "bin" / name).chmod(0o755)
        os.environ["STUB"] = str(self.stub)
        os.environ["PATH"] = f"{self.stub / 'bin'}{os.pathsep}{os.environ['PATH']}"
        os.environ["USER"] = ME
        for k in ("SSH_FAIL", "SSH_FAIL_MSG", "SQ_FAIL", "SC_RC", "SC_ERR", "SSH_CUT", "SC_SLEEP", "SSH_HANG",
                  "SSH_FALLBACK"):
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

    def cancel(self, *argv: str) -> tuple[int, str]:
        return run("cancel", "-C", str(self.proj), *argv)

    def queue(self, *rows: str) -> None:
        (self.stub / "queue").write_text("".join(r + "\n" for r in rows))

    def scancelled(self) -> str:
        f = self.stub / "scancel.log"
        return f.read_text() if f.exists() else ""

    def launched(self, name: str, job: str, nonce: str = "n1", **kw) -> None:
        self.led.record_attempt(name=name, target=kw.pop("target", "fx"), kind=kw.pop("kind", "slurm"), nonce=nonce,
                                submit=kw.pop("submit", "submitted"), job=job, plan_id=kw.pop("plan_id", "p-1"),
                                action=kw.pop("action", "launch"), **kw)

    def approvals(self) -> list[dict]:
        return [r for r in self.led.state().grants if r["kind"] == "approval"]


class Slurm(Base):
    def test_the_users_words_record_an_approval_then_the_identity_is_checked(self):
        self.launched("exp--a01", "101")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|")
        rc, text = self.cancel("exp", "--approve", "cancel the exp run")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.scancelled(), "101\n")
        ap = self.approvals()[0]
        self.assertEqual((ap["actions"], ap["scope"]["jobs"], ap["quote"], len(ap["used"])),
                         (["cancel"], ["101"], "cancel the exp run", 1))
        att = self.led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual(att["observed"]["state"], "CANCELLING")
        self.assertTrue(any(a.get("event") == "cancel" and a.get("outcome") == "cancelled" for a in self.led.read_audit()[0]))

    def test_without_words_or_cancel_own_it_is_the_users_call(self):
        self.launched("exp--a01", "101")
        rc, text = self.cancel("exp")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("needs user: approval — cancel job 101 on fx", text)
        self.assertFalse((self.stub / "ssh.log").exists())

    def test_cancel_own_covers_only_the_agents_own_runs(self):
        G.add(self.led, G.new_grant("stop your own runs when they go nowhere", {"targets": ["fx"]}, ["cancel_own"],
                                    max_live=None, max_launches=None, expires=None))
        self.launched("exp--a01", "101")
        self.launched("adopted--a01", "102", nonce="n2", submit="adopted", action="adopted", plan_id="")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|", f"102|adopted--a01|{ME}|{self.remote}|RUNNING|")
        self.assertEqual(self.cancel("exp")[0], OK)
        rc, text = self.cancel("adopted")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertEqual(self.scancelled(), "101\n")

    def test_a_job_the_identity_check_rejects_is_never_cancelled(self):
        self.launched("exp--a01", "101")
        for row, code, why in ((f"101|other--a01|{ME}|{self.remote}|RUNNING|", CONFLICT, "name=other--a01"),
                               (f"101|exp--a01|{ME}|/elsewhere/proj|RUNNING|", CONFLICT, "workdir=/elsewhere/proj"),
                               (f"101|exp--a01|someone|{self.remote}|RUNNING|", REFUSED, "belongs to someone")):
            self.queue(row)
            rc, text = self.cancel("exp", "--approve", "cancel exp")
            self.assertEqual(rc, code, text)
            self.assertIn(why, text)
        self.assertEqual(self.scancelled(), "")
        self.assertTrue(all(len(ap["used"]) == 1 for ap in self.approvals()), "each approval used up, never given back")

    def test_another_users_job_and_a_gone_job(self):
        self.queue()
        (self.stub / "others").write_text("555|someone|\n")
        rc, text = self.cancel("--job", "555", "-T", "fx", "--approve", "cancel job 555")
        self.assertEqual(rc, REFUSED, text)
        self.assertIn("belongs to someone", text)
        rc, text = self.cancel("--job", "556", "-T", "fx", "--approve", "cancel job 556")
        self.assertEqual(rc, CONFLICT, text)          # not in the ledger, not in the queue: a wrong id?
        self.assertIn("a wrong id?", text)
        self.launched("exp--a01", "101")
        rc, text = self.cancel("exp", "--approve", "cancel exp")
        self.assertEqual(rc, OK, text)                # ledgered and gone: it ended, nothing to do
        self.assertIn("nothing to cancel", text)
        self.assertEqual(self.scancelled(), "")

    def test_a_symlinked_workdir_and_a_bar_in_the_name(self):
        link = self.home / "link"
        link.symlink_to(self.remote)
        self.launched("a|b--a01", "101")
        self.queue(f"101|a|b--a01|{ME}|{link}|PENDING|")
        rc, text = self.cancel("a|b", "--approve", "cancel a|b")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.scancelled(), "101\n")

    def test_scancel_failing_or_no_answer_gives_back_a_grants_use_never_an_approvals(self):
        self.launched("exp--a01", "101")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|")
        os.environ["SC_RC"] = "1"
        rc, text = self.cancel("exp", "--approve", "cancel exp")
        self.assertEqual(rc, UNKNOWN, text)           # R5-5: a non-zero scancel proves nothing (it was FAILED before)
        os.environ.pop("SC_RC")
        os.environ["SQ_FAIL"] = "1"                   # squeue fails there: @@fail before any identity, ssh ends
        rc, text = self.cancel("exp", "--approve", "cancel exp")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("nothing was cancelled", text)
        self.assertTrue(all(len(ap["used"]) == 1 for ap in self.approvals()))   # D6: used up whatever the outcome
        g = G.add(self.led, G.new_grant("stop your own runs", {"targets": ["fx"]}, ["cancel_own"], max_live=None,
                                        max_launches=3, expires=None))
        rc, text = self.cancel("exp")                                         # covered by cancel_own: refunded
        self.assertEqual(rc, UNKNOWN, text)
        self.assertEqual(next(r for r in self.led.state().grants if r["id"] == g["id"])["used"], [])
        self.assertEqual(self.scancelled(), "101\n")                          # (the SC_RC=1 call above only)

    def test_ssh_255_before_any_answer_is_no_proof_the_cancel_was_not_sent(self):
        """not_fixed (round 4): ssh's own exit 255 with no @@start counted as proof that nothing was signalled — a
        refunded cancel_own use and 'nothing was cancelled'. The connection may die after the body ran there (here:
        cut before @@start arrived, scancel sent): exit 5, 'may have been sent', the use kept."""
        g = G.add(self.led, G.new_grant("stop your own runs", {"targets": ["fx"]}, ["cancel_own"], max_live=None,
                                        max_launches=3, expires=None))
        self.launched("exp--a01", "101")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|")
        os.environ["SSH_CUT"] = "^@@start"                       # the body ran to the end; nothing came back, ssh 255
        rc, text = self.cancel("exp")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertEqual(self.scancelled(), "101\n")             # it WAS cancelled
        self.assertIn("the cancel may have been sent", text)
        self.assertNotIn("nothing was cancelled", text)
        self.assertEqual(len(next(r for r in self.led.state().grants if r["id"] == g["id"])["used"]), 1)   # kept
        os.environ.pop("SSH_CUT")
        os.environ["SSH_FAIL"] = "1"                             # a session that opened, then died: the same
        os.environ["SSH_FAIL_MSG"] = "Connection to fxhost closed by remote host."
        rc, text = self.cancel("exp", "--approve", "cancel job 101")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("the cancel may have been sent", text)
        self.assertEqual(len(self.approvals()[0]["used"]), 1)     # D6: an approval is used up whatever the outcome

    def test_r6_4_ssh_255_before_start_may_have_been_sent_whatever_its_stderr_says(self):
        """V5-notreached-cancel-unsent (R6-4 reverts R5-6): a ProxyCommand whose first route printed `ssh: connect to
        host … Connection refused` before its second route connected, and a link that died before @@start came back:
        rsk said 'not reached — nothing sent' and gave the cancel_own use back although scancel ran. ssh's exit 255
        without @@start is 'the cancel may have been sent' (exit 5, the use kept), whatever its stderr says."""
        g = G.add(self.led, G.new_grant("stop your own runs", {"targets": ["fx"]}, ["cancel_own"], max_live=None,
                                        max_launches=None, expires=None))
        self.launched("exp--a01", "101")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|")

        def used() -> int:
            return len(next(r for r in self.led.state().grants if r["id"] == g["id"])["used"])
        os.environ["SSH_FALLBACK"] = "ssh: connect to host bastion-a port 22: Connection refused"
        rc, text = self.cancel("exp")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertEqual(self.scancelled(), "101\n")                   # it WAS cancelled
        self.assertIn("the cancel may have been sent", text)
        self.assertNotIn("nothing sent", text)
        self.assertEqual(used(), 1)                                     # kept
        last = [a for a in self.led.read_audit()[0] if a.get("event") == "cancel"][-1]
        self.assertEqual((last.get("outcome"), last.get("sent")), ("unobservable", "maybe"))
        os.environ.pop("SSH_FALLBACK")
        os.environ["SSH_FAIL"] = "1"                                    # the same words, the body never ran: rsk cannot
        for n, msg in enumerate(("ssh: connect to host fxhost port 22: Connection refused",       # tell the two apart
                                 "ssh: connect to host fxhost port 22: No route to host",
                                 "ssh: Could not resolve hostname fxhost: Name or service not known",
                                 "me@fxhost: Permission denied (publickey,password).",
                                 "Host key verification failed."), start=2):
            os.environ["SSH_FAIL_MSG"] = msg
            rc, text = self.cancel("exp")
            self.assertEqual(rc, UNKNOWN, (msg, text))
            self.assertIn("the cancel may have been sent", text)
            self.assertNotIn("not reached", text)
            self.assertEqual(used(), n, msg)
        self.assertEqual(self.scancelled(), "101\n")
        self.assertEqual(L.attempt_state(self.led.read_run("exp").data["attempts"]["a01"]), "SUBMITTED")   # unchanged

    def test_r5_5_a_failing_scancel_is_unknown_unless_its_own_words_say_there_was_nothing(self):
        """R5-scancel-nonzero-refunds-cancel_own: any non-zero scancel exit gave the cancel_own use back and said 'not
        cancelled' — a timed-out RPC slurmctld applied (the job WAS cancelled) left the budget one cancel richer. Now
        exit 5, the use kept, the ledger CANCELLING?; only scancel's own line for that id saying it is invalid or
        already completing / completed proves there was nothing to cancel (exit 0, given back, the ledger updated)."""
        g = G.add(self.led, G.new_grant("stop your own runs", {"targets": ["fx"]}, ["cancel_own"], max_live=None,
                                        max_launches=1, expires=None))
        self.launched("exp--a01", "101")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|")
        os.environ["SC_RC"] = "1"
        os.environ["SC_ERR"] = "scancel: error: Kill job error on job id 101: Socket timed out on send/recv operation"
        rc, text = self.cancel("exp")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("UNKNOWN: job 101 (exp a01): scancel exit 1 (scancel: error: Kill job error on job id 101: Socket "
                      "timed out", text)
        self.assertNotIn("not cancelled", text)
        self.assertEqual(len(next(r for r in self.led.state().grants if r["id"] == g["id"])["used"]), 1)   # kept
        att = self.led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual(att["observed"]["state"], "CANCELLING?")
        self.assertTrue(L.is_live(att))
        self.assertIn("uses 1/1", G.balance(next(r for r in self.led.state().grants if r["id"] == g["id"]),
                                            self.led.state()))
        for job, run, err, code, state in (
                ("102", "done", "scancel: error: Kill job error on job id 102: Job/step already completing or completed",
                 OK, "COMPLETING"),
                ("103", "inval", "scancel: error: Kill job error on job id 103: Invalid job id specified", OK, "COMPLETING"),
                ("104", "other", "scancel: error: Kill job error on job id 1040: Invalid job id specified", UNKNOWN,
                 "CANCELLING?"),          # another id's line proves nothing for this one
                ("105", "noid", "scancel: error: Invalid job id specified", UNKNOWN, "CANCELLING?")):
            self.launched(f"{run}--a01", job, nonce=f"n{job}")
            self.queue(f"{job}|{run}--a01|{ME}|{self.remote}|RUNNING|")
            os.environ["SC_ERR"] = err
            rc, text = self.cancel(run, "--approve", f"cancel job {job}")
            self.assertEqual(rc, code, (job, text))
            self.assertEqual(self.led.read_run(run).data["attempts"]["a01"]["observed"]["state"], state, job)
            if code == OK:
                self.assertIn(f"nothing to cancel: job {job} ({run} a01) — scancel exit 1:", text)
        self.assertEqual(C.scancel_moot("x\nscancel: error: Kill job error on job id 7_3: Invalid job id specified\n",
                                        "7_3"), "scancel: error: Kill job error on job id 7_3: Invalid job id specified")
        self.assertEqual(C.scancel_moot("scancel: error: Kill job error on job id 7_3: Invalid job id specified", "7"), "")

    def test_r6_8_the_unknown_message_quotes_scancel_s_line_for_that_job(self):
        """V5-scancel-msg-other-id: in a multi-job cancel the UNKNOWN line quoted scancel's LAST line — job 102's
        message could read job 101's `already completing or completed`. Each job's message (and the ledger detail)
        now quotes the line naming it; failing that the last line naming no job id; failing that none."""
        G.add(self.led, G.new_grant("stop your own runs", {"targets": ["fx"]}, ["cancel_own"], max_live=None,
                                    max_launches=None, expires=None))
        self.launched("sw1--a01", "101", nonce="n1")
        self.launched("sw1--a01", "102", nonce="n2")                    # a chain: two live segments of one attempt
        self.queue(f"101|sw1--a01|{ME}|{self.remote}|RUNNING|", f"102|sw1--a01|{ME}|{self.remote}|PENDING|")
        timed = "scancel: error: Kill job error on job id 102: Socket timed out on send/recv operation"
        done = "scancel: error: Kill job error on job id 101: Job/step already completing or completed"
        os.environ["SC_RC"] = "1"
        for err in (f"{timed}\n{done}", f"{done}\n{timed}"):          # either order
            os.environ["SC_ERR"] = err
            rc, text = self.cancel("sw1")
            self.assertEqual(rc, UNKNOWN, text)
            self.assertIn(f"UNKNOWN: job 102 (sw1 a01): scancel exit 1 ({timed})", text)
            self.assertNotIn("102 (sw1 a01): scancel exit 1 (scancel: error: Kill job error on job id 101", text)
            self.assertIn(f"nothing to cancel: job 101 (sw1 a01) — scancel exit 1: {done}", text)
            sub = next(s for s in self.led.read_run("sw1").data["attempts"]["a01"]["submissions"] if s["job"] == "102")
            self.assertNotIn("job id 101", str(sub.get("seen")) + str(self.led.read_run("sw1").data["attempts"]["a01"]
                                                                       .get("observed")))
        self.assertEqual(C.scancel_line(f"{done}\n{timed}\n", "102"), timed)
        self.assertEqual(C.scancel_line(f"{done}\nscancel: error: Unable to contact slurm controller\n", "102"),
                         "scancel: error: Unable to contact slurm controller")      # a line naming no id: the call's
        self.assertEqual(C.scancel_line(done, "102"), "")                            # only another job's: none
        self.assertEqual(C.scancel_line("x job id 1020: y", "102"), "")              # 1020 is not 102

    def test_l2_an_answer_cut_after_the_identity_passed_gives_nothing_back(self):
        self.launched("exp--a01", "101")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|")
        os.environ["SSH_CUT"] = "^@@scancel"                      # `@@c 101 ok` arrived, then the connection died
        rc, text = self.cancel("exp", "--approve", "cancel job 101")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("the cancel may have been sent", text)
        self.assertEqual(self.scancelled(), "101\n")
        self.assertEqual(len(self.approvals()[0]["used"]), 1)       # no refund: it was (or may have been) cancelled
        self.assertIn("each once", G.describe(self.approvals()[0]))
        d = G.check(self.led, "cancel", job="101", run="exp", plan={"target": "fx"})
        self.assertFalse(d.covered)                                  # the approval cannot be used a second time

    def test_g3_flow_2_a_timed_out_answer_keeps_what_arrived(self):
        self.launched("exp--a01", "101")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|PENDING|")
        os.environ["SC_SLEEP"] = "4"                     # `@@c 101 ok` is out, scancel is slow: the deadline cuts in
        t0 = time.time()
        rc, text = self.cancel("exp", "--approve", "cancel job 101", "--deadline", "1.5")
        self.assertLess(time.time() - t0, 4)
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("the cancel may have been sent: rsk status", text)
        self.assertNotIn("nothing was cancelled", text)
        for _ in range(60):                              # the remote went on: scancel ran after all
            if self.scancelled():
                break
            time.sleep(0.1)
        self.assertEqual(self.scancelled(), "101\n")
        self.assertEqual(len(self.approvals()[0]["used"]), 1)

    def test_d6_an_approval_is_used_once_and_bound_to_its_job(self):
        self.launched("exp--a01", "101")
        self.queue()                                     # gone: nothing to cancel …
        rc, text = self.cancel("exp", "--approve", "cancel job 101")
        self.assertEqual(rc, OK, text)
        self.assertIn("nothing to cancel", text)
        ap = self.approvals()[0]
        self.assertEqual(len(ap["used"]), 1)             # … and the approval is used up all the same (no refund)
        self.assertEqual(ap["scope"]["idents"], [G.cancel_ident("slurm", "fx", "101", "exp--a01", str(self.remote))])
        self.assertTrue(ap["limits"]["expires"])
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|")
        rc, text = self.cancel("exp")                    # the same job id later: the old words do not cover it
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertEqual(self.scancelled(), "")

    def test_r1_7_an_ended_job_is_recorded_now(self):
        self.launched("exp--a01", "101")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|COMPLETED|")
        rc, text = self.cancel("exp", "--approve", "cancel exp")
        self.assertEqual(rc, OK, text)
        self.assertIn("nothing to cancel: job 101 (exp a01) is ended (COMPLETED); ledger: exp a01 ended COMPLETED", text)
        att = self.led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual(L.attempt_state(att), "COMPLETED")

    def test_a_deny_on_cancel_wins_over_the_users_words(self):
        G.add(self.led, G.new_deny("never cancel exp", {"names": ["exp*"]}, ["cancel"]))
        self.launched("exp--a01", "101")
        rc, text = self.cancel("exp", "--approve", "cancel exp")
        self.assertEqual(rc, REFUSED, text)
        self.assertEqual(self.approvals(), [])
        self.assertFalse((self.stub / "ssh.log").exists())

    def test_a_chain_is_every_live_segment(self):
        self.launched("exp--a01", "101")
        self.led.record_attempt(name="exp--a01", target="fx", kind="slurm", nonce="n2", submit="submitted", job="102",
                                attempt="a01")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|", f"102|exp--a01|{ME}|{self.remote}|PENDING|")
        rc, text = self.cancel("exp", "--approve", "stop the exp chain")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.scancelled(), "101 102\n")
        self.assertEqual(self.approvals()[0]["scope"]["jobs"], ["101", "102"])

    def test_r4_10_a_timeout_with_no_answer_at_all_keeps_the_use(self):
        """N4-cancel-zero-byte-timeout: the body ran there (scancel) while nothing came back; 'nothing was cancelled'
        and a refunded cancel_own use were wrong. Now exit 5, 'may have been sent', the use kept."""
        g = G.add(self.led, G.new_grant("stop your own runs", {"targets": ["fx"]}, ["cancel_own"], max_live=None,
                                        max_launches=3, expires=None))
        self.launched("exp--a01", "101")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|")
        os.environ["SSH_HANG"] = "6"
        rc, text = self.cancel("exp", "--deadline", "1.5")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("the cancel may have been sent: rsk status (no answer at all", text)
        self.assertNotIn("nothing was cancelled", text)
        self.assertEqual(len(next(r for r in self.led.state().grants if r["id"] == g["id"])["used"]), 1)
        for _ in range(60):
            if self.scancelled():
                break
            time.sleep(0.1)
        self.assertEqual(self.scancelled(), "101\n")                 # it was cancelled after all

    def test_r4_1_a_deny_of_the_runs_plan_stops_its_cancel(self):
        """NEW-deny-run-failopen: `rsk grant deny --run H` ("do not touch that run") never matched rsk cancel."""
        h = "c" * 64
        G.add(self.led, G.new_grant("kill a broken smoke yourself", {"targets": ["fx"]}, ["launch", "cancel_own"],
                                    max_live=None, max_launches=None, expires=None))
        self.launched("exp--a01", "101", plan={"bound_hash": h, "partition": "gpu", "warnings": "0"})
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|", f"555|stray|{ME}|{self.remote}|RUNNING|")
        G.add(self.led, G.new_deny("do not touch that run, whatever happens", {"runs": [h]}))
        rc, text = self.cancel("exp")
        self.assertEqual(rc, REFUSED, text)
        self.assertIn("do not touch that run", text)
        rc, text = self.cancel("--job", "555", "-T", "fx", "--approve", "cancel job 555")
        self.assertEqual(rc, REFUSED, text)                            # no plan to compare: it may be that one
        self.assertEqual(self.scancelled(), "")
        self.assertFalse((self.stub / "ssh.log").exists())

    def test_r4_15_unreadable_grants_refuse_a_cancel(self):
        self.launched("exp--a01", "101")
        G.add(self.led, G.new_deny("never cancel exp", {"names": ["exp*"]}, ["cancel"]))
        (self.led.dir / "grants.json").write_text('{"version": 1, "records": [')
        (self.led.dir / "grants.json.prev").unlink(missing_ok=True)
        rc, text = self.cancel("exp", "--approve", "cancel exp")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("grants unreadable", text)
        self.assertFalse((self.stub / "ssh.log").exists())

    def test_r8_2_the_users_words_must_name_what_is_cancelled(self):
        """NF7-cancel-words-id: `rsk cancel --job 102 --approve "cancel job 101, it diverged"` recorded an approval for
        102 and cancelled it (the identity check only proves the job is this user's, in this project). The words must
        name what is cancelled as a whole word — the job id, the run id or its job name; RUN: the run id / name or
        every job id — else exit 4 `needs user: the words do not name <J|RUN>`, nothing recorded, no ssh."""
        self.launched("sw1--a01", "101")
        self.launched("sw2--a01", "102", nonce="n2")
        self.queue(f"101|sw1--a01|{ME}|{self.remote}|RUNNING|", f"102|sw2--a01|{ME}|{self.remote}|RUNNING|")
        for argv, asked in ((("--job", "102", "-T", "fx", "--approve", "cancel job 101, it diverged"), "102"),
                            (("sw2", "--approve", "cancel sw1, it diverged"), "sw2"),
                            (("sw2", "--approve", "cancel it"), "sw2"),
                            (("sw2", "--approve", "cancel sw20 and job 1102"), "sw2"),     # whole tokens only
                            (("sw2", "--approve", "cancel exp--sw2 and 102_3"), "sw2"),
                            (("--job", "102", "-T", "fx", "--approve", "cancel sw2--a011"), "102")):
            rc, text = self.cancel(*argv)
            self.assertEqual(rc, NEEDS_USER, (argv, text))
            self.assertIn(f"needs user: the words do not name {asked} — ", text)
            self.assertIn("nothing recorded or cancelled", text)
        self.assertEqual(self.approvals(), [])
        self.assertFalse((self.stub / "ssh.log").exists())
        for argv, job in ((("sw2", "--approve", "cancel job 102."), "102"),                  # the job id
                          (("--job", "101", "-T", "fx", "--approve", "stop sw1, it diverged"), "101")):   # its run id
            rc, text = self.cancel(*argv)
            self.assertEqual(rc, OK, (argv, text))
            self.assertIn(f"cancelled: job {job}", text)
        self.assertEqual(self.scancelled(), "102\n101\n")
        self.launched("sw3--a01", "103", nonce="n3")
        self.queue(f"103|sw3--a01|{ME}|{self.remote}|RUNNING|")
        rc, text = self.cancel("--job", "103", "-T", "fx", "--approve", "please kill (sw3--a01)")   # its job name
        self.assertEqual(rc, OK, text)
        rc, text = self.cancel("--job", "777", "-T", "fx", "--approve", "cancel sw1")    # unknown to the ledger: its id
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("needs user: the words do not name 777", text)

    def test_r8_2_a_chain_needs_its_run_or_every_job_and_cancel_own_is_unchanged(self):
        self.launched("exp--a01", "101")
        self.led.record_attempt(name="exp--a01", target="fx", kind="slurm", nonce="n2", submit="submitted", job="102",
                                attempt="a01")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|", f"102|exp--a01|{ME}|{self.remote}|PENDING|")
        rc, text = self.cancel("exp", "--approve", "cancel job 101")
        self.assertEqual(rc, NEEDS_USER, text)                    # 102 is cancelled too: the words name only 101
        self.assertIn("needs user: the words do not name exp — ", text)
        self.assertIn("job 102 = run exp (exp--a01)", text)
        self.assertNotIn("job 101 = run", text)
        self.assertEqual(self.approvals(), [])
        rc, text = self.cancel("exp", "--approve", "cancel jobs 101 and 102")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.scancelled(), "101 102\n")
        G.add(self.led, G.new_grant("stop your own runs when they go nowhere", {"targets": ["fx"]}, ["cancel_own"],
                                    max_live=None, max_launches=None, expires=None))
        self.launched("own--a01", "105", nonce="n5")
        self.queue(f"105|own--a01|{ME}|{self.remote}|RUNNING|")
        self.assertEqual(self.cancel("own")[0], OK)              # no words: the cancel_own path as before

    def test_usage(self):
        self.launched("exp--a01", "", submit="unknown")
        for argv, code in ((("--approve", "x"), USAGE), (("--job", "101"), USAGE), (("nope",), USAGE),
                           (("--job", "1x", "-T", "fx"), USAGE), (("exp",), CONFLICT), (("exp", "--approve", " "), USAGE)):
            rc, text = self.cancel(*argv)
            self.assertEqual(rc, code, (argv, text))
        self.assertFalse((self.stub / "ssh.log").exists())


class Named(unittest.TestCase):
    def test_r8_2_named_takes_whole_tokens_only_the_docs_examples(self):
        """The whole-token rule exactly as SKILL.md §3, procedure-slurm / -nohup and DESIGN state it: a token inside a
        longer one (letters, digits, '_' next to it, or a '.' / '-' that goes on into one) does not name it; trailing
        punctuation does."""
        for words, tok in (("cancel 1101", "101"), ("cancel 101_2", "101"), ("cancel sw10", "sw1"),
                           ("cancel exp--sw1", "sw1"), ("cancel sw1-b", "sw1"), ("cancel it", "sw1"), ("", "101")):
            self.assertFalse(C.named(words, tok), (words, tok))
        for words, tok in (("cancel job 101.", "101"), ("please kill (sw1)", "sw1"), ("101", "101"),
                           ("stop sw1, it diverged", "sw1"), ("cancel job 101 and 102", "102"), ("sw1-", "sw1")):
            self.assertTrue(C.named(words, tok), (words, tok))


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

    def spawn(self, script: str = "sleep 30", nonce: str = "n1", start: str | None = None, gate: str = "go",
              receipt: bool = True, name: str = "r", boot: str | None = None) -> subprocess.Popen:
        p = subprocess.Popen(["bash", "-c", script], start_new_session=True)
        self.procs.append(p)
        time.sleep(0.2)
        log = f"logs/{name}-20261104-120000.log"
        if receipt:
            a = self.remote / ".rs" / "attempts" / nonce
            a.mkdir(parents=True)
            (a / "receipt").write_text(f"pid={p.pid}\npgid={p.pid}\nstart={start or pstart(p.pid)}\nboot_id={boot or self.boot}\n"
                                       f"log={log}\nname={name}\nnonce={nonce}\n")
            (a / "gate").symlink_to(gate)
        self.led.record_attempt(name=name, target="ws", kind="nohup", nonce=nonce, submit="submitted", plan_id="p-1",
                                action="launch", proc={"pid": str(p.pid), "pgid": str(p.pid), "start": "", "boot_id": "",
                                                       "log": log, "gpu_ids": "0"})
        return p

    def test_term_to_the_group_records_cancelled(self):
        p = self.spawn()
        rc, text = self.cancel("r", "--approve", "stop r", "--grace", "5")
        self.assertEqual(rc, OK, text)
        self.assertIn(f"cancelled: pid {p.pid} (r a01) on ws — TERM, its group is gone", text)
        self.assertEqual(p.wait(timeout=5), -15)
        att = self.led.read_run("r").data["attempts"]["a01"]
        self.assertEqual((L.attempt_state(att), att["result"]["state"]), ("CANCELLED", "CANCELLED"))

    def test_r8_2_nohup_words_name_the_pid_or_the_run(self):
        p = self.spawn()
        rc, text = self.cancel("r", "--approve", "stop q", "--grace", "1")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn("needs user: the words do not name r — ", text)
        rc, text = self.cancel("--job", str(p.pid), "-T", "ws", "--approve", f"kill pid {p.pid + 1}", "--grace", "1")
        self.assertEqual(rc, NEEDS_USER, text)
        self.assertIn(f"needs user: the words do not name {p.pid}", text)
        time.sleep(0.2)
        self.assertIsNone(p.poll(), "never signalled")
        self.assertEqual(self.approvals(), [])
        rc, text = self.cancel("--job", str(p.pid), "-T", "ws", "--approve", f"kill pid {p.pid}", "--grace", "5")
        self.assertEqual(rc, OK, text)
        self.assertEqual(p.wait(timeout=5), -15)

    def test_a_run_ignoring_term_is_killed_after_the_grace(self):
        p = self.spawn("trap '' TERM; sleep 30")
        rc, text = self.cancel("r", "--approve", "stop r", "--grace", "1")
        self.assertEqual(rc, OK, text)
        self.assertIn("then KILL after the grace", text)
        self.assertEqual(p.wait(timeout=5), -9)

    def test_a_reused_pid_or_an_unconfirmed_receipt_is_never_signalled(self):
        p = self.spawn(start="1")                               # the receipt's start time is another process's
        rc, text = self.cancel("r", "--approve", "stop r", "--grace", "1")
        self.assertEqual(rc, OK, text)
        self.assertIn("nothing to cancel", text)
        self.assertIn("its pid now belongs to another process", text)          # r1-7: exit 0, ended, recorded now
        att = self.led.read_run("r").data["attempts"]["a01"]
        self.assertEqual((L.attempt_state(att), L.is_live(att)), ("ENDED", False))
        q = self.spawn(nonce="n2", gate="abort", name="g")      # its gate never said go: not the run it claims
        rc, text = self.cancel("g", "--approve", "stop g", "--grace", "1")
        self.assertEqual(rc, CONFLICT, text)
        o = self.spawn(nonce="n3", receipt=False, name="o")     # nothing proves which process it is
        rc, text = self.cancel("o", "--approve", "stop o", "--grace", "1")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("noidentity", text)
        b = self.spawn(nonce="n4", name="b", boot="another-boot")    # the box rebooted since: that run is over
        rc, text = self.cancel("b", "--approve", "stop b", "--grace", "1")
        self.assertEqual(rc, OK, text)
        self.assertIn("the box rebooted", text)
        self.assertEqual(L.attempt_state(self.led.read_run("b").data["attempts"]["a01"]), "REBOOT")
        time.sleep(0.3)
        self.assertEqual([x.poll() for x in (p, q, o, b)], [None, None, None, None], "none of them was signalled")

    # R4-10 on a workstation: the nohup identity always compares the receipt's start + boot_id, a ledger nonce is
    # never answered by another receipt, and cancel_own never covers an attempt the ledger shows ended.
    def receipt(self, nonce: str, pid: int, start: str, boot: str | None = None, gate: str = "go") -> None:
        a = self.remote / ".rs" / "attempts" / nonce
        a.mkdir(parents=True)
        (a / "receipt").write_text(f"pid={pid}\npgid={pid}\nstart={start}\nboot_id={boot or self.boot}\n"
                                   f"log=logs/{nonce}.log\nnonce={nonce}\n")
        (a / "gate").symlink_to(gate)

    def test_n1_an_ended_runs_reused_pid_is_never_signalled(self):
        """N1-cancel-job-ended-pid-kills-unledgered-run: sw-x a01 ENDED; the box gave its pid to the user's own run
        (launched by hand: a receipt whose digits-first nonce sorts first). `rsk cancel --job PID` under cancel_own
        killed it. Now: not covered (ended), and with the user's words the ledger's own receipt decides (reused)."""
        G.add(self.led, G.new_grant("stop your own sweep runs", {"targets": ["ws"]}, ["cancel_own"], max_live=None,
                                    max_launches=None, expires=None))
        p = subprocess.Popen(["bash", "-c", "sleep 30"], start_new_session=True)
        self.procs.append(p)
        time.sleep(0.2)
        self.receipt("20261105T094245Z-20792-12675", p.pid, pstart(p.pid))           # the user's run, not ledgered
        self.receipt("n-old", p.pid, "1")                                             # sw-x's, long ago
        self.led.record_attempt(name="sw-x", target="ws", kind="nohup", nonce="n-old", submit="submitted",
                                plan_id="p-1", action="launch",
                                proc={"pid": str(p.pid), "pgid": str(p.pid), "start": "1", "boot_id": self.boot,
                                      "log": "logs/n-old.log", "gpu_ids": "0"})
        self.led.observe("sw-x", "a01", "logs/n-old.log", "ENDED", "pid", end={"state": "ENDED", "rc": "0",
                                                                                "evidence": "x.rc"})
        rc, text = self.cancel("--job", str(p.pid), "-T", "ws", "--grace", "1")
        self.assertEqual(rc, NEEDS_USER, text)                         # cancel_own never covers an ended attempt
        rc, text = self.cancel("--job", str(p.pid), "-T", "ws", "--approve", "stop sw-x", "--grace", "1")
        self.assertEqual(rc, OK, text)
        self.assertIn("nothing to cancel", text)
        self.assertIn("its pid now belongs to another process", text)
        self.assertIn("ledger: sw-x a01 had ended already", text)
        end = self.led.read_run("sw-x").data["attempts"]["a01"]["result"]
        self.assertEqual((end["state"], end["rc"]), ("ENDED", "0"))   # its recorded end is kept, never rewritten
        time.sleep(0.3)
        self.assertIsNone(p.poll(), "the user's own run was never signalled")

    def test_the_receipts_start_and_boot_id_are_always_the_ledgers(self):
        q = self.spawn(nonce="n1", name="q")
        self.led.set_submission("q", "a01", "n1", proc={"pid": str(q.pid), "pgid": str(q.pid), "start": pstart(q.pid),
                                                       "boot_id": "another-boot-id", "log": "logs/q.log"})
        rc, text = self.cancel("q", "--approve", "stop q", "--grace", "1")
        self.assertEqual(rc, CONFLICT, text)                           # the receipt's boot_id is not the ledger's
        self.assertIn("ledger-boot=another-boot-id", text)
        o = self.spawn(nonce="n2", name="o", receipt=False)             # the ledger's nonce has no receipt …
        self.receipt("0-other", o.pid, pstart(o.pid))                   # … another one names the same pid: never used
        rc, text = self.cancel("o", "--approve", "stop o", "--grace", "1")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("noidentity", text)
        u = subprocess.Popen(["bash", "-c", "sleep 30"], start_new_session=True)   # not ledgered, two receipts
        self.procs.append(u)
        time.sleep(0.2)
        self.receipt("u1", u.pid, pstart(u.pid))
        self.receipt("u2", u.pid, pstart(u.pid))
        rc, text = self.cancel("--job", str(u.pid), "-T", "ws", "--approve", f"kill pid {u.pid}", "--grace", "1")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("ambiguous", text)
        time.sleep(0.3)
        self.assertEqual([x.poll() for x in (q, o, u)], [None, None, None], "none of them was signalled")


if __name__ == "__main__":
    unittest.main()
