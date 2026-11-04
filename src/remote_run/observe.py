"""Read-only observation of a project on its targets: one ssh per target, all in parallel under one deadline.

Discovery is by place, not by memory: every job of this user whose Slurm WorkDir is the project's remote dir
(`squeue --states=all` + `sacct` over the last few days), every nohup run that left `logs/<name>-<stamp>.log`
(+ `.pid`). A failed or partial query is reported as unobservable — never as "no jobs". A remote dir that does not
exist under a readable parent is "not synced here" (Slurm still matches jobs against its path); an unreadable parent
(an unmounted filesystem) stays unobservable. The remote script is sent on
stdin inside a function, so a cut-off transfer runs nothing (the same shape as bin/run-watch).
"""

from __future__ import annotations

import shlex
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

from remote_run.harness import Place

SLURM = r'''rs_obs() {
  echo @@start; U=${USER:-$(id -un)}; export SLURM_TIME_FORMAT=%s; echo "@@now $(date +%s)"
  if [ -d "$RDIR" ]; then cd "$RDIR" 2>/dev/null || { echo "@@fail cd $RDIR"; return; }; echo "@@pwd $(pwd)|$(pwd -P)"
  elif ls "$(dirname "$RDIR")" >/dev/null 2>&1; then echo "@@nodir"; echo "@@pwd $RDIR"   # jobs of a deleted dir still count
  else echo "@@fail cd $RDIR (its parent is not readable either)"; return; fi
  q=$(squeue -h -u "$U" --states=all -O "JobID:0|,Name:0|,State:0|,Reason:0|,RestartCnt:0|,StartTime:0|,WorkDir:0|") \
    || { echo "@@fail squeue"; return; }
  echo @@squeue; [ -z "$q" ] || printf "%s\n" "$q"   # no grep: in a UTF-8 locale it drops a non-UTF-8 name's row
  echo @@sacct
  sacct -X -n -P -u "$U" -S "now-${DAYS}days" -o JobID,JobName,State,ExitCode,End,WorkDir 2>&1 || echo "@@partial sacct"
  echo @@end
}
rs_obs'''

NOHUP = r'''rs_obs() {
  echo @@start; now=$(date +%s); echo "@@now $now"
  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\~/}" ;; esac
  if [ -d "$RDIR" ]; then cd "$RDIR" 2>/dev/null || { echo "@@fail cd $RDIR"; return; }
  elif ls "$(dirname "$RDIR")" >/dev/null 2>&1; then echo "@@nodir"; echo "@@end"; return   # no dir, no logs, no runs
  else echo "@@fail cd $RDIR (its parent is not readable either)"; return; fi
  echo "@@pwd $(pwd)|$(pwd -P)"
  echo @@ws
  for l in $(ls -1t logs/*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].log 2>/dev/null | head -n 50); do
    s=$(stat -c "%Y %s" "$l") || { echo "@@partial stat"; continue; }; p=nopid
    if [ -f "$l.pid" ]; then
      pid=$(head -c 64 "$l.pid" | head -n 1 | tr -d " \t\r"); pm=$(stat -c %Y "$l.pid" 2>/dev/null); p=unknown
      case "$pid" in ""|0*|*[!0-9]*) ;; *)
        o=$(ps -o etimes=,stat= -p "$pid" 2>&1); prc=$?; set -f; set -- $o; set +f
        if [ -z "$o" ] && [ "$prc" = 1 ]; then p=gone
        elif [ "$prc" != 0 ] || [ "$#" -lt 2 ] || [ -n "${1//[0-9]/}" ] || [ -z "$pm" ]; then p=unknown
        elif [ "$1" -lt $(( now - pm - 60 )) ]; then p=reused
        elif [ "${2#Z}" != "$2" ]; then p=gone
        else p="alive:$1:$pid"; fi ;;
      esac
    fi
    echo "$l $s $p"
  done
  echo @@end
}
rs_obs'''

TERMINAL = {"COMPLETED", "CANCELLED", "FAILED", "TIMEOUT", "PREEMPTED", "NODE_FAIL", "BOOT_FAIL", "DEADLINE",
            "OUT_OF_MEMORY", "REVOKED"}


@dataclass
class Job:
    id: str
    name: str
    state: str
    reason: str = ""
    restarts: str = ""
    start: int = 0          # epoch seconds (0 = unknown / not started)
    end: int = 0
    exit_code: str = ""
    source: str = ""        # squeue | sacct | pid
    log: str = ""
    pid: str = ""


@dataclass
class Observation:
    place: Place
    ok: bool = False
    why: str = ""                                  # unobservable / partial reason
    nodir: bool = False                            # the remote dir does not exist (its parent does): never synced
    partial: list[str] = field(default_factory=list)
    now: int = 0                                   # remote clock
    observed_at: float = 0.0                       # local clock when the answer arrived
    jobs: list[Job] = field(default_factory=list)


def script(place: Place, days: int) -> str:
    head = f"RDIR={shlex.quote(place.remote_dir)} DAYS={int(days)}\n"
    return head + (SLURM if place.kind == "slurm" else NOHUP) + "\n"


def _int(text: str) -> int:
    return int(text) if text.strip().isdigit() else 0


def parse(place: Place, text: str, rc: int, err: str) -> Observation:
    o = Observation(place, observed_at=time.time())
    sections: dict[str, list[str]] = {}
    cur = ""
    pwds: set[str] = set()
    for line in text.splitlines():
        if line.startswith("@@"):
            word, _, rest = line[2:].partition(" ")
            if word == "fail":
                o.why = rest or "failed"
            elif word == "partial":
                o.partial.append(rest)
            elif word == "nodir":
                o.nodir = True
            elif word == "now":
                o.now = _int(rest)
            elif word == "pwd":
                pwds = {p for p in rest.split("|") if p}
            elif word == "end":
                o.ok = not o.why
            if word in ("squeue", "sacct", "ws", "end"):   # a note inside a section (@@partial stat) does not end it
                cur = "" if word == "end" else word
            continue
        if cur:
            sections.setdefault(cur, []).append(line)
    if not o.ok:
        o.why = o.why or (f"ssh exited {rc}: {err.strip()[:200]}" if rc else "the answer was cut off")
        return o
    if place.kind == "slurm":
        # Name is free text and may hold '|': JobID from the left, every other field from the right.
        queued: dict[str, Job] = {}
        for line in sections.get("squeue", []):
            f = line.removesuffix("|").rsplit("|", 5)
            jid, bar, name = f[0].partition("|")
            if len(f) < 6 or not bar or f[5] not in pwds:
                continue
            queued[jid] = Job(jid, name, f[1], f[2], f[3], _int(f[4]), source="squeue")
            o.jobs.append(queued[jid])
        for line in sections.get("sacct", []):
            f = line.rsplit("|", 4)
            jid, bar, name = f[0].partition("|")
            if len(f) < 5 or not bar:
                if line.strip():
                    o.partial.append(f"sacct: {line.strip()[:160]}")
                continue
            state = f[1].split(" ")[0]
            if f[4] not in pwds:
                continue
            if jid in queued:   # squeue is fresher, unless both say it ended: then sacct's row has End and ExitCode
                if queued[jid].state not in TERMINAL or state not in TERMINAL:
                    continue
                o.jobs.remove(queued[jid])
            o.jobs.append(Job(jid, name, state, exit_code=f[2], end=_int(f[3]), source="sacct"))
    else:
        for line in sections.get("ws", []):
            f = line.split(" ")
            if len(f) < 4:
                continue
            log, mtime, p = f[0], _int(f[1]), f[3]
            name = log.removeprefix("logs/").rsplit("-", 2)[0]
            if p.startswith("alive:"):
                _, up, pid = p.split(":")
                o.jobs.append(Job(pid, name, "ALIVE", start=o.now - _int(up), source="pid", log=log, pid=pid))
            else:
                state = {"gone": "ENDED", "nopid": "NOPID", "reused": "ENDED", "unknown": "UNKNOWN"}.get(p, "UNKNOWN")
                o.jobs.append(Job("", name, state, end=mtime, source="pid", log=log, reason=p))
    return o


def observe(places: list[Place], days: int, deadline: float = 60.0) -> list[Observation]:
    """One ssh per place, in parallel; each one is killed at the deadline (then: unobservable, timeout)."""
    def one(place: Place) -> Observation:
        if place.error:
            return Observation(place, why=f"its profile does not load: {place.error}", observed_at=time.time())
        try:
            done = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={int(min(deadline, 30))}",
                                   place.host, "bash -s"], input=script(place, days), capture_output=True,
                                  encoding="utf-8", errors="replace", timeout=deadline)
            return parse(place, done.stdout, done.returncode, done.stderr)
        except subprocess.TimeoutExpired:
            return Observation(place, why=f"no answer within {deadline:.0f} s", observed_at=time.time())
        except OSError as exc:
            return Observation(place, why=f"ssh: {exc}", observed_at=time.time())
        except Exception as exc:   # one odd answer makes this target unobservable, never the whole read a traceback
            return Observation(place, why=f"unreadable answer: {exc!r}"[:300], observed_at=time.time())
    if not places:
        return []
    with ThreadPoolExecutor(max_workers=min(8, len(places))) as pool:
        return list(pool.map(one, places))


def age(seconds: float) -> str:
    s = int(max(0, seconds))
    if s < 90:
        return f"{s}s"
    if s < 5400:
        return f"{s // 60}m"
    if s < 172800:
        return f"{s // 3600}h{(s % 3600) // 60:02d}m"
    return f"{s // 86400}d{(s % 86400) // 3600}h"
