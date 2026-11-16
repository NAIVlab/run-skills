"""`rsk wait`: wait, read-only, until runs end — one stdout line per event, then a verdict line.

    rsk wait [-C DIR] [-T TARGET]... RUN... [--timeout S] [--every S] [--heartbeat S] [--json]
    rsk wait [-C DIR] [-T TARGET]... --all-live [...]

RUN is a run id or name the ledger knows (an attempt name <run>--aNN = that attempt, a run id = its latest attempt on
the -T targets), or, with exactly one -T, a Slurm job id / workstation pid / log path of this project, or a job name the
first read of the targets shows. A name the ledger does not hold is looked up on every searched target: one that cannot
be read makes the answer incomplete = exit 5 (name the readable one with -T), never the readable subset. A pid is
resolved against the first read and the ledger's launches of that pid: the live process under it is a launch's only
with that launch's log, boot_id AND /proc start (a pid alone proves nothing); two candidates, two logs naming it, or an
identity that cannot be read or does not match = exit 2, naming them. Every RUN is resolved before anything is waited
for: unknown or ambiguous = exit 2.

Each round is `rsk status`'s own read (observe.script + observe.parse: one read-only ssh per involved target, in
parallel, observe.FS_WAIT for a hung mount; the ledger reconciled through status.record()) — only the targets holding
the waited runs. A failed read is UNOBSERVABLE, never "ended". An ended run gets one bounded extra read: `rsk logs`'
digest (the deployed status.sh, -n 1) cut to one line; the digests of one round are read in parallel (8 at a time).
Rounds every --every s (2x after 30 min without a change of state, at most 600 s).

--timeout is ONE deadline for the whole command, from its start: target discovery, the ledger's reads, every read,
the ledger's write (its lock wait included; no change is written after the deadline or a signal) and every digest get
what is left of it when they start (and a read at most --deadline); nothing starts after it. The main thread only
supervises — the start line comes before anything that may block, and the heartbeat and the TIMEOUT line come on time
while discovery, the ledger or a read hangs.

When is a run ENDED? Only on evidence from a good read of its target made during this wait, as the ledger's
reconciliation accepted it (status.reconcile + ledger.apply_observation, each read ordered by its window [ssh start,
answer]: a read older than the one the ledger holds is dropped, one overlapping it that disagrees — live vs ended —
leaves the submission UNCERTAIN until a strictly newer read decides; a fresh live sighting beats an end the ledger
cached: a requeued job is waited for). An attempt ends only when none of its submissions may still be live, and each
one's recorded state rests on this round's read (or a newer one), or that complete read (no partial section) does not
list it (a live Slurm job is in squeue, a live box run has its logs/*.pid) — and never while that read shows one of its
submissions live (_live_here: an end the ledger holds as newer is not taken against it). While the target cannot be read, such a run
shows as `<STATE> per the ledger, unverified` and is never reported; at --timeout it is listed, exit 5. Only an
attempt that was never submitted (no job / log exists to read) is reported from the ledger alone (FAILED
state=NOT_SUBMITTED).

Lines (flushed, none repeated):

    rsk wait: N run(s) — read every Ss … (read-only)                    (first, before anything that may block)
    targets: <targets> (N run(s))                                       (once discovery and the ledger resolved them)
    resolved: <RUN> -> <name> [<target>]                                (a RUN the first read resolved)
    ENDED  <name> [<target>] rc=0 <digest> log <path>
    FAILED <name> [<target>] state=<S> rc=<N> <digest> log <path>
    UNOBSERVABLE <target>: <why>          OBSERVABLE again <target>
    waiting: K of N still running (<elapsed>) — <name> [<target>]: <state>, …   (after the first round, then every
                                          --heartbeat s, also while discovery, the ledger or a read is in flight;
                                          <state> UNCERTAIN (<why>; the next read decides) = reads disagree)
    TIMEOUT after <S>s: K of N not ended — …        interrupted: K of N not ended — …

Exit: 0 every run ended rc 0 · 1 any other end · 2 usage / an unknown or ambiguous RUN · 5 --timeout reached (or a RUN
that could not be resolved because a target is unreadable) · 130 SIGINT / SIGTERM (every ssh it started is terminated
and reaped, none is started after). Never submits, cancels or writes on a target; no grant check (like rsk status).
The ledger is written as rsk status writes it.
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import time as _wall          # real time for reaping children (tests replace `time` with a fake clock)
from concurrent import futures
from dataclasses import dataclass, field

from remote_run import harness, observe, paths
from remote_run import ledger as L
from remote_run import status as S
from remote_run.errors import FAILED, INTERRUPTED, OK, UNKNOWN, USAGE, RskError

EVERY = 60               # s between rounds (default)
EVERY_MIN = 10
EVERY_MAX = 600          # never slower than this, backoff included
HEARTBEAT = 300          # s between `waiting:` lines (default)
BACKOFF_AFTER = 1800     # s without any change: rounds every 2 × --every (at most EVERY_MAX)
DIGEST_CUT = 160         # characters of the one-line digest
DIGEST_WAIT = 60.0       # s for the digest read of one ended run
LIST_MAX = 20            # runs named in one waiting / timeout line
DEADLINE = 60.0          # s per target and round before it is UNOBSERVABLE
DEADLINE_MIN = 1.0
DISCOVERY_WAIT = 60.0    # s for the local target discovery (harness.places)
RECORD_NEED = 6.0        # s left that writing the ledger needs (status.record waits up to 5 s for its lock); less: in
                         # memory only, this round
WORKERS = 8              # reads / digests at a time
STOP_GRACE = 2.0         # s a terminated ssh gets before it is killed


def out(msg: str) -> None:
    print(msg, flush=True)


@dataclass
class Item:
    """One waited attempt (a ledger attempt, or a job / log of this project the ledger does not hold)."""
    label: str                  # what the lines name: the attempt's name, else the job's
    target: str
    kind: str = ""
    run: str = ""               # the ledger run id ('' = not in the ledger)
    aid: str = ""
    key: str = ""               # Slurm job id / nohup log ('' while SUBMIT_UNKNOWN)
    state: str = "?"            # the last known state ('?' = not read yet)
    detail: str = ""            # cheap extra for the heartbeat (up 1h, a pending reason)
    done: bool = False
    end: dict = field(default_factory=dict)
    word: str = ""              # a placeholder for a RUN the first read resolves (replaced then)


@dataclass
class Deferred:
    """A RUN only the first read can resolve: a name the ledger does not hold, a job id / log it does not hold, a pid."""
    word: str
    cands: list = field(default_factory=list)   # pid: [(Item, submission)] the ledger's launches of that pid there


# ------------------------------------------------------------------------------------------------ resolution
def _num(aid: str) -> int:
    return int(aid[1:]) if aid[1:].isdigit() else 0


def _ledger_item(run: str, aid: str, att: dict) -> Item:
    return Item(label=str(att.get("name") or run), target=str(att.get("target") or ""), kind=str(att.get("kind") or ""),
                run=run, aid=aid, key=_key(att))


def _key(att: dict) -> str:
    """The newest submission's job id / log (what the digest reads)."""
    for s in reversed(att.get("submissions") or []):
        k = s.get("job") or (s.get("proc") or {}).get("log")
        if k:
            return str(k)
    return ""


def from_ledger(runs: dict, word: str, targets: set[str] | None = None) -> Item | None:
    """WORD as the ledger knows it, among the attempts on TARGETS (None = every target): a run id (its newest attempt
    there), an attempt's exact name (the newest such attempt there), <run>--aNN (that attempt, wherever it is: the
    caller rejects one outside TARGETS)."""
    def here(att: dict) -> bool:
        return targets is None or att.get("target") in targets
    atts = {a: att for a, att in ((runs.get(word) or {}).get("attempts") or {}).items() if here(att)}
    if atts:
        a = max(atts, key=lambda k: (_num(k), k))
        return _ledger_item(word, a, atts[a])
    named = [(r, a, att) for r, rec in runs.items() for a, att in ((rec or {}).get("attempts") or {}).items()
             if att.get("name") == word and here(att)]
    if named:
        r, a, att = max(named, key=lambda x: (L.epoch(x[2].get("created_at")), _num(x[1])))
        return _ledger_item(r, a, att)
    rid, aid = L.run_id(word), L.attempt_of(word)
    atts = ((runs.get(rid) or {}).get("attempts") or {})
    if aid and aid in atts:
        return _ledger_item(rid, aid, atts[aid])
    return None


def by_key(runs: dict, word: str, target: str) -> list[tuple[Item, dict]]:
    """The ledger's submissions on TARGET whose Slurm job id, pid or log path is WORD: (attempt item, submission), one
    per attempt (a pid may have been reused: several)."""
    from remote_run.launch import rel_log
    log = rel_log(word) if "/" in word or word.endswith(".log") else ""
    hits: dict[tuple, tuple[Item, dict]] = {}
    for r, rec in runs.items():
        for a, att in ((rec or {}).get("attempts") or {}).items():
            if att.get("target") != target:
                continue
            for s in att.get("submissions") or []:
                proc = s.get("proc") or {}
                if (word.isdigit() and word in (str(s.get("job") or ""), str(proc.get("pid") or ""))) or (
                        log and log == proc.get("log")):
                    hits.setdefault((r, a), (_ledger_item(r, a, att), s))
    return list(hits.values())


def _cand_words(cands: list[tuple[Item, dict]]) -> str:
    words = []
    for it, s in cands:
        proc = s.get("proc") or {}
        words.append(f"{it.label} ({it.run} {it.aid}" + (f", log {proc['log']}" if proc.get("log") else "")
                     + (f", job {s['job']}" if s.get("job") else "") + ")")
    return "; ".join(words)


def from_observation(o: observe.Observation, word: str, keyed: bool) -> list[Item]:
    """WORD in one GOOD observation: by key (a job id, a pid alive now, a log path) or by job / run name — the live
    jobs of that name, else its newest ended one."""
    from remote_run.launch import rel_log
    if keyed:
        if word.isdigit():
            hits = [j for j in o.jobs if (o.place.kind == "slurm" and j.id == word) or
                    (o.place.kind != "slurm" and j.pid == word)]
        else:
            hits = [j for j in o.jobs if j.log and j.log == rel_log(word)]
    else:
        hits = [j for j in o.jobs if j.name == word or L.run_id(j.name) == word]
        live = [j for j in hits if not _job_ended(o.place.kind, j)]
        hits = live or sorted(hits, key=lambda j: j.end)[-1:]
    return [Item(label=j.name, target=o.place.target, kind=o.place.kind,
                 key=j.id if o.place.kind == "slurm" else j.log) for j in hits]


def resolve_pid(o: observe.Observation, word: str, cands: list[tuple[Item, dict]]) -> list[Item]:
    """A workstation pid against a GOOD read. Alive now: the process under that pid is the one meant when the ledger
    never launched that pid, or when it is a ledger launch's — the same log AND the same boot_id AND the same /proc
    start as its receipt (a pid alone proves nothing: pids are reused); with no live one, the ledger's single launch of
    that pid. Anything else — a reused pid, two logs naming it, an identity that cannot be read or does not match — is
    ambiguous: exit 2 naming the candidates."""
    t = o.place.target
    alive = [j for j in o.jobs if j.state == "ALIVE" and j.pid == word]
    if len(alive) > 1:
        raise RskError(f"rsk wait: pid {word} on {t} is ambiguous: alive under {len(alive)} logs ("
                       f"{', '.join(j.log for j in alive)}) — name the run or its log path", USAGE)
    if alive:
        j = alive[0]
        if not cands:
            return [Item(label=j.name, target=t, kind=o.place.kind, key=j.log)]
        mine = [(it, sb) for it, sb in cands if (sb.get("proc") or {}).get("log") == j.log]
        if len(mine) != 1:
            raise RskError(f"rsk wait: pid {word} on {t} is ambiguous: alive now as {j.name} (log {j.log}), and the "
                           f"ledger launched that pid before as {_cand_words(cands)} — name the run or its log path",
                           USAGE)
        it, sb = mine[0]
        proc = sb.get("proc") or {}
        boot, start = str(proc.get("boot_id") or ""), str(proc.get("start") or "")
        missing = [w for w, a, b in (("boot_id", boot, o.boot_id), ("process start", start, j.pstart)) if not a or not b]
        if missing:
            raise RskError(f"rsk wait: pid {word} on {t} is ambiguous: alive under the log of {_cand_words(mine)}, but "
                           f"its {' and '.join(missing)} cannot be compared with the launch's — name the run or its "
                           "log path", USAGE)
        if boot != o.boot_id or start != j.pstart:
            what = "boot_id" if boot != o.boot_id else "process start"
            raise RskError(f"rsk wait: pid {word} on {t} is ambiguous: alive under the log of {_cand_words(mine)}, but "
                           f"its {what} is not the launch's (another process under a reused pid) — name the run or "
                           "its log path", USAGE)
        return [it]
    if len(cands) > 1:
        raise RskError(f"rsk wait: pid {word} on {t} is ambiguous (not alive now; reused): the ledger "
                       f"launched it as {_cand_words(cands)} — name the run or its log path", USAGE)
    return [cands[0][0]] if cands else []


def _job_ended(kind: str, j: observe.Job) -> bool:
    return j.state in observe.TERMINAL if kind == "slurm" else j.state == "ENDED"


# ------------------------------------------------------------------------------------------------ judging
def _sync_runs(st: L.LedgerState, obs: list[observe.Observation]) -> dict:
    """The ledger's runs as of this round: what status.record() wrote, and — should it not have been able to write (a
    read-only state dir, too little time left, the wait stopping) — the same reconcile() applied to an in-memory copy
    under the same ordering rules (L.apply_observation / L.mark_uncertain; a no-op when it did write)."""
    runs = copy.deepcopy(st.runs)
    view = L.LedgerState(runs=runs)
    for o in obs:
        win, at = observe.obs_window(o), S._iso(o.observed_at)
        for c in S.reconcile(view, o):
            att = ((runs.get(c[1]) or {}).get("attempts") or {}).get(c[2])
            if att is None:
                continue
            if c[0] == "observe":
                L.apply_observation(att, c[3], c[4], c[5], at, end=c[6], win=win)
                continue
            if c[0] == "uncertain":
                L.mark_uncertain(att, c[3], c[4], at, c[5], c[6], win)
                continue
            for sub in att.get("submissions") or []:
                if sub.get("nonce") == c[3] and sub.get("submit") == "unknown":
                    sub.update(c[4] if c[0] == "submitted" else {"submit": "not_submitted", "evidence": c[4]})
            L._settle(att)
    return runs


def _sub_key(s: dict) -> str:
    return str(s.get("job") or (s.get("proc") or {}).get("log") or "")


def _find(o: observe.Observation | None, key: str) -> observe.Job | None:
    if o is None or not o.ok or not key:
        return None
    for j in o.jobs:
        if (o.place.kind == "slurm" and j.id == key and j.source != "pid") or (o.place.kind != "slurm" and j.log == key):
            return j
    return None


def _live_here(o: observe.Observation, kind: str, sub: dict) -> bool:
    """Does the GOOD read O show submission SUB live — its Slurm job in a live state, or its log's process alive and
    not provably another one (another boot, or the same pid with another /proc start)? Whatever the ledger's ordering
    kept (a read older than a recorded end by less than ledger.SKEW_S is dropped there: a clock that went back a little
    looks just like that), a run its own fresh read shows live is never reported ended: read again."""
    j = _find(o, _sub_key(sub))
    if j is None or _job_ended(kind, j):
        return False
    if kind == "slurm":
        return True
    proc = sub.get("proc") or {}
    boot, start = str(proc.get("boot_id") or ""), str(proc.get("start") or "")
    if boot and o.boot_id and boot != o.boot_id:
        return False
    return not (start and j.pstart and start != j.pstart)


def _detail(j: observe.Job | None, now: int) -> str:
    if j is None:
        return ""
    if j.state == "PENDING" and j.reason and j.reason != "None":
        return f"({j.reason})"
    if j.state in ("RUNNING", "ALIVE") and j.start:
        return f"up {observe.age(now - j.start)}"
    return ""


def judge(item: Item, runs: dict, o: observe.Observation | None) -> None:
    """Item's state after this round; done + end ({state, rc, at}) once it ended — on this round's evidence only (the
    rule in the module doc). A ledger attempt is judged from RUNS, the ledger as reconciled with this round's read
    under the ledger's ordering rules (_sync_runs) — never from a sighting reconciliation rejected: it ends only when
    no submission of it may still be live (L.is_live: every submission, not only the newest; an uncertain one counts
    live) and, for each submission that was submitted, this round's GOOD read is what the ledger's state of it rests
    on (its recorded window starts no earlier than this read's: this read, or a newer one) or that complete read does
    not list it. An unreadable target ends nothing; a job the ledger does not hold is judged from the read itself."""
    readable = o is not None and o.ok
    now = (o.now or int(o.observed_at)) if readable else 0
    item.detail = ""
    if item.run:
        att = ((runs.get(item.run) or {}).get("attempts") or {}).get(item.aid) or {}
        item.key = _key(att) or item.key
        if not att:
            item.state = "?"
            item.detail = "" if readable else "target UNOBSERVABLE"
            return
        subs = att.get("submissions") or []
        if L.is_live(att):
            unsure = [x["uncertain"] for x in subs if x.get("uncertain")]
            live = [j for x in subs if not x.get("end") for j in [_find(o, _sub_key(x))]
                    if j is not None and not _job_ended(item.kind, j)]
            if unsure:
                item.state = "UNCERTAIN"
                item.detail = f"({str(unsure[0].get('why', ''))[:120]}; the next read decides)"
            elif live:
                item.state, item.detail = live[0].state, _detail(live[0], now)
                k = live[0].id if item.kind == "slurm" else live[0].log
                if k != item.key:                         # another submission of the attempt is the live one
                    item.detail = (item.detail + f" ({k})").strip()
            else:
                item.state = L.attempt_state(att)
            if not readable:
                item.detail = "target UNOBSERVABLE"
            return
        res = att.get("result") or {}
        j = _find(o, item.key)
        end = {"state": str(res.get("state") or L.attempt_state(att)), "rc": str(res.get("rc") or ""),
               "at": S._iso(j.end) if j is not None and j.end and _job_ended(item.kind, j)   # the job's own end time
               else str(res.get("at") or L.now())}
        sent = [x for x in subs if _sub_key(x) and x.get("submit") != "not_submitted"]
        if not sent:                                      # never submitted: nothing exists to read
            item.done, item.end = True, end
            return
        shown_live = [x for x in sent if readable and _live_here(o, item.kind, x)]
        if readable and not shown_live:
            t0 = observe.obs_window(o)[0]

            def settled(x: dict) -> bool:
                w = L.obs_window(x)
                if w is not None and w[0] >= t0:          # this round's read (or a newer one) is what it rests on
                    return True
                return not o.partial and _find(o, _sub_key(x)) is None   # a complete read that does not list it
            if all(settled(x) for x in sent):
                item.done, item.end = True, end
                return
        item.state = f"{end['state']} per the ledger, unverified"
        item.detail = ("target UNOBSERVABLE" if not readable else
                       f"this read shows {_sub_key(shown_live[0])} live: read again" if shown_live else
                       "partial read: " + "; ".join(o.partial)[:80] if o.partial else
                       "this read is older than the ledger's last one: read again")
        return
    j = _find(o, item.key)
    if j is not None and _job_ended(item.kind, j):
        rc = j.exit_code if item.kind == "slurm" else str(j.rc.get("rc", ""))
        item.done, item.end = True, {"state": j.state, "rc": rc,
                                     "at": S._iso(j.end) if j.end else S._iso(o.observed_at)}
        return
    if readable:
        item.state = j.state if j is not None else "not listed"
        item.detail = _detail(j, now)
    else:
        item.detail = "target UNOBSERVABLE"


def succeeded(end: dict) -> bool:
    st, rc = end.get("state", ""), end.get("rc", "")
    if st == "COMPLETED":
        return rc in ("", "0", "0:0")
    return st == "ENDED" and rc == "0"


def rc_words(end: dict) -> str:
    """`state=<S> rc=<N>`: the state unless a plain end; a Slurm ExitCode code:signal as rc=N (+ sig=M)."""
    st, rc = end.get("state", ""), str(end.get("rc", ""))
    words = [] if st in ("ENDED", "COMPLETED") else [f"state={st}"]
    if ":" in rc:
        code, _, sig = rc.partition(":")
        words.append(f"rc={code or '?'}" + (f" sig={sig}" if sig not in ("", "0") else ""))
    elif rc:
        words.append(f"rc={rc}")
    elif st == "COMPLETED":                  # Slurm's COMPLETED is exit code 0
        words.append("rc=0")
    elif st == "ENDED":
        words.append("rc=unknown")
    return " ".join(words)


# ------------------------------------------------------------------------------------------------ subprocesses
_popen = subprocess.Popen     # the one place this module starts a process (tests count it)


class Cancelled(Exception):
    """The wait is over (a signal, the timeout, the end): no new subprocess is started."""


class Procs:
    """The ssh processes this wait started: each one tracked from its spawn to its reaping; stop() refuses new ones,
    then terminates (and after STOP_GRACE s kills) and reaps every one still running — never another process's."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.live: set[subprocess.Popen] = set()
        self.stopped = False

    def run(self, argv: list[str], body: str, timeout: float) -> subprocess.CompletedProcess:
        with self.lock:                     # the check and the spawn under one lock: stop() cannot slip in between
            if self.stopped:
                raise Cancelled()
            p = _popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8",
                       errors="replace")
            self.live.add(p)
        try:
            try:
                so, se = p.communicate(body, timeout=timeout)
            except subprocess.TimeoutExpired:
                p.kill()
                p.communicate()
                raise
            if self.stopped:                # stop() ended it: its answer is no answer
                raise Cancelled()
            return subprocess.CompletedProcess(argv, p.returncode, so, se)
        finally:
            with self.lock:
                self.live.discard(p)

    def stop(self) -> None:
        with self.lock:
            self.stopped = True
            ps = list(self.live)
        for p in ps:
            try:
                p.terminate()
            except OSError:
                pass
        until = _wall.monotonic() + STOP_GRACE
        for p in ps:
            try:
                p.wait(max(0.0, until - _wall.monotonic()))
            except subprocess.TimeoutExpired:
                try:
                    p.kill()
                    p.wait(STOP_GRACE)
                except (OSError, subprocess.TimeoutExpired):
                    pass


def _ssh_argv(place: harness.Place, deadline: float) -> list[str]:
    """observe.run()'s ssh: `bash -s` on the place's host, BatchMode."""
    return ["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={int(max(1, min(deadline, 30)))}", place.host,
            "bash -s"]


def read_target(procs: Procs, place: harness.Place, days: int, deadline: float, nonces: list[str],
                comments: bool, logs: list[str] | tuple[str, ...] = ()) -> observe.Observation:
    """observe.observe()'s read of one place — the same script and parser — through PROCS (cut at DEADLINE s). LOGS:
    the watched runs' logs there, read beside the discovery's newest 50 (observe.script's LOGS)."""
    t0 = _wall.time()
    o = _read_target(procs, place, days, deadline, nonces, comments, logs)
    o.started_at = o.started_at or t0               # observe.obs_time: orders this read against other readers'
    return o


def _read_target(procs: Procs, place: harness.Place, days: int, deadline: float, nonces: list[str],
                 comments: bool, logs: list[str] | tuple[str, ...] = ()) -> observe.Observation:
    if place.error:
        return observe.Observation(place, why=f"its profile does not load: {place.error}", observed_at=time.time())
    try:
        done = procs.run(_ssh_argv(place, deadline), observe.script(place, days, nonces, comments, logs), deadline)
        return observe.parse(place, done.stdout, done.returncode, done.stderr)
    except subprocess.TimeoutExpired:
        return observe.Observation(place, why=f"no answer within {deadline:.0f} s", observed_at=time.time())
    except Cancelled:
        raise
    except OSError as exc:
        return observe.Observation(place, why=f"ssh: {exc}", observed_at=time.time())
    except Exception as exc:   # one odd answer makes this target unobservable, never the whole wait a traceback
        return observe.Observation(place, why=f"unreadable answer: {exc!r}"[:300], observed_at=time.time())


class Pool:
    """WORKERS daemon threads (an exit never waits for one); a task queued when the wait stops never runs."""

    def __init__(self, n: int, stop: threading.Event) -> None:
        self.q: queue.SimpleQueue = queue.SimpleQueue()
        self.stop = stop
        self.n = n
        self.threads: list[threading.Thread] = []

    def submit(self, fn, *a) -> futures.Future:
        f: futures.Future = futures.Future()
        if len(self.threads) < self.n:
            t = threading.Thread(target=self._work, daemon=True, name="rsk-wait")
            t.start()
            self.threads.append(t)
        self.q.put((f, fn, a))
        return f

    def _work(self) -> None:
        while True:
            item = self.q.get()
            if item is None:
                return
            f, fn, a = item
            if not f.set_running_or_notify_cancel():
                continue
            if self.stop.is_set():
                f.set_exception(Cancelled())
                continue
            try:
                f.set_result(fn(*a))
            except BaseException as exc:    # noqa: BLE001 — handed to the supervisor through the future
                f.set_exception(exc)

    def close(self) -> None:
        for _ in self.threads:
            self.q.put(None)


def _pause(fs: list[futures.Future], timeout: float) -> None:
    """Until one of FS is done or TIMEOUT s passed (no FS: a plain sleep)."""
    if timeout <= 0:
        return
    if fs:
        futures.wait(fs, timeout=timeout, return_when=futures.FIRST_COMPLETED)
    else:
        time.sleep(timeout)


# ------------------------------------------------------------------------------------------------ the digest
_HINTS = re.compile(r"hints: traceback=(\d+) oom=(\d+) nonfinite=(\d+) error=(\d+)")
_PROC_RC = re.compile(r"^proc=gone pid=\d+ exit=(\d+) ")


def parse_digest(text: str) -> dict:
    """rsk logs' digest (status.sh's key=value lines) -> {"text": one line, "log": path, "rc": an rc it proves}."""
    log, hints, tail, rc, note = "", None, "", "", ""
    for line in text.splitlines():
        if line.startswith("log="):
            v = line[4:]
            if v.startswith(("none", "ambiguous", "not-a-regular-file")):
                note = "log " + v[:80]
            else:
                log = v.split(" bytes=")[0]
        elif line.startswith("scan=") and (m := _HINTS.search(line)):
            hints = dict(zip(("traceback", "oom", "nonfinite", "error"), map(int, m.groups())))
        elif line.startswith("scan=unknown") or line.startswith("starts=unknown scan=unknown"):
            note = "log unreadable"
        elif line.startswith("tail: "):
            tail = line[6:].strip()
        elif m := _PROC_RC.match(line):
            rc = m.group(1)
    if hints is None:
        head = note or "no digest"
    else:
        head = " ".join(f"{k}={v}" for k, v in hints.items() if v) or "no hints"
    one = head + (f" — {tail}" if tail else "")
    if len(one) > DIGEST_CUT:
        one = one[:DIGEST_CUT - 1] + "…"
    return {"text": one, "log": log, "rc": rc}


def digest(procs: Procs, place: harness.Place, key: str, wait: float = DIGEST_WAIT) -> dict:
    """One bounded read (WAIT s): the deployed status.sh for KEY, -n 1 (as rsk logs runs it), cut to one line."""
    if not key:
        return {"text": "no job / log (never submitted)", "log": "", "rc": ""}
    try:
        done = procs.run(_ssh_argv(place, wait), S.digest_body(place, key, 1), wait)
    except subprocess.TimeoutExpired:
        return {"text": f"digest: no answer within {wait:.0f} s", "log": "", "rc": ""}
    except OSError as exc:
        return {"text": f"digest: ssh: {exc}"[:DIGEST_CUT], "log": "", "rc": ""}
    if done.returncode != 0:
        first = (done.stdout.strip().splitlines() or done.stderr.strip().splitlines() or [""])[-1]
        return {"text": f"digest unavailable (exit {done.returncode}{': ' + first if first else ''})"[:DIGEST_CUT],
                "log": "", "rc": ""}
    return parse_digest(done.stdout)


def _cut_digest(why: str) -> dict:
    return {"text": f"no digest ({why})", "log": "", "rc": ""}


# ------------------------------------------------------------------------------------------------ the waiter
class _Interrupt(Exception):
    pass


def _ignore_signals() -> None:
    """A second SIGINT / SIGTERM while the first one is being reported: ignored (no traceback); restored on return."""
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, signal.SIG_IGN)
        except (OSError, ValueError):
            pass


def _asked(st: L.LedgerState, target: str) -> list[str]:
    """The nonces of the ledger's SUBMIT_UNKNOWN submissions on TARGET (status.read asks the journal for them)."""
    return sorted({str(s.get("nonce")) for rec in st.runs.values() for att in (rec.get("attempts") or {}).values()
                   if att.get("target") == target for s in att.get("submissions") or [] if s.get("submit") == "unknown"})


def _watched_logs(st: L.LedgerState, items: list["Item"], target: str) -> list[str]:
    """The logs of the waited, not yet ended runs on the workstation TARGET: every submission of each ledger attempt,
    and a log the user named — read by name each round, so one older than the discovery's newest 50 is still read."""
    out: list[str] = []
    for i in items:
        if i.done or i.target != target or i.kind == "slurm":
            continue
        att = ((st.runs.get(i.run) or {}).get("attempts") or {}).get(i.aid) or {} if i.run else {}
        out += [str((s.get("proc") or {}).get("log") or "") for s in att.get("submissions") or []]
        if not i.run and i.key:
            out.append(i.key)
    return [x for x in dict.fromkeys(out) if observe.LOG.fullmatch(x)]


class Waiter:
    def __init__(self, args: argparse.Namespace, t0: float) -> None:
        self.args = args
        self.led: L.Ledger | None = None
        self.places: dict[str, harness.Place] = {}
        self.days = 2
        self.deferred: list[Deferred] = []
        self.chosen: list[str] = []
        self.ready = False              # the runs are resolved as far as the ledger can (target discovery done)
        words = list(dict.fromkeys(args.runs or [])) or ["--all-live"]
        self.items = [Item(label=w, target="", state="resolving (target discovery)", word=w) for w in words]
        self.unobs: dict[str, str] = {}
        self.notes: set[str] = set()
        self.t0 = t0                    # the command's start: --timeout and the elapsed time count from it
        self.limit = t0 + args.timeout if args.timeout is not None else math.inf
        self.stop_ev = threading.Event()
        self.procs = Procs()
        self.pool = Pool(WORKERS, self.stop_ev)
        self.fs: list[futures.Future] = []
        self.reports: list[tuple[Item, futures.Future]] = []     # ended this round, digest pending: reported in order

    def left(self) -> float:
        """Seconds until --timeout (inf without one)."""
        return self.limit - time.monotonic()

    def task(self, fn, *a) -> futures.Future:
        """FN(left, *A) on the pool: LEFT = what is left of --timeout when it STARTS (not when it was queued)."""
        f = self.pool.submit(lambda: fn(self.left(), *a))
        self.fs.append(f)
        return f

    def shutdown(self) -> None:
        """Nothing new starts; every queued task is dropped; a ledger write in flight stops before its next change
        (the stop flag); every ssh still running is terminated and reaped."""
        self.stop_ev.set()
        for f in self.fs:
            f.cancel()
        self.procs.stop()
        self.pool.close()

    # ---- output
    def emit(self, kind: str, text: str, **fields) -> None:
        if self.args.json:
            out(json.dumps({"type": kind, **fields, "at": L.now()}, ensure_ascii=False))
        else:
            out(text)

    def elapsed(self) -> str:
        return observe.age(time.monotonic() - self.t0)

    def pending(self) -> list[Item]:
        return [i for i in self.items if not i.done]

    def _state(self, i: Item) -> str:
        if i.target in self.unobs and not i.state.endswith("unverified"):
            return f"UNOBSERVABLE ({i.target})"
        return ("not read yet" if i.state == "?" else i.state) + (f" {i.detail}" if i.detail else "")

    def listing(self, items: list[Item]) -> str:
        words = [f"{i.label}" + (f" [{i.target}]" if i.target else "") + f": {self._state(i)}" for i in items]
        more = len(words) - LIST_MAX
        return ", ".join(words[:LIST_MAX]) + (f", … +{more} more" if more > 0 else "")

    def _runs(self, items: list[Item]) -> list[dict]:
        return [{"run": i.label, "attempt": i.aid, "target": i.target,
                 "state": "UNOBSERVABLE" if i.target in self.unobs and not i.state.endswith("unverified") else i.state}
                for i in items]

    def total(self) -> int:
        return len(self.items)

    def waiting(self) -> None:
        p = self.pending()
        self.emit("waiting", f"waiting: {len(p)} of {len(self.items)} still running ({self.elapsed()}) — "
                  f"{self.listing(p)}", pending=len(p), total=len(self.items), runs=self._runs(p))

    def stopped(self, kind: str, head: str) -> None:
        p = self.pending()
        self.emit(kind, f"{head}: {len(p)} of {len(self.items)} not ended" + (f" — {self.listing(p)}" if p else ""),
                  pending=len(p), total=len(self.items), runs=self._runs(p))

    def start_line(self) -> None:
        """The first line, before anything that may block (target discovery, the ledger, a read)."""
        a = self.args
        what = "every live run (--all-live)" if a.all_live else f"{len(self.items)} run(s)"
        self.emit("start", f"rsk wait: {what} — read every {a.every:g}s"
                  + (f", timeout {a.timeout:g}s" if a.timeout is not None else "") + " (read-only)",
                  words=[i.word for i in self.items])

    def targets_line(self) -> None:
        self.emit("targets", f"targets: {', '.join(self.places)} ({len(self.items)} run(s))",
                  total=len(self.items), targets=list(self.places),
                  runs=[{"run": i.label, "attempt": i.aid, "target": i.target} for i in self.items if not i.word],
                  resolving=[d.word for d in self.deferred])

    # ---- tasks (every one on the pool: the main thread never blocks on discovery, the ledger or a read)
    def _setup(self, left: float) -> dict:
        return setup(self.args, left)

    def _state_read(self, left: float) -> L.LedgerState:
        if left <= 0:
            raise Cancelled()
        return self.led.state()

    def _read(self, left: float, place: harness.Place, nonces: list[str], comments: bool, logs: list[str]):
        dl = min(self.args.deadline, left)
        if dl <= 0:
            return observe.Observation(place, why="cut at --timeout", observed_at=time.time()), True
        o = read_target(self.procs, place, self.days, dl, nonces, comments, logs)
        # a read that failed only as --timeout came says nothing about the target: not an event
        return o, (not o.ok and self.left() <= 0)

    def _record(self, left: float, st0: L.LedgerState, obs: list[observe.Observation]
                ) -> tuple[list[str], L.LedgerState]:
        """status.record() within what is left of --timeout (the lock wait included) and until the wait stops; then
        the ledger as it now is. Too little time left (RECORD_NEED): nothing written — the round is judged on an
        in-memory reconciliation (_sync_runs), and nothing claims it was recorded."""
        if left < RECORD_NEED or self.stop_ev.is_set():
            return [], st0
        notes = S.record(self.led, st0, obs, deadline=_wall.monotonic() + left if math.isfinite(left) else None,
                         cancel=self.stop_ev)
        if self.stop_ev.is_set() or self.left() <= 0:
            return notes, st0
        return notes, self.led.state()

    def _digest(self, left: float, i: Item) -> dict:
        place = self.places.get(i.target)
        if place is None or place.error:
            return {"text": "no digest (the target's place is unknown)", "log": "", "rc": ""}
        wait = min(DIGEST_WAIT, left)
        if wait <= 0:
            return _cut_digest("cut at --timeout")
        return digest(self.procs, place, i.key, wait)

    def start_reads(self, st0: L.LedgerState) -> list[futures.Future]:
        fs = []
        for p in self.places.values():
            asked = _asked(st0, p.target)
            logs = _watched_logs(st0, self.items, p.target) if p.kind != "slurm" else []
            fs.append(self.task(self._read, p, asked, p.kind == "slurm" and bool(asked), logs))
        return fs

    def apply_setup(self, got: dict) -> None:
        self.led, self.places, self.days = got["led"], got["places"], got["days"]
        self.deferred, self.chosen = got["deferred"], got["chosen"]
        self.items = got["items"] + [Item(label=d.word, target=", ".join(self.chosen), state="resolving (first read)",
                                          word=d.word) for d in self.deferred]
        self.ready = True

    # ---- one round: what it shows
    def resolve(self, by: dict[str, observe.Observation], runs: dict) -> None:
        """The deferred RUNs against the first read (raises: exit 2 unknown / ambiguous, 5 a searched target blind).
        RUNS = the ledger after this read was recorded (a job it learned from this very read)."""
        found_all: list[Item] = []
        for d in self.deferred:
            w = d.word
            keyed = _keylike(w)
            blind = [t for t in self.chosen if not (by.get(t) and by[t].ok)]
            found: list[Item] = []
            for t in self.chosen:
                o = by.get(t)
                if o is None or not o.ok:
                    continue
                if keyed and w.isdigit() and o.place.kind != "slurm":
                    found += resolve_pid(o, w, d.cands)
                else:
                    found += from_observation(o, w, keyed)
            if not found and not (keyed and w.isdigit() and len(self.chosen) == 1
                                  and self.places[self.chosen[0]].kind != "slurm"):
                # a job the ledger learned from this very read (reconciled): the ledger's name for it
                it = from_ledger(runs, w, set(self.chosen)) if not keyed else None
                if it is None and keyed and len(self.chosen) == 1:
                    hits = by_key(runs, w, self.chosen[0])
                    it = hits[0][0] if len(hits) == 1 else None
                if it is not None:
                    found = [it]
            if blind:
                why = "; ".join(by[t].why for t in blind if t in by)[:200]
                seen = (f"; on {', '.join(sorted({i.target for i in found}))} it is "
                        f"{', '.join(i.label for i in found)}" if found else "")
                raise RskError(f"rsk wait: {w} is not in the ledger and {', '.join(blind)} could not be read ({why}) — "
                               f"cannot tell what or where it is{seen}; with -T, only the named targets are searched",
                               UNKNOWN)
            if not found:
                raise RskError(f"rsk wait: unknown run {w} — rsk status lists this project's runs", USAGE)
            for i in found:
                self.emit("resolved", f"resolved: {w} -> {i.label} [{i.target}]", word=w, run=i.label, attempt=i.aid,
                          target=i.target)
            found_all += found
        self.deferred = []
        uniq: dict[tuple, Item] = {}
        for i in [i for i in self.items if not i.word] + found_all:
            uniq.setdefault((i.target, i.run, i.aid) if i.run else (i.target, "", i.key), i)
        self.items = list(uniq.values())
        # only the targets holding the waited runs from here on
        self.places = {t: p for t, p in self.places.items() if any(i.target == t for i in self.items)}
        for t in list(self.unobs):
            if t not in self.places:
                del self.unobs[t]

    def after_read(self, results: list[tuple[observe.Observation, bool]], notes: list[str],
                   obs: list[observe.Observation], st: L.LedgerState) -> tuple[bool, list[Item]]:
        before = [(i.state, i.done) for i in self.items]   # not the detail: `up 3h` moves every round
        changed = False
        for n in notes:
            if n not in self.notes:
                self.notes.add(n)
                self.emit("note", f"ledger: {n}", note=n)
        by: dict[str, observe.Observation] = {}
        for o, cut in results:
            t = o.place.target
            if cut:                     # keeps what was known: UNOBSERVABLE stays, a good target is not judged
                if t in self.unobs:
                    by[t] = o
                continue
            by[t] = o
            if not o.ok and t not in self.unobs:
                self.unobs[t] = o.why
                changed = True
                self.emit("unobservable", f"UNOBSERVABLE {t}: {o.why} — its runs' state is unknown, not ended",
                          target=t, why=o.why)
            elif o.ok and t in self.unobs:
                del self.unobs[t]
                changed = True
                self.emit("observable", f"OBSERVABLE again {t}", target=t)
        runs = _sync_runs(st, obs)
        if self.deferred:
            self.resolve(by, runs)
            before = None
        ended = []
        cut_targets = {o.place.target for o, cut in results if cut}
        for i in self.items:
            if not i.done and i.target not in cut_targets:
                judge(i, runs, by.get(i.target))
                if i.done:
                    ended.append(i)
        ended.sort(key=lambda i: (i.end.get("at", ""), i.label))
        return changed or bool(ended) or before != [(i.state, i.done) for i in self.items], ended

    def report(self, i: Item, d: dict) -> None:
        end = dict(i.end)
        if end.get("state") == "ENDED" and not end.get("rc") and d.get("rc"):
            end["rc"] = d["rc"]                     # no <log>.rc, but the log's EXIT footer of that pid says it
        i.end = end
        ok = succeeded(end)
        log = d.get("log") or (i.key if i.kind == "nohup" else "") or "?"
        words = [f"{'ENDED' if ok else 'FAILED':<6}", i.label, f"[{i.target}]", rc_words(end), d["text"], "log", log]
        self.emit("ended" if ok else "failed", " ".join(x for x in words if x),
                  run=i.label, attempt=i.aid, target=i.target, rc=end.get("rc", ""), state=end.get("state", ""),
                  digest=d["text"], log=log)

    def flush_reports(self, why: str) -> None:
        """The ends a good read showed whose digest is still out (the timeout, a signal): reported, the digest cut."""
        while self.reports:
            i, f = self.reports.pop(0)
            self.report(i, f.result() if f.done() and not f.cancelled() and f.exception() is None
                        else _cut_digest(why))

    def verdict(self) -> int:
        return OK if all(succeeded(i.end) for i in self.items) else FAILED

    # ---- the loop: the main thread only supervises (start line, heartbeat, timeout, signals); target discovery, the
    # ledger's reads and writes, the reads and the digests all run on the pool, each awaited with a timeout of
    # min(the next heartbeat, the deadline)
    def run(self) -> int:
        a = self.args
        self.start_line()
        next_hb = time.monotonic() + a.heartbeat
        last_change = time.monotonic()
        first = True
        next_round = time.monotonic()
        phase = "setup"
        cur: futures.Future | None = self.task(self._setup)
        reads: list[futures.Future] = []
        st0: L.LedgerState | None = None
        results: list[tuple[observe.Observation, bool]] = []
        self.reports = reports = []
        while True:
            if self.left() <= 0:            # first: a result that came at the deadline is not waited on, nor judged
                if phase == "setup":
                    raise RskError(f"rsk wait: --timeout {a.timeout:g}s reached while resolving the runs (the local "
                                   "target discovery or the ledger gave no answer)", UNKNOWN)
                self.flush_reports("cut at --timeout")
                if not self.pending():
                    return self.verdict()
                self.stopped("timeout", f"TIMEOUT after {int(a.timeout)}s" if a.timeout == int(a.timeout)
                             else f"TIMEOUT after {a.timeout:g}s")
                return UNKNOWN
            if phase == "setup" and cur.done():
                got = cur.result()                  # an RskError (unknown run, no target, …) ends the wait here
                if got.get("nothing"):
                    msg = got["nothing"]
                    out(json.dumps({"type": "nothing_live", "text": msg, "at": L.now()}) if a.json else msg)
                    return OK
                self.apply_setup(got)
                self.targets_line()
                phase, next_round = "idle", time.monotonic()
            if phase == "state" and cur.done():
                st0 = cur.result()                  # (cancelled only by shutdown, after the loop)
                reads, phase = self.start_reads(st0), "read"
            if phase == "read" and all(f.done() for f in reads):
                results = [f.result() for f in reads]
                good = [o for o, cut in results if o.ok and not cut]
                if good:
                    cur, phase = self.task(self._record, st0, good), "record"
                else:
                    cur, phase = None, "judge"
            if phase == "record" and cur.done():
                phase = "judge"
            if phase == "judge":
                notes, st = cur.result() if cur is not None else ([], st0)
                obs = [o for o, cut in results if not cut]
                changed, ended = self.after_read(results, notes, obs, st)
                if changed:
                    last_change = time.monotonic()
                reports[:] = [(i, self.task(self._digest, i)) for i in ended]
                phase = "digests"
            if phase == "digests":
                while reports and reports[0][1].done():
                    i, f = reports.pop(0)
                    self.report(i, f.result())
                if not reports:
                    phase = "idle"
                    if not self.pending():
                        return self.verdict()
                    if first:
                        self.waiting()
                        next_hb = time.monotonic() + a.heartbeat
                        first = False
                    quiet = time.monotonic() - last_change >= BACKOFF_AFTER
                    next_round = time.monotonic() + (min(EVERY_MAX, 2 * a.every) if quiet else a.every)
            if phase == "idle" and time.monotonic() >= next_round:
                cur, phase = self.task(self._state_read), "state"
                continue
            if time.monotonic() >= next_hb:
                self.waiting()
                next_hb = time.monotonic() + a.heartbeat
            inflight = [f for f in (reads if phase == "read" else [cur] if phase in ("setup", "state", "record") else
                                    [f for _i, f in reports[:1]] if phase == "digests" else []) if f and not f.done()]
            wake = min(next_hb, self.limit, next_round if phase == "idle" else math.inf)
            _pause(inflight, wake - time.monotonic())


# ------------------------------------------------------------------------------------------------ the command
def _days(items: list[Item], runs: dict) -> int:
    """Back far enough for the oldest waited ledger attempt (Slurm's sacct window), as launch.refresh() does."""
    born = [L.epoch(((runs.get(i.run) or {}).get("attempts") or {}).get(i.aid, {}).get("created_at")) for i in items
            if i.run]
    born = [b for b in born if b]
    if not born:
        return 2
    return max(2, min(30, int((time.time() - min(born)) // 86400) + 2))


def _check_args(args: argparse.Namespace) -> None:
    if args.all_live and args.runs:
        raise RskError("rsk wait: name runs or --all-live, not both", USAGE)
    if not args.all_live and not args.runs:
        raise RskError("rsk wait: name the runs to wait for (RUN...) or --all-live", USAGE)
    for name in ("every", "heartbeat", "timeout", "deadline"):
        v = getattr(args, name)
        if v is not None and not math.isfinite(v):
            raise RskError(f"rsk wait: --{name} needs a finite number of seconds", USAGE)
    if not EVERY_MIN <= args.every <= EVERY_MAX:
        raise RskError(f"rsk wait: --every {EVERY_MIN}..{EVERY_MAX} seconds", USAGE)
    if args.heartbeat < EVERY_MIN:
        raise RskError(f"rsk wait: --heartbeat at least {EVERY_MIN} seconds", USAGE)
    if args.timeout is not None and args.timeout <= 0:
        raise RskError("rsk wait: --timeout S needs S > 0", USAGE)
    if not DEADLINE_MIN <= args.deadline <= 600:
        raise RskError(f"rsk wait: --deadline {DEADLINE_MIN:g}..600 seconds", USAGE)


def _keylike(word: str) -> bool:
    """A Slurm job id / pid (digits) or a log path — never a run name."""
    return word.isdigit() or "/" in word or word.endswith(".log")


def cmd_wait(args: argparse.Namespace) -> int:
    t0 = time.monotonic()
    _check_args(args)
    handlers = {}
    if threading.current_thread() is threading.main_thread():   # no traceback, no ssh left behind
        def stop(signum, _frame):
            _ignore_signals()
            raise _Interrupt(signum)
        for sig in (signal.SIGINT, signal.SIGTERM):
            handlers[sig] = signal.signal(sig, stop)
    w = Waiter(args, t0)
    try:
        try:
            rc = w.run()
        except (_Interrupt, KeyboardInterrupt):
            _ignore_signals()
            rc = INTERRUPTED
            w.shutdown()                    # first: nothing new starts, every ssh is terminated and reaped
            if not w.ready:
                msg = "interrupted: while resolving the runs — nothing waited for yet"
                out(json.dumps({"type": "interrupted", "text": msg, "at": L.now()}) if args.json else msg)
            else:
                w.flush_reports("interrupted")
                w.stopped("interrupted", "interrupted")
    finally:
        w.shutdown()
        for sig, h in handlers.items():
            signal.signal(sig, h)
    if args.json and w.ready:
        items = w.items
        out(json.dumps({"type": "summary", "exit": rc, "total": w.total(),
                        "ended": [i.label for i in items if i.done and succeeded(i.end)],
                        "failed": [i.label for i in items if i.done and not succeeded(i.end)],
                        "pending": [i.label for i in items if not i.done],
                        "at": L.now()}, ensure_ascii=False))
    sys.stdout.flush()
    return rc


def setup(args: argparse.Namespace, left: float) -> dict:
    """Target discovery and the ledger's resolution of the RUNs (a pool task: LEFT = what is left of --timeout).
    {"nothing": msg} when --all-live finds nothing live; else the Waiter's led, places, items, deferred, chosen, days."""
    proj = S.project_dir(args.dir)
    discover = min(DISCOVERY_WAIT, left)
    if discover <= 0:
        raise RskError(f"rsk wait: --timeout {args.timeout:g}s reached before the targets were known", UNKNOWN)
    try:
        all_places = harness.places(paths.harness_src(), proj, timeout=discover)
    except subprocess.TimeoutExpired:
        raise RskError(f"rsk wait: the local target discovery gave no answer within {discover:.0f} s"
                       + (" (--timeout)" if discover < DISCOVERY_WAIT else ""), UNKNOWN) from None
    chosen = {p.target: p for p in S.select(all_places, args.target)}
    if not chosen:
        raise RskError(f"no target resolves a remote dir from {proj}'s conf (REMOTE_DIR / <TAG>_REMOTE_DIR / "
                       "WS_REMOTE_DIR) — see references/project-setup.md", USAGE)
    targets = set(chosen) if args.target else None
    led = L.Ledger(proj)
    runs = led.state().runs
    one = args.target[0] if args.target and len(set(args.target)) == 1 else ""
    items: list[Item] = []
    deferred: list[Deferred] = []
    if args.all_live:
        for r, rec in sorted(runs.items()):
            for a, att in sorted(((rec or {}).get("attempts") or {}).items()):
                if L.is_live(att) and (targets is None or att.get("target") in targets):
                    items.append(_ledger_item(r, a, att))
        if not items:
            return {"nothing": "rsk wait: nothing live in this project's ledger"
                    + (f" on {', '.join(chosen)}" if args.target else "") + " — nothing to wait for"}
    for w in dict.fromkeys(args.runs or []):
        if _keylike(w):
            if not one:
                raise RskError(f"rsk wait: {w} is not a run name; as a job id / pid / log path it needs exactly one -T "
                               "(its target)", USAGE)
            hits = by_key(runs, w, one)
            if w.isdigit() and chosen[one].kind != "slurm":
                deferred.append(Deferred(w, hits))          # a pid: only the first read tells which launch it is
            elif len(hits) > 1:
                raise RskError(f"rsk wait: {w} on {one} matches {len(hits)} ledger attempts: {_cand_words(hits)} — "
                               "name the run", USAGE)
            elif hits:
                items.append(hits[0][0])
            else:
                deferred.append(Deferred(w))
            continue
        it = from_ledger(runs, w, targets)
        if it is None:
            deferred.append(Deferred(w))
            continue
        if targets is not None and it.target not in targets:
            raise RskError(f"rsk wait: {w} is {it.label} on {it.target}, not on {', '.join(chosen)} (-T)", USAGE)
        items.append(it)
    places: dict[str, harness.Place] = {}
    for t in dict.fromkeys([i.target for i in items] + (list(chosen) if deferred else [])):
        places[t] = chosen.get(t) or next((p for p in all_places if p.target == t), None) or harness.Place(
            target=t, error="this project's conf gives it no remote dir")
    days = _days(items + [it for d in deferred for it, _s in d.cands], runs)
    return {"led": led, "places": places, "items": items, "deferred": deferred,
            "chosen": list(chosen) if deferred else [], "days": days}


def add_parser(sub) -> None:
    w = sub.add_parser("wait", help="wait, read-only, until runs end: one line per event (ENDED / FAILED / "
                       "UNOBSERVABLE), then the verdict line",
                       description=__doc__.split("\n\n")[0], epilog=__doc__.split("\n\n", 1)[1],
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    w.add_argument("runs", nargs="*", metavar="RUN", help="a run id or name (<run>--aNN = that attempt); with one -T "
                   "also a Slurm job id, a workstation pid or a log path")
    w.add_argument("--all-live", action="store_true", help="every attempt the ledger counts live (SUBMIT_UNKNOWN "
                   "included)")
    w.add_argument("-T", "--target", action="append", help="only this target (repeatable): RUNs resolve among its "
                   "attempts")
    w.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory)")
    w.add_argument("--timeout", type=float, default=None, metavar="S", help="give up S seconds after the start, all "
                   "reads and digests included: exit 5")
    w.add_argument("--every", type=float, default=EVERY, metavar="S", help=f"seconds between reads (default {EVERY}, "
                   f"{EVERY_MIN}..{EVERY_MAX}; 2x after {BACKOFF_AFTER // 60} min without change, at most "
                   f"{EVERY_MAX})")
    w.add_argument("--heartbeat", type=float, default=HEARTBEAT, metavar="S",
                   help=f"seconds between `waiting:` lines (default {HEARTBEAT})")
    w.add_argument("--deadline", type=float, default=DEADLINE, metavar="S", help="seconds per target and read before it "
                   f"counts as UNOBSERVABLE (default {DEADLINE:g}, {DEADLINE_MIN:g}..600; never past --timeout)")
    w.add_argument("--json", action="store_true", help="one JSON object per event, then a summary object")
    w.set_defaults(func=cmd_wait)
