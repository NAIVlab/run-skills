"""`rsk cancel`: stop a run of this project — only after grants.check() and an identity check on the target.

    rsk cancel RUN [--job J] [-T T] [--approve "the user's words"] [-C DIR] [--grace S] [--deadline S]
    rsk cancel --job J -T T [--approve "the user's words"] [-C DIR] [--grace S] [--deadline S]

What may be stopped (the user's policy, §U of the P3 contract):
  - the user said it ("cancel job 123"): --approve "their words" records a cancel approval naming exactly those job(s)
    (grants.new_cancel_approval) — acted on once the identity check passes;
  - the agent's own judgment: only a run rsk launched for this project (a ledger attempt with a plan, never an
    adopted one) under a standing grant with cancel_own in scope; anything else is the user's call → exit 4;
  - a deny always wins (exit 3, its quote); someone else's job or process: never (exit 3), whatever was approved.
Identity, then the action, in ONE ssh (nothing is cancelled that this same read did not check):
  slurm  J is in `squeue -u $USER` with this user, the ledger's job name (an unledgered job: its own record's), and
         WorkDir = the project's remote dir (logical or physical) → `scancel J`. A job not in that list is not
         cancelled: another user's (exit 3, from `squeue -j J`), or ended / a wrong id.
  nohup  J = the run's pid: its receipt (.rs/attempts/<nonce>/receipt, else the one naming pid=J, else the ledger's
         adopted triple) has pid J, gate go, the box's boot_id and /proc/J's start time, the owner is $USER and it
         leads its process group → `kill -TERM -- -<pgid>`, up to --grace seconds (30) for the group to go, then
         `kill -KILL -- -<pgid>`; the run's <log>.rc is read back.
Recorded: the approval (if any), the grant use (given back only when nothing can have been cancelled: not once a job
passed its identity check, even if the answer was cut off after it), the observation (Slurm: CANCELLING until rsk
status sees the end; nohup: CANCELLED with its rc) and an audit line.
Exit: 0 cancelled (or already gone) · 2 usage · 3 denied / not this user's · 4 needs the user · 5 the target could
not be read · 6 the identity does not match (name, WorkDir, receipt) · 1 scancel / kill failed.
"""

from __future__ import annotations

import argparse
import re
import secrets
import shlex
import subprocess
from dataclasses import dataclass

from remote_run import grants, harness, observe, paths
from remote_run import ledger as L
from remote_run.errors import CONFLICT, FAILED, NEEDS_USER, OK, REFUSED, UNKNOWN, USAGE, RskError

JOB_RE = re.compile(r"[0-9]+(?:_[0-9]+)?")
PID_RE = re.compile(r"[1-9][0-9]{0,9}")

SLURM_SH = r'''rs_cancel() {   # rs_cancel JOB WANT_NAME ... : identity of each, then scancel of exactly those that passed
  echo @@start; U=${USER:-$(id -un)}; echo "@@user $U"
  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\~/}" ;; esac
  cd "$RDIR" 2>/dev/null || { echo "@@fail cd $RDIR"; return 0; }; p1=$(pwd); p2=$(pwd -P); echo "@@pwd $p1|$p2"
  q=$(squeue -h -u "$U" --states=all -O "JobID:0|,Name:0|,UserName:0|,WorkDir:0|,State:0|") || { echo "@@fail squeue"; return 0; }
  ok=""
  while [ "$#" -ge 2 ]; do j=$1; want=$2; shift 2
    case "$j" in ""|*[!0-9_]*) echo "@@c $j badid"; continue ;; esac
    l=$(printf '%s\n' "$q" | LC_ALL=C grep -a "^$j|" | head -n 1)
    if [ -z "$l" ]; then   # not among this user's: another user's queued job, or ended / a wrong id
      o=$(squeue -h -j "$j" -O "JobID:0|,UserName:0|" 2>/dev/null | LC_ALL=C grep -a "^$j|" | head -n 1)
      if [ -n "$o" ]; then o=${o#*|}; echo "@@c $j user=${o%|}"; else echo "@@c $j gone"; fi; continue; fi
    r=${l%|}; js=${r##*|}; r=${r%|*}; jw=${r##*|}; r=${r%|*}; ju=${r##*|}; r=${r%|*}; jn=${r#*|}   # Name may hold '|'
    case "$js" in COMPLETED|CANCELLED|FAILED|TIMEOUT|PREEMPTED|NODE_FAIL|BOOT_FAIL|DEADLINE|OUT_OF_MEMORY|REVOKED) echo "@@c $j ended=$js"; continue ;; esac
    [ "$ju" = "$U" ] || { echo "@@c $j user=$ju"; continue; }
    [ -z "$want" ] || [ "$jn" = "$want" ] || { echo "@@c $j name=$jn"; continue; }
    if [ "$jw" != "$p1" ] && [ "$jw" != "$p2" ] && { [ -z "$jw" ] || [ "$(CDPATH= cd -- "$jw" 2>/dev/null && pwd -P)" != "$p2" ]; }; then
      echo "@@c $j workdir=$jw"; continue; fi
    echo "@@c $j ok state=$js name=$jn"; ok="$ok $j"
  done
  [ -n "$ok" ] || { echo "@@scancel none"; echo @@end; return 0; }
  scancel $ok; echo "@@scancel rc=$? ids=${ok# }"; echo @@end
}'''

NOHUP_SH = r'''rs_kill() {   # rs_kill PID NONCE START BOOT ... : identity of each (receipt, /proc, owner, group), then TERM, grace, KILL
  echo @@start; U=${USER:-$(id -un)}; echo "@@user $U"; boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\~/}" ;; esac
  cd "$RDIR" 2>/dev/null || { echo "@@fail cd $RDIR"; return 0; }
  [ -n "$boot" ] || { echo "@@fail no /proc boot_id"; return 0; }
  kv() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }
  pst() { local s; s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1; s=${s##*)}; set -f; set -- $s; set +f
    [ "$#" -ge 20 ] && [ "$1" != Z ] && [ "$1" != X ] || return 1; printf '%s %s\n' "${20}" "$3"; }
  ngrp() { ps -e -o pgid=,stat= 2>/dev/null | awk -v g="$1" '$1 == g && $2 !~ /^Z/' | grep -c .; }   # a zombie holds nothing
  groups=""; logs=""
  while [ "$#" -ge 4 ]; do p=$1; n=$2; es=$3; eb=$4; shift 4
    case "$p" in ""|0*|*[!0-9]*) echo "@@c $p badpid"; continue ;; esac
    r=""; case "$n" in ""|*[!A-Za-z0-9._-]*) ;; *) [ ! -f ".rs/attempts/$n/receipt" ] || r=.rs/attempts/$n/receipt ;; esac
    [ -n "$r" ] || r=$(LC_ALL=C grep -l -a -x -F -e "pid=$p" .rs/attempts/*/receipt 2>/dev/null | head -n 1)
    if [ -n "$r" ]; then d=${r%/receipt}; g=$(readlink "$d/gate" 2>/dev/null)
      rp=$(kv pid "$r"); rg=$(kv pgid "$r"); rs=$(kv start "$r"); rb=$(kv boot_id "$r"); rl=$(kv log "$r")
      echo "@@r $p receipt=${d##*/} pid=$rp pgid=$rg start=$rs boot_id=$rb gate=$g log=$rl"
      [ "$rp" = "$p" ] || { echo "@@c $p receipt-pid=$rp"; continue; }
      [ "$g" = go ] || { echo "@@c $p notstarted"; continue; }
      [ -z "$es" ] || [ "$es" = "$rs" ] || { echo "@@c $p ledger-start=$es"; continue; }
    elif [ -n "$es" ] && [ -n "$eb" ]; then rs=$es; rb=$eb; rg=$p; rl=""; echo "@@r $p ledger start=$rs boot_id=$rb"
    else echo "@@c $p noidentity"; continue; fi
    [ "$rb" = "$boot" ] || { echo "@@c $p gone boot"; continue; }
    cur=$(pst "$p") || { echo "@@c $p gone"; continue; }
    [ "${cur%% *}" = "$rs" ] || { echo "@@c $p gone reused"; continue; }
    o=$(stat -c %U "/proc/$p" 2>/dev/null); [ "$o" = "$U" ] || { echo "@@c $p user=${o:-?}"; continue; }
    pg=${cur#* }; [ "$pg" = "$p" ] && { [ -z "$rg" ] || [ "$rg" = "$pg" ]; } || { echo "@@c $p pgid=$pg"; continue; }
    echo "@@c $p ok"; groups="$groups $p"; logs="$logs $p:$rl"
  done
  [ -n "$groups" ] || { echo "@@kill none"; echo @@end; return 0; }
  for g in $groups; do kill -TERM -- "-$g" 2>/dev/null; echo "@@term $g rc=$?"; done
  i=0; while [ "$i" -lt "$GRACE" ]; do n=0; for g in $groups; do [ "$(ngrp "$g")" = 0 ] || n=$((n + 1)); done
    [ "$n" -gt 0 ] || break; sleep 1; i=$((i + 1)); done
  for g in $groups; do if [ "$(ngrp "$g")" != 0 ]; then kill -KILL -- "-$g" 2>/dev/null; echo "@@killed $g rc=$? after=${i}s"; fi; done
  sleep 1; for e in $logs; do g=${e%%:*}; l=${e#*:}; c=""; [ -z "$l" ] || [ ! -f "$l.rc" ] || c=$(head -c 128 "$l.rc" | head -n 1)
    echo "@@left $g $(ngrp "$g") after=${i}s rc=[$c]"; done
  echo @@end
}'''


def out(msg: str = "") -> None:
    print(msg, flush=True)


@dataclass
class Item:
    """One job (Slurm id) or process (nohup pid) to stop, and what its identity must be."""
    job: str
    run: str = ""                # '' = not in the ledger (the named job's own record decides the name)
    attempt: str = ""
    nonce: str = ""
    name: str = ""
    start: str = ""              # nohup: the ledger's /proc start and boot_id (adopted runs without a receipt)
    boot_id: str = ""
    log: str = ""
    own: bool = False            # a ledger attempt rsk launched with a plan (cancel_own may cover it)


def items_of_run(led: L.Ledger, run: str, target: str, job: str) -> tuple[str, list[Item]]:
    """(target, items) — every live submission of RUN (on TARGET when given; only JOB when given). No live one:
    (the target of its last attempt, [])."""
    got = led.read_run(run)
    atts = (got.data or {}).get("attempts") or {}
    if not atts:
        raise RskError(f"no ledger run {run!r} (rsk status lists them; a job the ledger does not know: --job J -T T)",
                       USAGE)
    found: list[tuple[str, Item]] = []
    for aid, att in sorted(atts.items()):
        if target and att.get("target") != target:
            continue
        own = (att.get("request") or {}).get("action") in grants.LAUNCHES and bool((att.get("request") or {}).get("plan"))
        for s in att.get("submissions") or []:
            if s.get("end") or s.get("submit") == "not_submitted":
                continue
            seen = (s.get("seen") or {}).get("state", "")
            if seen in L.TERMINAL:
                continue
            p = s.get("proc") or {}
            key = str(s.get("job") or p.get("pid") or "")
            if job and key != job:
                continue
            if not key:
                raise RskError(f"{run} {aid}: nonce {s.get('nonce')} is SUBMIT_UNKNOWN — no job id to cancel yet: rsk "
                               "status reconciles it first", CONFLICT)
            found.append((str(att.get("target")), Item(key, run, aid, str(s.get("nonce", "")), str(att.get("name", "")),
                                                       str(p.get("start", "")), str(p.get("boot_id", "")),
                                                       str(p.get("log", "")), own and s.get("submit") != "adopted")))
    if not found:
        last = atts[max(atts, key=lambda k: int(k[1:]) if k[1:].isdigit() else 0)]
        return target or str(last.get("target", "")), []
    targets = sorted({t for t, _ in found})
    if len(targets) > 1:
        raise RskError(f"run {run} is live on {', '.join(targets)}: name one with -T", USAGE)
    return targets[0], [i for _, i in found]


def item_of_job(led: L.Ledger, target: str, job: str, kind: str) -> Item:
    if kind == "slurm":
        hit = led.find_job(target, job)
    else:
        hit = led._find(target, lambda s: str((s.get("proc") or {}).get("pid", "")) == job)
    if not hit:
        return Item(job)
    run, aid = hit
    live = items_of_run(led, run, target, job)[1]
    if live:
        return live[0]
    att = led.read_run(run).data["attempts"][aid]    # recorded as ended: the target says whether it still runs
    return Item(job, run, aid, name=str(att.get("name", "")))


def authorize(led: L.Ledger, target: str, kind: str, items: list[Item], words: str | None) -> dict[str, dict]:
    """{job: the record that covers its cancel}; a deny → exit 3; with WORDS the user's request is recorded first."""
    def ask(i: Item, st: L.Ledger | L.LedgerState) -> grants.Decision:
        return grants.check(st, "cancel", job=i.job, run=i.run, plan={"target": target, "kind": kind,
                                                                       "name": i.name, "warnings": "0"})
    with led.locked():
        for i in items:
            d = ask(i, led)
            if d.denied:
                raise RskError(f"cancel of {i.job} is denied by {d.record['id']}: \"{d.record['quote']}\" — nothing "
                               "cancelled", REFUSED)
        if words is not None:
            ap = grants.add(led, grants.new_cancel_approval(words, target, [i.job for i in items]))
            out(f"approval {ap['id']}: {grants.describe(ap)} — \"{words}\"")
        cover: dict[str, dict] = {}
        for i in items:
            d = ask(i, led)
            if not d.covered:
                out("not covered: " + ("; ".join(d.reasons) or "no record"))
                what = f"run {i.run} ({i.name})" if i.run else "a job the ledger does not know"
                out(f"needs user: approval — cancel {'job' if kind == 'slurm' else 'pid'} {i.job} on {target}, {what}")
                raise RskError(f"cancelling {i.job} is the user's call (no cancel approval names it, and "
                               f"{'no cancel_own grant covers this run' if i.own else 'it is not a run rsk launched'})",
                               NEEDS_USER)
            cover[i.job] = d.record
        for i in items:
            grants.use(led, cover[i.job]["id"], f"cancel-{i.job}-{secrets.token_hex(4)}", "cancel", job=i.job)
    return cover


def body(place: harness.Place, items: list[Item], grace: int) -> str:
    head = f"RDIR={shlex.quote(place.remote_dir)} GRACE={int(grace)}\n"
    if place.kind == "slurm":
        args = [w for i in items for w in (i.job, i.name)]
        return head + SLURM_SH + "\nrs_cancel " + " ".join(shlex.quote(a) for a in args) + "\n"
    args = [w for i in items for w in (i.job, i.nonce, i.start, i.boot_id)]
    return head + NOHUP_SH + "\nrs_kill " + " ".join(shlex.quote(a) for a in args) + "\n"


def parse(text: str) -> tuple[dict, dict[str, str], dict[str, str]]:
    """(facts: start/end/fail/user/scancel/kill, {job: verdict line}, {job: extra})."""
    facts: dict = {}
    verdict: dict[str, str] = {}
    extra: dict[str, str] = {}
    for ln in text.splitlines():
        if not ln.startswith("@@"):
            continue
        w, _, rest = ln[2:].partition(" ")
        if w == "c":
            j, _, v = rest.partition(" ")
            verdict.setdefault(j, v)
        elif w in ("left", "killed", "term", "r"):
            j, _, v = rest.partition(" ")
            extra[f"{w}:{j}"] = v
        else:
            facts.setdefault(w, rest)
    return facts, verdict, extra


def refund(led: L.Ledger, rec: dict, job: str, why: str) -> None:
    """Give back the cancel use of JOB under REC (nothing was cancelled)."""
    cur = next((r for r in led.state().grants if r.get("id") == rec["id"]), None)
    for u in reversed((cur or {}).get("used") or []):
        if u.get("job") == job and u.get("action") == "cancel":
            grants.refund(led, rec["id"], u["nonce"], why)
            return


def cmd_cancel(args: argparse.Namespace) -> int:
    from remote_run.status import project_dir, select
    proj = project_dir(args.dir)
    led, src = L.Ledger(proj), paths.harness_src()
    words = args.approve
    if words is not None and not words.strip():
        raise RskError("--approve takes the user's words, verbatim (non-empty)", USAGE)
    if not args.run and not args.job:
        raise RskError("rsk cancel RUN | --job J -T T", USAGE)
    all_places = harness.places(src, proj)
    if args.run:
        target, items = items_of_run(led, args.run, args.target, args.job)
        if not items:
            if args.job:
                raise RskError(f"job {args.job} is not a live submission of run {args.run} in the ledger", USAGE)
            out(f"run {args.run} has nothing live in the ledger{' on ' + target if target else ''} — nothing to cancel "
                "(rsk status shows how it ended)")
            return OK
        place = select(all_places, [target])[0]
    else:
        if not args.target:
            raise RskError("--job J needs -T T (the target it runs on)", USAGE)
        place = select(all_places, [args.target])[0]
        items = [item_of_job(led, place.target, args.job, place.kind)]
    rx = JOB_RE if place.kind == "slurm" else PID_RE
    bad = [i.job for i in items if not rx.fullmatch(i.job)]
    if bad:
        raise RskError(f"{', '.join(bad)}: {'a Slurm job id' if place.kind == 'slurm' else 'a pid (the run wrapper)'}",
                       USAGE)
    cover = authorize(led, place.target, place.kind, items, words)
    deadline = args.deadline + (args.grace + 5 if place.kind == "nohup" else 0)
    try:
        done = observe.run(place, body(place, items, args.grace), deadline)
        text, rc, err = done.stdout, done.returncode, done.stderr
    except subprocess.TimeoutExpired:
        text, rc, err = "", None, f"no answer within {deadline:.0f} s"
    except OSError as exc:
        text, rc, err = "", None, f"ssh: {exc}"
    facts, verdict, extra = parse(text)
    if "end" not in facts or "fail" in facts:
        why = facts.get("fail") or (f"ssh exited {rc}: {err.strip()[:200]}" if rc else err or "the answer was cut off")
        # once a job passed its identity check (`@@c J ok`) the scancel / TERM may have gone out: no use given back
        sent = "scancel" in facts or "term:" in " ".join(extra) or any(v.startswith("ok") for v in verdict.values())
        for i in items:
            if not sent:
                refund(led, cover[i.job], i.job, "the identity check did not complete")
        led.audit("cancel", target=place.target, jobs=[i.job for i in items], outcome="unobservable", why=why[:200])
        raise RskError(f"[{place.target}] {why} — {'the cancel may have been sent: rsk status' if sent else 'nothing was cancelled'}",
                       UNKNOWN)
    worst = OK
    for i in items:
        v = verdict.get(i.job, "missing")
        rid = cover[i.job]["id"]
        what = f"{'job' if place.kind == 'slurm' else 'pid'} {i.job}" + (f" ({i.run} {i.attempt})" if i.run else "")
        if v.startswith("ok"):
            if place.kind == "slurm":
                sc = observe._kv(facts.get("scancel", ""))
                if sc.get("rc") != "0":
                    refund(led, cover[i.job], i.job, f"scancel rc={sc.get('rc', '?')}")
                    out(f"FAILED: {what}: scancel exit {sc.get('rc', '?')} — not cancelled")
                    worst = worst or FAILED
                    continue
                if i.run:
                    led.observe(i.run, i.attempt, i.job, "CANCELLING", "rsk cancel (scancel rc=0)")
                out(f"cancelled: {what} on {place.target} — scancel accepted (under {rid}); rsk status shows it end")
            else:
                left = extra.get(f"left:{i.job}", "")
                n = left.split(" ")[0] if left else "?"
                rcv = re.search(r"rc=\[(.*)\]", left)
                rcd = observe._kv(rcv.group(1)) if rcv else {}
                killed = f"killed:{i.job}" in extra
                if n != "0":
                    out(f"FAILED: {what}: {n} process(es) still in its group after TERM{' and KILL' if killed else ''}")
                    worst = worst or FAILED
                    continue
                if i.run:
                    led.observe(i.run, i.attempt, i.log or i.job, "CANCELLED", "rsk cancel", end={
                        "state": "CANCELLED", "rc": rcd.get("rc", ""),
                        "evidence": f"rsk cancel: TERM{' + KILL' if killed else ''} to group {i.job}, gone"})
                out(f"cancelled: {what} on {place.target} — TERM{' then KILL after the grace' if killed else ''}, its "
                    f"group is gone{', rc ' + rcd['rc'] if rcd.get('rc') else ''} (under {rid})")
            led.audit("cancel", run=i.run, attempt=i.attempt, target=place.target, job=i.job, record=rid,
                      outcome="cancelled")
            continue
        refund(led, cover[i.job], i.job, f"not cancelled: {v}")
        if v.startswith("user="):
            out(f"REFUSED: {what} belongs to {v[5:]} — another user's job/process is never cancelled")
            code = REFUSED
        elif v.startswith("gone") or v.startswith("ended="):
            out(f"nothing to cancel: {what} is {'ended (' + v[6:] + ')' if v.startswith('ended=') else 'not running'}"
                f"{' (' + v[5:] + ')' if v.startswith('gone ') else ''}" + ("" if i.run else
                " — and the ledger never had it: a wrong id?"))
            code = OK if i.run else CONFLICT
        else:
            out(f"NOT cancelled: {what}: the identity does not match ({v}) — "
                + ("its name/WorkDir are not this run's" if place.kind == "slurm" else "the receipt does not prove it"))
            code = CONFLICT
        led.audit("cancel", run=i.run, attempt=i.attempt, target=place.target, job=i.job, record=rid,
                  outcome=f"not cancelled: {v}"[:200])
        worst = worst or code
    return worst


def add_parser(sub) -> None:
    p = sub.add_parser("cancel", help="stop a run of this project: the user's words or a cancel_own grant, then an "
                       "identity check and scancel / kill in one ssh — recorded in the ledger",
                       description=__doc__.split("\n\n")[0], epilog=__doc__.split("\n\n", 1)[1],
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("run", nargs="?", default="", metavar="RUN", help="a ledger run id (rsk status)")
    p.add_argument("--job", default="", metavar="J", help="Slurm job id, or the nohup run's pid")
    p.add_argument("-T", "--target", default="")
    p.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory)")
    p.add_argument("--approve", default=None, metavar="WORDS", help="the user's words asking for this cancel")
    p.add_argument("--grace", type=int, default=30, help="nohup: seconds between TERM and KILL (default 30)")
    p.add_argument("--deadline", type=float, default=60.0)
    p.set_defaults(func=cmd_cancel)
