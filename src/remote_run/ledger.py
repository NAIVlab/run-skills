"""The local ledger: what rsk planned, launched, was allowed to do and last saw, per project, on this machine.

It is bookkeeping, not proof: a record that says "approved" shows what was written, not that the user agreed (the
skill's rails — show the card, wait for the user's words — do that). Nothing here is ever sent to a target.

Layout — one dir per project (`RS_STATE_DIR` overrides the state dir, see paths.state_dir()):

    <state>/projects/<sha256(realpath(project))[:16]>/
      project          the project's real path (one line; a different path there = refuse, never share a dir)
      lock             fcntl.flock target, held for every read-modify-write (Ledger.locked(); re-entrant per thread)
      runs/<run>.json  one record per run id (RUN below); the file name is the run id, %-quoted when it needs it
      grants.json      {"version": 1, "records": [grants.py records], "budgets_unknown": null | {"at", "why"}}
      plans/<id>.json  one plan each, created O_EXCL and never rewritten; plans/<id>.used (O_EXCL) = consumed
      audit.jsonl      append-only, one JSON object per line: {"at", "event", ...}
      watch.lease      {"pid", "pid_start", "host", "boot_id", "started", "until", "argv"}

Writes (write_json): temp file -> fsync -> the current file, if it parses, hard-linked to <file>.prev -> rename over
-> fsync the dir. A crash leaves the old file or the new one, never half of one. Reads return Loaded(data, source):
  ok       the file parsed;
  prev     the file is missing or corrupt and <file>.prev parsed: data = .prev (a write may be lost) — every budget
           (launch counts, live runs) is UNKNOWN from then on: grants.json records it in "budgets_unknown" (with the
           ids of the records it affects), a run record in "recovered", and grants.check() covers nothing those
           affect until `rsk grant recount` (which rebuilds `used` from audit.jsonl); records made later are fine;
  missing  neither exists (data None); corrupt  neither parses (data None): writers refuse (exit 6), never guess.

API (every mutator takes the lock itself; hold `with led.locked():` around a check-then-act sequence):

  run_id(name) -> str                         the name minus a trailing --aNN (experiment-conventions.md §2)
  attempt_of(name) -> str                     'a01' from '...--a01', '' when the name has none
  Ledger(project)                             .dir .project; nothing is created until the first write
  led.locked(timeout=30.0, wait=True)         context manager; RskError(CONFLICT) naming the holder when busy
  led.read_run(run) -> Loaded                 led.runs() -> {run: Loaded}
  led.update_run(run, fn) -> dict             fn(record) mutates (or returns) the record; written atomically
  led.record_attempt(name=, target=, kind=, nonce=, submit=, plan=None, plan_id='', grant='', quote='',
                     card='', action='launch', cls='', job='', proc=None, evidence='', at=None, attempt='')
                     -> (run, attempt)        a new submission. plan = the parsed @@plan block (its bound fields
                                              and bound_hash go to request). The attempt key is ATTEMPT, else the
                                              name's --aNN (same name + target = the same attempt: a chain segment,
                                              a watch resubmit), else the next free one. The same nonce again = no-op
  led.set_submission(run, attempt, nonce, **fields)   e.g. submit='submitted', job='123' (SUBMIT_UNKNOWN -> known)
  led.find_nonce(nonce) -> (run, attempt) | None      led.find_job(target, job) / led.find_log(target, log)
  led.observe(run, attempt, key, state, source, at=None, detail='', end=None)
                                              last GOOD observation of one submission (key = job id or log); a
                                              failed read must never call it. end={'state','rc','evidence'} closes it
  led.grants() -> Loaded                      led.write_grants(doc) (grants.py owns the record type)
  led.create_plan(record) -> id               O_EXCL; id 'p-<UTC stamp>-<hex>' unless given
  led.read_plan(id) -> Loaded                 led.plans() -> [record, ...] oldest first
  led.claim_plan(id, **info) -> dict          O_EXCL plans/<id>.used; RskError(CONFLICT) when already used
  led.plan_claim(id) -> dict | None           led.latest_plan(target, name) -> record | None
  led.audit(event, **fields)                  led.read_audit() -> (records, bad_line_count)
  led.lease() -> Loaded                       lease_state(lease) -> 'none'|'live'|'dead'|'expired'|'foreign'
  led.take_lease(until, argv=()) -> dict      RskError(CONFLICT) while another pid's lease is live/foreign
  led.release_lease() -> bool                 only this process's lease
  led.state(now=None) -> LedgerState          what grants.check()/covers() read: .grants .runs .budgets_unknown
                                              (why, '' = known) .affected(record) -> bool

RUN record (runs/<run>.json):
  {"version": 1, "run": str, "created_at": iso, "recovered": null | {"at", "why"},
   "attempts": {"a01": ATTEMPT, ...}}
ATTEMPT:
  {"name": str, "target": str, "kind": "slurm"|"nohup", "created_at": iso,
   "request": {"action", "plan" (id), "bound_hash", "bound" {bound fields of the plan}, "class", "grant" (record id),
               "quote", "card"},
   "submissions": [SUBMISSION, ...],
   "observed": null | {"state", "at", "source", "key"},     the newest good observation of any submission
   "result": null | {"state", "rc", "at", "evidence"}}       set once no submission can still be live
SUBMISSION:
  {"nonce", "at", "submit": "submitted"|"unknown"|"not_submitted"|"adopted", "evidence",
   "job": str (Slurm id, '' if none), "proc": null | {"pid", "pgid", "start", "boot_id", "log", "gpu_ids"} (nohup),
   "seen": null | {"state", "at", "source"}, "end": null | {"state", "rc", "at", "evidence"}}
attempt_state(attempt) -> 'SUBMIT_UNKNOWN' | 'NOT_SUBMITTED' | result/observed state | 'SUBMITTED';
is_live(attempt) -> bool (unknown counts as live: a budget never assumes a lost submit did not happen).
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import re
import secrets
import socket
import tempfile
import threading
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote, unquote

from remote_run import paths
from remote_run.errors import CONFLICT, USAGE, RskError

VERSION = 1
SUBMIT = ("submitted", "unknown", "not_submitted", "adopted")
TERMINAL = {"COMPLETED", "CANCELLED", "FAILED", "TIMEOUT", "PREEMPTED", "NODE_FAIL", "BOOT_FAIL", "DEADLINE",
            "OUT_OF_MEMORY", "REVOKED", "ENDED", "NOT_SUBMITTED"}
NONCE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")      # submit.sh / launch.sh accept exactly this
_ATTEMPT = re.compile(r"--(a[0-9]{2,})$")


def now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch(iso: str | None) -> float:
    """'YYYY-MM-DDTHH:MM:SSZ' -> epoch seconds (0.0 when unparsable)."""
    try:
        return datetime.strptime(str(iso), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC).timestamp()
    except ValueError:
        return 0.0


def run_id(name: str) -> str:
    """The logical run: the job/run name minus a trailing --aNN (experiment-conventions.md §2)."""
    return _ATTEMPT.sub("", name) or name


def attempt_of(name: str) -> str:
    m = _ATTEMPT.search(name)
    return m.group(1) if m else ""


def attempt_state(att: dict) -> str:
    if att.get("result"):
        return str(att["result"].get("state") or "ENDED")
    subs = att.get("submissions") or []
    if any(s.get("submit") == "unknown" for s in subs):
        return "SUBMIT_UNKNOWN"
    if subs and all(s.get("submit") == "not_submitted" for s in subs):
        return "NOT_SUBMITTED"
    if att.get("observed"):
        return str(att["observed"].get("state") or "UNKNOWN")
    return "SUBMITTED"


def is_live(att: dict) -> bool:
    """May this attempt still hold resources? Unknown submits count as live (a budget never assumes they failed)."""
    if att.get("result"):
        return False
    for s in att.get("submissions") or []:
        if s.get("submit") == "not_submitted" or s.get("end"):
            continue
        if s.get("submit") == "unknown":
            return True
        seen = (s.get("seen") or {}).get("state", "")
        if seen not in TERMINAL:
            return True
    return False


@dataclass
class Loaded:
    data: Any
    source: str          # ok | prev | missing | corrupt
    why: str = ""

    @property
    def recovered(self) -> bool:
        return self.source == "prev"


@dataclass
class LedgerState:
    """A snapshot for grants.check()/covers(): pure data, no file access."""
    grants: list[dict] = field(default_factory=list)
    runs: dict[str, dict] = field(default_factory=dict)
    budgets_unknown: str = ""          # why the counts cannot be trusted ('' = they can)
    unknown_since: float = 0.0         # records created at or before this are affected (a run record was recovered)
    unknown_ids: frozenset = frozenset()   # records affected by a recovered grants.json (made later ones are not)
    now: float | None = None

    def affected(self, rec: dict) -> bool:
        return bool(self.budgets_unknown) and (rec.get("id") in self.unknown_ids
                                               or epoch(rec.get("created_at")) <= self.unknown_since)


# ------------------------------------------------------------------------------------------------ files
def _parse(path: Path) -> tuple[Any, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None, "missing"
    except OSError as exc:
        return None, f"unreadable: {exc}"
    try:
        return json.loads(text), ""
    except ValueError as exc:
        return None, f"not JSON: {exc}"


def read_json(path: Path, shape: Callable[[Any], bool] = lambda d: isinstance(d, dict)) -> Loaded:
    """PATH, else PATH.prev when PATH is missing or does not parse into SHAPE."""
    data, err = _parse(path)
    if not err and shape(data):
        return Loaded(data, "ok")
    why = err or "unexpected shape"
    pdata, perr = _parse(path.with_name(path.name + ".prev"))
    if not perr and shape(pdata):
        return Loaded(pdata, "prev", f"{path.name}: {why}; using {path.name}.prev")
    if err == "missing" and perr == "missing":
        return Loaded(None, "missing")
    return Loaded(None, "corrupt", f"{path.name}: {why}; {path.name}.prev: {perr or 'unexpected shape'}")


def _fsync_dir(d: Path) -> None:
    with contextlib.suppress(OSError):
        fd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def write_json(path: Path, data: Any, shape: Callable[[Any], bool] = lambda d: isinstance(d, dict)) -> None:
    """tmp -> fsync -> keep the current GOOD file as .prev (hard link, no window without a file) -> rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1, sort_keys=True, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        cur, err = _parse(path)
        if not err and shape(cur):               # a corrupt current file never replaces a good .prev
            ptmp = path.with_name(f".{path.name}.prev.{os.getpid()}.tmp")
            with contextlib.suppress(FileNotFoundError):
                os.unlink(ptmp)
            try:
                os.link(path, ptmp)
            except OSError:                       # no hard links here: a copy (the old file stays in place meanwhile)
                ptmp.write_bytes(path.read_bytes())
            os.replace(ptmp, path.with_name(path.name + ".prev"))
        os.replace(tmp, path)
        _fsync_dir(path.parent)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def _pid_start(pid: int) -> str:
    """Field 22 of /proc/PID/stat (start time in clock ticks since boot); '' where there is no /proc."""
    try:
        s = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return ""
    f = s[s.rfind(")") + 2:].split()
    return f[19] if len(f) > 19 else ""


def boot_id() -> str:
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    except OSError:
        return ""


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def lease_state(lease: dict | None, at: float | None = None) -> str:
    """none | live (its pid runs here) | dead (its pid is gone or reused) | expired (past until) | foreign (another
    host or boot: cannot be checked, counts as live until it expires)."""
    if not lease:
        return "none"
    t = time.time() if at is None else at
    if t > float(lease.get("until") or 0):
        return "expired"
    if lease.get("host") != socket.gethostname() or (lease.get("boot_id") or "") != boot_id():
        return "foreign"
    try:
        pid = int(lease.get("pid") or 0)
    except (TypeError, ValueError):
        return "dead"
    if pid <= 0 or not _alive(pid):
        return "dead"
    want = str(lease.get("pid_start") or "")
    return "live" if not want or want == _pid_start(pid) else "dead"


# ------------------------------------------------------------------------------------------------ the lock
_GUARD = threading.Lock()
_HELD: dict[str, list] = {}                      # lock path -> [fd, depth, thread id]
_TLOCKS: dict[str, threading.Lock] = {}


def _tlock(key: str) -> threading.Lock:
    with _GUARD:
        return _TLOCKS.setdefault(key, threading.Lock())


def _safe_name(run: str) -> str:
    q = quote(run, safe="-_.")
    if q.startswith("."):
        q = "%2E" + q[1:]
    if len(q) > 180:
        q = q[:120] + "~" + hashlib.sha256(run.encode()).hexdigest()[:16]
    return q


class Ledger:
    def __init__(self, project: Path | str) -> None:
        self.project = Path(os.path.realpath(project))
        key = hashlib.sha256(str(self.project).encode()).hexdigest()[:16]
        self.dir = paths.state_dir() / "projects" / key

    # ---- setup and lock
    def ensure(self) -> None:
        for d in (self.dir / "runs", self.dir / "plans"):
            d.mkdir(parents=True, exist_ok=True)
        f = self.dir / "project"
        try:
            have = f.read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            have = ""
        if not have:
            fd, tmp = tempfile.mkstemp(prefix=".project.", dir=self.dir)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(f"{self.project}\n")
            os.replace(tmp, f)
        elif have != str(self.project):
            raise RskError(f"ledger dir {self.dir} belongs to {have}, not {self.project} — move it aside", CONFLICT)

    def holding(self) -> bool:
        with _GUARD:
            h = _HELD.get(str(self.dir / "lock"))
            return bool(h and h[2] == threading.get_ident())

    @contextlib.contextmanager
    def locked(self, timeout: float = 30.0, wait: bool = True) -> Iterator[None]:
        key = str(self.dir / "lock")
        tid = threading.get_ident()
        with _GUARD:
            held = _HELD.get(key)
            if held and held[2] == tid:
                held[1] += 1
                mine = held
            else:
                mine = None
        if mine is not None:                      # re-entrant: this thread already holds it
            try:
                yield
            finally:
                with _GUARD:
                    mine[1] -= 1
            return
        tl = _tlock(key)
        if not tl.acquire(timeout=timeout if wait else 0):
            raise RskError(f"the project ledger is busy (another rsk thread holds {key})", CONFLICT)
        try:
            self.ensure()
            fd = os.open(key, os.O_RDWR | os.O_CREAT, 0o600)
            end = time.monotonic() + (timeout if wait else 0)
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= end:
                        holder = os.pread(fd, 200, 0).decode("utf-8", "replace").strip() or "?"
                        os.close(fd)
                        raise RskError(f"the project ledger is busy: lock {key} held by {holder} — wait for it to "
                                       "finish", CONFLICT) from None
                    time.sleep(0.02)
            os.ftruncate(fd, 0)
            os.pwrite(fd, f"pid {os.getpid()} on {socket.gethostname()} since {now()}\n".encode(), 0)
            with _GUARD:
                _HELD[key] = [fd, 1, tid]
            try:
                yield
            finally:
                with _GUARD:
                    _HELD.pop(key, None)
                with contextlib.suppress(OSError):
                    os.ftruncate(fd, 0)
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)
        finally:
            tl.release()

    # ---- runs
    def run_path(self, run: str) -> Path:
        return self.dir / "runs" / f"{_safe_name(run)}.json"

    def read_run(self, run: str) -> Loaded:
        return read_json(self.run_path(run), _is_run)

    def runs(self) -> dict[str, Loaded]:
        out: dict[str, Loaded] = {}
        d = self.dir / "runs"
        if not d.is_dir():
            return out
        for p in sorted(d.glob("*.json")) + sorted(d.glob("*.json.prev")):
            base = p.name.removesuffix(".prev")
            if base.startswith(".") or base.endswith(".tmp"):
                continue
            path = d / base
            got = read_json(path, _is_run)
            name = got.data.get("run") if got.data else unquote(base.removesuffix(".json"))
            out.setdefault(str(name), got)
        return out

    def update_run(self, run: str, fn: Callable[[dict], dict | None]) -> dict:
        with self.locked():
            got = self.read_run(run)
            if got.source == "corrupt":
                raise RskError(f"ledger run record unreadable: {got.why} — move {self.run_path(run)} aside "
                               "(nothing was written)", CONFLICT)
            rec = got.data or {"version": VERSION, "run": run, "created_at": now(), "recovered": None, "attempts": {}}
            if got.recovered and not rec.get("recovered"):
                rec["recovered"] = {"at": now(), "why": got.why}
                self.audit("recovered", file=self.run_path(run).name, why=got.why)
            new = fn(rec)
            rec = rec if new is None else new
            write_json(self.run_path(run), rec, _is_run)
            return rec

    def record_attempt(self, *, name: str, target: str, kind: str, nonce: str, submit: str,
                       plan: dict | None = None, plan_id: str = "", grant: str = "", quote: str = "", card: str = "",
                       action: str = "launch", cls: str = "", job: str = "", proc: dict | None = None,
                       evidence: str = "", at: str | None = None, attempt: str = "") -> tuple[str, str]:
        if submit not in SUBMIT:
            raise RskError(f"submit must be one of {', '.join(SUBMIT)}", USAGE)
        if not NONCE_RE.fullmatch(nonce or ""):
            raise RskError(f"nonce {nonce!r} must match {NONCE_RE.pattern}", USAGE)
        if kind not in ("slurm", "nohup"):
            raise RskError(f"kind must be slurm or nohup, not {kind!r}", USAGE)
        run = run_id(name)
        when = at or now()
        aid_box: list[str] = []

        def put(rec: dict) -> None:
            atts = rec.setdefault("attempts", {})
            for k, a in atts.items():             # the same nonce again: a retry of the same record, a no-op
                if any(s.get("nonce") == nonce for s in a.get("submissions") or []):
                    aid_box.extend((k, "again"))
                    return
            aid = attempt or attempt_of(name)
            if attempt and attempt not in atts:
                raise RskError(f"run {run} has no attempt {attempt}", USAGE)
            if not aid or (not attempt and aid in atts and (atts[aid].get("name"), atts[aid].get("target"))
                           != (name, target)):
                aid = next_attempt(atts)
            att = atts.get(aid)
            if att is None:
                bound = {k: v for k, v in (plan or {}).items() if k in BOUND_KEYS}
                att = atts[aid] = {
                    "name": name, "target": target, "kind": kind, "created_at": when,
                    "request": {"action": action, "plan": plan_id, "bound_hash": (plan or {}).get("bound_hash", ""),
                                "bound": bound, "class": cls, "grant": grant, "quote": quote, "card": card},
                    "submissions": [], "observed": None, "result": None}
            att["submissions"].append({"nonce": nonce, "at": when, "submit": submit, "evidence": evidence,
                                       "job": str(job or ""), "proc": proc, "seen": None, "end": None})
            if submit != "not_submitted":
                att["result"] = None              # a new live segment reopens the attempt
            _settle(att)
            aid_box.append(aid)

        with self.locked():
            got = self.read_run(run).data or {}
            again = [k for k, a in (got.get("attempts") or {}).items()
                     if any(s.get("nonce") == nonce for s in a.get("submissions") or [])]
            if again:
                return run, again[0]
            self.update_run(run, put)
            self.audit("attempt", run=run, attempt=aid_box[0], name=name, target=target, nonce=nonce, submit=submit,
                       job=str(job or ""), grant=grant, plan=plan_id, action=action)
        return run, aid_box[0]

    def set_submission(self, run: str, attempt: str, nonce: str, **fields: Any) -> dict:
        def put(rec: dict) -> None:
            sub = _submission(rec, attempt, nonce)
            sub.update(fields)
            _settle(rec["attempts"][attempt])
        return self.update_run(run, put)

    def observe(self, run: str, attempt: str, key: str, state: str, source: str, at: str | None = None,
                detail: str = "", end: dict | None = None) -> dict:
        """A GOOD observation of one submission (KEY = its job id or log path). END closes that submission."""
        when = at or now()

        def put(rec: dict) -> None:
            att = rec["attempts"][attempt]
            for s in att.get("submissions") or []:
                if key and key in (s.get("job"), (s.get("proc") or {}).get("log")):
                    s["seen"] = {"state": state, "at": when, "source": source, **({"detail": detail} if detail else {})}
                    if end:
                        s["end"] = {"at": when, **end}
                    elif state not in TERMINAL and s.get("end"):   # a requeued job is live again
                        s["end"] = None
                        att["result"] = None
            att["observed"] = {"state": state, "at": when, "source": source, "key": key}
            _settle(att)
        return self.update_run(run, put)

    def find_nonce(self, nonce: str) -> tuple[str, str] | None:
        for run, got in self.runs().items():
            for aid, att in ((got.data or {}).get("attempts") or {}).items():
                if any(s.get("nonce") == nonce for s in att.get("submissions") or []):
                    return run, aid
        return None

    def find_job(self, target: str, job: str) -> tuple[str, str] | None:
        return self._find(target, lambda s: s.get("job") == job)

    def find_log(self, target: str, log: str) -> tuple[str, str] | None:
        return self._find(target, lambda s: (s.get("proc") or {}).get("log") == log)

    def _find(self, target: str, hit: Callable[[dict], bool]) -> tuple[str, str] | None:
        for run, got in self.runs().items():
            for aid, att in ((got.data or {}).get("attempts") or {}).items():
                if att.get("target") == target and any(hit(s) for s in att.get("submissions") or []):
                    return run, aid
        return None

    # ---- grants (the record type and its rules live in grants.py)
    def grants(self) -> Loaded:
        return read_json(self.dir / "grants.json", _is_grants)

    def write_grants(self, doc: dict) -> None:
        with self.locked():
            write_json(self.dir / "grants.json", doc, _is_grants)

    # ---- plans
    def create_plan(self, record: dict) -> str:
        rec = dict(record)
        rec.setdefault("id", f"p-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}-{secrets.token_hex(3)}")
        rec.setdefault("created_at", now())
        pid = str(rec["id"])
        if not NONCE_RE.fullmatch(pid):
            raise RskError(f"plan id {pid!r} must match {NONCE_RE.pattern}", USAGE)
        with self.locked():
            path = self.dir / "plans" / f"{pid}.json"
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                raise RskError(f"plan {pid} exists already — plans are never overwritten", CONFLICT) from None
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(rec, f, indent=1, sort_keys=True, ensure_ascii=False)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())
            _fsync_dir(path.parent)
            self.audit("plan", plan=pid, target=rec.get("target", ""), name=rec.get("name", ""))
        return pid

    def read_plan(self, pid: str) -> Loaded:
        if not NONCE_RE.fullmatch(pid or ""):
            return Loaded(None, "missing")
        data, err = _parse(self.dir / "plans" / f"{pid}.json")
        if err == "missing":
            return Loaded(None, "missing")
        if err or not isinstance(data, dict):
            return Loaded(None, "corrupt", f"plan {pid}: {err or 'unexpected shape'} — make a new plan")
        return Loaded(data, "ok")

    def plans(self) -> list[dict]:
        d = self.dir / "plans"
        out = []
        for p in d.glob("*.json") if d.is_dir() else ():
            got = self.read_plan(p.name.removesuffix(".json"))
            if got.data:
                out.append(got.data)
        return sorted(out, key=lambda r: (str(r.get("created_at", "")), str(r.get("id", ""))))

    def latest_plan(self, target: str, name: str) -> dict | None:
        same = [p for p in self.plans() if p.get("target") == target and p.get("name") == name]
        return same[-1] if same else None

    def claim_plan(self, pid: str, **info: Any) -> dict:
        if not NONCE_RE.fullmatch(pid or ""):
            raise RskError(f"plan id {pid!r} must match {NONCE_RE.pattern}", USAGE)
        rec = {"plan": pid, "at": now(), **info}
        with self.locked():
            path = self.dir / "plans" / f"{pid}.used"
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                prev = self.plan_claim(pid) or {}
                raise RskError(f"plan {pid} was used already ({prev.get('at', '?')}) — make a new plan", CONFLICT) from None
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(rec, f, sort_keys=True, ensure_ascii=False)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())
            self.audit("plan_used", **rec)
        return rec

    def plan_claim(self, pid: str) -> dict | None:
        data, err = _parse(self.dir / "plans" / f"{pid}.used")
        if err == "missing":
            return None
        return data if isinstance(data, dict) else {"plan": pid, "at": "?", "why": err or "unexpected shape"}

    # ---- audit
    def audit(self, event: str, **fields: Any) -> None:
        rec = {"at": now(), "event": event, **fields}
        line = (json.dumps(rec, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
        with self.locked():
            path = self.dir / "audit.jsonl"
            fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                size = os.fstat(fd).st_size
                if size and os.pread(fd, 1, size - 1) != b"\n":   # a torn last line (crash mid-append) stays alone
                    line = b"\n" + line
                os.write(fd, line)
                os.fsync(fd)
            finally:
                os.close(fd)

    def read_audit(self) -> tuple[list[dict], int]:
        out, bad = [], 0
        try:
            text = (self.dir / "audit.jsonl").read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            return [], 0
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                bad += 1
                continue
            if isinstance(rec, dict):
                out.append(rec)
            else:
                bad += 1
        return out, bad

    # ---- watch lease
    def lease(self) -> Loaded:
        return read_json(self.dir / "watch.lease")

    def take_lease(self, until: float, argv: list[str] | tuple[str, ...] = ()) -> dict:
        with self.locked():
            cur = self.lease().data
            st = lease_state(cur)
            if st in ("live", "foreign") and int(cur.get("pid") or 0) != os.getpid():
                raise RskError(f"a watch lease is held: pid {cur.get('pid')} on {cur.get('host')} since "
                               f"{cur.get('started')} until {_iso(cur.get('until'))} ({st}) — one watcher per project",
                               CONFLICT)
            rec = {"pid": os.getpid(), "pid_start": _pid_start(os.getpid()), "host": socket.gethostname(),
                   "boot_id": boot_id(), "started": now(), "until": float(until), "argv": list(argv)}
            write_json(self.dir / "watch.lease", rec)
            self.audit("lease_take", pid=rec["pid"], until=_iso(until), replaced=st if cur else "none")
            return rec

    def release_lease(self) -> bool:
        with self.locked():
            cur = self.lease().data
            if not cur or int(cur.get("pid") or 0) != os.getpid() or cur.get("host") != socket.gethostname():
                return False
            for p in (self.dir / "watch.lease", self.dir / "watch.lease.prev"):
                with contextlib.suppress(FileNotFoundError):
                    p.unlink()
            self.audit("lease_release", pid=os.getpid())
            return True

    # ---- the snapshot grants.check() reads
    def state(self, at: float | None = None) -> LedgerState:
        g = self.grants()
        why, since, ids = [], 0.0, set()
        doc = g.data or {}
        recs = list(doc.get("records") or [])
        if g.source == "corrupt":
            why.append(g.why)
        elif g.recovered:                         # read from .prev right now: every record in it is affected
            why.append(g.why)
            ids |= {r.get("id") for r in recs}
        bu = doc.get("budgets_unknown") or None
        if bu:
            why.append(str(bu.get("why", "grants.json was recovered")))
            ids |= set(bu.get("ids") or [])
        runs: dict[str, dict] = {}
        for name, got in self.runs().items():
            if got.data:
                runs[name] = got.data
                rv = got.data.get("recovered")
                if rv or got.recovered:
                    why.append(f"run {name}: {(rv or {}).get('why') or got.why}")
                    since = max(since, epoch((rv or {}).get("at")) if rv else time.time())
            else:
                why.append(f"run {name}: {got.why}")
                since = time.time()
        return LedgerState(grants=recs, runs=runs, budgets_unknown="; ".join(dict.fromkeys(why)),
                           unknown_since=since, unknown_ids=frozenset(ids), now=at)


BOUND_KEYS = frozenset("partition gres cpus mem time account name extra payload env_kind env_name wandb_mode chain "
                       "gpus_req exclude nice".split())


def next_attempt(atts: dict) -> str:
    n = [int(k[1:]) for k in atts if re.fullmatch(r"a[0-9]+", k)]
    return f"a{(max(n) + 1 if n else 1):02d}"


def _submission(rec: dict, attempt: str, nonce: str) -> dict:
    for s in rec["attempts"][attempt].get("submissions") or []:
        if s.get("nonce") == nonce:
            return s
    raise RskError(f"run {rec.get('run')} {attempt}: no submission with nonce {nonce}", USAGE)


def _settle(att: dict) -> None:
    """The attempt's result, once no submission can still be live: the last ended one decides."""
    subs = att.get("submissions") or []
    if att.get("result") or not subs or is_live({**att, "result": None}):
        return
    ended = [s for s in subs if s.get("end")]
    if ended:
        last = max(ended, key=lambda s: epoch((s.get("end") or {}).get("at")))
        att["result"] = {k: last["end"].get(k, "") for k in ("state", "rc", "at", "evidence")}
    elif all(s.get("submit") == "not_submitted" for s in subs):
        e = subs[-1]
        att["result"] = {"state": "NOT_SUBMITTED", "rc": "", "at": now(), "evidence": e.get("evidence", "")}


def _is_run(d: Any) -> bool:
    return isinstance(d, dict) and isinstance(d.get("attempts"), dict) and isinstance(d.get("run"), str)


def _is_grants(d: Any) -> bool:
    return isinstance(d, dict) and isinstance(d.get("records"), list)


def _iso(t: Any) -> str:
    try:
        return datetime.fromtimestamp(float(t), UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError, OverflowError, OSError):
        return "?"
