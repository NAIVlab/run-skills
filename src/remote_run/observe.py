"""Read-only observation of a project on its targets: one ssh per target, all in parallel under one deadline.

Discovery is by place, not by memory: every job of this user whose Slurm WorkDir is the project's remote dir
(`squeue --states=all` + `sacct` over the last few days), every nohup run that left `logs/<name>-<stamp>.log`
(+ `.pid`). A failed or partial query is reported as unobservable — never as "no jobs". A remote dir that does not
exist under a readable parent is "not synced here" (Slurm still matches jobs against its path); an unreadable parent
(an unmounted filesystem) stays unobservable. The remote script is sent on
stdin inside a function, so a cut-off transfer runs nothing (the same shape as bin/run-watch).

The same read lists the attempt journal (`.rs/attempts/*/`: the newest 50 plus any NONCES asked for, each with its
result, stage, the identity keys of its receipt, the last 512 bytes of its argv and, for asked NONCES, the processes
that still name it), the box's boot_id (nohup: a run whose receipt names another boot ended with that boot), the jobs
whose Slurm comment carries `rs=<NONCE>` (when asked: COMMENTS=1) and, for nohup logs, `<log>.rc` (the wrapper's
`rc= term= at=`). Every read is byte-bounded. run() is the one ssh runner (rsk adopt uses it too).
"""

from __future__ import annotations

import re
import shlex
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

from remote_run.harness import Place

FS_WAIT = 15   # s: how long the remote dir's filesystem may take to answer one stat before the target is unobservable

# A hung mount (its file server gone) blocks even a stat in an uninterruptible wait no `timeout` can kill, and a shell
# that runs `[ -d DIR ]` itself hangs with it, holding the ssh session open until the local deadline. So the first look
# at the dir is a child whose fds are none of the session's (ssh would wait for it), and the shell stops waiting after
# FS_WAIT s; the child stays behind until its filesystem answers. stat, not the builtin `[ -d ]`: tests stub it.
_DIRPROBE = r'''rs_dir() {   # rs_dir DIR -> d (a dir) | n (none; its parent is readable) | x (neither) | h (no answer)
  r=""; read -r -t "${FS_WAIT:-15}" r < <(exec </dev/null 2>/dev/null
    if [ "$(stat -L -c %F -- "$1")" = directory ]; then echo d; elif ls "$(dirname "$1")" >/dev/null; then echo n
    else echo x; fi)
  case "$r" in d|n|x) echo "$r" ;; *) echo h ;; esac
}'''
_HUNG = 'echo "@@fail $RDIR: its filesystem gave no answer within ${FS_WAIT:-15} s (a hung mount?)"; return'

_ATTEMPTS = r'''rs_att() {   # rs_att 1|0 (cwd = the project dir): the newest 50 attempts + the asked NONCES, bounded
  echo @@attempts; [ "$1" = 1 ] && [ -d .rs/attempts ] || return 0
  l=$(ls -1t .rs/attempts 2>/dev/null) || { echo "@@partial attempts"; return 0; }
  pl=""; [ -z "$NONCES" ] || pl=$(ps -u "$U" -o pid=,args= 2>/dev/null) || pl="@@unknown"
  { printf '%s\n' "$l" | head -n 50; for n in $NONCES; do echo "$n"; done; } | awk '!s[$0]++' | while IFS= read -r n; do
    case "$n" in ""|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) continue ;; esac
    a=.rs/attempts/$n
    [ -d "$a" ] || { echo "A $n missing"; continue; }
    echo "A $n $(stat -c %Y "$a" "$a/out" "$a/err" 2>/dev/null | sort -n | tail -n 1)"
    [ ! -f "$a/result" ] || echo "r $(head -c 256 "$a/result" | head -n 1)"
    [ ! -f "$a/stage" ] || echo "s $(head -c 64 "$a/stage" | head -n 1)"
    [ ! -f "$a/receipt" ] || LC_ALL=C grep -a -E '^(job|name|nonce|at|pid|pgid|start|boot_id|log|gpu_ids|target|partition)=' \
      "$a/receipt" | head -c 2048 | sed 's/^/k /'
    [ ! -f "$a/receipt" ] || { v=$(LC_ALL=C sed -n 's/^argv=//p' "$a/receipt" | head -n 1 | tail -c 512); [ -z "$v" ] || printf 'v %s\n' "$v"; }
    g=$(readlink "$a/gate" 2>/dev/null) && echo "g $g"
    case " $NONCES " in *" $n "*)   # a process still naming it: the submit/launch may not be over
      if [ "$pl" = "@@unknown" ]; then echo "p ?"
      else printf '%s\n' "$pl" | LC_ALL=C grep -a -F -e "attempts/$n/" -e "--rs-attempt $n" | head -n 3 | cut -c1-200 | sed 's/^/p /'; fi ;;
    esac
  done
}'''

SLURM = _DIRPROBE + "\n" + _ATTEMPTS + "\n" + r'''rs_obs() {
  echo @@start; U=${USER:-$(id -un)}; export SLURM_TIME_FORMAT=%s; echo "@@now $(date +%s)"; here=0
  case "$(rs_dir "$RDIR")" in
    d) cd "$RDIR" 2>/dev/null || { echo "@@fail cd $RDIR"; return; }; echo "@@pwd $(pwd)|$(pwd -P)"; here=1 ;;
    n) echo "@@nodir"; echo "@@pwd $RDIR" ;;   # jobs of a deleted dir still count
    h) '''+ _HUNG +r''' ;;
    *) echo "@@fail cd $RDIR (its parent is not readable either)"; return ;;
  esac
  q=$(squeue -h -u "$U" --states=all -O "JobID:0|,Name:0|,State:0|,Reason:0|,RestartCnt:0|,StartTime:0|,WorkDir:0|") \
    || { echo "@@fail squeue"; return; }
  echo @@squeue; [ -z "$q" ] || printf "%s\n" "$q"   # no grep: in a UTF-8 locale it drops a non-UTF-8 name's row
  echo @@sacct
  sacct -X -n -P -u "$U" -S "now-${DAYS}days" -o JobID,JobName,State,ExitCode,End,WorkDir 2>&1 || echo "@@partial sacct"
  rs_att "$here"
  if [ "$COMMENTS" = 1 ]; then   # JobID first, the free-text comment last: rs=<NONCE> ends it (submit.sh)
    echo @@comments; c=$(squeue -h -u "$U" --states=all -O "JobID:0|,Comment:0|") || echo "@@partial comments"
    printf '%s\n' "$c" | LC_ALL=C grep -a -F 'rs=' | head -c 65536
  fi
  echo @@end
}
rs_obs'''

NOHUP = _DIRPROBE + "\n" + _ATTEMPTS + "\n" + r'''rs_obs() {
  echo @@start; now=$(date +%s); echo "@@now $now"; U=${USER:-$(id -un)}
  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\~/}" ;; esac
  case "$(rs_dir "$RDIR")" in
    d) cd "$RDIR" 2>/dev/null || { echo "@@fail cd $RDIR"; return; } ;;
    n) echo "@@nodir"; echo "@@end"; return ;;   # no dir, no logs, no runs
    h) '''+ _HUNG +r''' ;;
    *) echo "@@fail cd $RDIR (its parent is not readable either)"; return ;;
  esac
  echo "@@pwd $(pwd)|$(pwd -P)"; echo "@@boot $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
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
    r=""; [ ! -f "$l.rc" ] || r=$(head -c 128 "$l.rc" | head -n 1 | LC_ALL=C tr -c 'A-Za-z0-9=' ',')   # rc=N term=N at=T
    echo "$l $s $p${r:+ $r}"
  done
  rs_att 1
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
    rc: dict = field(default_factory=dict)   # nohup <log>.rc: {"rc", "term", "at"} once the wrapper ended


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
    attempts: dict[str, dict] = field(default_factory=dict)   # nonce -> {mtime missing result stage receipt gate procs}
    attempts_ok: bool = False                      # the journal was listed in full (no @@partial attempts)
    comments: dict[str, str] = field(default_factory=dict)    # Slurm job id -> the NONCE its comment carries
    comments_ok: bool = False                      # asked for, and squeue answered
    boot_id: str = ""                              # nohup: the box's boot_id now ('' = not read)


NONCE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
_RS = re.compile(r"(?:^|\s)rs=([A-Za-z0-9][A-Za-z0-9._-]{0,63})\s*$")


def script(place: Place, days: int, nonces: list[str] | tuple[str, ...] = (), comments: bool = False) -> str:
    asked = " ".join(n for n in nonces if NONCE.fullmatch(n))
    head = (f"RDIR={shlex.quote(place.remote_dir)} DAYS={int(days)} NONCES={shlex.quote(asked)} "
            f"COMMENTS={int(bool(comments))} FS_WAIT={int(FS_WAIT)}\n")
    return head + (SLURM if place.kind == "slurm" else NOHUP) + "\n"   # each one self-contained (rs_att inside)


def _kv(text: str, sep: str = " ") -> dict[str, str]:
    return dict(w.split("=", 1) for w in text.split(sep) if "=" in w)


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
            elif word == "boot":
                o.boot_id = rest.strip()
            elif word == "end":
                o.ok = not o.why
            if word in ("squeue", "sacct", "ws", "attempts", "comments", "end"):   # a note (@@partial stat) is no end
                cur = "" if word == "end" else word
                o.attempts_ok |= word == "attempts"
                o.comments_ok |= word == "comments"
            continue
        if cur:
            sections.setdefault(cur, []).append(line)
    if not o.ok:
        o.why = o.why or (f"ssh exited {rc}: {err.strip()[:200]}" if rc else "the answer was cut off")
        o.attempts_ok = o.comments_ok = False
        return o
    o.attempts_ok &= "attempts" not in o.partial
    o.comments_ok &= "comments" not in o.partial
    cur_a: dict | None = None
    for line in sections.get("attempts", []):
        tag, _, rest = line.partition(" ")
        if tag == "A":
            n, _, m = rest.partition(" ")
            cur_a = o.attempts[n] = {"mtime": _int(m), "missing": m == "missing", "result": {}, "stage": "",
                                     "receipt": {}, "gate": "", "procs": [], "procs_unknown": False, "argv_tail": ""}
        elif cur_a is None:
            continue
        elif tag == "r":
            cur_a["result"] = _kv(rest)
        elif tag == "s":
            cur_a["stage"] = rest.strip()
        elif tag == "k" and "=" in rest:
            k, _, v = rest.partition("=")
            cur_a["receipt"].setdefault(k, v)
        elif tag == "g":
            cur_a["gate"] = rest.strip()
        elif tag == "v":
            cur_a["argv_tail"] = rest
        elif tag == "p":
            if rest.strip() == "?":
                cur_a["procs_unknown"] = True
            else:
                cur_a["procs"].append(rest.strip())
    for line in sections.get("comments", []):
        jid, bar, rest = line.partition("|")
        m = _RS.search(rest.removesuffix("|")) if bar else None
        if m and re.fullmatch(r"[0-9]+(?:_[0-9]+)?", jid.strip()):
            o.comments[jid.strip()] = m.group(1)
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
            rcd = _kv(f[4], ",") if len(f) > 4 and f[4] not in ("", "-") else {}
            name = log.removeprefix("logs/").rsplit("-", 2)[0]
            if rcd.get("rc", "").isdigit():   # the wrapper wrote <log>.rc on its way out: ended, with its status
                o.jobs.append(Job("", name, "ENDED", end=_int(rcd.get("at", "")) or mtime, source="pid", log=log,
                                  reason=p.split(":")[0], exit_code=rcd["rc"], rc=rcd))
            elif p.startswith("alive:"):
                _, up, pid = p.split(":")
                o.jobs.append(Job(pid, name, "ALIVE", start=o.now - _int(up), source="pid", log=log, pid=pid))
            else:
                state = {"gone": "ENDED", "nopid": "NOPID", "reused": "ENDED", "unknown": "UNKNOWN"}.get(p, "UNKNOWN")
                o.jobs.append(Job("", name, state, end=mtime, source="pid", log=log, reason=p))
    return o


def run(place: Place, body: str, deadline: float = 60.0) -> subprocess.CompletedProcess:
    """The one ssh runner: BODY on stdin of `bash -s` on the place's host (BatchMode, bounded by DEADLINE: raises
    subprocess.TimeoutExpired). Callers wrap BODY in a function so a cut-off transfer runs nothing."""
    return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={int(max(1, min(deadline, 30)))}",
                           place.host, "bash -s"], input=body, capture_output=True, encoding="utf-8",
                          errors="replace", timeout=deadline)


def observe(places: list[Place], days: int, deadline: float = 60.0, nonces: dict[str, list[str]] | None = None,
            comments: dict[str, bool] | None = None) -> list[Observation]:
    """One ssh per place, in parallel; each one is killed at the deadline (then: unobservable, timeout).
    NONCES / COMMENTS (per target name): attempts to report even when older than the newest 50 / list rs= comments."""
    def one(place: Place) -> Observation:
        if place.error:
            return Observation(place, why=f"its profile does not load: {place.error}", observed_at=time.time())
        try:
            done = run(place, script(place, days, (nonces or {}).get(place.target, ()),
                                     (comments or {}).get(place.target, False)), deadline)
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
