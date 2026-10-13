#!/usr/bin/env bash
# run-skills remote/status.sh — ONE bounded status digest for one run (both kinds). Deployed next to env.sh; runs on
# the login node / the box (Linux: GNU stat, procps) under a bare `ssh host 'bash <REMOTE_DIR>/.<t>/status.sh …'`.
# Read-only, no state, never sources env.sh. Output = `key=value` lines then `tail:` lines, ~2 KB at the default:
#   status.sh [-n LINES] <jobid> [<ckpt-dir>]     slurm: squeue (else sacct) for the job + its logs/<name>_<jobid>.out
#   status.sh [-n LINES] <log>   [<ckpt-dir>]     any kind: that log; on nohup also the PID from <log>.pid
# Hint input is bounded by BYTES: the last 256 KiB, CR-normalised; patterns are counted there BEFORE display
# truncation. Harness markers (`] target=<t> job=<id> restart=N` / `] EXIT rc=N `) come from a separate last-64-MiB
# scan; the wandb URL also uses the first 64 KiB. Counts are hints, not diagnoses (coverage=partial = the file is
# larger than the window, so 0 ≠ "no errors"). Displayed lines are cut to 200 chars, a cut is marked with `…`;
# -n (default 5, max 200) = displayed lines, so `-n 40` is the bounded deep read. Paths are absolute or relative to
# the project dir (the parent of this script's dir). Every failed or ambiguous lookup is printed as unknown — the
# digest never turns one into a state. `starts=` counts harness headers (Slurm restarts), not `a<attempt>`.
set -u; export LC_ALL=C
D=$(cd "$(dirname "$0")" && pwd); PROJ=$(cd "$D/.." && pwd); N=5; W=262144; MW=67108864; HW=65536; CUT=200
pf() { sed -n "s/^[[:space:]]*\(export[[:space:]]*\)\{0,1\}$1='\([^']*\)'.*/\2/p; s/^[[:space:]]*\(export[[:space:]]*\)\{0,1\}$1=\"\([^\"]*\)\".*/\2/p; s/^[[:space:]]*\(export[[:space:]]*\)\{0,1\}$1=\([^'\";[:space:]]*\).*/\2/p" "$D/profile.sh" 2>/dev/null | head -n 1; }   # profile = data, quoted value read whole
KIND=$(pf T_KIND); TNAME=$(pf T_NAME); note=""
case "$KIND" in slurm|nohup) ;; *) KIND=unknown; note=" (no usable T_KIND in $D/profile.sh: the PID section runs only if <log>.pid exists)" ;; esac
case "$TNAME" in ''|*[!A-Za-z0-9_.-]*) TNAME=""; note="$note (no usable T_NAME in $D/profile.sh: a job id's log cannot be checked against this target)" ;; esac
usage() { sed -n '5,6p' "$0"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) [ "$#" -ge 2 ] || { echo "ERROR: -n needs a count" >&2; exit 2; }; N=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "ERROR: unknown flag '$1'" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done
[ "$#" -ge 1 ] && [ "$#" -le 2 ] && [ -n "$1" ] || { usage >&2; exit 2; }
N=$(printf %s "$N" | sed 's/^0*//'); case "$N" in ''|*[!0-9]*) echo "ERROR: -n needs a positive integer" >&2; exit 2 ;; esac
[ "${#N}" -le 3 ] && [ "$N" -le 200 ] || N=200
ID=$1; CK=${2:-}; now=$(date +%s)
case "$CK" in -*) echo "ERROR: '$CK' is not a checkpoint dir (flags go before the id / log)" >&2; exit 2 ;; esac
case "$ID" in */*|*.*) ;; [0-9]*[_+][0-9]*) echo "ERROR: '$ID' looks like an array / hetjob id — pass the base job id or the log path" >&2; exit 2 ;; esac
echo "observed=$(date +%FT%T) proj=$PROJ"; echo "target=${TNAME:-unknown} kind=$KIND$note"
clip() { awk -v n="$1" '{ if (length($0) <= n) { print; next } s = substr($0, 1, n); sub(/[\300-\377][\200-\277]*$/, "", s); print s "…" }'; }   # cut marked, no partial UTF-8
norm() { tr '\r' '\n' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\000-\010\013-\037\177'; }   # CR → newline; ANSI + control bytes out
g() { grep -aoE "$1" || { s=$?; [ "$s" = 1 ] && return 0; return "$s"; }; }     # no match is not a failure; a real grep error keeps its status
TS='\[[^]]{0,60}[0-9][0-9][^]0-9]+[0-9][0-9][^]]{0,20}\] '   # the `[<date>] ` a marker carries: two SEPARATED digit runs, which `[step 10]` / `[step 1000]` / `[eval]` lack
_t=${TMPDIR:-/tmp}; { [ -d "$_t" ] && [ -w "$_t" ]; } || _t=/tmp   # a login node's TMPDIR is often a purged scratch path
tmp=$(mktemp -d "$_t/rs-status.XXXXXX" 2>/dev/null) || { _t=/tmp; tmp=$(mktemp -d "$_t/rs-status.XXXXXX" 2>/dev/null); } \
  || { echo "status=unknown (no usable temp dir: tried '${TMPDIR:-/tmp}' and /tmp)"; exit 1; }
trap 'rm -rf "$tmp"' EXIT; export TMPDIR="$_t"; E="$tmp/e"; WIN="$tmp/w"   # exported: bash herestrings need a writable one
amb=""
case "$ID" in
  *[!0-9]*) JID=""; LOG=$ID ;;
  *) [ "$KIND" != nohup ] || { echo "ERROR: a nohup target takes the log path, not a job id" >&2; exit 2; }
     JID=$(printf %s "$ID" | sed 's/^0*//'); [ -n "$JID" ] || { echo "ERROR: '$ID' is not a job id" >&2; exit 2; }
     LOG=""; n=0; m=0; rfail=0; ft=""; set --
     for f in "$PROJ"/logs/*_"$JID".out; do [ -f "$f" ] || continue; n=$((n+1)); set -- "$@" "$f"; done   # regular files only (a FIFO would hang)
     for f in "$@"; do   # targets sharing a filesystem collide on job ids: a header, when present, must name THIS target (literal compare)
       hdr=$(head -c 4096 "$f" 2>/dev/null) || { rfail=1; continue; }   # an unreadable candidate is never assumed headerless
       t=""; [ -z "$TNAME" ] || t=$(printf '%s\n' "$hdr" | grep -aoE "$TS""target=[^[:space:]]+ job=$JID restart=" | head -n 1 | sed 's/.*\] target=//; s/ job=.*//')
       if [ -n "$t" ] && [ "$t" = "$TNAME" ]; then LOG=$f; m=$((m+1)); elif [ -n "$t" ]; then ft=$t; elif [ "$n" = 1 ]; then LOG=$f; m=1; fi
     done
     if [ "$rfail" = 1 ]; then LOG=""; amb="a candidate logs/*_$JID.out could not be read (it may be this run's newer log) — pass the log path"
     elif [ "$m" -gt 1 ]; then LOG=""; amb="$n files match logs/*_$JID.out and more than one names '$TNAME' — pass the log path"   # rfail first: it may be this run's newer log
     elif [ "$m" = 1 ] || [ "$n" = 0 ]; then :
     elif [ -n "$ft" ] && [ "$n" = 1 ]; then amb="logs/*_$JID.out belongs to target '$ft', not '$TNAME'"
     else amb="$n files match logs/*_$JID.out and none names target '${TNAME:-unknown}' — pass the log path"; fi ;;
esac
[ -z "$LOG" ] || [ "${LOG#/}" != "$LOG" ] || LOG="$PROJ/$LOG"

# --- scheduler view (slurm): squeue while queued/running/just ended; sacct once it aged out — labelled with WHY -------
if [ -n "$JID" ]; then
  q=$(squeue -h -j "$JID" --Format='State:0|,Reason:0|,TimeUsed:0|,TimeLeft:0|,RestartCnt:0|,NodeList:0' 2>"$E"); qrc=$?
  row=$(printf '%s\n' "$q" | grep -m 1 '|.*|.*|.*|.*|'); err=$(head -n 1 "$E" | clip 100)   # the first row-shaped line
  ok=0; if [ "$qrc" = 0 ] && [ -n "$row" ]; then
    IFS='|' read -r st rs tu tl rc nl <<<"$row"; ok=1
    case "$st" in ''|*[!A-Z_]*) ok=0 ;; esac; case "$rc" in ''|*[!0-9]*) ok=0 ;; esac   # a state word and a restart count, else not a row
  fi
  if [ "$ok" = 1 ]; then echo "job=$JID state=$st reason=$rs elapsed=$tu left=$tl restarts=$rc nodes=${nl:-none}"
  else
    case "$qrc:$err:$q" in *"Invalid job id"*) why="gone from the queue" ;; 0::) why="not in the queue" ;; 0:*) why="unparsable squeue output, queue state unverified" ;; *) why="squeue FAILED (exit $qrc${err:+: $err})" ;; esac
    a=$(sacct -j "$JID" -X -n -P -o State,ExitCode,Elapsed,End 2>"$E"); arc=$?   # status captured BEFORE parsing
    row=$(printf '%s\n' "$a" | grep -m 1 -E '^[A-Z_]+(\+| by [0-9]+)?\|[0-9]+:[0-9]+\|[0-9:-]+\|[^|]+$')
    if [ "$arc" = 0 ] && [ -n "$row" ]; then IFS='|' read -r st ec el en <<<"$row"; echo "job=$JID state=$st exit=$ec elapsed=$el end=$en (sacct; $why)"
    else
      if [ "$arc" != 0 ]; then detail="sacct FAILED (exit $arc)"; elif [ -n "$a" ]; then detail="unparsable sacct output"; else detail="sacct has no record"; fi
      echo "job=$JID state=unknown ($why; $detail)"
    fi
  fi
fi

# --- the log: size/age, harness markers (marker text only, so one glued to a progress line stays clean), one bounded
#     window for hints / URL / tail. A failed read or stat is said, never scored as "no hints". -------------------------
have_log=0
if [ -n "$amb" ]; then echo "log=ambiguous ($amb)"
elif [ -z "$LOG" ] || [ ! -e "$LOG" ]; then echo "log=none${LOG:+ ($LOG)}${JID:+ (logs/<name>_$JID.out appears when the job starts)}"
elif [ ! -f "$LOG" ]; then echo "log=not-a-regular-file ($LOG)"
else
  sz=$(stat -L -c %s "$LOG" 2>/dev/null) || sz=""; mt=$(stat -L -c %Y "$LOG" 2>/dev/null) || mt=""
  case "$sz:$mt" in *[!0-9:]*|:*|*:) sz=""; ag="" ;; *) ag=$(( now - mt )) ;; esac
  if [ -z "$sz" ]; then echo "log=$LOG bytes=unknown age=unknown (stat failed)"
  elif [ "$ag" -ge 0 ]; then echo "log=$LOG bytes=$sz age=${ag}s"
  else echo "log=$LOG bytes=$sz age=unknown (mtime ${ag#-}s in the future: clock skew)"; fi
  set -o pipefail; rerr=$( { tail -c "$W" "$LOG" | norm > "$WIN"; } 2>&1 ); rd=$?; set +o pipefail
  if [ -z "$sz" ] || [ "$rd" != 0 ]; then echo "starts=unknown scan=unknown wandb=unknown (log read FAILED: $(printf '%s\n' "${rerr:-stat}" | head -n 1 | clip 100))"
  else have_log=1
    set -o pipefail   # only grep's no-match (exit 1) is neutralised, so mrc is a real failure of either command
    marks=$( { tail -c "$MW" "$LOG" | g "$TS""(target=[^[:space:]]+ job=[^[:space:]]+ restart=[0-9]+|EXIT rc=[0-9]+ )[^[:cntrl:]]{0,240}"; } 2>"$E" ); mrc=$?
    set +o pipefail; marks=$(printf '%s\n' "$marks" | sed 's/^\[[^]]*\] //')   # keep the marker text, drop the timestamp
    lab=starts; [ "$sz" -le "$MW" ] || lab=starts_in_last_64MiB
    if [ "$mrc" != 0 ] || [ -s "$E" ]; then echo "starts=unknown (marker read FAILED (exit $mrc): $(head -n 1 "$E" | clip 100))"
    elif [ -n "$marks" ]; then   # the latest start is closed iff the LAST marker is a footer
      hd=$(printf '%s\n' "$marks" | grep -c '^target='); lastm=$(printf '%s\n' "$marks" | tail -n 1)
      last=$(printf '%s\n' "$marks" | grep '^target=' | tail -n 1 | sed -n 's/.* restart=\([0-9][0-9]*\) .*/\1/p')
      case "$lastm" in
        'EXIT rc='*) echo "$lab=$hd restart=${last:-?} footer=$(printf '%s\n' "$lastm" | clip 160)" ;;
        *) echo "$lab=$hd restart=${last:-?} footer=none (start open: running, or killed before writing it)" ;;
      esac
    elif [ "$sz" -gt "$MW" ]; then echo "starts=unknown (no harness marker in the last 64 MiB)"
    elif [ "$KIND" = slurm ]; then echo "starts=0 footer=none (no harness marker: not started, the env refused, or not a harness log)"; fi
    [ "$sz" -le "$W" ] && cov=full || cov="partial (last $W of $sz bytes)"
    NF='(^|[^a-z0-9_])(nan|inf|infinity)([^a-z0-9_]|$)'; OOM='out of memory|out_of_memory|oom-kill|oom_kill|cuda error'
    echo "scan=$cov hints: traceback=$(grep -ci 'traceback' "$WIN") oom=$(grep -ciE "$OOM" "$WIN") nonfinite=$(grep -ciE "$NF" "$WIN") error=$(grep -ciE 'error|exception' "$WIN")   (window-scoped line counts)"
    h=$(grep -iE "traceback|$OOM|$NF|error|exception" "$WIN" | tail -n 1 | clip "$CUT"); [ -z "$h" ] || echo "last_hint=$h"
    # ONE checked head snapshot; its last line is dropped only when byte 64 KiB is not a line end (the line was cut)
    if ! head -c "$HW" "$LOG" > "$tmp/h" 2>"$E"; then echo "wandb=unknown (head read FAILED: $(head -n 1 "$E" | clip 100))"
    else
      cutline=0; [ "$sz" -le "$HW" ] || [ "$(tail -c 1 "$tmp/h" | tr -d '\r\n' | wc -c)" = 0 ] || cutline=1
      RU='/runs/[A-Za-z0-9_-]+'   # a run URL counts on the public host, or on the wandb client's own "View run … <url>" line
      set -o pipefail
      u=$( { { norm < "$tmp/h" | { [ "$cutline" = 0 ] && cat || sed '$d'; }; echo; cat "$WIN"; } \
             | g "https://wandb\.ai/[^[:space:]]+$RU|wandb:[^[:cntrl:]]*[Vv]iew run[^[:cntrl:]]*https?://[^[:space:]]+$RU" \
             | g "https?://[^[:space:]]+$RU" | tail -n 1 | clip "$CUT"; } 2>"$E" ); urc=$?
      set +o pipefail
      if [ "$urc" != 0 ]; then echo "wandb=unknown (URL scan FAILED (exit $urc): $(head -n 1 "$E" | clip 100))"
      else echo "wandb=${u:-none} (wandb.ai, or a client View-run line on any host; first 64 KiB + window)"; fi
    fi
  fi
fi

# --- nohup: the PID file beside the log (even when the log is missing). ps: exit 1 + silence = no such process; -------
#     anything else = the query failed. A process younger than the pid file is a reused pid OR clock skew: unknown. ----
if [ -n "$LOG" ] && { [ "$KIND" = nohup ] || { [ "$KIND" = unknown ] && [ -f "$LOG.pid" ]; }; }; then
  if [ ! -f "$LOG.pid" ]; then echo "proc=unknown (no $LOG.pid)"
  else
    ok=1; pid=""   # ≤ 64 bytes of digits / whitespace only, checked as raw bytes (NUL never reaches a variable); first line, edges trimmed
    if [ "$(head -c 65 "$LOG.pid" | wc -c)" -gt 64 ] || [ "$(head -c 65 "$LOG.pid" | tr -d '0-9 \t\n' | wc -c)" != 0 ]; then ok=0
    else pid=$(head -n 1 "$LOG.pid" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'); case "$pid" in ''|0*|*[!0-9]*) ok=0 ;; esac; [ "${#pid}" -le 9 ] || ok=0; fi
    if [ "$ok" = 0 ]; then echo "proc=unknown (unreadable $LOG.pid: '$(head -c 40 "$LOG.pid" | tr -d '\000-\037\177')')"
    else
      pmt=$(stat -L -c %Y "$LOG.pid" 2>/dev/null) || pmt=""; case "$pmt" in ''|*[!0-9]*) pmt="" ;; esac
      p=$(ps -o etimes=,stat=,pcpu=,cmd= -p "$pid" 2>"$E"); prc=$?; perr=$(head -n 1 "$E" | clip 100); set -f; set -- ${p:-}; set +f
      if [ -z "$p" ] && [ "$prc" = 1 ] && [ -z "$perr" ]; then echo "proc=gone pid=$pid exit=unknown (nothing records a nohup exit: judge by the last lines + the final artifact)"
      elif [ "$prc" != 0 ] || [ -n "$perr" ] || [ "$#" -lt 4 ] || [ -n "${1//[0-9]/}" ]; then echo "proc=unknown (ps FAILED or unparsable (exit $prc${perr:+: $perr}))"
      elif [ -z "$pmt" ]; then echo "proc=unknown pid=$pid (cannot stat $LOG.pid, so the process cannot be tied to the launch)"
      elif [ "$1" -lt $(( now - pmt - 60 )) ]; then echo "proc=unknown pid=$pid (that process is ${1}s old but the launch was $(( now - pmt ))s ago: reused pid or clock skew)"
      elif [ "${2#Z}" != "$2" ]; then echo "proc=zombie pid=$pid (exited, not reaped)"
      else et=$1 cpu=$3; shift 3; echo "proc=alive pid=$pid etime=${et}s cpu=${cpu}% cmd=$(printf '%s\n' "$*" | clip 120)"; fi
    fi
  fi
fi
[ "$have_log" = 0 ] || grep -v '^[[:space:]]*$' "$WIN" | tail -n "$N" | clip "$CUT" | sed 's/^/tail: /'

# --- directory activity, NOT checkpoint validation: an entry may be temporary, metadata, or a directory ------------
if [ -n "$CK" ]; then
  [ "${CK#/}" != "$CK" ] || CK="$PROJ/$CK"
  if [ ! -d "$CK" ]; then echo "ckpt_entry=none (no dir $CK)"
  else
    set -o pipefail; nf=$(ls -t "$CK" 2>/dev/null | sed -n '1p'); lrc=$?; set +o pipefail   # sed drains: no SIGPIPE on a huge dir
    if [ "$lrc" != 0 ]; then echo "ckpt_entry=unknown (cannot list $CK)"
    elif [ -z "$nf" ]; then echo "ckpt_entry=none (empty $CK)"
    elif mt=$(stat -L -c %Y "$CK/$nf" 2>/dev/null) && [ -z "${mt//[0-9]/}" ]; then
      echo "ckpt_entry=$nf age=$(( now - mt ))s dir=$CK resume=unverified"
    else echo "ckpt_entry=unknown (cannot stat $CK/$nf)"; fi
  fi
fi
