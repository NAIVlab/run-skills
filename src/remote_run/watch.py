"""`rsk watch TABLE… [run-watch flags]`: bin/run-watch under the project's watch lease.

    rsk watch [-C DIR] TABLE... [--act] [--once] [--every S] [--for S] [--stall-after S] [--max-active N]
              [--release NAME] [--adopt NAME=JOBID]
    rsk watch [-C DIR] TABLE --approve "the user's words"

One watcher per project: the lease (the ledger's watch.lease: pid, host, boot_id, started, until) is taken first — a
live lease of another process (or one on another host / boot, until it expires) → exit 6, run-watch never starts. Then
the harness's bin/run-watch runs with every other argument unchanged (bash stays the one implementation; cwd = the
project, so TABLE paths are relative to it), and the lease is released when it ends — also on SIGTERM / SIGINT /
SIGHUP, which are passed on to run-watch first. `until` = now + --for (run-watch's lease, default 7200 s; the last
--for / --every given wins, as in run-watch) + one round (--every, default 300 s) + 15 min of slack for a last submit,
and while run-watch runs rsk moves it forward every minute to now + one round + the slack (a long last round never
outlives its lease); `rsk status` shows the lease.
Exit: run-watch's, with its 3 (lease over, or --once with rows still moving) as rsk's 7 (LEASE_ENDED); 0 every row
done, 2 table/conf/lock error, 4 the rest waits on the user; 6 another watcher holds the lease.
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time

from remote_run import harness, paths
from remote_run import ledger as L
from remote_run.errors import LEASE_ENDED, USAGE, RskError

FOR_DEFAULT, EVERY_DEFAULT, SLACK = 7200, 300, 900
REFRESH_S = 60                     # how often the lease's `until` moves forward while run-watch runs
RC_MAP = {3: LEASE_ENDED}          # run-watch's exit -> rsk's (the others mean the same in both)


def until_of(argv: list[str], now: float | None = None) -> float:
    """When the lease ends: run-watch's own --for, one more round, slack ( --approve: a few minutes)."""
    t = time.time() if now is None else now
    if "--approve" in argv:
        return t + 300
    def num(flag: str, default: int) -> int:
        return last(argv, flag, default)
    if "--once" in argv:
        return t + SLACK + num("--every", EVERY_DEFAULT)
    return t + num("--for", FOR_DEFAULT) + num("--every", EVERY_DEFAULT) + SLACK


def last(argv: list[str], flag: str, default: int) -> int:
    """The value of the LAST FLAG in ARGV (run-watch's parser: a later one overrides), DEFAULT without one."""
    v = default
    for i, w in enumerate(argv[:-1]):
        if w == flag:
            v = int(argv[i + 1]) if argv[i + 1].isdigit() else default
    return v


def _foreground() -> bool:
    try:
        return os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp()
    except OSError:
        return False


def script() -> str:
    s = paths.harness_src() / "bin" / "run-watch"
    if not s.is_file():
        raise RskError(f"{s} is missing (a broken install?)", USAGE)
    return str(s)


def run_watch(led: L.Ledger, argv: list[str], cwd: str, env: dict[str, str], cmd: list[str] | None = None) -> int:
    """Take the lease, run CMD (default: bash bin/run-watch ARGV), release the lease however it ends."""
    led.take_lease(until_of(argv), argv)
    child: subprocess.Popen | None = None
    got: list[int] = []
    old = {}

    def forward(signum, _frame) -> None:
        got.append(signum)
        if signum == signal.SIGINT and _foreground():
            return                 # a Ctrl-C reached run-watch too (one foreground group): never deliver it twice
        if child is not None and child.poll() is None:
            try:
                child.send_signal(signum)
            except OSError:
                pass

    try:
        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            old[s] = signal.signal(s, forward)
        sys.stdout.flush()
        sys.stderr.flush()
        child = subprocess.Popen(cmd or ["bash", script(), *argv], cwd=cwd, env=env)
        if got:                    # a signal that came while it was starting: it gets it now
            forward(got[-1], None)
        round_s = last(argv, "--every", EVERY_DEFAULT) + SLACK
        while True:
            try:
                rc = child.wait(timeout=REFRESH_S)
                break
            except subprocess.TimeoutExpired:   # still running: its lease covers one more round from now
                led.refresh_lease(time.time() + round_s)
            except InterruptedError:   # (PEP 475 retries; kept for clarity)
                continue
    finally:
        if child is not None and child.poll() is None:   # rsk itself is going down: never leave a watcher unleased
            child.terminate()
            try:
                child.wait(timeout=30)
            except subprocess.TimeoutExpired:
                child.kill()
        led.release_lease()
        for s, h in old.items():
            signal.signal(s, h)
    if rc < 0:                     # killed by a signal: the shell's 128+N
        return 128 - rc
    return RC_MAP.get(rc, rc)


def cmd_watch(args: argparse.Namespace) -> int:
    from remote_run.status import project_dir
    argv = list(getattr(args, "extra", []) or [])
    if argv[:1] == ["--"]:
        argv = argv[1:]
    proj = project_dir(args.dir)
    env = harness.env(paths.harness_src())
    env["RS_VIA_RSK"] = "1"
    for k in ("CLUSTER", "STATION", "TARGET"):
        env.pop(k, None)
    return run_watch(L.Ledger(proj), argv, str(proj), env)


def add_parser(sub) -> None:
    p = sub.add_parser("watch", allow_abbrev=False, help="bin/run-watch under the project's watch lease (one watcher "
                       "per project); every other argument goes to run-watch unchanged",
                       description=__doc__.split("\n\n")[0], epilog=__doc__.split("\n\n", 1)[1],
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory); TABLE paths "
                   "are relative to it")
    p.set_defaults(func=cmd_watch, passthrough=True)
