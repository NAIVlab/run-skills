"""`rsk watch TABLE… [run-watch flags]`: bin/run-watch under the project's watch lease.

    rsk watch [-C DIR] TABLE... [--act] [--once] [--every S] [--for S] [--stall-after S] [--max-active N]
              [--release NAME] [--adopt NAME=JOBID]
    rsk watch [-C DIR] TABLE --approve "the user's words"

One watcher per project: the lease (the ledger's watch.lease: pid, host, boot_id, started, until) is taken first — a
live lease of another process (or one on another host / boot, until it expires) → exit 6, run-watch never starts; so
is a run-watch that still holds logs/run-watch/.lock and runs on this host (an orphan whose rsk watch was killed) →
exit 6 naming it. Then the harness's bin/run-watch runs with every other argument unchanged (bash stays the one
implementation; cwd = the project, so TABLE paths are relative to it), and the lease is released when it ends — also
on SIGTERM / SIGINT / SIGHUP, which are passed on to run-watch first. `until` = now + --for (run-watch's lease, default
7200 s; the last --for / --every given wins, as in run-watch) + one round (--every, default 300 s) + 15 min of slack
for a last submit, and while run-watch runs rsk moves it forward every minute to now + one round + the slack (a long
last round never outlives its lease); `rsk status` shows the lease and a live run-watch lock holder.
Denies bind run-watch too: with --act (and --approve), every row of every table (target, -p, -g, -t, name / run id,
class) is checked against the ledger's denies for EVERY action run-watch could take on it — launch, relaunch,
resubmit, chain, cancel — whatever its `#@ allow` line says (--release launches or resubmits a row outside it, a conf
SBATCH_EXTRA singleton makes a launch a chain): a match → exit 3 with the deny's quote, nothing started (--approve: no
`#@ ok` written); and again on every lease refresh — a new matching deny → run-watch gets TERM, exit 3. What a row
cannot show counts as matching (fail closed): its GPU type (the partition's policy may force one: a GPU-type deny
matches every row of its target), its partition (the target's t_policy may rewrite -p: a partition deny matches every
Slurm row of its target), its plan (no bound hash: a deny of plans matches every row in its scope). A damaged record that may be a deny matches every row; an unreadable grants.json → exit 6
("grants unreadable"), before anything starts and on a refresh (run-watch gets TERM).
run-watch runs with RS_VIA_RSK=1 and RS_WATCH_PARENT=<this rsk's pid>, as its direct child: in every mode it stops
(exit 7, LEASE_ENDED: nothing more submitted or cancelled, its lock released) once that pid is gone or is no longer its
parent — a run-watch whose rsk watch was killed outright stops at its next check (start, each round, after each read,
before each submit or cancel ssh), never holding the lock for the rest of --for.
Exit: run-watch's, with its 3 (lease over, or --once with rows still moving) as rsk's 7 (LEASE_ENDED); 0 every row
done, 2 table/conf error, 3 a deny matches a row, 4 the rest waits on the user; 6 another watcher holds the lease or
the run-watch lock (rsk's check above, or run-watch's own: a live holder here, or any holder on another host — its
pid, host, start and act printed, nothing run), or grants.json cannot be read. Numeric flags are read as run-watch
reads them: base 10, leading zeros dropped, at most 9 significant digits.
"""

from __future__ import annotations

import argparse
import os
import re
import signal
import socket
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path

from remote_run import grants, harness, paths
from remote_run import ledger as L
from remote_run.errors import CONFLICT, LEASE_ENDED, REFUSED, USAGE, RskError

FOR_DEFAULT, EVERY_DEFAULT, SLACK = 7200, 300, 900
REFRESH_S = 60                     # how often the lease's `until` moves forward while run-watch runs
RC_MAP = {3: LEASE_ENDED}          # run-watch's exit -> rsk's (the others mean the same in both)
VALUE_FLAGS = ("--every", "--for", "--stall-after", "--max-active", "--release", "--adopt", "--approve")
LOCK = Path("logs/run-watch/.lock")   # bin/run-watch's lock dir: pid (alone) + info "host started act"


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
    """The value of the LAST FLAG in ARGV (run-watch's parser: a later one overrides), DEFAULT without one — read as
    run-watch's dec10 reads it (ASCII digits, base 10, leading zeros dropped, <= 9 significant digits; anything else
    is run-watch's usage error, exit 2: DEFAULT here)."""
    v = default
    for i, w in enumerate(argv[:-1]):
        if w == flag:
            v = int(argv[i + 1]) if re.fullmatch(r"0*[0-9]{1,9}", argv[i + 1]) else default
    return v


def tables(argv: list[str]) -> list[str]:
    """The TABLE words of a run-watch argv (its own grammar: every flag in VALUE_FLAGS takes the next word)."""
    out, i = [], 0
    while i < len(argv):
        w = argv[i]
        if w in VALUE_FLAGS:
            i += 2
            continue
        if not w.startswith("-"):
            out.append(w)
        i += 1
    return out


def table_rows(path: Path, kinds: dict[str, str]) -> tuple[set[str], list[dict]]:
    """(the actions the table's `#@ allow` line lets run-watch take, one plan-like dict per row) — read only to check
    denies (run-watch parses and validates the table itself). Row: `name target done submit-words` (-p -g -G -t …
    before `--`), `#@ allow launch preempt=N errors=N timeout=N fail-stop`. A row's GPU type and partition are left
    unknown (the -G / -p words are kept as asked_gtype / asked_partition, for the message): the target's policy may
    force a GPU type or rewrite the partition. An unreadable file → no rows (run-watch refuses it)."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return set(), []
    acts: set[str] = set()
    rows: list[dict] = []
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if line.startswith("#@ allow"):
            for w in line.split()[2:]:
                key, _, val = w.partition("=")
                if key == "launch":
                    acts.add("launch")
                elif key in ("preempt", "errors", "timeout") and val.isdigit() and int(val, 10) > 0:
                    acts |= {"resubmit", "relaunch"}
                elif key == "fail-stop":
                    acts.add("cancel")
            continue
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = line.split()
        if len(f) < 3:
            continue
        name, tgt, words = f[0], f[1], f[3:]
        opt: dict[str, str] = {}
        i = 0
        while i < len(words) and words[i] != "--":
            if words[i] in ("-p", "-g", "-G", "-t") and i + 1 < len(words):
                opt[words[i]] = words[i + 1]
                i += 2
                continue
            i += 1
        plan = {"target": tgt, "kind": kinds.get(tgt, ""), "name": name, "warnings": "0"}
        if "-p" in opt:                  # asked, never certain: t_policy may rewrite PART (policy.sh API) — any
            plan["asked_partition"] = opt["-p"]   # partition, so a partition deny matches it (fail closed)
        if "-G" in opt or "-g" in opt:   # the count only: the GPU type is never certain here (the partition's policy may
            plan["gres"] = f"gpu:{opt.get('-g', '1')}"   # force one: P_GTYPE) — any type, so a GPU-type deny matches it
            plan["asked_gtype"] = opt.get("-G", "")
        if "-t" in opt:
            plan["time"] = opt["-t"]
        rows.append(plan)
    return acts, rows


ROW_ACTIONS = ("launch", "relaunch", "resubmit", "chain", "cancel")   # what run-watch may do to any row (R4-4; chain:
                                                                      # Slurm rows, or a target of unknown kind)


def deny_hit(led: L.Ledger, proj: Path, argv: list[str], kinds: dict[str, str]) -> str:
    """'' unless a deny in the ledger matches a row of the tables in ARGV for ANY action run-watch could take on it
    (ROW_ACTIONS, whatever the `#@ allow` line says: --release, an SBATCH_EXTRA singleton); else the line saying which
    (row, action, deny id, quote, and why an unknown fact of the row matched). A grants.json that cannot be read →
    RskError(CONFLICT): no deny can be ruled out."""
    st = led.state()
    bad = grants.unreadable(st)
    if bad:
        raise RskError(bad, CONFLICT)
    for t in tables(argv):
        _acts, rows = table_rows(proj / t, kinds)
        for row in rows:
            row = {**row, "classes_recorded": grants.run_classes(st.runs.get(L.run_id(row["name"])))}
            for a in ROW_ACTIONS:
                if a == "chain" and row["kind"] == "nohup":   # a workstation launch is never a singleton chain
                    continue
                d, why, _own = grants.deny_match(row, (a,), st, job=None)
                if d:
                    sc = d.get("scope") or {}
                    notes = []
                    if sc.get("gpu_types") and row["kind"] == "nohup":
                        notes.append("a workstation row names no GPU type: a GPU-type deny matches every row of its "
                                     "target")
                    elif sc.get("gpu_types"):
                        notes.append("the row's GPU type is not certain here (" + (f"it asks -G {row['asked_gtype']}, "
                                     if row.get("asked_gtype") else "") + "but the partition's policy may force one): "
                                     "a GPU-type deny matches every row of its target")
                    if sc.get("partitions") and row["kind"] != "nohup":
                        notes.append("the row's partition is not certain here (" + (
                                     f"it asks -p {row['asked_partition']}, " if row.get("asked_partition") else "")
                                     + "but the target's policy may rewrite it): a partition deny matches every row "
                                     "of its target")
                    if sc.get("runs") or sc.get("plans"):
                        notes.append("a row has no plan (bound hash) to compare: a deny of plans matches every row in "
                                     "its scope")
                    return (f"{t}: row {row['name']} on {row['target']} ({a}): {why}"
                            + (" — " + "; ".join(notes) if notes else ""))
    return ""


def lock_holder(proj: Path) -> dict | None:
    """bin/run-watch's lock in PROJ (logs/run-watch/.lock): {pid, host, started, act, alive} — alive: its pid runs on
    this host (another host's cannot be checked: alive None). None without a lock."""
    d = proj / LOCK
    if not d.is_dir():
        return None
    try:
        pid = (d / "pid").read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        pid = ""
    try:
        info = (d / "info").read_text(encoding="utf-8", errors="replace").split()
    except OSError:
        info = []
    host = info[0] if info else ""
    alive: bool | None = None
    if host and host != socket.gethostname() and host != os.uname().nodename:
        alive = None
    elif pid.isdigit() and int(pid) > 0:
        alive = L._alive(int(pid))
    else:
        alive = False
    return {"pid": pid, "host": host, "started": info[1] if len(info) > 1 else "",
            "act": info[2] if len(info) > 2 else "", "alive": alive}


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


def run_watch(led: L.Ledger, argv: list[str], cwd: str, env: dict[str, str], cmd: list[str] | None = None,
              guard: Callable[[], str] | None = None) -> int:
    """Take the lease, run CMD (default: bash bin/run-watch ARGV), release the lease however it ends. GUARD: '' or why
    run-watch must not act (a deny matching a row) — asked before anything starts (→ exit 3) and on every refresh
    (→ TERM to run-watch, exit 3)."""
    if guard is not None:
        why = guard()
        if why:
            print(f"denied: {why}", flush=True)
            raise RskError(f"a deny matches a row of the table(s): nothing started — {why}", REFUSED)
    h = lock_holder(Path(cwd))
    if h and h["alive"]:
        raise RskError(f"a run-watch still holds {LOCK}: pid {h['pid']} on {h['host'] or 'this host'} since "
                       f"{h['started'] or '?'} (act={h['act'] or '?'}), alive here — its rsk watch lease is gone (an "
                       "orphan); one watcher per project: stop it (with the user's OK) or let it end first", CONFLICT)
    led.take_lease(until_of(argv), argv)
    child: subprocess.Popen | None = None
    got: list[int] = []
    old = {}
    denied, denied_code = "", REFUSED

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
                if guard is not None:
                    try:
                        denied = guard()
                    except RskError as exc:                # grants.json unreadable (exit 6) …
                        denied, denied_code = f"the ledger's denies cannot be read ({exc})", exc.code
                    except OSError as exc:                 # … or the ledger itself: never act unchecked
                        denied = f"the ledger's denies cannot be read ({exc})"
                    if denied:
                        print(f"denied: {denied} — run-watch gets TERM", flush=True)
                        child.terminate()
                        try:
                            rc = child.wait(timeout=30)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            rc = child.wait()
                        break
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
    if denied:
        raise RskError(f"a deny now matches a row: run-watch was stopped (TERM) — {denied}" if denied_code == REFUSED
                       else f"run-watch was stopped (TERM) — {denied}", denied_code)
    if rc < 0:                     # killed by a signal: the shell's 128+N
        return 128 - rc
    return RC_MAP.get(rc, rc)


def cmd_watch(args: argparse.Namespace) -> int:
    from remote_run.status import project_dir
    argv = list(getattr(args, "extra", []) or [])
    if argv[:1] == ["--"]:
        argv = argv[1:]
    proj = project_dir(args.dir)
    src = paths.harness_src()
    env = harness.env(src)
    env["RS_VIA_RSK"] = "1"
    env["RS_WATCH_PARENT"] = str(os.getpid())    # run-watch stops (exit 7) once this rsk is gone (R4-7): Popen it directly
    for k in ("CLUSTER", "STATION", "TARGET"):
        env.pop(k, None)
    led = L.Ledger(proj)
    guard = None
    if "--act" in argv or "--approve" in argv:
        kinds = {t.name: t.kind for t in harness.targets(src)}
        guard = lambda: deny_hit(led, proj, argv, kinds)   # noqa: E731
    return run_watch(led, argv, str(proj), env, guard=guard)


def add_parser(sub) -> None:
    p = sub.add_parser("watch", allow_abbrev=False, help="bin/run-watch under the project's watch lease (one watcher "
                       "per project); every other argument goes to run-watch unchanged",
                       description=__doc__.split("\n\n")[0], epilog=__doc__.split("\n\n", 1)[1],
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory); TABLE paths "
                   "are relative to it")
    p.set_defaults(func=cmd_watch, passthrough=True)
