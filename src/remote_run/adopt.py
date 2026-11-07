"""`rsk adopt`: record in the ledger a job or run this project already has on a target, or close an attempt whose
submit outcome is unknown — each after ONE ssh (observe.run) that checks it really is this project's and this user's.

  rsk adopt -T t --job J --as RUN       Slurm: J is listed for this user (squeue/sacct -u, the `rsk status` read),
                                        its WorkDir is the project's remote dir (logical or physical) and its name's
                                        run id (minus --aNN) is RUN. Its nonce comes from the journal or its comment.
  rsk adopt -T t --log L --as RUN       nohup: the attempt receipt naming L, checked by its triple (pid + /proc start
                                        + boot_id); a launch without a receipt by L.pid's /proc entry (owner = you,
                                        cwd = the project dir, at least as old as the pid file). A run that ended is
                                        adopted as ended (its <log>.rc when there is one).
  rsk adopt -T t --not-submitted NONCE --approve "the user's words" [--as RUN]
                                        only while that attempt's outcome is open (result unknown or absent): no
                                        receipt, no job carrying rs=NONCE, no process naming it, nothing moved for
                                        GRACE_S, and (Slurm) no unledgered job of this dir with its name. Marks it
                                        NOT_SUBMITTED and gives its grant use back. The words are the user's: the
                                        agent asks; this command cannot tell who typed them.
Adopted runs are bookkeeping: they use no grant, and `cancel_own` never covers them (they are not the agent's).
Exit: 0 recorded (or already there), 2 usage, 4 --approve words that repeat a standing grant's quote (grants.recycled),
5 the target could not be read, 6 the identity does not match.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import shlex
import subprocess
import time

from remote_run import grants, harness, observe, paths
from remote_run import ledger as L
from remote_run.errors import CONFLICT, OK, UNKNOWN, USAGE, RskError
from remote_run.status import GRACE_S, known_keys, project_dir, select

LOG_RE = re.compile(r"logs/([^/]+)-[0-9]{8}-[0-9]{6}\.log")
JOB_RE = re.compile(r"[0-9]+(?:_[0-9]+)?")

NOHUP_LOG = r'''rs_adopt() {
  echo @@start; now=$(date +%s); echo "@@now $now"; echo "@@user ${USER:-$(id -un)}"
  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\~/}" ;; esac
  cd "$RDIR" 2>/dev/null || { echo "@@fail cd $RDIR"; return; }
  echo "@@pwd $(pwd)|$(pwd -P)"; echo "@@boot $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
  [ -f "$L" ] || { echo "@@nolog"; echo @@end; return; }
  r=$(LC_ALL=C grep -l -a -x -F -e "log=$L" .rs/attempts/*/receipt 2>/dev/null | head -n 1); p=""
  if [ -n "$r" ]; then d=${r%/receipt}; echo "@@receipt ${d##*/}"
    LC_ALL=C grep -a -E '^(pid|pgid|start|boot_id|log|name|nonce|at|gpu_ids)=' "$r" | head -c 2048 | sed 's/^/k /'
    echo "@@gate $(readlink "$d/gate" 2>/dev/null)"; p=$(sed -n 's/^pid=//p' "$r" | head -n 1); fi
  if [ -f "$L.pid" ]; then q=$(head -c 64 "$L.pid" | head -n 1 | tr -d ' \t\r'); echo "@@pidfile $q $(stat -c %Y "$L.pid")"
    [ -n "$p" ] || p=$q; fi
  [ ! -f "$L.rc" ] || echo "@@rc $(head -c 128 "$L.rc" | head -n 1)"
  case "$p" in ''|*[!0-9]*) ;; *)
    if s=$(cat "/proc/$p/stat" 2>/dev/null); then s=${s##*)}; set -f; set -- $s; set +f
      echo "@@proc $p $1 $3 ${20}"; echo "@@owner $(stat -c %U "/proc/$p" 2>/dev/null)"
      echo "@@cwd $(readlink "/proc/$p/cwd" 2>/dev/null)"; echo "@@etimes $(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')"
    else echo "@@proc $p gone"; fi ;;
  esac
  echo @@end
}
rs_adopt'''


def out(msg: str) -> None:
    print(msg, flush=True)


def _place(args: argparse.Namespace) -> tuple[L.Ledger, harness.Place]:
    proj = project_dir(args.dir)
    return L.Ledger(proj), select(harness.places(paths.harness_src(), proj), [args.target])[0]


def _read(place: harness.Place, days: int, deadline: float, nonce: str = "") -> observe.Observation:
    o = observe.observe([place], days, deadline, nonces={place.target: [nonce] if nonce else []},
                        comments={place.target: place.kind == "slurm"})[0]
    if not o.ok:
        raise RskError(f"[{place.target}] cannot verify — the target did not answer in full: {o.why} (nothing "
                       "recorded)", UNKNOWN)
    return o


def adopt_job(led: L.Ledger, place: harness.Place, job: str, run: str, days: int, deadline: float) -> int:
    if place.kind != "slurm":
        raise RskError(f"--job is for Slurm targets; {place.target} is nohup: --log <logs/…log>", USAGE)
    if not JOB_RE.fullmatch(job):
        raise RskError(f"--job {job!r}: a Slurm job id", USAGE)
    hit = led.find_job(place.target, job)
    if hit:
        out(f"job {job} is in the ledger already: run {hit[0]} {hit[1]}")
        return OK
    o = _read(place, days, deadline)
    j = next((x for x in o.jobs if x.id == job), None)
    if j is None:
        raise RskError(f"job {job} is not among your jobs from {place.remote_dir} on {place.target} (squeue + sacct "
                       f"{days}d, WorkDir compared logically and physically): another dir, another user, a wrong id or "
                       "older than --days — nothing adopted", CONFLICT)
    if L.run_id(j.name) != run:
        raise RskError(f"job {job} is named {j.name!r} (run {L.run_id(j.name)!r}), not run {run!r} — nothing adopted",
                       CONFLICT)
    nonce = next((n for n, a in o.attempts.items() if (a.get("receipt") or {}).get("job") == job), "") \
        or o.comments.get(job, "")
    known = led.find_nonce(nonce) if nonce else None
    ev = f"adopted: {j.source} lists it for this user with WorkDir = the project dir"
    if known:       # the ledger has this attempt with an open outcome: it is the job
        led.set_submission(known[0], known[1], nonce, submit="submitted", job=job, evidence=ev)
        r, a = known
    else:
        r, a = led.record_attempt(name=j.name, target=place.target, kind="slurm", nonce=nonce or f"adopt-job-{job}",
                                  submit="adopted", job=job, action="adopted", evidence=ev)
    end = {"state": j.state, "rc": j.exit_code, "evidence": j.source} if j.state in observe.TERMINAL else None
    led.observe(r, a, job, j.state, j.source, end=end)
    led.audit("adopt", run=r, attempt=a, target=place.target, job=job, nonce=nonce, state=j.state)
    out(f"adopted job {job} ({j.name}, {j.state}) as run {r} {a}{' — nonce ' + nonce if nonce else ''}")
    return OK


def _norm_log(log: str, rdir: str) -> str:
    rdir = rdir.rstrip("/")
    if log.startswith(rdir + "/"):
        log = log[len(rdir) + 1:]
    log = log.removeprefix("./")
    if not LOG_RE.fullmatch(log) or ".." in log.split("/"):
        raise RskError(f"--log {log!r}: logs/<name>-<YYYYmmdd-HHMMSS>.log (relative to the project dir)", USAGE)
    return log


def _ws_parse(text: str) -> tuple[dict[str, str], dict[str, str]]:
    """(the @@ facts, the receipt's keys) of NOHUP_LOG's answer."""
    d: dict[str, str] = {}
    rc: dict[str, str] = {}
    for line in text.splitlines():
        if line.startswith("k ") and "=" in line:
            k, _, v = line[2:].partition("=")
            rc.setdefault(k, v)
        elif line.startswith("@@"):
            w, _, rest = line[2:].partition(" ")
            d.setdefault(w, rest.strip())
    return d, rc


def adopt_log(led: L.Ledger, place: harness.Place, log: str, run: str, deadline: float) -> int:
    if place.kind != "nohup":
        raise RskError(f"--log is for nohup targets; {place.target} is Slurm: --job <id>", USAGE)
    log = _norm_log(log, place.remote_dir)
    name = LOG_RE.fullmatch(log).group(1)
    if L.run_id(name) != run:
        raise RskError(f"{log} is run {L.run_id(name)!r} ({name}), not {run!r} — nothing adopted", CONFLICT)
    hit = led.find_log(place.target, log)
    if hit:
        out(f"{log} is in the ledger already: run {hit[0]} {hit[1]}")
        return OK
    body = f"RDIR={shlex.quote(place.remote_dir)} L={shlex.quote(log)}\n{NOHUP_LOG}\n"
    try:
        done = observe.run(place, body, deadline)
    except subprocess.TimeoutExpired:
        raise RskError(f"[{place.target}] no answer within {deadline:.0f} s — nothing recorded", UNKNOWN) from None
    d, rc = _ws_parse(done.stdout)
    if "end" not in d or "fail" in d:
        raise RskError(f"[{place.target}] cannot verify: {d.get('fail') or done.stderr.strip()[:200] or 'cut off'}",
                       UNKNOWN)
    if "nolog" in d:
        raise RskError(f"no {log} in {place.remote_dir} on {place.target} — nothing adopted", USAGE)
    pwds = {p for p in d.get("pwd", "").split("|") if p}
    boot = d.get("boot", "")
    proc = d.get("proc", "").split()
    alive = len(proc) == 4 and proc[1] not in ("Z", "X")
    rcd = observe._kv(d.get("rc", ""))
    nonce = d.get("receipt", "")
    if rc:
        nonce = rc.get("nonce", "") or nonce
        if rc.get("name") and rc.get("name") != name:
            raise RskError(f"the receipt for {log} names {rc.get('name')!r}, not {name!r} — nothing adopted", CONFLICT)
        if d.get("gate", "") != "go":
            raise RskError(f"the attempt behind {log} never started its run (gate {d.get('gate') or 'unset'})"
                           " — nothing to adopt", CONFLICT)
        ident = {k: rc.get(k, "") for k in ("pid", "pgid", "start", "boot_id", "log", "gpu_ids")}
        same = alive and proc[0] == rc.get("pid") and proc[3] == rc.get("start") and boot == rc.get("boot_id")
        how = "receipt triple (pid + start + boot_id)"
        why_not = "" if same else ("the pid is gone" if not alive else "the pid now belongs to another process "
                                   "(start or boot differs)")
    else:
        pf = (d.get("pidfile") or "").split()
        if not pf:
            raise RskError(f"{log} has neither a receipt nor a .pid file: nothing proves which process it was", CONFLICT)
        pmt = int(pf[1]) if len(pf) > 1 and pf[1].isdigit() else 0
        now = int(d.get("now", "0") or 0)
        et = d.get("etimes", "")
        owner_ok = bool(d.get("owner")) and d.get("owner") == d.get("user")
        cwd_ok = d.get("cwd", "") in pwds
        age_ok = et.isdigit() and pmt and int(et) >= now - pmt - 60
        same = alive and owner_ok and cwd_ok and bool(age_ok)
        ident = {"pid": pf[0], "pgid": proc[2] if alive else "", "start": proc[3] if alive else "", "boot_id": boot,
                 "log": log, "gpu_ids": ""}
        how = "/proc (owner, cwd, older than the .pid file)"
        why_not = "" if same else ("the pid is gone" if not alive else "pid " + pf[0] + " is not this run: " + ", ".join(
            w for w, ok in (("owner", owner_ok), ("cwd", cwd_ok), ("age", age_ok)) if not ok))
    ev = f"adopted: {how}" if same else f"adopted ended: {why_not}"
    known = led.find_nonce(nonce) if nonce else None
    if known:
        led.set_submission(known[0], known[1], nonce, submit="submitted", proc=ident, evidence=ev)
        r, a = known
    else:
        r, a = led.record_attempt(name=name, target=place.target, kind="nohup",
                                  nonce=nonce or "adopt-log-" + hashlib.sha256(log.encode()).hexdigest()[:16],
                                  submit="adopted", proc=ident, action="adopted", evidence=ev)
    if rcd.get("rc", "").isdigit():
        led.observe(r, a, log, "ENDED", "pid", end={"state": "ENDED", "rc": rcd["rc"],
                                                    "evidence": f"{log}.rc term={rcd.get('term', '?')}"})
        st = f"ENDED rc={rcd['rc']}"
    elif same:
        led.observe(r, a, log, "ALIVE", "pid")
        st = "ALIVE"
    else:
        led.observe(r, a, log, "ENDED", "pid", end={"state": "ENDED", "rc": "", "evidence": why_not})
        st = f"ENDED ({why_not})"
    led.audit("adopt", run=r, attempt=a, target=place.target, log=log, nonce=nonce, state=st)
    out(f"adopted {log} as run {r} {a}: {st} — {how}")
    return OK


def not_submitted(led: L.Ledger, place: harness.Place, nonce: str, words: str, run: str, days: int,
                  deadline: float) -> int:
    if not L.NONCE_RE.fullmatch(nonce):
        raise RskError(f"--not-submitted {nonce!r}: a nonce ({L.NONCE_RE.pattern})", USAGE)
    if not words.strip():
        raise RskError("--not-submitted needs --approve \"the user's words\": only the user decides that an unknown "
                       "submit did not happen", USAGE)
    hit = led.find_nonce(nonce)
    sub, att = None, None
    if hit:
        att = led.read_run(hit[0]).data["attempts"][hit[1]]
        sub = next(s for s in att["submissions"] if s.get("nonce") == nonce)
        if att.get("target") != place.target:
            raise RskError(f"nonce {nonce} is an attempt on {att.get('target')}, not {place.target}", USAGE)
        if sub.get("submit") == "not_submitted":
            out(f"{hit[0]} {hit[1]}: nonce {nonce} is recorded as not submitted already")
            return OK
        if sub.get("submit") != "unknown":
            raise RskError(f"{hit[0]} {hit[1]}: nonce {nonce} is {sub.get('submit')} (job {sub.get('job') or '?'}) — "
                           "not an open outcome", CONFLICT)
    elif not run:
        raise RskError(f"no ledger attempt carries nonce {nonce}: name its run with --as RUN to record it", USAGE)
    o = _read(place, days, deadline, nonce)
    if not o.attempts_ok:
        raise RskError(f"[{place.target}] the attempt journal could not be listed — cannot prove anything", UNKNOWN)
    a = o.attempts.get(nonce) or {"missing": True}
    rcpt, res = a.get("receipt") or {}, a.get("result") or {}
    verdict = res.get("verdict", "")
    if rcpt:
        what = f"job {rcpt['job']}" if rcpt.get("job") else f"pid {rcpt.get('pid')}, log {rcpt.get('log')}"
        raise RskError(f"attempt {nonce} has a receipt ({what}): it was submitted — rsk adopt "
                       f"{'--job ' + rcpt['job'] if rcpt.get('job') else '--log ' + rcpt.get('log', '<log>')} --as <run>",
                       CONFLICT)
    if a.get("gate") == "go" or verdict in ("submitted", "launched"):
        raise RskError(f"attempt {nonce}: verdict {verdict or 'launched (gate go)'} — it was submitted", CONFLICT)
    if place.kind == "slurm":
        if not o.comments_ok:
            raise RskError(f"[{place.target}] squeue's comments could not be read: cannot prove that no job carries "
                           f"rs={nonce}", UNKNOWN)
        carried = [j for j, n in o.comments.items() if n == nonce]
        if carried:
            raise RskError(f"job {carried[0]} carries rs={nonce}: it was submitted — rsk adopt --job {carried[0]} "
                           "--as <run>", CONFLICT)
    if a.get("procs_unknown"):
        raise RskError(f"[{place.target}] the process list could not be read: the submit may still run", UNKNOWN)
    if a.get("procs"):
        raise RskError(f"a process still names attempt {nonce}: {a['procs'][0][:160]} — it is not over", CONFLICT)
    moved = max(float(a.get("mtime") or 0), L.epoch((sub or {}).get("at")))
    if verdict not in ("refused", "failed") and time.time() - moved < GRACE_S:
        raise RskError(f"attempt {nonce} moved {observe.age(time.time() - moved)} ago: it may still be running "
                       f"somewhere — read it again after {GRACE_S // 60} minutes", CONFLICT)
    if place.kind == "slurm":
        keys, _ = known_keys(led.state(), place.target)
        want = L.run_id((att or {}).get("name") or run)
        twins = [j for j in o.jobs if j.id not in keys and L.run_id(j.name) == want]
        if twins:
            raise RskError(f"job {twins[0].id} ({twins[0].name}, {twins[0].state}) from this dir is not in the ledger "
                           f"and could be this attempt — if it is: rsk adopt -T {place.target} --job {twins[0].id} "
                           f"--as {want}", CONFLICT)
    ev = (f"remote: {'no attempt dir' if a.get('missing') else 'stage ' + (a.get('stage') or '?')}"
          f", result {('verdict=' + verdict) if verdict else 'absent'}, no receipt, no job/process carries it")
    if hit:
        led.set_submission(hit[0], hit[1], nonce, submit="not_submitted", evidence=ev, quote=words)
        gid = str((att.get("request") or {}).get("grant", ""))
        if gid and grants.refund(led, gid, nonce, "not submitted (the user's words)"):
            out(f"  the use of {gid} by {nonce} is given back")
        r, aid = hit
    else:
        r, aid = led.record_attempt(name=run, target=place.target, kind=place.kind, nonce=nonce,
                                    submit="not_submitted", action="adopted", evidence=ev, quote=words)
    led.audit("not_submitted", run=r, attempt=aid, target=place.target, nonce=nonce, evidence=ev, quote=words)
    out(f"{r} {aid}: attempt {nonce} recorded as NOT_SUBMITTED ({ev})")
    return OK


def cmd_adopt(args: argparse.Namespace) -> int:
    chosen = [x for x in (args.job, args.log, args.not_submitted) if x]
    if len(chosen) != 1:
        raise RskError("rsk adopt takes one of --job J, --log L, --not-submitted NONCE", USAGE)
    if (args.job or args.log) and not args.run:
        raise RskError("--as RUN: the run id the ledger files it under (the name minus --aNN)", USAGE)
    if args.approve and not args.not_submitted:
        raise RskError("--approve belongs to --not-submitted only (adopting is bookkeeping)", USAGE)
    led, place = _place(args)
    if args.not_submitted:
        grants.refuse_recycled(args.approve or None, led.state().grants, "this unknown submit")
    if args.job:
        return adopt_job(led, place, args.job, args.run, args.days, args.deadline)
    if args.log:
        return adopt_log(led, place, args.log, args.run, args.deadline)
    return not_submitted(led, place, args.not_submitted, args.approve or "", args.run or "", args.days, args.deadline)


def add_parser(sub) -> None:
    a = sub.add_parser("adopt", help="record an existing job/run of this project in the ledger (identity checked), "
                       "or close an unknown submit with the user's words")
    a.add_argument("-T", "--target", required=True)
    a.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory)")
    a.add_argument("--job", default="", help="Slurm job id")
    a.add_argument("--log", default="", help="nohup log: logs/<name>-<YYYYmmdd-HHMMSS>.log")
    a.add_argument("--not-submitted", default="", metavar="NONCE", help="an attempt whose outcome is unknown")
    a.add_argument("--as", dest="run", default="", metavar="RUN", help="the run id (the name minus --aNN)")
    a.add_argument("--approve", default="", metavar="WORDS", help="the user's words (only with --not-submitted)")
    a.add_argument("--days", type=int, default=7, help="how far back sacct looks for the job (default 7)")
    a.add_argument("--deadline", type=float, default=60.0)
    a.set_defaults(func=cmd_adopt)
