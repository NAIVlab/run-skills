"""`rsk cancel`: stop a run of this project — only after grants.check() and an identity check on the target.

    rsk cancel RUN [--job J] [-T T] [--approve "the user's words" [--asked "your question"]] [-C DIR] [--grace S]
               [--deadline S] [--wait S]
    rsk cancel --job J -T T [--approve "the user's words" [--asked "your question"]] [-C DIR] [--grace S] [--deadline S]
               [--wait S]

What may be stopped (the user's policy, §U of the P3 contract):
  - the user said it ("cancel job 123"): the words must name what is cancelled as a whole word — for --job J the job
    id J (Slurm) / the pid (nohup), or the run's id or job name; for RUN the run id or name, or every job id cancelled;
    a numeric range names every id in it ("cancel jobs 102-104", "102 to 104", "102…104") — or, when the words answer
    a question of the agent's ("sw1 (job 101) diverged — cancel it?" → "yes"), that question, given verbatim with
    --asked, may name it instead (the user is never asked twice; the question is the agent's own text: bookkeeping,
    not proof — rsk does not read whether the answer was a yes) — else exit 4 `needs user: the words do not name
    <J|RUN>`, nothing recorded or cancelled (R8-2: "cancel job 101" never approves 102; a yes to "cancel sw1?" never
    approves sw2; and words that repeat a standing grant's quote — grants.recycled — are exit 4 too, before anything).
    Then --approve "their words" records a cancel approval naming exactly those job(s) (its quote the
    words, its source the asked question; the audit lines carry it too),
    each bound to the identity it was asked for (Slurm: target, job id, run name, WorkDir; nohup: target, pid, start,
    boot_id), for 1 h — acted on once the identity check passes, and used up by that first cancel whatever its
    outcome (never given back: a later cancel of the same id needs the user's words again);
  - the agent's own judgment: only a live run rsk launched for this project (a ledger attempt with a plan, never an
    adopted one, never one the ledger shows ended) under a standing grant with cancel_own in scope, each cancel
    counted against its max_launches; anything else is the user's call → exit 4;
  - a deny always wins (exit 3, its quote); someone else's job or process: never (exit 3), whatever was approved.
Identity, then the action, in ONE ssh (nothing is cancelled that this same read did not check) — after one look at
the project dir, the probe rsk status makes: a filesystem that gives no answer within 15 s (a hung mount) ends the
call there, before anything is read or sent: exit 5 `<dir>: its filesystem gave no answer within 15 s (a hung mount?)
— nothing was sent`, a cancel_own use given back (an approval is used up all the same):
  slurm  J is in `squeue -u $USER` with this user, the ledger's job name (an unledgered job: its own record's), and
         WorkDir = the project's remote dir (logical or physical) → `scancel J`. A job not in that list is not
         cancelled: another user's (exit 3, from `squeue -j J`), or ended / a wrong id.
  nohup  J = the run's pid: its receipt (the ledger's own .rs/attempts/<nonce>/receipt — never another receipt naming
         pid=J —, else the ledger's adopted triple; a job the ledger does not know: the ONE receipt naming pid=J whose
         start and boot_id are J's now, several = exit 6) has pid J, gate go, a start and boot_id that are the
         ledger's (a mismatch: exit 6, nothing signalled), the box's boot_id and /proc/J's start time, the owner is
         $USER and it leads its process group → `kill -TERM -- -<pgid>`, up to --grace seconds (30) for the group to
         go, then `kill -KILL -- -<pgid>`; the run's <log>.rc is read back. `--job J` of a run the ledger shows ended
         is checked against THAT run's identity (a pid reused since is "ended", nothing signalled).
Recorded: the approval (if any), the use (a cancel_own grant's is given back only when the answer proves nothing
was signalled — an @@fail, `none`, or no identity that passed, or an ssh that ended with the remote's own status (or
never started) before it said @@start; an answer cut off after it started, a timeout's partial output included, and no
@@start from an ssh that did not end that way (a timeout, ssh's own exit 255 — the connection may have died after the
body ran —, a signal) count as "may have been sent": exit 5, the use kept; an approval's never), the observation (Slurm: CANCELLING until rsk
status sees the end; nohup: CANCELLED with its rc) and an audit line. A ledgered run that already ended — Slurm: ended
in squeue; nohup: its pid gone, reused by another process (start differs), or the box rebooted (boot_id differs) — is
exit 0 "nothing to cancel … ended", its end recorded in the ledger now (REBOOT for a changed boot_id).
ssh's own exit 255 before @@start is exit 5 "may have been sent", the use kept, WHATEVER its stderr says (R6-4: a
ProxyCommand's fallback route or a login shell can print "Connection refused" / "Permission denied" lines on a session
that did open and ran the body). A non-zero scancel (R5-5) is exit 5, the use kept, the ledger CANCELLING? (not
confirmed: a timed-out request may have been applied; the message quotes scancel's line naming that job, R6-8) — unless
scancel's own line for that id says it is invalid or already completing / completed: then exit 0 "nothing to cancel",
the use given back, the ledger COMPLETING.
--wait S (Slurm; default 0 = return once scancel answered): an accepted scancel only asks Slurm to end the job, and
until a read sees the end the ledger keeps the run live (CANCELLING) — a relaunch of the same name meanwhile meets the
duplicate guard. --wait S reads the target again right away, then every ~10 s (the read rsk status makes, recorded in
the ledger as rsk status would), until each accepted job is seen ended or S s pass; one line per job: `ended: job J
(RUN aNN) on T: STATE (squeue|sacct)`, or `not ended yet: job J (RUN aNN) on T: STATE — the cancel was accepted; rsk
status shows its end` and exit 5 (nothing given back or taken: the cancel's accounting stands). A read that fails or
does not list the job proves no end. Jobs already ended / moot, an unknown scancel: no wait. A job an earlier rsk
cancel already saw accepted (the ledger's CANCELLING, or that cancel's audit line) is not sent scancel again under
--wait: `already cancelled: …`, then only the wait — a read, so nothing is authorised or used (the user is not asked
twice). nohup: accepted, changes nothing (the cancel itself waits --grace and records the end).
Exit: 0 cancelled (or already ended; with --wait: and seen ended) · 2 usage · 3 denied / not this user's · 4 needs the
user · 5 the target could not be read or answered too little (the cancel may have been sent), its project filesystem
hung (nothing sent), a scancel whose outcome is unknown, or --wait S passed before the end was seen · 6 the identity
does not match (name, WorkDir, receipt) · 1 kill failed (processes left in the group).
"""

from __future__ import annotations

import argparse
import re
import secrets
import shlex
import subprocess
import time
from dataclasses import dataclass

from remote_run import grants, harness, observe, paths
from remote_run import ledger as L
from remote_run.errors import CONFLICT, FAILED, NEEDS_USER, OK, REFUSED, UNKNOWN, USAGE, RskError

JOB_RE = re.compile(r"[0-9]+(?:_[0-9]+)?")
PID_RE = re.compile(r"[1-9][0-9]{0,9}")
# R5-5: scancel's words that prove its non-zero exit cancelled nothing for that id: the id is unknown to slurmctld, or
# the job was ending already (Slurm: "Kill job error on job id <id>: Invalid job id specified" / "… Job/step already
# completing or completed"); any other non-zero exit may have been applied (a timed-out RPC) — unknown
MOOT = re.compile(r"invalid job id|already completing or completed", re.I)
_ID_IN = re.compile(r"\bjob id ([0-9]+(?:_[0-9]+)?)\b", re.I)


def scancel_moot(text: str, job: str) -> str:
    """The line of scancel's output that proves there was nothing for it to cancel for JOB (the line names that id and
    says it is invalid or already completing / completed); '' otherwise."""
    for ln in text.splitlines():
        m = _ID_IN.search(ln)
        if m and m.group(1) == job and MOOT.search(ln):
            return ln.strip()
    return ""


def scancel_line(text: str, job: str) -> str:
    """R6-8: the line of scancel's output to quote for JOB — the last one naming `job id <JOB>`; failing that, the last
    one naming no job id (a message for the whole call); '' when every line names another job."""
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    own = [ln for ln in lines if any(m.group(1) == job for m in _ID_IN.finditer(ln))]
    if own:
        return own[-1]
    general = [ln for ln in lines if not _ID_IN.search(ln)]
    return general[-1] if general else ""

# I8: both bodies look at the project dir first with rsk status's probe (observe.rs_dir: a child holding none of the
# session's fds, waited for FS_WAIT s) — a hung mount would hold `cd` (and the ssh) until the local deadline, after
# @@start: "may have been sent". Its `h` ends the call BEFORE @@start with observe's @@fail: proof that nothing ran.
# Only `h` is decided here; d / n / x go on to the `cd` below as before (its own @@fail).
_PROBE = '  [ "$(rs_dir "$RDIR")" != h ] || { ' + observe._HUNG + '; }   # I8: before @@start, nothing sent\n'

SLURM_SH = r'''rs_cancel() {   # rs_cancel JOB WANT_NAME ... : identity of each, then scancel of exactly those that passed
  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\~/}" ;; esac
''' + _PROBE + r'''  echo @@start; U=${USER:-$(id -un)}; echo "@@user $U"
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
  e=$(scancel $ok 2>&1); rc=$?   # its words decide a non-zero exit: only "invalid id" / "already completing" prove it moot
  [ -z "$e" ] || printf '%s\n' "$e" | head -c 4096 | sed 's/^/@@scerr /'
  echo "@@scancel rc=$rc ids=${ok# }"; echo @@end
}'''

NOHUP_SH = r'''rs_kill() {   # rs_kill PID NONCE START BOOT ... : identity of each (receipt, /proc, owner, group), then TERM, grace, KILL
  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\~/}" ;; esac
''' + _PROBE + r'''  echo @@start; U=${USER:-$(id -un)}; echo "@@user $U"; boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  cd "$RDIR" 2>/dev/null || { echo "@@fail cd $RDIR"; return 0; }
  [ -n "$boot" ] || { echo "@@fail no /proc boot_id"; return 0; }
  kv() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }
  pst() { local s; s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1; s=${s##*)}; set -f; set -- $s; set +f
    [ "$#" -ge 20 ] && [ "$1" != Z ] && [ "$1" != X ] || return 1; printf '%s %s\n' "${20}" "$3"; }
  ngrp() { ps -e -o pgid=,stat= 2>/dev/null | awk -v g="$1" '$1 == g && $2 !~ /^Z/' | grep -c .; }   # a zombie holds nothing
  groups=""; logs=""
  while [ "$#" -ge 4 ]; do p=$1; n=$2; es=$3; eb=$4; shift 4
    case "$p" in ""|0*|*[!0-9]*) echo "@@c $p badpid"; continue ;; esac
    case "$n" in *[!A-Za-z0-9._-]*) echo "@@c $p badnonce"; continue ;; esac
    r=""
    if [ -n "$n" ]; then   # the ledger's own attempt: ITS receipt or nothing — never another run's naming the same pid
      [ ! -f ".rs/attempts/$n/receipt" ] || r=.rs/attempts/$n/receipt
    else                   # no nonce known: the one receipt naming pid=P whose start and boot are this process's now
      cur=$(pst "$p") || { echo "@@c $p gone"; continue; }; k=0
      for f in $(LC_ALL=C grep -l -a -x -F -e "pid=$p" .rs/attempts/*/receipt 2>/dev/null); do
        [ "$(kv start "$f")" = "${cur%% *}" ] && [ "$(kv boot_id "$f")" = "$boot" ] || continue; r=$f; k=$((k + 1)); done
      [ "$k" -le 1 ] || { echo "@@c $p ambiguous receipts=$k"; continue; }
    fi
    if [ -n "$r" ]; then d=${r%/receipt}; g=$(readlink "$d/gate" 2>/dev/null)
      rp=$(kv pid "$r"); rg=$(kv pgid "$r"); rs=$(kv start "$r"); rb=$(kv boot_id "$r"); rl=$(kv log "$r")
      echo "@@r $p receipt=${d##*/} pid=$rp pgid=$rg start=$rs boot_id=$rb gate=$g log=$rl"
      [ "$rp" = "$p" ] || { echo "@@c $p receipt-pid=$rp"; continue; }
      [ "$g" = go ] || { echo "@@c $p notstarted"; continue; }
      [ -n "$rs" ] && [ -n "$rb" ] || { echo "@@c $p noidentity receipt"; continue; }   # start + boot_id: always both
      [ -z "$es" ] || [ "$es" = "$rs" ] || { echo "@@c $p ledger-start=$es"; continue; }
      [ -z "$eb" ] || [ "$eb" = "$rb" ] || { echo "@@c $p ledger-boot=$eb"; continue; }
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
    ended: bool = False          # the ledger shows this submission ended already (its end is never rewritten here)


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
    """The ledger's submission of JOB (Slurm id / nohup pid) on TARGET: a live one first; else the last one that
    ended — with ITS identity (nonce, start, boot_id: the target then checks the process against that run's receipt,
    so a pid the box has since given to another process is never taken for it) and own=False (cancel_own never covers
    an attempt the ledger shows ended). Not in the ledger: Item(job)."""
    def hit(s: dict) -> bool:
        return (s.get("job") == job) if kind == "slurm" else str((s.get("proc") or {}).get("pid", "")) == job
    ended: list[tuple[str, str, dict, dict]] = []
    for run, got in sorted(led.runs().items()):
        for aid, att in sorted(((got.data or {}).get("attempts") or {}).items()):
            if att.get("target") != target or not any(hit(s) for s in att.get("submissions") or []):
                continue
            live = items_of_run(led, run, target, job)[1]
            if live:
                return live[0]
            ended += [(run, aid, att, s) for s in att.get("submissions") or [] if hit(s)]
    if not ended:
        return Item(job)
    run, aid, att, s = max(ended, key=lambda x: L.epoch(x[3].get("at")))   # recorded as ended: the target says
    p = s.get("proc") or {}                                                # whether it still runs
    return Item(job, run, aid, str(s.get("nonce", "")), str(att.get("name", "")), str(p.get("start", "")),
                str(p.get("boot_id", "")), str(p.get("log", "")), own=False, ended=True)


def ident(place: harness.Place, i: Item) -> str:
    """The identity a cancel approval is bound to (grants.cancel_ident): Slurm target + job id + run name + WorkDir
    (the project's remote dir), nohup target + pid + /proc start + boot_id."""
    if place.kind == "slurm":
        return grants.cancel_ident("slurm", place.target, i.job, i.name, place.remote_dir)
    return grants.cancel_ident("nohup", place.target, i.job, i.start, i.boot_id)


_WORD = re.compile(r"[A-Za-z0-9_]")     # continues a token; '.' / '-' do too when one of [A-Za-z0-9_.-] follows


def _goes_on(c: str, next_c: str) -> bool:
    """C (the character next to a match; NEXT_C the one beyond it) makes the match part of a longer token."""
    return bool(c) and bool(_WORD.match(c) or (c in ".-" and next_c and (_WORD.match(next_c) or next_c in ".-")))


def named(words: str, tok: str) -> bool:
    """R8-2: TOK (a job id, a pid, a run id or name) appears in WORDS as a whole token — not inside a longer id or
    name: no letter, digit or '_' next to it, and no '.' / '-' that goes on into one ('101' is not named by '1101',
    '101_2' or 'sw1' by 'sw10', 'exp--sw1', 'sw1-b'; 'cancel job 101.' and '(sw1)' name them)."""
    for m in re.finditer(re.escape(tok), words) if tok else ():
        a, b = m.start(), m.end()
        if not _goes_on(words[a - 1:a], words[a - 2:a - 1] if a >= 2 else "") \
                and not _goes_on(words[b:b + 1], words[b + 1:b + 2]):
            return True
    return False


# NF8: a numeric range names every id in it — "102-104", "102 – 104", "102 to 104", "102..104", "102…104", "102~104",
# "102到104" / "102至104" — read as whole tokens (named()'s rule at both ends: "1102-104", "102-104_2" name nothing), low
# end first (a high-to-low pair is no range)
_RANGE = re.compile(r"([0-9]+)(?:[ \t]*(?:-|–|~|\.\.\.?|…|到|至)[ \t]*|[ \t]+(?:to|through|thru)[ \t]+)([0-9]+)", re.I)


def ranges(words: str) -> list[tuple[int, int]]:
    """The numeric ranges WORDS name, as (low, high), each end a whole token."""
    out = []
    for m in _RANGE.finditer(words or ""):
        a, b = m.start(1), m.end(2)
        lo, hi = int(m.group(1)), int(m.group(2))
        if lo <= hi and not _goes_on(words[a - 1:a], words[a - 2:a - 1] if a >= 2 else "") \
                and not _goes_on(words[b:b + 1], words[b + 1:b + 2]):
            out.append((lo, hi))
    return out


def names(text: str, i: Item) -> bool:
    """TEXT names the item: its job id / pid (whole, or inside a numeric range of TEXT), its run id or its job name."""
    return bool(text) and (named(text, i.job) or (i.job.isdigit() and any(lo <= int(i.job) <= hi
                                                                          for lo, hi in ranges(text)))
                           or bool(i.run and named(text, i.run)) or bool(i.name and named(text, i.name)))


def unnamed(items: list[Item], words: str, asked: str = "") -> list[Item]:
    """R8-2: the items neither the user's WORDS nor ASKED — the agent's own question those words answer (`--asked`,
    NF8) — name: an item is named by its job id (Slurm) / pid (nohup), a numeric range holding it, its run id or its
    attempt's name (the job name), as a whole token (names()). `rsk cancel RUN`: the run id names every item of it;
    else each job id. A good-faith slip ("cancel job 101" approving 102, "cancel sw1" approving sw2, a yes to "cancel
    sw1?" passed for sw2) is caught here; words naming nothing at all ("cancel it") with no question name nothing.
    ASKED is the agent's text: bookkeeping that keeps the user from being asked twice, never proof of what they meant."""
    return [i for i in items if not (names(words, i) or names(asked, i))]


def authorize(led: L.Ledger, place: harness.Place, items: list[Item], words: str | None,
              what: str = "", asked: str = "") -> dict[str, dict]:
    """{job: the record that covers its cancel}; a deny → exit 3; with WORDS the user's request is recorded first,
    bound to each item's identity — only when the words, or ASKED (the agent's question they answer, `--asked`), name
    what is cancelled (R8-2 / NF8: unnamed(); else exit 4 `needs user: the words do not name WHAT`, nothing recorded or
    cancelled); the approval keeps both (its quote = WORDS, its source = ASKED). Every use is counted here, before the
    ssh."""
    target, kind = place.target, place.kind

    def ask(i: Item, st: L.Ledger | L.LedgerState) -> grants.Decision:
        return grants.check(st, "cancel", job=i.job, run=i.run, ident=ident(place, i),
                            plan={"target": target, "kind": kind, "name": i.name, "warnings": "0"})
    with led.locked():
        for i in items:
            d = ask(i, led)
            if d.denied:
                raise RskError(f"cancel of {i.job} is denied by {d.record['id']}: \"{d.record['quote']}\" — nothing "
                               "cancelled", REFUSED)
        miss = unnamed(items, words, asked) if words is not None else []
        if miss:
            unit = "job" if kind == "slurm" else "pid"
            them = "; ".join(f"{unit} {i.job}" + (f" = run {i.run} ({i.name})" if i.run else "") for i in miss)
            out(f"needs user: the words do not name {what or ', '.join(i.job for i in miss)} — \"{words}\""
                + (f" (answering \"{asked}\")" if asked else "")
                + f" names none of: {them} on {target}; nothing recorded or cancelled")
            raise RskError(f"the user's words — or your question they answered, given with --asked — must name what "
                           f"is cancelled: the {unit} id (or a range holding it), the run id or its name, a whole word"
                           + (": your question does not name it either — ask the user which one they mean"
                              if asked else
                              ": if they answered a question of yours naming it, pass that question with --asked "
                              "\"<your question>\" (never ask again); else ask the user which one they mean"),
                           NEEDS_USER)
        if words is not None:
            ap = grants.add(led, grants.new_cancel_approval(words, target, [i.job for i in items],
                                                            idents=[ident(place, i) for i in items], asked=asked))
            out(f"approval {ap['id']}: {grants.describe(ap)} — \"{words}\""
                + (f" (answering \"{asked}\")" if asked else ""))
        cover: dict[str, dict] = {}
        for i in items:
            d = ask(i, led)
            if not d.covered:
                out("not covered: " + ("; ".join(d.reasons) or "no record"))
                what = f"run {i.run} ({i.name})" if i.run else "a job the ledger does not know"
                out(f"needs user: approval — cancel {'job' if kind == 'slurm' else 'pid'} {i.job} on {target}, {what}")
                raise RskError(f"cancelling {i.job} is the user's call (no cancel approval names it, and "
                               + ("no cancel_own grant covers this run" if i.own else
                                  "it is not a live run rsk launched: adopted, or the ledger shows it ended" if i.run else
                                  "it is not a run rsk launched") + ")", NEEDS_USER)
            cover[i.job] = d.record
        for i in items:
            grants.use(led, cover[i.job]["id"], f"cancel-{i.job}-{secrets.token_hex(4)}", "cancel", job=i.job)
    return cover


def body(place: harness.Place, items: list[Item], grace: int) -> str:
    head = (f"RDIR={shlex.quote(place.remote_dir)} GRACE={int(grace)} FS_WAIT={int(observe.FS_WAIT)}\n"
            + observe._DIRPROBE + "\n")              # rs_dir, which both bodies call first (_PROBE, I8)
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
        elif w == "scerr":                     # scancel's own output (every line)
            facts["scerr"] = facts.get("scerr", "") + rest + "\n"
        elif w in ("left", "killed", "term", "r"):
            j, _, v = rest.partition(" ")
            extra[f"{w}:{j}"] = v
        else:
            facts.setdefault(w, rest)
    return facts, verdict, extra


def refund(led: L.Ledger, rec: dict, job: str, why: str) -> None:
    """Give back the cancel use of JOB under REC — a cancel_own grant's, when nothing was signalled. A cancel approval
    is never given back: it was the user's word for that one cancel, used up by it whatever came of it."""
    if rec.get("kind") == "approval":
        return
    cur = next((r for r in led.state().grants if isinstance(r, dict) and r.get("id") == rec["id"]), None)
    for u in reversed((cur or {}).get("used") or []):
        if u.get("job") == job and u.get("action") == "cancel":
            grants.refund(led, rec["id"], u["nonce"], why)
            return


def cmd_cancel(args: argparse.Namespace) -> int:
    from remote_run.status import project_dir, select
    proj = project_dir(args.dir)
    led, src = L.Ledger(proj), paths.harness_src()
    words, asked = args.approve, args.asked
    if words is not None and not words.strip():
        raise RskError("--approve takes the user's words, verbatim (non-empty)", USAGE)
    if asked is not None and (words is None or not asked.strip()):
        raise RskError("--asked takes your question the user answered, verbatim (non-empty), and goes with --approve "
                       "\"<their answer>\"", USAGE)
    if not 0 <= args.wait <= WAIT_MAX_S:
        raise RskError(f"--wait S takes seconds from 0 (the default: no wait) to {WAIT_MAX_S}, not {args.wait} — a "
                       "longer wait is a later rsk status, not a loop of reads on the login node", USAGE)
    grants.refuse_recycled(words, led.state().grants, "this cancel")
    asked = asked or ""
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
    before = accepted_before(led, place.target, items) if args.wait > 0 and place.kind == "slurm" else {}
    for i in items:
        if i.job in before:
            out(f"already cancelled: {_label(i)} on {place.target} — an earlier rsk cancel's scancel was accepted "
                f"({before[i.job] or 'at ?'}); not sent again: --wait follows its end")
    waiting = [i for i in items if i.job in before]
    items = [i for i in items if i.job not in before]
    if not items:                          # only a wait: a read, nothing to authorise or send
        return wait_end(led, place, waiting, args.wait, args.deadline)
    cover = authorize(led, place, items, words, args.run or args.job, asked)
    q_kw = {"asked": asked} if asked else {}         # NF8: the question the words answer, in every audit line
    deadline = args.deadline + (args.grace + 5 if place.kind == "nohup" else 0)
    timed_out = False
    try:
        done = observe.run(place, body(place, items, args.grace), deadline)
        text, rc, err = done.stdout, done.returncode, done.stderr
    except subprocess.TimeoutExpired as exc:   # what arrived before the deadline still counts (an `@@c J ok`)
        text, rc, err, timed_out = _text(exc.stdout), None, f"no answer within {deadline:.0f} s", True
    except OSError as exc:
        text, rc, err = "", None, f"ssh: {exc}"
    facts, verdict, extra = parse(text)
    # R6-4: ssh's own exit 255 before @@start is "may have been sent" whatever its stderr says (a ProxyCommand's
    # fallback route, a login shell's ssh can print "Connection refused" / "Permission denied" on a session that opened)
    if "end" not in facts or "fail" in facts:
        why = facts.get("fail") or (f"ssh exited {rc}: {err.strip()[:200]}" if rc else err or "the answer was cut off")
        cut = timed_out or (rc is not None and not 0 <= rc < 255)   # not the remote's own status: output may be lost
        if not sent_maybe(facts, verdict, items, cut):
            for i in items:
                refund(led, cover[i.job], i.job, "nothing was signalled")
            sent = False
        else:
            sent = True
        led.audit("cancel", target=place.target, jobs=[i.job for i in items], outcome="unobservable", why=why[:200],
                  sent="maybe" if sent else "no", **q_kw)
        silent = sent and "start" not in facts       # no answer at all (timeout, 255, signal): the body may have run
        early = "fail" in facts and "start" not in facts   # I8: the hung-mount probe stopped it before anything ran
        raise RskError(f"[{place.target}] {why} — "
                       + ("the cancel may have been sent: rsk status (no answer at all: the job may have been cancelled "
                          "— ssh's own words are no proof that the body never ran; the use is kept)" if silent else
                          "the cancel may have been sent: rsk status" if sent else
                          "nothing was sent, nothing was cancelled (it stopped before reading any job; retry once rsk "
                          "status reads the target again)" if early else "nothing was cancelled"), UNKNOWN)
    worst = OK
    accepted = waiting                     # Slurm: scancel rc=0 (the ledger's CANCELLING) — what --wait follows
    for i in items:
        v = verdict.get(i.job, "missing")
        rid = cover[i.job]["id"]
        what = f"{'job' if place.kind == 'slurm' else 'pid'} {i.job}" + (f" ({i.run} {i.attempt})" if i.run else "")
        if v.startswith("ok"):
            if place.kind == "slurm":
                sc = observe._kv(facts.get("scancel", ""))
                if sc.get("rc") != "0":                     # R5-5: no refund without proof that it cancelled nothing
                    src = sc.get("rc", "?")
                    moot = scancel_moot(facts.get("scerr", ""), i.job)
                    if moot:
                        refund(led, cover[i.job], i.job, f"scancel: {moot[:150]}")
                        if i.run:
                            led.observe(i.run, i.attempt, i.job, "COMPLETING", "rsk cancel",
                                        detail=f"scancel exit {src}: {moot[:200]}")
                        out(f"nothing to cancel: {what} — scancel exit {src}: {moot[:200]} (it was ending or gone "
                            "already)" + (f"; ledger: {i.run} {i.attempt} ending (rsk status shows how)" if i.run else ""))
                        led.audit("cancel", run=i.run, attempt=i.attempt, target=place.target, job=i.job, record=rid,
                                  outcome=f"nothing to cancel: {moot}"[:200], **q_kw)
                        continue
                    said = scancel_line(facts.get("scerr") or "", i.job)    # R6-8: its own line, never another id's
                    if i.run:
                        led.observe(i.run, i.attempt, i.job, "CANCELLING?", "rsk cancel",
                                    detail=f"scancel exit {src}, not confirmed" + (f": {said[:160]}" if said else ""))
                    out(f"UNKNOWN: {what}: scancel exit {src}" + (f" ({said[:200]})" if said else "")
                        + " — it may have been applied (a timed-out request can be): rsk status shows whether it ends; "
                        "the use is kept")
                    led.audit("cancel", run=i.run, attempt=i.attempt, target=place.target, job=i.job, record=rid,
                              outcome=f"unknown: scancel exit {src}"[:200], **q_kw)
                    worst = worst or UNKNOWN
                    continue
                if i.run:
                    led.observe(i.run, i.attempt, i.job, "CANCELLING", "rsk cancel (scancel rc=0)")
                out(f"cancelled: {what} on {place.target} — scancel accepted (under {rid}); rsk status shows it end")
                accepted.append(i)
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
                      outcome="cancelled", **q_kw)
            continue
        refund(led, cover[i.job], i.job, f"not cancelled: {v}")
        if v.startswith("user="):
            out(f"REFUSED: {what} belongs to {v[5:]} — another user's job/process is never cancelled")
            code = REFUSED
        elif v.startswith("gone") or v.startswith("ended="):
            end = ended(place, i, v)
            out(f"nothing to cancel: {what} is {end['said']}" + ("" if i.run else
                " — and the ledger never had it: a wrong id?")
                + (f"; ledger: {i.run} {i.attempt} had ended already" if i.run and i.ended else
                   f"; ledger: {i.run} {i.attempt} ended {end['state']}" if i.run and end["recorded"] and
                   _record_end(led, i, end) else ""))
            code = OK if i.run else CONFLICT
        else:
            out(f"NOT cancelled: {what}: the identity does not match ({v}) — "
                + ("its name/WorkDir are not this run's" if place.kind == "slurm" else "the receipt does not prove it"))
            code = CONFLICT
        led.audit("cancel", run=i.run, attempt=i.attempt, target=place.target, job=i.job, record=rid,
                  outcome=f"not cancelled: {v}"[:200], **q_kw)
        worst = worst or code
    if accepted and args.wait > 0:         # nohup: the cancel already waited --grace and recorded the end
        w = wait_end(led, place, accepted, args.wait, args.deadline)   # also after another item's non-zero code
        worst = worst or w
    return worst


WAIT_EVERY = 10.0      # s between two reads of `rsk cancel --wait` (a login node's squeue + sacct each; tests patch it)
WAIT_MAX_S = 600       # the longest --wait: at most ~60 reads, as --check-after is capped (launch.CHECK_MAX_S)


def _label(i: Item) -> str:
    return f"job {i.job}" + (f" ({i.run} {i.attempt})" if i.run else "")


def _sub(led: L.Ledger, i: Item) -> dict:
    """I's submission (Slurm job id) in the ledger now; {} when the ledger has none."""
    att = ((((led.read_run(i.run).data or {}).get("attempts") or {}).get(i.attempt)) or {}) if i.run else {}
    return next((s for s in att.get("submissions") or [] if str(s.get("job") or "") == i.job), {})


def _ledger_end(led: L.Ledger, i: Item) -> tuple[str, str, bool]:
    """(state, source, ended) of I's submission in the ledger now: its recorded end, else the last state seen."""
    s = _sub(led, i)
    seen, end = s.get("seen") or {}, s.get("end") or {}
    state = str(end.get("state") or seen.get("state") or "") if end else str(seen.get("state") or "")
    return state or "CANCELLING", str(seen.get("source") or end.get("evidence") or "ledger"), \
        bool(end) or state in L.TERMINAL


def accepted_before(led: L.Ledger, target: str, items: list[Item]) -> dict[str, str]:
    """--wait (Slurm): {job: when} for the ledgered live ITEMS whose scancel an earlier rsk cancel saw ACCEPTED and
    whose end no read has shown since (ledger.sub_cancel_pending == CANCELLING: the ledger's CANCELLING, or the marker
    rsk cancel left while later reads show the job COMPLETING). `rsk cancel RUN --wait S` then waits for their end
    without sending scancel again: a read acts on nothing, so nothing is authorised or used (an approval used up by
    that cancel is not asked for twice). Not an unclear one (CANCELLING?: it may not have been applied — sent again,
    authorised as a new cancel), nor one a later read shows live in another state (a requeue: the job runs again).
    A submission recorded before the marker existed: that cancel's audit line (`cancelled`, this target, job, run and
    attempt) counts while no read since shows the job in a state but COMPLETING. Without --wait the cancel is sent
    again, as before."""
    live = {i.job: i for i in items if i.run and not i.ended}
    got, legacy = {}, {}
    for j, i in live.items():
        s = _sub(led, i)
        st, at = L.sub_cancel_pending(s)
        if st == "CANCELLING":
            got[j] = at
        elif not st and not s.get("cancel"):
            legacy[j] = s.get("seen") or {}
    if legacy:
        for a in led.read_audit()[0]:
            i = live.get(str(a.get("job", "")))
            if i is None or i.job not in legacy or i.job in got:
                continue
            seen = legacy[i.job]
            if a.get("event") == "cancel" and a.get("outcome") == "cancelled" and a.get("target") == target \
                    and a.get("run") == i.run and a.get("attempt") == i.attempt \
                    and (seen.get("state") == "COMPLETING" or str(seen.get("at", "")) <= str(a.get("at", ""))):
                got[i.job] = str(a.get("at", ""))
    return got


def wait_end(led: L.Ledger, place: harness.Place, items: list[Item], wait: int, deadline: float) -> int:
    """I1, `--wait S` (Slurm): the jobs whose scancel was accepted (ITEMS: the ledger's CANCELLING) are followed with the
    read rsk status makes — observe + status.record, so the ledger learns what rsk status would — at once, then every
    WAIT_EVERY s, until each one's end is observed or S s pass. One line per job: `ended: job J (RUN aNN) on T: STATE
    (squeue|sacct)`, or `not ended yet: …` → exit 5: the cancel was accepted, its end not seen (no use is given back or
    taken: the cancel settled them). Absence from a read is no end (its rows may be out of sacct's window), a read that
    fails changes nothing (said once per reason; the next read may answer). A job the ledger does not know (--job J,
    WorkDir checked by the cancel) is followed in the read itself."""
    from remote_run import status as S
    todo = list(items)
    state = {i.job: ("CANCELLING", "") for i in items}
    atts = [((led.read_run(i.run).data or {}).get("attempts") or {}).get(i.attempt) or {} for i in items if i.run]
    oldest = min([L.epoch(a.get("created_at")) or time.time() for a in atts] or [time.time()])
    days = max(2, min(30, int((time.time() - oldest) // 86400) + 2))   # launch.refresh's window: back to the oldest
    stop, said = time.monotonic() + wait, set()
    while True:
        left = stop - time.monotonic()
        st0 = led.state()
        o = observe.observe([place], days, min(deadline, max(left, 20.0)))[0]   # a read is never cut below 20 s
        for n in S.record(led, st0, [o]):
            out(f"ledger: {n}")
        hung = not o.ok and "its filesystem gave no answer" in o.why   # observe._HUNG: each read leaves a stuck stat
        if not o.ok and re.sub(r"[0-9]+", "#", o.why) not in said:      # "no answer within N s": one reason
            said.add(re.sub(r"[0-9]+", "#", o.why))
            out(f"NOTE: {place.target} could not be read now ({o.why}) — the jobs' state stands; "
                + ("not reading it again now (a hung mount: each read would leave a stuck process on the login node)"
                   if hung else "reading again"))
        for i in list(todo):
            if i.run:
                st, source, done = _ledger_end(led, i)
            else:
                j = next((j for j in o.jobs if j.id == i.job), None) if o.ok else None
                st, source = (j.state, j.source) if j else state[i.job]
                done = bool(j) and j.state in observe.TERMINAL
            state[i.job] = (st, source)
            if done:
                out(f"ended: {_label(i)} on {place.target}: {st} ({source or 'ledger'})")
                todo.remove(i)
        left = stop - time.monotonic()
        if not todo or left <= 0 or hung:
            break
        time.sleep(min(WAIT_EVERY, left))
    for i in todo:
        out(f"not ended yet: {_label(i)} on {place.target}: {state[i.job][0]} — the cancel was accepted; rsk status "
            "shows its end")
    return UNKNOWN if todo else OK


def _text(b: bytes | str | None) -> str:
    """subprocess.TimeoutExpired.stdout: the raw bytes read before the deadline (also in text mode), or None."""
    if b is None:
        return ""
    return b.decode("utf-8", "replace") if isinstance(b, bytes) else b


def sent_maybe(facts: dict, verdict: dict[str, str], items: list[Item], cut: bool = False) -> bool:
    """For an answer without @@end (cut off, timed out) or with @@fail: may a scancel / TERM have gone out? Only proof
    says no — no @@start from an ssh that ended with the remote's own status or never started (CUT False: all it
    printed arrived, so the remote never began; CUT = a timeout, ssh's own 255 or a signal is no proof — the body may
    have run there while nothing came back), @@fail (it stopped before any identity — I8: the hung-mount probe's
    before @@start too; whatever came after it, the body returns right after printing it), `@@scancel none` / `@@kill
    none`, or every item's identity verdict arrived and none passed. Anything else after @@start: maybe."""
    if "fail" in facts:
        return False
    if "start" not in facts:
        return cut
    if facts.get("scancel") == "none" or facts.get("kill") == "none":
        return False
    if all(i.job in verdict for i in items) and not any(v.startswith("ok") for v in verdict.values()):
        return False
    return True


def ended(place: harness.Place, i: Item, v: str) -> dict:
    """What a `gone…` / `ended=STATE` verdict says about an item: {said, state, evidence, recorded}."""
    if v.startswith("ended="):
        st = v[6:]
        return {"said": f"ended ({st})", "state": st, "evidence": f"rsk cancel: squeue says {st}", "recorded": True}
    why = v[5:] if v.startswith("gone ") else ""
    if why == "boot":
        return {"said": "ended (the box rebooted since it started: boot_id differs)", "state": "REBOOT",
                "evidence": "rsk cancel: the box's boot_id differs from the run's", "recorded": True}
    if why == "reused":
        return {"said": "ended (its pid now belongs to another process: start time differs; nothing was signalled)",
                "state": "ENDED", "evidence": "rsk cancel: pid reused (its /proc start differs), nothing signalled",
                "recorded": True}
    if place.kind == "slurm":       # not in this user's squeue: ended long ago, or a wrong id — rsk status reads sacct
        return {"said": "not running (not in squeue)", "state": "", "evidence": "", "recorded": False}
    return {"said": "ended (its pid is gone)", "state": "ENDED", "evidence": "rsk cancel: pid gone (no /proc entry)",
            "recorded": True}


def _record_end(led: L.Ledger, i: Item, end: dict) -> bool:
    """The end a cancel's identity read proved, into the ledger now (never a guess: only recorded verdicts)."""
    try:
        led.observe(i.run, i.attempt, i.log or i.job, end["state"], "rsk cancel", end={
            "state": end["state"], "rc": "", "evidence": end["evidence"]})
    except (RskError, KeyError, OSError):
        return False
    return True


def add_parser(sub) -> None:
    p = sub.add_parser("cancel", help="stop a run of this project: the user's words or a cancel_own grant, then an "
                       "identity check and scancel / kill in one ssh — recorded in the ledger",
                       description=__doc__.split("\n\n")[0], epilog=__doc__.split("\n\n", 1)[1],
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("run", nargs="?", default="", metavar="RUN", help="a ledger run id (rsk status)")
    p.add_argument("--job", default="", metavar="J", help="Slurm job id, or the nohup run's pid")
    p.add_argument("-T", "--target", default="")
    p.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory)")
    p.add_argument("--approve", default=None, metavar="WORDS",
                   help="the user's words asking for this cancel — naming it: the job id / pid (or a range holding "
                   "it: 102-104), the run id or name — or their answer to your question naming it (--asked)")
    p.add_argument("--asked", default=None, metavar="QUESTION",
                   help="with --approve: your own question the user's words answer, verbatim (\"sw1 (job 101) "
                   "diverged — cancel it?\" answered \"yes\"); it may name what is cancelled for them — recorded "
                   "with the approval and in the audit; bookkeeping, not proof")
    p.add_argument("--grace", type=int, default=30, help="nohup: seconds between TERM and KILL (default 30)")
    p.add_argument("--deadline", type=float, default=60.0)
    p.add_argument("--wait", type=int, default=0, metavar="S",
                   help="Slurm: after an accepted scancel, read the target again (as rsk status does, every ~10 s; S <= 600) "
                   "until the job's end is seen or S seconds pass — then exit 5 'not ended yet' (default 0: no wait; "
                   "a job an earlier rsk cancel saw accepted is only waited for, not cancelled again; nohup: the "
                   "cancel already waits --grace)")
    p.set_defaults(func=cmd_cancel)
