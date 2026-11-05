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

from remote_run import cli
from remote_run import grants as G
from remote_run import ledger as L
from remote_run.errors import CONFLICT, FAILED, NEEDS_USER, OK, REFUSED, UNKNOWN, USAGE

SSH = """#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
echo "$1" >> "$STUB/ssh.log"; shift
[ -z "${SSH_FAIL:-}" ] || { echo "ssh: connect to host: Connection timed out" >&2; exit 255; }
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
                           ("scancel", '#!/usr/bin/env bash\necho "$*" >> "$STUB/scancel.log"; exit ${SC_RC:-0}\n')):
            (self.stub / "bin" / name).write_text(text)
            (self.stub / "bin" / name).chmod(0o755)
        os.environ["STUB"] = str(self.stub)
        os.environ["PATH"] = f"{self.stub / 'bin'}{os.pathsep}{os.environ['PATH']}"
        os.environ["USER"] = ME
        for k in ("SSH_FAIL", "SQ_FAIL", "SC_RC", "SSH_CUT"):
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
            rc, text = self.cancel("exp", "--approve", "cancel it")
            self.assertEqual(rc, code, text)
            self.assertIn(why, text)
        self.assertEqual(self.scancelled(), "")
        self.assertTrue(all(ap["used"] == [] for ap in self.approvals()), "every use given back")

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
        rc, text = self.cancel("exp", "--approve", "cancel it")
        self.assertEqual(rc, OK, text)                # ledgered and gone: it ended, nothing to do
        self.assertIn("nothing to cancel", text)
        self.assertEqual(self.scancelled(), "")

    def test_a_symlinked_workdir_and_a_bar_in_the_name(self):
        link = self.home / "link"
        link.symlink_to(self.remote)
        self.launched("a|b--a01", "101")
        self.queue(f"101|a|b--a01|{ME}|{link}|PENDING|")
        rc, text = self.cancel("a|b", "--approve", "cancel it")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.scancelled(), "101\n")

    def test_scancel_failing_or_no_answer_gives_the_use_back(self):
        self.launched("exp--a01", "101")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|")
        os.environ["SC_RC"] = "1"
        rc, text = self.cancel("exp", "--approve", "cancel it")
        self.assertEqual(rc, FAILED, text)
        os.environ.pop("SC_RC")
        os.environ["SSH_FAIL"] = "1"
        rc, text = self.cancel("exp", "--approve", "cancel it")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("nothing was cancelled", text)
        self.assertTrue(all(ap["used"] == [] for ap in self.approvals()))

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

    def test_a_deny_on_cancel_wins_over_the_users_words(self):
        G.add(self.led, G.new_deny("never cancel exp", {"names": ["exp*"]}, ["cancel"]))
        self.launched("exp--a01", "101")
        rc, text = self.cancel("exp", "--approve", "cancel it")
        self.assertEqual(rc, REFUSED, text)
        self.assertEqual(self.approvals(), [])
        self.assertFalse((self.stub / "ssh.log").exists())

    def test_a_chain_is_every_live_segment(self):
        self.launched("exp--a01", "101")
        self.led.record_attempt(name="exp--a01", target="fx", kind="slurm", nonce="n2", submit="submitted", job="102",
                                attempt="a01")
        self.queue(f"101|exp--a01|{ME}|{self.remote}|RUNNING|", f"102|exp--a01|{ME}|{self.remote}|PENDING|")
        rc, text = self.cancel("exp", "--approve", "stop the chain")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.scancelled(), "101 102\n")
        self.assertEqual(self.approvals()[0]["scope"]["jobs"], ["101", "102"])

    def test_usage(self):
        self.launched("exp--a01", "", submit="unknown")
        for argv, code in ((("--approve", "x"), USAGE), (("--job", "101"), USAGE), (("nope",), USAGE),
                           (("--job", "1x", "-T", "fx"), USAGE), (("exp",), CONFLICT), (("exp", "--approve", " "), USAGE)):
            rc, text = self.cancel(*argv)
            self.assertEqual(rc, code, (argv, text))
        self.assertFalse((self.stub / "ssh.log").exists())


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
              receipt: bool = True, name: str = "r") -> subprocess.Popen:
        p = subprocess.Popen(["bash", "-c", script], start_new_session=True)
        self.procs.append(p)
        time.sleep(0.2)
        log = f"logs/{name}-20261104-120000.log"
        if receipt:
            a = self.remote / ".rs" / "attempts" / nonce
            a.mkdir(parents=True)
            (a / "receipt").write_text(f"pid={p.pid}\npgid={p.pid}\nstart={start or pstart(p.pid)}\nboot_id={self.boot}\n"
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
        q = self.spawn(nonce="n2", gate="abort", name="g")      # its gate never said go: not the run it claims
        rc, text = self.cancel("g", "--approve", "stop g", "--grace", "1")
        self.assertEqual(rc, CONFLICT, text)
        o = self.spawn(nonce="n3", receipt=False, name="o")     # nothing proves which process it is
        rc, text = self.cancel("o", "--approve", "stop o", "--grace", "1")
        self.assertEqual(rc, CONFLICT, text)
        self.assertIn("noidentity", text)
        time.sleep(0.3)
        self.assertEqual([x.poll() for x in (p, q, o)], [None, None, None], "none of them was signalled")


if __name__ == "__main__":
    unittest.main()
