"""rsk wait: resolution, rounds, events, cadence, the end — the reads scripted (observe.observe replaced by a list of
rounds, status.read / record / reconcile real), the digest stubbed, the module's own clock fake (nothing else's)."""

import contextlib
import io
import json
import os
import signal
import subprocess
import sys
import threading
import time as _time
import unittest
from pathlib import Path
from unittest import mock

from helpers import ScratchHome

from remote_run import cli, harness, observe
from remote_run import ledger as L
from remote_run import wait as W
from remote_run.errors import FAILED, INTERRUPTED, OK, UNKNOWN, USAGE, RskError


class Clock:
    """wait.time's stand-in: monotonic() / time() advance only through sleep(); every sleep is recorded."""

    def __init__(self) -> None:
        self.t = 0.0
        self.base = _time.time()
        self.sleeps: list[float] = []
        self.hook = None

    def monotonic(self) -> float:
        return self.t

    def time(self) -> float:
        return self.base + self.t

    def sleep(self, s: float) -> None:
        self.sleeps.append(s)
        self.t += s
        if self.hook:
            self.hook(self)


def run(*argv: str) -> tuple[int, str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        rc = cli.main(list(argv))
    return rc, buf.getvalue()


def job(jid, name, state, *, rc="", end=0, start=0, reason="", source=""):
    src = source or ("sacct" if state in observe.TERMINAL else "squeue")
    return observe.Job(jid, name, state, reason=reason, start=start, end=end, exit_code=rc, source=src)


def box(log, state, *, pid="", rc=None, start=0, pstart="1"):
    name = log.removeprefix("logs/").rsplit("-", 2)[0]
    return observe.Job(pid if state == "ALIVE" else "", name, state, start=start, source="pid", log=log, pid=pid,
                       exit_code=(rc or {}).get("rc", ""), rc=rc or {}, pstart=pstart if state == "ALIVE" else "")


class Base(ScratchHome):
    fake_clock = True           # the module's clock replaced (cadence over hours); RealTime sets False

    def setUp(self) -> None:
        super().setUp()
        self.proj = self.home / "proj"
        self.proj.mkdir()
        for name, prof in (("fx-slurm", "T_KIND=slurm; T_HOST=fxhost\n"), ("fx-box", "T_KIND=nohup; T_HOST=fxbox\n")):
            d = Path(os.environ["RS_USER_DIR"]) / "targets" / name
            d.mkdir(parents=True)
            (d / "profile.sh").write_text(prof)
        (self.proj / ".hpc.conf").write_text("REMOTE_DIR=/r/proj\n")
        (self.proj / ".ws.conf").write_text("WS_REMOTE_DIR=/r/proj\n")
        self.led = L.Ledger(self.proj)
        self.lock = threading.Lock()
        self.rounds = []
        self.calls: list[tuple[float, str]] = []
        self.deadlines: list[float] = []
        self.named_logs: list[tuple[str, list[str]]] = []
        self.read_hook = None
        self.digest_waits: list[float] = []
        self.digests: list[tuple[str, str]] = []
        self.clock = Clock()
        self.stack = contextlib.ExitStack()
        self.stack.enter_context(mock.patch.object(W, "read_target", self.fake_read))
        self.stack.enter_context(mock.patch.object(W, "digest", self.fake_digest))
        if self.fake_clock:
            self.stack.enter_context(mock.patch.object(W, "time", self.clock))

    def tearDown(self) -> None:
        self.stack.close()
        super().tearDown()

    # one dict per round: target -> list of jobs | ("down", why) | (jobs, attempts) | (jobs, attempts, partial);
    # the last one repeats. Each target steps through them on its own (one read per target per round).
    @property
    def rounds(self):
        return self._rounds

    @rounds.setter
    def rounds(self, value):
        self._rounds, self._at = list(value), {}

    @property
    def reads(self):
        """[(clock time, the targets read)] per round (a fake-clock round reads every target at one instant)."""
        got: dict[float, list[str]] = {}
        for t, tgt in self.calls:
            got.setdefault(t, []).append(tgt)
        return [(t, sorted(v)) for t, v in got.items()]

    def fake_read(self, procs, place, days, deadline, nonces, comments, logs=()):
        t0 = _time.time()                       # the read's window starts here (read_target's own stamp)
        with self.lock:
            self.named_logs.append((place.target, list(logs)))
            n = self._at.get(place.target, 0)
            self._at[place.target] = n + 1
            spec = self._rounds[min(n, len(self._rounds) - 1)]
            self.calls.append((self.clock.t, place.target))
            self.deadlines.append(deadline)
        if self.read_hook:
            self.read_hook()
        s = spec.get(place.target, [])
        if isinstance(s, tuple) and s[0] == "down":
            return observe.Observation(place, why=s[1], observed_at=_time.time())
        jobs, atts, partial = (s + ([],) if len(s) == 2 else s) if isinstance(s, tuple) else (s, {}, [])
        return observe.Observation(place, ok=True, now=int(_time.time()), observed_at=_time.time(), jobs=list(jobs),
                                   attempts=atts, attempts_ok=True, comments_ok=True, partial=list(partial),
                                   boot_id="b1" if place.kind == "nohup" else "", started_at=t0)

    def fake_digest(self, procs, place, key, wait=60.0):
        with self.lock:
            self.digests.append((place.target, key))
            self.digest_waits.append(wait)
        return {"text": "error=2 — RuntimeError: boom" if key.endswith("7") else "no hints — step 100 loss 0.1",
                "log": f"{place.remote_dir}/logs/x_{key}.out" if place.kind == "slurm" else f"{place.remote_dir}/{key}",
                "rc": ""}

    def slurm_run(self, name, jid, nonce=None):
        return self.led.record_attempt(name=name, target="fx-slurm", kind="slurm", nonce=nonce or f"n{jid}",
                                       submit="submitted", job=str(jid))

    def wait(self, *argv):
        return run("wait", "-C", str(self.proj), *argv)

    def lines(self, text):
        return [ln for ln in text.splitlines() if ln and not ln.startswith("rsk: ")]


class Resolution(Base):
    def test_a_run_id_waits_for_its_newest_attempt(self):
        self.slurm_run("exp--x", 100)
        self.led.record_attempt(name="exp--x--a02", target="fx-slurm", kind="slurm", nonce="n101", submit="submitted",
                                job="101")
        self.rounds = [{"fx-slurm": [job("100", "exp--x", "FAILED", rc="1:0"), job("101", "exp--x--a02", "COMPLETED",
                                                                                     rc="0:0")]}]
        rc, text = self.wait("exp--x")
        self.assertEqual(rc, OK, text)
        self.assertIn("ENDED  exp--x--a02 [fx-slurm] rc=0 no hints — step 100 loss 0.1 log /r/proj/logs/x_101.out", text)
        self.assertNotIn("FAILED", text.replace("rsk wait: exit", ""))
        self.assertEqual(self.reads[0][1], ["fx-slurm"])            # only the target holding the run

    def test_an_attempt_name_is_that_attempt(self):
        self.slurm_run("exp--x", 100)
        self.led.record_attempt(name="exp--x--a02", target="fx-slurm", kind="slurm", nonce="n101", submit="submitted",
                                job="101")
        self.rounds = [{"fx-slurm": [job("100", "exp--x", "FAILED", rc="1:0"), job("101", "exp--x--a02", "RUNNING")]}]
        rc, text = self.wait("exp--x--a01")
        self.assertEqual(rc, FAILED, text)
        self.assertIn("FAILED exp--x [fx-slurm] state=FAILED rc=1 ", text)
        self.assertNotIn("a02", text)

    def test_a_job_id_or_pid_with_one_target(self):
        self.rounds = [{"fx-slurm": [job("555", "adhoc", "RUNNING")]}, {"fx-slurm": [job("555", "adhoc", "COMPLETED",
                                                                                         rc="0:0")]}]
        rc, text = self.wait("-T", "fx-slurm", "555")
        self.assertEqual(rc, OK, text)
        self.assertIn("ENDED  adhoc [fx-slurm] rc=0", text)
        log = "logs/bx--a01-20261116-120000.log"
        self.rounds = [{"fx-box": [box(log, "ALIVE", pid="4242")]}, {"fx-box": [box(log, "ENDED", rc={"rc": "0"})]}]
        rc, text = self.wait("-T", "fx-box", "4242")
        self.assertEqual(rc, OK, text)
        self.assertIn(f"ENDED  bx--a01 [fx-box] rc=0 no hints — step 100 loss 0.1 log /r/proj/{log}", text)
        self.assertEqual(self.digests[-1], ("fx-box", log))
        self.rounds = [{"fx-box": [box(log, "ENDED", rc={"rc": "3"})]}]
        rc, text = self.wait("-T", "fx-box", f"/r/proj/{log}")            # a log path: absolute or relative
        self.assertEqual(rc, FAILED, text)
        self.assertIn("FAILED bx--a01 [fx-box] rc=3", text)

    def test_a_ledger_job_id_with_one_target(self):
        self.slurm_run("exp--j", 321)
        self.rounds = [{"fx-slurm": [job("321", "exp--j", "COMPLETED", rc="0:0")]}]
        rc, text = self.wait("-T", "fx-slurm", "321")
        self.assertEqual(rc, OK, text)
        self.assertIn("ENDED  exp--j [fx-slurm] rc=0", text)
        self.assertEqual(self.led.read_run("exp--j").data["attempts"]["a01"]["result"]["state"], "COMPLETED")

    def test_unknown_is_exit_2_nothing_waited(self):
        self.slurm_run("exp--k", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--k", "RUNNING")], "fx-box": []}]
        rc, text = self.wait("exp--k", "nosuch")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("rsk wait: unknown run nosuch — rsk status lists this project's runs", text)
        self.assertEqual(len(self.reads), 1)                        # the one read that resolves names
        self.assertEqual(self.clock.sleeps, [])
        self.assertNotIn("waiting:", text)
        self.assertNotIn("ENDED", text)
        self.assertEqual(text.splitlines()[-1], "rsk wait: exit 2 (usage, config or setup problem) — rsk wait: unknown "
                                                "run nosuch — rsk status lists this project's runs")

    def test_a_job_id_needs_one_target_and_no_read(self):
        rc, text = self.wait("555")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("exactly one -T", text)
        self.assertEqual(self.reads, [])

    def test_a_name_on_an_unreadable_target_is_unknown_not_unknown_run(self):
        self.rounds = [{"fx-slurm": ("down", "ssh exited 255: timeout"), "fx-box": []}]
        rc, text = self.wait("ghost")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("could not be read", text)

    def test_a_name_only_the_target_knows(self):
        self.rounds = [{"fx-slurm": [job("700", "free--x", "RUNNING")], "fx-box": []},
                       {"fx-slurm": [job("700", "free--x", "COMPLETED", rc="0:0")]}]
        rc, text = self.wait("free--x")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.reads[1][1], ["fx-slurm"])            # after resolution: only the target holding it

    def test_usage(self):
        for argv, why in ((("--all-live", "x"), "not both"), ((), "name the runs"), (("x", "--every", "5"), "--every"),
                          (("x", "--timeout", "0"), "--timeout"), (("x", "--heartbeat", "inf"), "--heartbeat"),
                          (("x", "--heartbeat", "nan"), "--heartbeat"), (("x", "--timeout", "nan"), "--timeout"),
                          (("x", "--deadline", "0"), "--deadline")):
            rc, text = self.wait(*argv)
            self.assertEqual(rc, USAGE, (argv, text))
            self.assertIn(why, text)


class Rounds(Base):
    def test_already_ended_at_start_is_reported_in_the_first_round(self):
        self.slurm_run("exp--a", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--a", "COMPLETED", rc="0:0", end=1)]}]
        rc, text = self.wait("exp--a")
        self.assertEqual(rc, OK, text)
        self.assertEqual(len(self.reads), 1)
        self.assertEqual(self.clock.sleeps, [])
        self.assertEqual(self.lines(text)[-1], "rsk wait: exit 0 (ok)")
        self.assertEqual(self.lines(text)[:2], ["rsk wait: 1 run(s) — read every 60s (read-only)",
                                                "targets: fx-slurm (1 run(s))"])

    def test_events_in_end_order_once_each(self):
        self.slurm_run("exp--a", 100)
        self.slurm_run("exp--b", 107)
        self.slurm_run("exp--c", 108)
        run_ = [job("100", "exp--a", "RUNNING"), job("107", "exp--b", "RUNNING"), job("108", "exp--c", "PENDING",
                                                                                      reason="Priority")]
        self.rounds = [{"fx-slurm": run_},
                       {"fx-slurm": [job("100", "exp--a", "RUNNING"), job("107", "exp--b", "FAILED", rc="1:0", end=5),
                                     job("108", "exp--c", "RUNNING")]},
                       {"fx-slurm": [job("100", "exp--a", "COMPLETED", rc="0:0", end=9),
                                     job("107", "exp--b", "FAILED", rc="1:0", end=5),
                                     job("108", "exp--c", "OUT_OF_MEMORY", rc="0:125", end=8)]}]
        rc, text = self.wait("exp--a", "exp--b", "exp--c", "--every", "10")
        self.assertEqual(rc, FAILED, text)
        ev = [ln.split()[0] + " " + ln.split()[1] for ln in self.lines(text) if ln.startswith(("ENDED", "FAILED"))]
        self.assertEqual(ev, ["FAILED exp--b", "FAILED exp--c", "ENDED exp--a"])   # round 2, then round 3 by end time
        self.assertIn("FAILED exp--b [fx-slurm] state=FAILED rc=1 error=2 — RuntimeError: boom log /r/proj/logs/x_107.out",
                      text)
        self.assertIn("FAILED exp--c [fx-slurm] state=OUT_OF_MEMORY rc=0 sig=125", text)
        self.assertIn("waiting: 3 of 3 still running (0s) — exp--a [fx-slurm]: RUNNING", text)
        self.assertIn("exp--c [fx-slurm]: PENDING (Priority)", text)
        self.assertEqual(len(self.digests), 3)
        self.assertEqual(self.clock.sleeps, [10, 10])

    def test_failed_states_are_named(self):
        for st, rc, words in (("TIMEOUT", "0:0", "state=TIMEOUT rc=0"), ("CANCELLED", "0:15", "state=CANCELLED rc=0 sig=15"),
                              ("NODE_FAIL", "0:0", "state=NODE_FAIL rc=0"), ("PREEMPTED", "0:0", "state=PREEMPTED rc=0"),
                              ("REBOOT", "", "state=REBOOT"), ("ENDED", "", "rc=unknown"), ("ENDED", "137", "rc=137"),
                              ("NOT_SUBMITTED", "", "state=NOT_SUBMITTED")):
            end = {"state": st, "rc": rc}
            self.assertEqual(W.rc_words(end), words)
            self.assertFalse(W.succeeded(end), end)
        self.assertTrue(W.succeeded({"state": "COMPLETED", "rc": "0:0"}))
        self.assertTrue(W.succeeded({"state": "ENDED", "rc": "0"}))
        self.slurm_run("exp--t", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--t", "TIMEOUT", rc="0:0", end=3)]}]
        rc, text = self.wait("exp--t")
        self.assertEqual(rc, FAILED)
        self.assertIn("FAILED exp--t [fx-slurm] state=TIMEOUT rc=0 ", text)

    def test_unobservable_then_recovery_once_each(self):
        self.slurm_run("exp--u", 100)
        live = [job("100", "exp--u", "RUNNING")]
        self.rounds = [{"fx-slurm": live}, {"fx-slurm": ("down", "ssh exited 255: no route")},
                       {"fx-slurm": ("down", "ssh exited 255: no route")}, {"fx-slurm": live},
                       {"fx-slurm": [job("100", "exp--u", "COMPLETED", rc="0:0", end=4)]}]
        rc, text = self.wait("exp--u", "--every", "10")
        self.assertEqual(rc, OK, text)
        ls = self.lines(text)
        self.assertEqual([ln for ln in ls if ln.startswith("UNOBSERVABLE")],
                         ["UNOBSERVABLE fx-slurm: ssh exited 255: no route — its runs' state is unknown, not ended"])
        self.assertEqual([ln for ln in ls if ln.startswith("OBSERVABLE")], ["OBSERVABLE again fx-slurm"])
        self.assertLess(ls.index("OBSERVABLE again fx-slurm"), [i for i, ln in enumerate(ls) if ln.startswith("ENDED")][0])
        self.assertEqual(len(self.reads), 5)

    def test_heartbeat_cadence_and_timeout(self):
        self.slurm_run("exp--h", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--h", "RUNNING", start=int(_time.time()) - 60)]}]
        rc, text = self.wait("exp--h", "--every", "60", "--heartbeat", "300", "--timeout", "1000")
        self.assertEqual(rc, UNKNOWN, text)
        ls = self.lines(text)
        self.assertEqual(len([ln for ln in ls if ln.startswith("waiting:")]), 4)   # at 0, 300, 600, 900
        self.assertIn("waiting: 1 of 1 still running (5m) — exp--h [fx-slurm]: RUNNING up ", text)
        self.assertEqual(ls[-2], "TIMEOUT after 1000s: 1 of 1 not ended — exp--h [fx-slurm]: RUNNING up 60s")
        self.assertEqual(ls[-1], "rsk wait: exit 5 (unknown or unreachable)")
        self.assertEqual(len(self.reads), 17)                       # 0, 60, …, 960
        self.assertTrue(all(0 < s <= 60 for s in self.clock.sleeps), self.clock.sleeps)
        self.assertEqual(self.clock.t, 1000)

    def test_backoff_after_30_quiet_minutes_never_above_600(self):
        self.slurm_run("exp--q", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--q", "RUNNING")]}]
        rc, _ = self.wait("exp--q", "--every", "400", "--heartbeat", "100000", "--timeout", "5000")
        self.assertEqual(rc, UNKNOWN)
        at = [t for t, _ in self.reads]
        gaps = [b - a for a, b in zip(at, at[1:])]
        self.assertEqual(gaps[:5], [400] * 5)                       # 0 … 2000: the first quiet 30 min
        self.assertEqual(set(gaps[5:]), {600})                      # then 2 x 400, capped at 600
        self.slurm_run("exp--r", 101)
        self.calls.clear()
        self.clock.t = 0
        self.rounds = [{"fx-slurm": [job("101", "exp--r", "RUNNING")]}]
        self.wait("exp--r", "--every", "100", "--heartbeat", "100000", "--timeout", "2500")
        gaps = [b - a for a, b in zip([t for t, _ in self.reads], [t for t, _ in self.reads][1:])]
        self.assertEqual(gaps[-1], 200)

    def test_backoff_is_not_held_off_by_a_growing_uptime(self):
        self.slurm_run("exp--up", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--up", "RUNNING", start=int(_time.time()) - 60)]}]
        rc, _ = self.wait("exp--up", "--every", "400", "--heartbeat", "100000", "--timeout", "5000")
        self.assertEqual(rc, UNKNOWN)
        at = [t for t, _ in self.reads]
        self.assertEqual({b - a for a, b in zip(at[5:], at[6:])}, {600})   # `up 1h` → `up 2h` is no change of state

    def test_a_read_or_a_digest_is_cut_at_the_timeout(self):
        self.slurm_run("exp--cut", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--cut", "RUNNING")]}] * 3 + [
            {"fx-slurm": [job("100", "exp--cut", "COMPLETED", rc="0:0", end=1)]}]
        rc, text = self.wait("exp--cut", "--every", "10", "--timeout", "38")
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.deadlines, [38, 28, 18, 8])            # what is left of --timeout, at most --deadline 60
        self.assertEqual(self.digest_waits, [8])
        self.calls.clear()
        self.deadlines.clear()
        self.clock.t = 0
        self.slurm_run("exp--cut2", 101)
        self.rounds = [{"fx-slurm": [job("101", "exp--cut2", "RUNNING")]}]
        rc, text = self.wait("exp--cut2", "--every", "10", "--timeout", "12")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertEqual(self.deadlines, [12, 2])                   # one deadline: what is left of it, no floor
        self.assertNotIn("UNOBSERVABLE", text)
        self.assertEqual(self.clock.t, 12)

    def test_completed_without_an_exit_code_is_rc_0(self):
        self.assertEqual(W.rc_words({"state": "COMPLETED", "rc": ""}), "rc=0")
        self.assertTrue(W.succeeded({"state": "COMPLETED", "rc": ""}))

    def test_a_signal_during_the_first_read_is_130_with_a_line(self):
        self.slurm_run("exp--s0", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--s0", "RUNNING")]}]
        self.read_hook = lambda: os.kill(os.getpid(), signal.SIGINT)
        before = signal.getsignal(signal.SIGINT)
        rc, text = self.wait("exp--s0")
        self.assertEqual(rc, INTERRUPTED, text)
        ls = self.lines(text)
        self.assertEqual(ls[:2], ["rsk wait: 1 run(s) — read every 60s (read-only)",   # before the read
                                  "targets: fx-slurm (1 run(s))"])
        self.assertEqual(ls[-2], "interrupted: 1 of 1 not ended — exp--s0 [fx-slurm]: not read yet")
        self.assertEqual(ls[-1], "rsk wait: exit 130 (interrupted (SIGINT / SIGTERM))")
        self.assertNotIn("Traceback", text)
        self.assertIs(signal.getsignal(signal.SIGINT), before)

    def test_timeout_names_an_unobservable_target(self):
        self.slurm_run("exp--v", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--v", "RUNNING")]}, {"fx-slurm": ("down", "no answer within 60 s")}]
        rc, text = self.wait("exp--v", "--every", "10", "--timeout", "30")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("TIMEOUT after 30s: 1 of 1 not ended — exp--v [fx-slurm]: UNOBSERVABLE (fx-slurm)", text)

    def test_sigterm_is_130_with_a_line(self):
        self.slurm_run("exp--s", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--s", "RUNNING")]}]
        self.clock.hook = lambda c: os.kill(os.getpid(), signal.SIGTERM)
        before = signal.getsignal(signal.SIGTERM)
        rc, text = self.wait("exp--s", "--every", "10")
        self.assertEqual(rc, INTERRUPTED, text)
        ls = self.lines(text)
        self.assertEqual(ls[-2], "interrupted: 1 of 1 not ended — exp--s [fx-slurm]: RUNNING")
        self.assertEqual(ls[-1], "rsk wait: exit 130 (interrupted (SIGINT / SIGTERM))")
        self.assertNotIn("Traceback", text)
        self.assertIs(signal.getsignal(signal.SIGTERM), before)     # the handler is put back

    def test_all_live(self):
        self.slurm_run("exp--l1", 100)
        self.slurm_run("exp--l2", 101)
        self.slurm_run("exp--old", 99)
        self.led.observe("exp--old", "a01", "99", "COMPLETED", "sacct", end={"state": "COMPLETED", "rc": "0:0",
                                                                              "evidence": "sacct"})
        self.led.record_attempt(name="exp--u", target="fx-slurm", kind="slurm", nonce="nu", submit="unknown")
        self.rounds = [{"fx-slurm": ([job("100", "exp--l1", "COMPLETED", rc="0:0", end=2),
                                      job("101", "exp--l2", "COMPLETED", rc="0:0", end=3),
                                      job("105", "exp--u", "COMPLETED", rc="0:0", end=4)],
                                     {"nu": {"mtime": 1, "missing": False, "result": {}, "stage": "", "gate": "",
                                             "receipt": {"job": "105"}, "procs": [], "argv_tail": ""}})}]
        rc, text = self.wait("--all-live")
        self.assertEqual(rc, OK, text)
        self.assertIn("ledger: exp--u a01: SUBMIT_UNKNOWN -> submitted (remote receipt (reconciled))", text)
        self.assertEqual(sorted(ln.split()[1] for ln in self.lines(text) if ln.startswith("ENDED")),
                         ["exp--l1", "exp--l2", "exp--u"])
        self.assertNotIn("exp--old", text)
        rc, text = self.wait("--all-live")
        self.assertEqual(rc, OK, text)
        self.assertIn("nothing live", text)

    def test_json(self):
        self.slurm_run("exp--a", 100)
        self.slurm_run("exp--b", 107)
        self.rounds = [{"fx-slurm": [job("100", "exp--a", "RUNNING"), job("107", "exp--b", "RUNNING")]},
                       {"fx-slurm": [job("100", "exp--a", "COMPLETED", rc="0:0", end=1),
                                     job("107", "exp--b", "FAILED", rc="2:0", end=2)]}]
        rc, text = self.wait("exp--a", "exp--b", "--json", "--every", "10")
        self.assertEqual(rc, FAILED, text)
        ls = self.lines(text)
        self.assertEqual(ls[-1], "rsk wait: exit 1 (the remote command ran and failed (its exit code is printed))")
        docs = [json.loads(ln) for ln in ls[:-1]]
        self.assertEqual([d["type"] for d in docs], ["start", "targets", "waiting", "ended", "failed", "summary"])
        self.assertEqual(docs[1]["targets"], ["fx-slurm"])
        f = docs[4]
        self.assertEqual({k: f[k] for k in ("run", "attempt", "target", "rc", "state", "log")},
                         {"run": "exp--b", "attempt": "a01", "target": "fx-slurm", "rc": "2:0", "state": "FAILED",
                          "log": "/r/proj/logs/x_107.out"})
        self.assertIn("RuntimeError", f["digest"])
        self.assertTrue(f["at"].endswith("Z"))
        self.assertEqual(docs[-1]["ended"], ["exp--a"])
        self.assertEqual(docs[-1]["failed"], ["exp--b"])
        self.assertEqual(docs[-1]["exit"], FAILED)

    def test_a_ledger_it_cannot_write_still_sees_the_end(self):
        self.slurm_run("exp--ro", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--ro", "COMPLETED", rc="0:0", end=1)]}]
        with mock.patch.object(L.Ledger, "locked", side_effect=RskError("read-only", 6)):
            rc, text = self.wait("exp--ro")
        self.assertEqual(rc, OK, text)
        self.assertIn("ledger: WARNING: ledger not updated (read-only view): read-only", text)
        self.assertIn("ENDED  exp--ro [fx-slurm] rc=0", text)
        self.assertIsNone(self.led.read_run("exp--ro").data["attempts"]["a01"]["result"])


class Evidence(Base):
    """An end counts only on this wait's evidence: a cached ledger end never beats a fresh live sighting, and an
    unreadable target ends nothing."""

    def ended_in_ledger(self, name, jid, state="COMPLETED", rc="0:0"):
        self.slurm_run(name, jid)
        self.led.observe(name, "a01", str(jid), state, "sacct", end={"state": state, "rc": rc, "evidence": "sacct"})
        self.assertFalse(L.is_live(self.led.read_run(name).data["attempts"]["a01"]))

    def test_a_requeued_job_is_waited_for_not_its_cached_end(self):
        self.ended_in_ledger("exp--rq", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--rq", "PENDING", reason="BeginTime")]},
                       {"fx-slurm": [job("100", "exp--rq", "RUNNING")]},
                       {"fx-slurm": [job("100", "exp--rq", "FAILED", rc="3:0", end=9)]}]
        rc, text = self.wait("exp--rq", "--every", "10")
        self.assertEqual(rc, FAILED, text)                          # the requeued attempt's own end, not the cache's
        ls = self.lines(text)
        self.assertIn("waiting: 1 of 1 still running (0s) — exp--rq [fx-slurm]: PENDING (BeginTime)", ls)
        self.assertEqual([ln.split()[0] for ln in ls if ln.startswith(("ENDED", "FAILED"))], ["FAILED"])
        self.assertIn("FAILED exp--rq [fx-slurm] state=FAILED rc=3 ", text)
        self.assertEqual(len(self.reads), 3)

    def test_a_cached_success_a_newer_read_shows_failed_is_failed(self):   # round 3 P2: requeued, ended again
        self.ended_in_ledger("exp--re", 100)                     # COMPLETED 0:0 cached by an earlier read
        self.rounds = [{"fx-slurm": [job("100", "exp--re", "FAILED", rc="1:0", end=9)]}]
        rc, text = self.wait("exp--re", "--every", "10")
        self.assertEqual(rc, FAILED, text)
        self.assertIn("FAILED exp--re [fx-slurm] state=FAILED rc=1 ", text)
        self.assertNotIn("ENDED  exp--re", text)
        res = self.led.read_run("exp--re").data["attempts"]["a01"]["result"]
        self.assertEqual((res["state"], res["rc"]), ("FAILED", "1:0"))

    def test_judge_takes_a_newer_different_end_in_memory(self):
        now = _time.time()
        att = {"name": "r", "target": "fx-slurm", "kind": "slurm",
               "submissions": [{"nonce": "n", "submit": "submitted", "job": "5", "obs_w": [now - 100, now - 99],
                                "seen": {"state": "COMPLETED"},
                                "end": {"state": "COMPLETED", "rc": "0:0", "at": "2026-01-01T00:00:00Z"}}],
               "result": {"state": "COMPLETED", "rc": "0:0", "at": "2026-01-01T00:00:00Z"}}
        st = L.LedgerState(runs={"r": {"run": "r", "attempts": {"a01": att}}})
        place = harness.Place("fx-slurm", kind="slurm", host="h", remote_dir="/r", deploy=".fx-slurm")
        o = observe.Observation(place, ok=True, observed_at=now, started_at=now - 1,
                                jobs=[job("5", "r", "FAILED", rc="1:0", end=int(now) - 5)])
        it = W.Item(label="r", target="fx-slurm", kind="slurm", run="r", aid="a01")
        W.judge(it, W._sync_runs(st, [o]), o)
        self.assertTrue(it.done)
        self.assertEqual((it.end["state"], it.end["rc"]), ("FAILED", "1:0"))
        self.assertFalse(W.succeeded(it.end))

    def test_an_overlapping_read_of_another_end_is_not_done(self):
        """Codex round 4: cached COMPLETED 0:0 over [t, t+10], a read over [t+5, t+11] shows FAILED 1:0 → never ENDED."""
        now = _time.time()
        att = {"name": "r", "target": "fx-slurm", "kind": "slurm",
               "submissions": [{"nonce": "n", "submit": "submitted", "job": "5", "obs_w": [now - 10, now],
                                "seen": {"state": "COMPLETED"},
                                "end": {"state": "COMPLETED", "rc": "0:0", "at": "2026-01-01T00:00:00Z"}}],
               "result": {"state": "COMPLETED", "rc": "0:0", "at": "2026-01-01T00:00:00Z"}}
        st = L.LedgerState(runs={"r": {"run": "r", "attempts": {"a01": att}}})
        place = harness.Place("fx-slurm", kind="slurm", host="h", remote_dir="/r", deploy=".fx-slurm")
        o = observe.Observation(place, ok=True, observed_at=now + 1, started_at=now - 5,
                                jobs=[job("5", "r", "FAILED", rc="1:0", end=int(now) - 6)])
        it = W.Item(label="r", target="fx-slurm", kind="slurm", run="r", aid="a01")
        W.judge(it, W._sync_runs(st, [o]), o)
        self.assertFalse(it.done, it.end)

    def test_an_earlier_started_overlapping_read_of_another_end_is_not_done(self):
        """The other direction: cached COMPLETED 0:0 over [t+5, t+11], a read over [t, t+10] shows FAILED 1:0."""
        now = _time.time()
        att = {"name": "r", "target": "fx-slurm", "kind": "slurm",
               "submissions": [{"nonce": "n", "submit": "submitted", "job": "5", "obs_w": [now - 5, now + 1],
                                "seen": {"state": "COMPLETED"},
                                "end": {"state": "COMPLETED", "rc": "0:0", "at": "2026-01-01T00:00:00Z"}}],
               "result": {"state": "COMPLETED", "rc": "0:0", "at": "2026-01-01T00:00:00Z"}}
        st = L.LedgerState(runs={"r": {"run": "r", "attempts": {"a01": att}}})
        place = harness.Place("fx-slurm", kind="slurm", host="h", remote_dir="/r", deploy=".fx-slurm")
        o = observe.Observation(place, ok=True, observed_at=now, started_at=now - 10,
                                jobs=[job("5", "r", "FAILED", rc="1:0", end=int(now) - 11)])
        it = W.Item(label="r", target="fx-slurm", kind="slurm", run="r", aid="a01")
        W.judge(it, W._sync_runs(st, [o]), o)
        self.assertFalse(it.done, it.end)

    def test_a_cached_end_on_an_unreadable_target_is_never_reported(self):
        self.ended_in_ledger("exp--ce", 100)
        self.rounds = [{"fx-slurm": ("down", "ssh exited 255: no route")}]
        rc, text = self.wait("exp--ce", "--every", "10", "--timeout", "25")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertNotIn("ENDED", text)
        self.assertIn("UNOBSERVABLE fx-slurm: ssh exited 255: no route", text)
        self.assertIn("TIMEOUT after 25s: 1 of 1 not ended — exp--ce [fx-slurm]: COMPLETED per the ledger, unverified "
                      "target UNOBSERVABLE", text)
        self.assertEqual(self.lines(text)[-1], "rsk wait: exit 5 (unknown or unreachable)")

    def test_a_cached_end_counts_once_a_complete_read_agrees(self):
        self.ended_in_ledger("exp--ok", 100)
        self.rounds = [{"fx-slurm": ("down", "ssh exited 255: no route")},
                       {"fx-slurm": ([job("200", "other", "RUNNING")], {}, ["sacct: odd line"])},   # partial: no
                       {"fx-slurm": [job("200", "other", "RUNNING")]}]                              # complete: yes
        rc, text = self.wait("exp--ok", "--every", "10")
        self.assertEqual(rc, OK, text)
        self.assertIn("ENDED  exp--ok [fx-slurm] rc=0", text)
        self.assertEqual(len(self.reads), 3)
        self.assertLess(text.index("OBSERVABLE again"), text.index("ENDED"))

    def test_a_target_down_mid_wait_ends_nothing(self):
        self.slurm_run("exp--md", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--md", "RUNNING")]}, {"fx-slurm": ("down", "no answer")}]

        def concurrent_status():        # another reader records an end while this wait cannot read the target
            if len(self.calls) == 2:
                self.led.observe("exp--md", "a01", "100", "COMPLETED", "sacct",
                                 end={"state": "COMPLETED", "rc": "0:0", "evidence": "sacct"})
        self.read_hook = concurrent_status
        rc, text = self.wait("exp--md", "--every", "10", "--timeout", "35")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertNotIn("ENDED", text)
        self.assertIn("exp--md [fx-slurm]: COMPLETED per the ledger, unverified target UNOBSERVABLE", text)

    def test_judge_unit(self):
        att = {"name": "r", "target": "fx-slurm", "kind": "slurm",
               "submissions": [{"nonce": "n", "submit": "submitted", "job": "5", "obs_w": [100.0, 101.0],
                                "seen": {"state": "COMPLETED"},
                                "end": {"state": "COMPLETED", "rc": "0:0", "at": "2026-01-01T00:00:00Z"}}],
               "result": {"state": "COMPLETED", "rc": "0:0", "at": "2026-01-01T00:00:00Z"}}
        st = L.LedgerState(runs={"r": {"run": "r", "attempts": {"a01": att}}})
        place = harness.Place("fx-slurm", kind="slurm", host="h", remote_dir="/r", deploy=".fx-slurm")
        now = _time.time()
        live = observe.Observation(place, ok=True, observed_at=now, started_at=now - 1, jobs=[job("5", "r", "RUNNING")])
        it = W.Item(label="r", target="fx-slurm", kind="slurm", run="r", aid="a01")
        W.judge(it, W._sync_runs(st, [live]), live)                # a newer live read: reopened (a requeue)
        self.assertFalse(it.done)
        self.assertEqual(it.state, "RUNNING")
        it = W.Item(label="r", target="fx-slurm", kind="slurm", run="r", aid="a01")
        W.judge(it, st.runs, observe.Observation(place, why="down"))
        self.assertFalse(it.done)
        W.judge(it, st.runs, None)
        self.assertFalse(it.done)
        empty = observe.Observation(place, ok=True, observed_at=now, started_at=now - 1)
        W.judge(it, W._sync_runs(st, [empty]), empty)              # a complete read that does not list it
        self.assertTrue(it.done)
        self.assertEqual(it.end["state"], "COMPLETED")

    def test_judge_never_ends_on_a_sighting_reconciliation_rejected(self):   # finding 1, in memory
        att = {"name": "r", "target": "fx-slurm", "kind": "slurm",
               "submissions": [{"nonce": "n", "submit": "submitted", "job": "5", "end": None,
                                "seen": {"state": "RUNNING"}}], "result": None, "observed": {"state": "RUNNING"}}
        now = _time.time()
        att["submissions"][0]["obs_w"] = [now + 50, now + 51]       # a live read newer than this one (a requeue)
        st = L.LedgerState(runs={"r": {"run": "r", "attempts": {"a01": att}}})
        place = harness.Place("fx-slurm", kind="slurm", host="h", remote_dir="/r", deploy=".fx-slurm")
        old = observe.Observation(place, ok=True, observed_at=now, started_at=now - 1,
                                  jobs=[job("5", "r", "COMPLETED", rc="0:0", end=int(now))])
        it = W.Item(label="r", target="fx-slurm", kind="slurm", run="r", aid="a01")
        W.judge(it, W._sync_runs(st, [old]), old)
        self.assertFalse(it.done, it)
        self.assertEqual(it.state, "RUNNING")
        att["submissions"][0]["obs_w"] = [now - 0.5, now + 3]       # overlapping, live: neither is newer
        W.judge(it, W._sync_runs(st, [old]), old)
        self.assertFalse(it.done, it)
        self.assertEqual(it.state, "UNCERTAIN")
        self.assertIn("conflicting reads", it.detail)

    def test_an_end_this_rounds_own_read_shows_live_is_never_reported(self):   # round 3: clock back < SKEW_S
        now = _time.time()
        att = {"name": "r", "target": "fx-slurm", "kind": "slurm",
               "submissions": [{"nonce": "n", "submit": "submitted", "job": "5", "obs_w": [now + 600, now + 601],
                                "seen": {"state": "COMPLETED"},
                                "end": {"state": "COMPLETED", "rc": "0:0", "at": "2026-01-01T00:00:00Z"}}],
               "result": {"state": "COMPLETED", "rc": "0:0", "at": "2026-01-01T00:00:00Z"}}
        st = L.LedgerState(runs={"r": {"run": "r", "attempts": {"a01": att}}})
        place = harness.Place("fx-slurm", kind="slurm", host="h", remote_dir="/r", deploy=".fx-slurm")
        live = observe.Observation(place, ok=True, observed_at=now, started_at=now - 1, jobs=[job("5", "r", "RUNNING")])
        runs = W._sync_runs(st, [live])           # 10 min "older" than the recorded end: dropped by the ledger ...
        self.assertFalse(L.is_live(runs["r"]["attempts"]["a01"]))
        it = W.Item(label="r", target="fx-slurm", kind="slurm", run="r", aid="a01")
        W.judge(it, runs, live)                    # ... but never an end this read shows live
        self.assertFalse(it.done, it)
        self.assertEqual((it.state, it.detail), ("COMPLETED per the ledger, unverified", "this read shows 5 live: read again"))

    def test_a_box_end_a_reused_pid_cannot_hold_open(self):   # round 3: provably another process confirms the end
        log = "logs/bx-20261101-100000.log"
        now = _time.time()
        att = {"name": "bx", "target": "fx-box", "kind": "nohup",
               "submissions": [{"nonce": "n", "submit": "submitted", "job": "", "obs_w": [now - 100, now - 99],
                                "proc": {"pid": "77", "start": "5", "boot_id": "b1", "log": log},
                                "seen": {"state": "ENDED"}, "end": {"state": "ENDED", "rc": "0", "at": "x"}}],
               "result": {"state": "ENDED", "rc": "0", "at": "x"}}
        st = L.LedgerState(runs={"bx": {"run": "bx", "attempts": {"a01": att}}})
        place = harness.Place("fx-box", kind="nohup", host="b", remote_dir="/r", deploy=".ws")
        for boot, pstart, done in (("b1", "5", False), ("b1", "", False), ("b1", "9", True), ("b2", "5", True)):
            o = observe.Observation(place, ok=True, observed_at=now, started_at=now - 1, boot_id=boot,
                                    jobs=[box(log, "ALIVE", pid="77", pstart=pstart)])
            it = W.Item(label="bx", target="fx-box", kind="nohup", run="bx", aid="a01")
            W.judge(it, W._sync_runs(st, [o]), o)
            self.assertEqual(it.done, done, (boot, pstart, it))


class Order(Base):
    """Findings 1 and 2: an end counts only as reconciliation accepted it, and only once every submission ended."""

    def test_a_terminal_read_overlapping_a_concurrent_live_one_is_read_again(self):
        self.slurm_run("exp--ov", 100)

        def concurrent():               # during this wait's first read another reader records the job live (requeued)
            if len(self.calls) == 1:
                t = _time.time()
                self.led.observe("exp--ov", "a01", "100", "PENDING", "squeue", win=(t, t))
        self.read_hook = concurrent
        self.rounds = [{"fx-slurm": [job("100", "exp--ov", "COMPLETED", rc="0:0", end=5)]}]
        rc, text = self.wait("exp--ov", "--every", "10")
        self.assertEqual(rc, OK, text)
        self.assertEqual(len(self.reads), 2)                        # the first read's end was not taken
        self.assertIn("waiting: 1 of 1 still running (0s) — exp--ov [fx-slurm]: UNCERTAIN (conflicting reads", text)
        self.assertIn("ledger: exp--ov a01: 100 is uncertain", text)
        self.assertEqual(text.count("ENDED  exp--ov"), 1)
        self.assertLess(text.index("UNCERTAIN"), text.index("ENDED  exp--ov"))

    def test_a_terminal_read_older_than_a_recorded_live_one_never_ends_it(self):
        self.slurm_run("exp--old", 100)
        t = _time.time() + 3600                                     # another reader's live read, newer than any here
        self.led.observe("exp--old", "a01", "100", "RUNNING", "squeue", win=(t, t))
        self.rounds = [{"fx-slurm": [job("100", "exp--old", "COMPLETED", rc="0:0", end=5)]}]
        rc, text = self.wait("exp--old", "--every", "10", "--timeout", "25")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertNotIn("ENDED", text)
        self.assertIn("TIMEOUT after 25s: 1 of 1 not ended — exp--old [fx-slurm]: RUNNING", text)
        self.assertIsNone(self.led.read_run("exp--old").data["attempts"]["a01"]["result"])

    def test_an_attempt_ends_only_when_every_submission_ended(self):
        self.slurm_run("exp--two--a01", 100, nonce="na")
        self.slurm_run("exp--two--a01", 101, nonce="nb")            # the same attempt, a second submission
        att = self.led.read_run("exp--two").data["attempts"]
        self.assertEqual(list(att), ["a01"])
        self.assertEqual(len(att["a01"]["submissions"]), 2)
        n = "exp--two--a01"
        self.rounds = [{"fx-slurm": [job("100", n, "RUNNING"), job("101", n, "COMPLETED", rc="0:0", end=3)]},
                       {"fx-slurm": [job("100", n, "COMPLETED", rc="0:0", end=9),
                                     job("101", n, "COMPLETED", rc="0:0", end=3)]}]
        rc, text = self.wait("exp--two", "--every", "10")
        self.assertEqual(rc, OK, text)
        self.assertEqual(len(self.reads), 2)
        self.assertIn(f"waiting: 1 of 1 still running (0s) — {n} [fx-slurm]: RUNNING (100)", text)
        self.assertEqual(text.count(f"ENDED  {n}"), 1)
        self.assertEqual(self.digests, [("fx-slurm", "101")])      # the digest: the newest submission's

    def test_a_failed_older_submission_still_running_is_not_success(self):
        self.slurm_run("exp--tw--a01", 200, nonce="na")
        self.slurm_run("exp--tw--a01", 201, nonce="nb")
        self.rounds = [{"fx-slurm": [job("200", "exp--tw--a01", "PENDING", reason="Priority"),
                                     job("201", "exp--tw--a01", "COMPLETED", rc="0:0", end=3)]}]
        rc, text = self.wait("exp--tw", "--every", "10", "--timeout", "15")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertNotIn("ENDED", text)
        self.assertIn("exp--tw--a01 [fx-slurm]: PENDING (Priority) (200)", text)


class Pids(Base):
    def box_run(self, name, pid, log, nonce, boot="b1"):
        return self.led.record_attempt(name=name, target="fx-box", kind="nohup", nonce=nonce, submit="submitted",
                                       proc={"pid": pid, "pgid": pid, "start": "1", "boot_id": boot, "log": log})

    def test_every_watched_box_log_is_named_in_each_read(self):   # round 3 P2: a log out of the newest 50
        log = "logs/bx--far-20261101-100000.log"
        self.box_run("bx--far", "321", log, "n1")
        self.slurm_run("exp--s", 100)
        self.rounds = [{"fx-box": [box(log, "ENDED", rc={"rc": "4"})],
                        "fx-slurm": [job("100", "exp--s", "COMPLETED", rc="0:0", end=3)]}]
        rc, text = self.wait("bx--far", "exp--s", "--every", "10")
        self.assertEqual(rc, FAILED, text)
        self.assertIn("FAILED bx--far [fx-box] rc=4 ", text)
        self.assertIn(("fx-box", [log]), self.named_logs)
        self.assertIn(("fx-slurm", []), self.named_logs)        # a Slurm read names no log

    def test_watched_logs_unit(self):
        st = L.LedgerState(runs={"r": {"run": "r", "attempts": {"a01": {"target": "fx-box", "submissions": [
            {"proc": {"log": "logs/r-20261101-000000.log"}}, {"proc": {"log": "logs/r-20261102-000000.log"}},
            {"proc": {"log": "../x-20261101-000000.log"}}]}}}})
        items = [W.Item(label="r", target="fx-box", kind="nohup", run="r", aid="a01"),
                 W.Item(label="u", target="fx-box", kind="nohup", key="logs/u-20261101-000000.log"),
                 W.Item(label="d", target="fx-box", kind="nohup", key="logs/d-20261101-000000.log", done=True),
                 W.Item(label="o", target="fx-other", kind="nohup", key="logs/o-20261101-000000.log")]
        self.assertEqual(W._watched_logs(st, items, "fx-box"),
                         ["logs/r-20261101-000000.log", "logs/r-20261102-000000.log", "logs/u-20261101-000000.log"])

    def test_a_reused_pid_not_alive_is_ambiguous(self):
        self.box_run("bx--old", "123", "logs/bx--old-20261101-100000.log", "n1")
        self.box_run("bx--new", "123", "logs/bx--new-20261110-100000.log", "n2")
        self.rounds = [{"fx-box": []}]
        rc, text = self.wait("-T", "fx-box", "123")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("pid 123 on fx-box is ambiguous", text)
        self.assertIn("bx--old (bx--old a01, log logs/bx--old-20261101-100000.log)", text)
        self.assertIn("bx--new (bx--new a01, log logs/bx--new-20261110-100000.log)", text)
        self.assertNotIn("ENDED", text)

    def test_a_reused_pid_alive_is_the_launch_with_its_log(self):
        self.box_run("bx--old", "123", "logs/bx--old-20261101-100000.log", "n1")
        new = "logs/bx--new-20261110-100000.log"
        self.box_run("bx--new", "123", new, "n2")
        self.rounds = [{"fx-box": [box(new, "ALIVE", pid="123")]}, {"fx-box": [box(new, "ENDED", rc={"rc": "0"})]}]
        rc, text = self.wait("-T", "fx-box", "123", "--every", "10")
        self.assertEqual(rc, OK, text)
        self.assertIn("resolved: 123 -> bx--new [fx-box]", text)
        self.assertIn(f"ENDED  bx--new [fx-box] rc=0 no hints — step 100 loss 0.1 log /r/proj/{new}", text)
        self.assertNotIn("bx--old", text)

    def test_a_pid_alive_under_the_launch_log_needs_its_boot_and_start(self):   # finding 5
        log = "logs/bx--id-20261110-100000.log"
        self.box_run("bx--id", "321", log, "n1")                   # receipt: start 1, boot b1
        for spec, why in (({"pstart": ""}, "its process start cannot be compared"),
                          ({"pstart": "999"}, "its process start is not the launch's (another process under a reused pid)")):
            self.calls.clear()
            self.rounds = [{"fx-box": [box(log, "ALIVE", pid="321", **spec)]}]
            rc, text = self.wait("-T", "fx-box", "321")
            self.assertEqual(rc, USAGE, text)
            self.assertIn(f"pid 321 on fx-box is ambiguous: alive under the log of bx--id (bx--id a01, log {log}), but "
                          + why, text)
            self.assertNotIn("ENDED", text)
        self.box_run("bx--id2", "322", "logs/bx--id2-20261110-100000.log", "n2", boot="b0")   # another boot
        self.rounds = [{"fx-box": [box("logs/bx--id2-20261110-100000.log", "ALIVE", pid="322")]}]
        rc, text = self.wait("-T", "fx-box", "322")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("its boot_id is not the launch's", text)

    def test_two_logs_naming_one_live_pid_are_ambiguous(self):
        self.rounds = [{"fx-box": [box("logs/a-20261110-100000.log", "ALIVE", pid="55"),
                                   box("logs/b-20261110-100000.log", "ALIVE", pid="55")]}]
        rc, text = self.wait("-T", "fx-box", "55")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("pid 55 on fx-box is ambiguous: alive under 2 logs", text)

    def test_an_ended_box_run_alive_again_without_a_checkable_identity_is_never_ended(self):
        log = "logs/bx--re-20261110-100000.log"
        self.box_run("bx--re", "77", log, "n1")
        self.led.observe("bx--re", "a01", log, "ENDED", "pid", end={"state": "ENDED", "rc": "0", "evidence": "rc"},
                         win=(1.0, 2.0))
        self.rounds = [{"fx-box": [box(log, "ALIVE", pid="77", pstart="")]}]
        rc, text = self.wait("bx--re", "--every", "10", "--timeout", "25")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertNotIn("ENDED  bx--re", text)
        self.assertIn("bx--re [fx-box]: UNCERTAIN (pid 77 is alive under its log, but its process start cannot be "
                      "compared", text)
        self.rounds = [{"fx-box": [box(log, "ENDED", rc={"rc": "0"})]}]           # the next read decides
        rc, text = self.wait("bx--re", "--every", "10")
        self.assertEqual(rc, OK, text)
        self.assertIn("ENDED  bx--re [fx-box] rc=0", text)

    def test_a_live_stranger_under_a_ledger_pid_is_ambiguous(self):
        self.box_run("bx--old", "123", "logs/bx--old-20261101-100000.log", "n1")
        self.rounds = [{"fx-box": [box("logs/adhoc-20261116-100000.log", "ALIVE", pid="123")]}]
        rc, text = self.wait("-T", "fx-box", "123")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("alive now as adhoc (log logs/adhoc-20261116-100000.log)", text)
        self.assertIn("bx--old", text)

    def test_one_historical_launch_of_the_pid(self):
        log = "logs/bx--one-20261101-100000.log"
        self.box_run("bx--one", "77", log, "n1")
        self.rounds = [{"fx-box": [box(log, "ENDED", rc={"rc": "4"})]}]
        rc, text = self.wait("-T", "fx-box", "77")
        self.assertEqual(rc, FAILED, text)
        self.assertIn("FAILED bx--one [fx-box] rc=4", text)

    def test_a_slurm_job_id_two_attempts_hold_is_ambiguous(self):
        self.slurm_run("exp--j1", 900, nonce="na")
        self.slurm_run("exp--j2", 900, nonce="nb")
        rc, text = self.wait("-T", "fx-slurm", "900")
        self.assertEqual(rc, USAGE, text)
        self.assertIn("900 on fx-slurm matches 2 ledger attempts", text)
        self.assertEqual(self.reads, [])


class Targets(Base):
    def test_minus_t_picks_among_that_targets_attempts(self):
        self.slurm_run("exp--x", 100)
        self.led.record_attempt(name="exp--x--a02", target="fx-box", kind="nohup", nonce="nbx", submit="submitted",
                                proc={"pid": "5", "log": "logs/exp--x--a02-20261116-100000.log", "boot_id": "b"})
        self.rounds = [{"fx-slurm": [job("100", "exp--x", "COMPLETED", rc="0:0", end=1)]}]
        rc, text = self.wait("-T", "fx-slurm", "exp--x")
        self.assertEqual(rc, OK, text)
        self.assertIn("ENDED  exp--x [fx-slurm] rc=0", text)
        self.assertEqual(self.reads[0][1], ["fx-slurm"])
        rc, text = self.wait("-T", "fx-slurm", "exp--x--a02")         # that attempt, named: not on -T
        self.assertEqual(rc, USAGE, text)
        self.assertIn("is exp--x--a02 on fx-box, not on fx-slurm (-T)", text)

    def test_partial_discovery_is_exit_5_never_the_readable_subset(self):
        self.rounds = [{"fx-slurm": [job("700", "free--x", "COMPLETED", rc="0:0", end=1)],
                        "fx-box": ("down", "ssh exited 255: timeout")}]
        rc, text = self.wait("free--x")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertIn("fx-box could not be read (ssh exited 255: timeout)", text)
        self.assertIn("on fx-slurm it is free--x", text)
        self.assertNotIn("ENDED", text)
        self.calls.clear()
        self.rounds = [{"fx-slurm": [job("700", "free--x", "COMPLETED", rc="0:0", end=1)],
                        "fx-box": ("down", "ssh exited 255: timeout")}]
        rc, text = self.wait("-T", "fx-slurm", "free--x")               # the readable one, named: searched alone
        self.assertEqual(rc, OK, text)
        self.assertEqual(self.reads[0][1], ["fx-slurm"])


class RealTime(Base):
    """Real clocks and threads: the deadline, the heartbeat while a read hangs, queued digests, a signal mid-pool."""
    fake_clock = False

    def setUp(self) -> None:
        super().setUp()
        self.release = threading.Event()
        for k, v in (("EVERY_MIN", 0.05), ("DEADLINE_MIN", 0.05)):
            self.stack.enter_context(mock.patch.object(W, k, v))

    def tearDown(self) -> None:
        self.release.set()
        super().tearDown()

    def test_heartbeat_and_start_line_while_the_first_read_hangs(self):
        self.slurm_run("exp--hb", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--hb", "COMPLETED", rc="0:0", end=1)]}]
        seen = []

        def slow():
            seen.append(sys.stdout.getvalue())
            self.release.wait(1.0)
        self.read_hook = slow
        t = _time.monotonic()
        rc, text = self.wait("exp--hb", "--heartbeat", "0.2", "--every", "0.5")
        self.assertEqual(rc, OK, text)
        self.assertGreaterEqual(_time.monotonic() - t, 0.9)
        self.assertTrue(seen[0].startswith("rsk wait: 1 run(s) — read every 0.5s (read-only)\n"
                                           "targets: fx-slurm (1 run(s))\n"), seen)     # printed before the read
        before = text[:text.index("ENDED")]
        self.assertGreaterEqual(before.count("waiting: 1 of 1 still running"), 3, text)
        self.assertIn("exp--hb [fx-slurm]: not read yet", before)

    def test_a_name_resolving_while_the_read_hangs_is_listed(self):
        self.rounds = [{"fx-slurm": [job("700", "free--x", "COMPLETED", rc="0:0", end=1)], "fx-box": []}]
        self.read_hook = lambda: self.release.wait(0.6)
        rc, text = self.wait("free--x", "--heartbeat", "0.2")
        self.assertEqual(rc, OK, text)
        ls = self.lines(text)
        self.assertEqual(ls[:2], ["rsk wait: 1 run(s) — read every 60s (read-only)", "targets: fx-box, fx-slurm (1 run(s))"])
        self.assertIn("waiting: 1 of 1 still running (0s) — free--x [fx-box, fx-slurm]: resolving (first read)", ls)
        self.assertIn("resolved: free--x -> free--x [fx-slurm]", ls)
        self.assertLess(ls.index("resolved: free--x -> free--x [fx-slurm]"),
                        [k for k, ln in enumerate(ls) if ln.startswith("ENDED")][0])

    def test_one_deadline_for_the_whole_command(self):
        self.slurm_run("exp--dl", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--dl", "RUNNING")]}]
        self.read_hook = lambda: self.release.wait(30)
        t = _time.monotonic()
        rc, text = self.wait("exp--dl", "--timeout", "0.8", "--heartbeat", "100")
        took = _time.monotonic() - t
        self.assertEqual(rc, UNKNOWN, text)
        self.assertLess(took, 1.6, text)                             # not --deadline (60 s) and not 0.8 + a read
        self.assertIn("TIMEOUT after 0.8s: 1 of 1 not ended — exp--dl [fx-slurm]: not read yet", text)
        self.assertLessEqual(self.deadlines[0], 0.8)                 # the read got what was left, never the full --timeout

    def test_target_discovery_gets_what_is_left_of_the_timeout(self):
        self.slurm_run("exp--disc", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--disc", "COMPLETED", rc="0:0", end=1)]}]
        real, given = harness.places, []

        def spy(src, proj, timeout=60):
            given.append(timeout)
            return real(src, proj, timeout=timeout)
        with mock.patch.object(harness, "places", spy):
            rc, text = self.wait("exp--disc", "--timeout", "5")
        self.assertEqual(rc, OK, text)
        self.assertLessEqual(given[0], 5)                            # never its own 60 s beside a 5 s --timeout

        def hang(src, proj, timeout=60):
            given.append(timeout)
            raise subprocess.TimeoutExpired("bash", timeout)
        with mock.patch.object(harness, "places", hang):
            rc, text = self.wait("exp--disc", "--timeout", "0.5")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertLessEqual(given[-1], 0.5)
        self.assertIn("the local target discovery gave no answer", text)
        self.assertNotIn("ENDED", text)

    def test_start_line_and_heartbeat_while_target_discovery_blocks(self):   # finding 6
        self.slurm_run("exp--disc6", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--disc6", "COMPLETED", rc="0:0", end=1)]}]
        real, seen = harness.places, []

        def slow(src, proj, timeout=60):
            seen.append(sys.stdout.getvalue())
            self.release.wait(0.8)
            return real(src, proj, timeout=timeout)
        with mock.patch.object(harness, "places", slow):
            rc, text = self.wait("exp--disc6", "--heartbeat", "0.2")
        self.assertEqual(rc, OK, text)
        self.assertEqual(seen[0], "rsk wait: 1 run(s) — read every 60s (read-only)\n")   # before discovery started
        before = text[:text.index("targets:")]
        self.assertGreaterEqual(before.count("waiting: 1 of 1 still running"), 2, text)
        self.assertIn("exp--disc6: resolving (target discovery)", before)

    def test_a_ledger_read_that_blocks_never_holds_the_heartbeat_or_the_timeout(self):   # finding 6
        self.slurm_run("exp--lst", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--lst", "RUNNING")]}]
        real, n = L.Ledger.state, []

        def state(led, *a, **k):
            n.append(1)
            if len(n) > 1:                                           # the round's ledger read: hangs
                self.release.wait(30)
            return real(led, *a, **k)
        t = _time.monotonic()
        with mock.patch.object(L.Ledger, "state", state):
            rc, text = self.wait("exp--lst", "--heartbeat", "0.2", "--timeout", "1")
        self.assertEqual(rc, UNKNOWN, text)
        self.assertLess(_time.monotonic() - t, 1.7, text)
        self.assertGreaterEqual(text.count("waiting: 1 of 1 still running"), 3, text)
        self.assertIn("TIMEOUT after 1s: 1 of 1 not ended — exp--lst [fx-slurm]: not read yet", text)

    def test_a_ledger_write_never_outlives_the_deadline(self):   # finding 7
        self.slurm_run("exp--lk", 100)
        self.rounds = [{"fx-slurm": [job("100", "exp--lk", "COMPLETED", rc="0:0", end=1)]}]
        self.stack.enter_context(mock.patch.object(W, "RECORD_NEED", 0.05))
        held = threading.Event()

        def holder():
            with self.led.locked():
                held.set()
                self.release.wait(30)
        threading.Thread(target=holder, daemon=True).start()
        held.wait(5)
        t = _time.monotonic()
        rc, text = self.wait("exp--lk", "--timeout", "1")
        took = _time.monotonic() - t
        self.release.set()
        _time.sleep(0.3)
        self.assertLess(took, 1.7, text)                             # not the lock's own 5 s
        self.assertEqual(rc, UNKNOWN, text)
        self.assertNotIn("ENDED", text)
        sub = self.led.read_run("exp--lk").data["attempts"]["a01"]["submissions"][0]
        self.assertEqual((sub.get("end"), sub.get("obs_w")), (None, None))   # nothing written, then or later

    def ten_ended(self):
        for k in range(10):
            self.slurm_run(f"exp--d{k}", 300 + k)
        self.rounds = [{"fx-slurm": [job(str(300 + k), f"exp--d{k}", "COMPLETED", rc="0:0", end=1) for k in range(10)]}]
        return [f"exp--d{k}" for k in range(10)]

    def test_queued_digests_get_what_is_left_when_they_start(self):
        names = self.ten_ended()
        starts = []

        def slow_digest(procs, place, key, wait=60.0):
            with self.lock:
                starts.append((_time.monotonic(), wait))
            _time.sleep(0.5)
            return {"text": "no hints", "log": f"/r/proj/logs/x_{key}.out", "rc": ""}
        t = _time.monotonic()
        with mock.patch.object(W, "digest", slow_digest):
            rc, text = self.wait(*names, "--timeout", "3")
        self.assertEqual(rc, OK, text)
        self.assertEqual(len(starts), 10)
        self.assertLess(_time.monotonic() - t, 2.5)
        starts.sort()
        first, late = starts[:8], starts[8:]
        self.assertGreaterEqual(late[0][0] - first[0][0], 0.45)       # 8 at a time: the 9th waited for a worker
        limits = [s + w for s, w in starts]                          # start + its wait = one deadline for all
        self.assertLess(max(limits) - min(limits), 0.1, starts)
        self.assertLess(late[0][1], first[0][1] - 0.4)

    def test_a_digest_queued_past_the_deadline_is_never_started(self):
        names = self.ten_ended()
        starts = []

        def slow_digest(procs, place, key, wait=60.0):
            with self.lock:
                starts.append(key)
            self.release.wait(30)               # a hung read: never answers within the wait
            return {"text": "no hints", "log": "", "rc": ""}
        with mock.patch.object(W, "digest", slow_digest):
            rc, text = self.wait(*names, "--timeout", "1.2")
        _time.sleep(0.3)
        self.assertEqual(len(starts), 8, starts)                     # the 2 queued ones never ran
        self.assertEqual(len([ln for ln in text.splitlines() if ln.startswith("ENDED")]), 10, text)
        self.assertEqual(text.count("no digest (cut at --timeout)"), 10, text)   # the 8 hung up to the deadline
        self.assertEqual(rc, OK, text)                               # every end came from a good read

    def test_sigterm_mid_pool_terminates_reaps_and_spawns_nothing_after(self):
        names = self.ten_ended()
        spawned: list[subprocess.Popen] = []
        real_popen = W._popen

        def counting(*a, **k):
            p = real_popen(*a, **k)
            with self.lock:
                spawned.append(p)
            return p
        self.stack.enter_context(mock.patch.object(W, "_popen", counting))
        self.stack.enter_context(mock.patch.object(W, "_ssh_argv", lambda place, dl: ["sleep", "30"]))
        self.stack.enter_context(mock.patch.object(W, "digest", REAL_DIGEST))

        def term_when_busy():
            for _ in range(200):
                with self.lock:
                    if len(spawned) >= 8:
                        break
                _time.sleep(0.02)
            os.kill(os.getpid(), signal.SIGTERM)
        threading.Thread(target=term_when_busy, daemon=True).start()
        t = _time.monotonic()
        rc, text = self.wait(*names)
        self.assertEqual(rc, INTERRUPTED, text)
        self.assertLess(_time.monotonic() - t, 6)
        _time.sleep(0.5)
        self.assertEqual(len(spawned), 8, text)                      # the 2 queued digests started no ssh
        self.assertTrue(all(p.returncode is not None for p in spawned), [p.returncode for p in spawned])
        self.assertEqual(text.count("ENDED  exp--d"), 10, text)    # ends a good read showed, their digests cut
        self.assertEqual(text.count("no digest (interrupted)"), 10, text)
        self.assertIn("\ninterrupted: 0 of 10 not ended\n", text)
        self.assertNotIn("Traceback", text)


REAL_DIGEST = W.digest


class Digest(unittest.TestCase):
    def test_one_line_from_status_sh(self):
        text = ("observed=2026-11-16T10:00:00 proj=/r/proj\ntarget=fx kind=slurm\n"
                "job=7 state=FAILED exit=1:0 elapsed=00:01:00 end=x (sacct; gone from the queue)\n"
                "log=/r/proj/logs/a_7.out bytes=900 age=5s\nstarts=1 restart=0 footer=EXIT rc=1 x\n"
                "scan=full hints: traceback=1 oom=0 nonfinite=0 error=3   (window-scoped line counts)\n"
                "last_hint=RuntimeError: x\nwandb=none (…)\ntail: " + "y" * 300 + "\n")
        d = W.parse_digest(text)
        self.assertEqual(d["log"], "/r/proj/logs/a_7.out")
        self.assertTrue(d["text"].startswith("traceback=1 error=3 — yyy"))
        self.assertEqual(len(d["text"]), W.DIGEST_CUT)
        self.assertTrue(d["text"].endswith("…"))
        d = W.parse_digest("log=/p/logs/b.log bytes=1 age=1s\nscan=full hints: traceback=0 oom=0 nonfinite=0 error=0  x\n"
                           "proc=gone pid=12 exit=0 term=0 (the log's EXIT footer)\ntail: done\n")
        self.assertEqual((d["text"], d["rc"]), ("no hints — done", "0"))
        self.assertEqual(W.parse_digest("job=1 state=unknown\nlog=none (logs/<name>_1.out appears …)\n")["text"],
                         "log none (logs/<name>_1.out appears …)")


if __name__ == "__main__":
    unittest.main()
