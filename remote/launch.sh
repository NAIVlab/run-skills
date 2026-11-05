#!/usr/bin/env bash
# run-skills remote/launch.sh — the nohup launch, deployed as <REMOTE_DIR>/.ws/launch.sh and run by bin/run-launch over
# ONE ssh (`cd <dir>; TARGET=<t> bash .ws/launch.sh …`). Linux + bash + coreutils + util-linux setsid (flock if present).
#   launch.sh [--rs-attempt NONCE] [--rs-mode plan] [--rs-expect HASH [--rs-warnings ID]] [--same-name-ok] [--gpu-busy-ok]
#             [-d IDS | -n N [-x IDS]] [--nice N] [-N NAME] [--log PATH] -- RUN…
# Claims .rs/attempts/<NONCE>/ (mkdir) and records everything there FIRST — out, err, stage, receipt, result (EXIT trap) —
# then replays out/err to the caller, so a dead ssh loses nothing. Gate: env.sh in a subshell, then the venv / conda
# check (as the old inline chain). Refuses a run of the same NAME still alive (receipt pid + /proc start + boot_id).
# GPUs: one nvidia-smi query; CUDA_VISIBLE_DEVICES=<ids> with CUDA_DEVICE_ORDER=PCI_BUS_ID (= nvidia-smi's index order;
# ids, not UUIDs: some payloads parse it as integers), the UUIDs go to the receipt. A GPU with a compute process (one
# --query-compute-apps query, parsed without a temp file) is never auto-picked, and -d onto one is exit 6, without
# --gpu-busy-ok (the user's OK); a failed or unreadable query = unknown = exit 1 without it. Protocol api=3 (the
# `# rs-api=3` line below, which run-launch checks): --rs-mode plan runs every check — the env gate read-only (the venv's
# python / the conda env, resolved as env.sh does; a plan creates nothing outside .rs/) — prints ONE `@@plan v1` … `@@end`
# block and starts nothing; --rs-expect HASH launches only if rs_bound still gives that hash — bound: the occupants of the
# landing's busy GPUs (busy_ok=<id>:<uuid>:<user>,…) and the ENV_HOOK file's sha256 — and this call's warnings_id (the
# distinct WARNING: lines, digit runs masked) is the approved card's (--rs-warnings ID; default: no warning), else the
# block, `changed: <keys>` (from the approved plan's journal, when here) and ERROR, exit 6, before the wrapper exists.
# rs-api=3
# The run is setsid'd under a wrapper (pid = pgid = <log>.pid) that starts the payload only after the receipt is on disk
# (.rs/attempts/<NONCE>/gate -> go; anything else = never started), forwards TERM/INT once and ends the log with
# `[<date>] EXIT rc=N term=0|1 …` + <log>.rc (`rc= term= at=`). RUN is one shell string, parsed once (as before), and
# never picks the GPUs: leading words (before its command, also after a leading `env`) that set or clear CUDA_VISIBLE_DEVICES,
# CUDA_DEVICE_ORDER, NVIDIA_/HIP_/ROCR_VISIBLE_DEVICES, or an env option that may (-i, -S, …) = exit 2 before the claim when
# RUN's text shows it; else (an expansion) the wrapper checks the expanded words and never starts it (rc 2, ERROR in the log).
# Exit: 0 launched (planned), 1 failed (env gate, nvidia-smi, start) or too few free GPUs, 2 usage/data (RUN setting a GPU
# variable: before the claim, no .rs/attempts/<NONCE>/), 6 NAME still
# running, a busy -d GPU, or not the --rs-expect plan; 75 NONCE claimed.
set -u
unset RS_ATTEMPT RS_CONF_FILE RS_RUN RS_ACKS    # a launch from inside a run never inherits that run's attempt
_l0=" $(compgen -v 2>/dev/null | tr '\n' ' ') "             # the shell's own + inherited names: everything else below is launch.sh's
SELF=$(cd "$(dirname "$0")" && pwd) && PROJ=$(cd "$SELF/.." && pwd) || { echo "ERROR: cannot resolve the project dir" >&2; exit 2; }
trap '' HUP                                     # decide and record even if the session hangs up (inherited by the run, as nohup)
GPUS=""; NPICK=""; EXCL=""; NICE=""; NAME=""; LOG=""; SAME=0; NONCE=""; RA=0; uerr=""; MODE=""; EXPECT=""; BOK=0; RS_WARN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d|-n|-x|-N|--nice|--log|--rs-attempt|--rs-mode|--rs-expect|--rs-warnings)
      [ "$#" -ge 2 ] || { uerr=${uerr:-"$1 needs a value"}; shift; continue; }
      case "$1:$2" in --rs-*:*) ;; *:*--rs-*) uerr=${uerr:-"$1 '$2': an --rs- word is never an option's value"} ;; esac
      case "$1" in -d) GPUS=$2 ;; -n) NPICK=$2 ;; -x) EXCL=$2 ;; -N) NAME=$2 ;; --nice) NICE=$2 ;; --log) LOG=$2 ;;
        --rs-mode) [ -z "$MODE" ] && [ "$2" = plan ] && MODE=plan || uerr=${uerr:-"--rs-mode takes one value, plan, once"} ;;
        --rs-expect) [ -z "$EXPECT" ] && [ "${#2}" = 64 ] && [ -n "${2##*[!0123456789abcdef]*}" ] && EXPECT=$2 \
                       || uerr=${uerr:-"--rs-expect takes one bound_hash (64 lowercase hex), once"} ;;
        --rs-warnings) [ -z "$RS_WARN" ] && [ "${#2}" = 64 ] && [ -n "${2##*[!0123456789abcdef]*}" ] && RS_WARN=$2 \
                         || uerr=${uerr:-"--rs-warnings takes one warnings_id (64 lowercase hex: the approved card's), once"} ;;
        *) NONCE=$2; RA=1 ;; esac
      shift 2 ;;
    --same-name-ok) SAME=1; shift ;;
    --gpu-busy-ok) BOK=1; shift ;;
    --) shift; break ;;
    *) uerr=${uerr:-"unknown arg '$1'"}; shift ;;
  esac
done
RUN_CMD="$*"; PLAN=0; [ "$MODE" != plan ] || PLAN=1
[ -z "$RS_WARN" ] || [ -n "$EXPECT" ] || uerr=${uerr:-"--rs-warnings goes with --rs-expect (the approved card's warnings_id)"}

# ---- RUN never picks the GPUs: the landing (-d / -n, checked for other users' processes, bound in the plan) is this
#      script's. The run starts as `env <RUN>`, so a GPU variable set (or cleared) by RUN's leading words would replace it.
rs_gpuenv() {   # rs_gpuenv WORD…: the words `env` gets. 0 = they leave the GPU variables alone; else 1 and why (stdout).
  # GNU env: options first (getopt '+': they end at the first non-option; `--` ends them; a `-` then = -i), then every word
  # holding '=' is NAME=VALUE (NAME = up to the first '='), then the command — `env` again (or …/env) is read the same way.
  # Only options that leave the environment's GPU variables alone pass (-v --debug -C DIR -u NAME); any other may set or
  # clear them (-i, -S, an abbreviation…). The payload is code: what it does once it runs is beyond this check.
  local w n o=1
  while [ "$#" -gt 0 ]; do
    w=$1; shift; n=""
    if [ "$o" = 1 ]; then
      case "$w" in
        --) o=2; continue ;;
        -v|--debug) continue ;;
        -C|--chdir) [ "$#" = 0 ] || shift; continue ;;
        -C?*|--chdir=*) continue ;;
        -u|--unset) [ "$#" -gt 0 ] || return 0; n=$1; shift ;;
        -u?*) n=${w#-u} ;;
        --unset=*) n=${w#--unset=} ;;
        -) echo "starts env with '-' (= -i: the harness's CUDA_VISIBLE_DEVICES and CUDA_DEVICE_ORDER would go)"; return 1 ;;
        -?*) echo "gives env the option '$w' (it may set or clear the GPU variables; only -v, -C DIR and -u NAME pass)"; return 1 ;;
        *) o=0 ;;
      esac
      if [ -n "$n" ]; then case "$n" in
        CUDA_VISIBLE_DEVICES|CUDA_DEVICE_ORDER|NVIDIA_VISIBLE_DEVICES|HIP_VISIBLE_DEVICES|ROCR_VISIBLE_DEVICES) echo "clears $n (env -u)"; return 1 ;;
      esac; continue; fi
    fi
    if [ "$o" = 2 ]; then o=0; [ "$w" != - ] || { echo "gives env '-- -' (= -i: the harness's CUDA_VISIBLE_DEVICES and CUDA_DEVICE_ORDER would go)"; return 1; }; fi
    case "$w" in
      *=*) n=${w%%=*}; case "$n" in
             CUDA_VISIBLE_DEVICES|CUDA_DEVICE_ORDER|NVIDIA_VISIBLE_DEVICES|HIP_VISIBLE_DEVICES|ROCR_VISIBLE_DEVICES) echo "sets $n before its command ('$w')"; return 1 ;;
           esac ;;
      env|*/env) o=1 ;;
      *) return 0 ;;   # the command: what it does is the payload's
    esac
  done
  return 0
}
rs_runwords() {   # rs_runwords RUN -> RS_W: RUN's first words as env gets them (quotes removed) while each is literal; RS_P: the
  # literal start of the word where that ends — an expansion ($ `), a glob, a brace, a leading ~, an unquoted separator,
  # redirection or comment. Reads only what is certain without expanding anything; the wrapper checks the expanded words.
  local LC_ALL=C; local s=$1 i=0 n c q="" w="" in=0 st=""   # bytes (O(1) ${s:i:1}); multibyte text is copied byte by byte
  n=${#s}; RS_W=(); RS_P=""
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}; i=$((i + 1))
    case "$q" in
      "'") if [ "$c" = "'" ]; then q=""; else w=$w$c; fi; continue ;;
      '"') case "$c" in
             '"') q="" ;;
             '\') c=${s:i:1}; case "$c" in '$'|'`'|'"'|'\') w=$w$c; i=$((i + 1)) ;; $'\n') i=$((i + 1)) ;; *) w=$w'\' ;; esac ;;
             '$'|'`') st=x; break ;;
             *) w=$w$c ;;
           esac; continue ;;
    esac
    case "$c" in
      ' '|$'\t') [ "$in" = 0 ] || { RS_W+=("$w"); w=""; in=0; } ;;
      "'"|'"') q=$c; in=1 ;;
      '\') [ "$i" -lt "$n" ] || { st=x; break; }; c=${s:i:1}; i=$((i + 1)); [ "$c" = $'\n' ] || { w=$w$c; in=1; } ;;
      '~'|'#') [ "$in" = 1 ] || { st=x; break; }; w=$w$c ;;
      '$'|'`'|'*'|'?'|'['|'{'|$'\n'|';'|'&'|'|'|'<'|'>'|'('|')') st=x; break ;;
      *) w=$w$c; in=1 ;;
    esac
  done
  if [ -n "$st" ]; then RS_P=$w; elif [ -z "$q" ] && [ "$in" = 1 ]; then RS_W+=("$w"); fi
}
if [ -z "$uerr" ]; then   # before the claim: nothing is created for a RUN refused here
  rs_runwords "$RUN_CMD"; set -- ${RS_W[@]+"${RS_W[@]}"}
  case "$RS_P" in -*) ;; *=*) set -- ${1+"$@"} "$RS_P" ;; esac   # a word that starts NAME=…: an assignment of NAME, whatever follows
  why=$(rs_gpuenv ${1+"$@"}) || { echo "ERROR: RUN $why — the GPUs are launch.sh's choice (-d IDS / -n N: checked for other users' processes, bound in the plan), not RUN's; nothing launched" >&2; exit 2; }
fi

# ---- the claim: mkdir of the attempt dir (never -p for the leaf); a caller's NONCE that exists = it ran already ----
AN=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789   # spelled out: [A-Z] ranges follow the locale (as submit.sh)
if [ "$RA" = 1 ]; then case "$NONCE" in [$AN]*) ;; *) NONCE=/ ;; esac   # never '', '.', '..' or a leading '-' (an old parser's flag)
  case "$NONCE" in *[!$AN._-]*) echo "ERROR: --rs-attempt NONCE must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}" >&2; exit 2 ;; esac
  [ "${#NONCE}" -le 64 ] || { echo "ERROR: --rs-attempt NONCE is longer than 64 characters" >&2; exit 2; }; fi
mkdir -p "$PROJ/.rs/attempts" 2>/dev/null || { echo "ERROR: cannot create $PROJ/.rs/attempts (the attempt journal; permissions/quota?) — nothing launched" >&2; exit 2; }
gen=0; [ "$RA" = 1 ] || gen=1
for _i in 1 2 3 4 5; do
  [ "$gen" = 0 ] || NONCE="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  A=$PROJ/.rs/attempts/$NONCE
  mkdir "$A" 2>/dev/null && break
  [ -e "$A" ] || { echo "ERROR: cannot create $A (permissions/quota?) — nothing launched" >&2; exit 2; }
  [ "$gen" = 1 ] || { echo "ERROR: attempt $NONCE is already claimed (.rs/attempts/$NONCE): it ran before — read its result and receipt, never retry with the same NONCE" >&2; exit 75; }
  [ "$_i" -lt 5 ] || { echo "ERROR: could not claim a fresh attempt dir under $PROJ/.rs/attempts" >&2; exit 75; }
done
exec 3>&1 4>&2                                  # the caller's stdout/stderr, used once: the replay at exit
exec >"$A/out" 2>"$A/err" </dev/null
stage() { printf '%s\n' "$1" > "$A/stage.tmp" && mv -f "$A/stage.tmp" "$A/stage"; }
VERDICT=""
on_exit() {
  local rc=$? st g v; trap - EXIT; trap '' TERM INT
  st=$(cat "$A/stage" 2>/dev/null) || st=unknown
  [ "$st" != launch ] || ln -s abort "$A/gate" 2>/dev/null   # an undecided gate fails closed: the payload never starts
  g=$(readlink "$A/gate" 2>/dev/null) || g=""
  [ "$g" = go ] || rm -f "$A/vars"              # never sourced (the wrapper reads it only after go): nothing of it stays
  if [ "$g" = go ]; then v=launched; elif [ -n "$VERDICT" ]; then v=$VERDICT   # (planned: set just before a plan's exit 0)
  else case "$rc" in 2|6) v=refused ;; 0) v=unknown ;; *) v=failed ;; esac; fi
  printf 'stage=%s rc=%s verdict=%s at=%s\n' "$st" "$rc" "$v" "$(date +%s)" > "$A/result.tmp" && mv -f "$A/result.tmp" "$A/result"
  trap '' PIPE                                  # a dead caller: the replay fails quietly, the exit status stays
  cat "$A/out" >&3 2>/dev/null; cat "$A/err" >&4 2>/dev/null
  exit "$rc"
}
trap on_exit EXIT; trap 'exit 143' TERM; trap 'exit 130' INT
stage pre-policy
echo "attempt: .rs/attempts/$NONCE"
die2() { echo "ERROR: $*" >&2; exit 2; }
[ -z "$uerr" ] || die2 "$uerr (usage: launch.sh [--rs-attempt NONCE] [--rs-mode plan] [--rs-expect HASH [--rs-warnings ID]] [--same-name-ok] [--gpu-busy-ok] [-d ids | -n N [-x ids]] [--nice N] [-N name] [--log logs/<name>-<YYYYmmdd-HHMMSS>.log] -- <cmd>)"

# ---- target, arguments -------------------------------------------------------------------------------------------
[ -f "$SELF/profile.sh" ] || die2 "MISSING $SELF/profile.sh (partial sync?)"
. "$SELF/profile.sh" || die2 "FAILED sourcing $SELF/profile.sh"
[ "${T_KIND:-}" = nohup ] || die2 "launch.sh is for nohup targets (T_KIND='${T_KIND:-}' in $SELF/profile.sh)"
TN=${T_NAME:-}; [ -n "$TN" ] || die2 "$SELF/profile.sh lacks T_NAME — deploy with run-sync"
TARGET=${TARGET:-$TN}
[ "$TARGET" = "$TN" ] || die2 "$SELF/ was deployed for target '$TN', not '$TARGET' (boxes sharing this dir?) — run-sync for '$TARGET' first"
TAG=$(printf %s "$TN" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]')
[ -n "$RUN_CMD" ] || die2 "no run command after --"
[ -n "$NAME" ] || NAME=$(basename "$PROJ")
case "$NAME" in ''|.*|-*|*/*|*\'*|*[[:space:]]*|*[[:cntrl:]]*) die2 "-N '$NAME': a run name is one word, no / or ' (letters, digits, . _ - …)" ;; esac
[ "${#NAME}" -le 200 ] || die2 "-N: a run name is at most 200 characters"
if [ -n "$LOG" ]; then
  s=${LOG#"logs/$NAME-"}; s=${s%.log}
  case "$LOG:$s" in "logs/$NAME-"*.log:[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) die2 "--log must be logs/$NAME-<YYYYmmdd-HHMMSS>.log (got '$LOG')" ;; esac
else LOG="logs/$NAME-$(date +%Y%m%d-%H%M%S).log"; fi
idlist() { printf %s "$1" | grep -Eq '^[0-9]+(,[0-9]+)*$'; }
if [ -n "$GPUS" ]; then
  [ -z "$NPICK" ] || die2 "-d and -n are exclusive"
  idlist "$GPUS" || die2 "-d must be comma-separated GPU ids (got '$GPUS')"
else
  NPICK=${NPICK:-1}; printf %s "$NPICK" | grep -Eq '^[1-9][0-9]{0,3}$' || die2 "GPU count (-n) must be a positive integer (got '$NPICK')"
fi
[ -z "$EXCL" ] || idlist "$EXCL" || die2 "-x (GPU_EXCLUDE) must be comma-separated GPU ids (got '$EXCL')"
[ -z "$NICE" ] || printf %s "$NICE" | grep -Eq '^[0-9]+$' || die2 "--nice must be a non-negative integer 0-19 (got '$NICE')"
command -v setsid >/dev/null 2>&1 || { echo "ERROR: setsid not found (util-linux): cannot detach the run" >&2; exit 1; }
BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) && [ -n "$BOOT" ] || { echo "ERROR: no /proc boot_id: launch.sh needs Linux /proc" >&2; exit 1; }
cd "$PROJ" || exit 1; export PROJ TARGET
[ "$PLAN" = 1 ] || mkdir -p logs || { echo "ERROR: cannot create $PROJ/logs" >&2; exit 1; }   # a plan creates nothing

# ---- one launch of this project at a time from here to the gate; then the duplicate guard by live triple ----------
if command -v flock >/dev/null 2>&1; then
  exec 9>>"$PROJ/.rs/launch.lock" && flock -w 60 9 \
    || { echo "ERROR: could not lock .rs/launch.lock within 60 s (another launch from this project in progress?)" >&2; exit 1; }
else echo "NOTE: no flock here: two simultaneous launches of one name are not serialised" >&2; fi
pstat() {   # pstat PID -> "<start> <pgid>" from /proc/PID/stat (fields 22 and 5, counted after the LAST ')'); 1 = gone/zombie
  local s; s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  s=${s##*)}; set -f; set -- $s; set +f
  [ "$#" -ge 20 ] && [ "$1" != Z ] && [ "$1" != X ] || return 1
  printf '%s %s\n' "${20}" "$3"
}
kv() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }
if [ "$SAME" = 0 ]; then
  for r in "$PROJ"/.rs/attempts/*/receipt; do
    [ -f "$r" ] && grep -qxF -e "name=$NAME" "$r" || continue
    d=${r%/receipt}; [ "$(readlink "$d/gate" 2>/dev/null)" = go ] && [ "$(kv boot_id "$r")" = "$BOOT" ] || continue
    rp=$(kv pid "$r"); case "$rp" in ''|*[!0-9]*) continue ;; esac
    cur=$(pstat "$rp") && [ "${cur%% *}" = "$(kv start "$r")" ] || continue
    VERDICT=refused
    echo "ERROR: '$NAME' is already running from this project: pid $rp (attempt .rs/attempts/${d##*/}, log $(kv log "$r")) — stop it first, pick another -N, or pass --same-name-ok to run both" >&2
    exit 6
  done
fi

[ ! -e "$LOG" ] && [ ! -e "$LOG.pid" ] || die2 "$LOG already exists (a launch of '$NAME' in the same second?) — retry"

# ---- GPUs: ONE query; the ids checked against it, their UUIDs recorded in the receipt -----------------------------
q=$(nvidia-smi --query-gpu=index,uuid,memory.used --format=csv,noheader,nounits) \
  || { echo "ERROR: nvidia-smi failed (exit $?): GPU ids cannot be mapped to UUIDs — nothing launched" >&2; exit 1; }
TAB=$(printf '%s\n' "$q" | tr -d ' \r' | awk -F, '$1 ~ /^[0-9]+$/ && $2 ~ /^(GPU|MIG)-[A-Za-z0-9-]+$/ { print $1 "," $2 "," ($3 ~ /^[0-9]+$/ ? $3 : 999999999) }')
[ -n "$TAB" ] || { echo "ERROR: nvidia-smi listed no GPU (index, uuid) rows — nothing launched" >&2; exit 1; }
# busy = a compute process on it (ONE query; its owner from ps). Parsed in this shell by expansion — never through a
# heredoc (bash <= 5.0 writes it to $TMPDIR: a full one would read as "none busy"); a row that names no GPU of TAB, or
# anything unreadable, = unknown (fail closed). BROWS: one <id>:<uuid>:<user> per busy process (busy_ok is made of them)
BUSY=""; BROWS=""; BID=,; if ap=$(nvidia-smi --query-compute-apps=gpu_uuid,pid --format=csv,noheader 2>/dev/null); then
  set -f; _ifs=$IFS; IFS='
'
  for l in $ap; do l=${l//[[:space:]]/}; case "$l" in ''|*[Nn]orunningprocesses*) continue ;; esac
    u=${l%%,*}; p=${l#*,}; i=""; for t in $TAB; do case "$t" in *",$u,"*) i=${t%%,*}; break ;; esac; done
    case "$i" in ''|*[!0-9]*) BUSY=unknown; break ;; esac; case "$p" in ''|*[!0-9]*) BUSY=unknown; break ;; esac
    w=$(ps -o user= -p "$p" 2>/dev/null) || w=""; w=${w//[[:space:]]/}; case "$w" in ''|*[!A-Za-z0-9._@+-]*) w='?' ;; esac
    BUSY=${BUSY:+$BUSY,}$i:$w:$p; BROWS="$BROWS$i:$u:$w
"; BID=$BID$i,
  done; IFS=$_ifs; set +f
else BUSY=unknown; fi
if [ "$BUSY" = unknown ]; then BID=,
  [ "$BOK" = 1 ] || { VERDICT=refused; echo "ERROR: cannot tell which GPUs are busy (nvidia-smi --query-compute-apps failed or unparsable) — nothing launched; only with the user's OK: --gpu-busy-ok" >&2; exit 1; }
  echo "WARNING: GPU busy state unknown; --gpu-busy-ok: launching without that check" >&2
elif [ -n "$BUSY" ]; then echo "[$TN] GPU(s) in use (id:user:pid): $BUSY"; fi
if [ -n "$GPUS" ]; then
  DEV=$GPUS; UUIDS=""; b=""
  for i in $(printf %s "$GPUS" | tr ',' ' '); do
    u=$(printf '%s\n' "$TAB" | awk -F, -v i="$i" '$1 == i { print $2; exit }')
    [ -n "$u" ] || die2 "GPU id $i is not on this box (ids: $(printf '%s\n' "$TAB" | cut -d, -f1 | paste -sd, -))"
    case ",$UUIDS," in *",$u,"*) die2 "-d lists GPU $i twice" ;; esac
    UUIDS=${UUIDS:+$UUIDS,}$u; case "$BID" in *",$((10#$i)),"*) b=${b:+$b,}$((10#$i)) ;; esac
  done
  if [ -n "$b" ] && [ "$BOK" = 0 ]; then VERDICT=refused
    echo "ERROR: -d GPU(s) $b already run a compute process ($BUSY) — pick others, or (only with the user's OK naming them) --gpu-busy-ok" >&2; exit 6; fi
  [ -z "$b" ] || echo "WARNING: -d GPU(s) $b already run a compute process ($BUSY); --gpu-busy-ok: launching onto them" >&2
else   # the NPICK idlest by memory.used among the free ones (busy ones last, and only with --gpu-busy-ok), GPU_EXCLUDE skipped;
  # fewer than asked is a hard error (world size / batch math)
  P=$(printf '%s\n' "$TAB" | awk -F, -v x=",$EXCL," -v b="$BID" -v ok="$BOK" 'index(x, "," $1 ",") == 0 { y = index(b, "," $1 ",") > 0
      if (!y || ok) print y "," $0 }' | sort -t, -k1,1n -k4,4n -k2,2n | head -n "$NPICK" | cut -d, -f2-)
  DEV=$(printf '%s\n' "$P" | cut -d, -f1 | paste -sd, -); UUIDS=$(printf '%s\n' "$P" | cut -d, -f2 | paste -sd, -)
  got=$(printf '%s\n' "$P" | grep -c .)
  [ "$got" -ge "$NPICK" ] || { VERDICT=refused; echo "ERROR: asked -n $NPICK but only $got GPU id(s) free (no compute process${BUSY:+; in use: $BUSY}) after GPU_EXCLUDE. Use -n $got, -d <ids>, or (only with the user's OK) --gpu-busy-ok." >&2; exit 1; }
  b=$(printf '%s\n' "$P" | awk -F, -v b="$BID" 'index(b, "," $1 ",") { print $1 }' | paste -sd, -)
  [ -z "$b" ] || echo "WARNING: the pick includes GPU(s) $b with a compute process ($BUSY); --gpu-busy-ok: launching onto them" >&2
fi

BUSYOK=""   # who this landing accepts sharing with (bound): <id>:<uuid>:<user> of each busy GPU in it, sorted by id, then user —
# only ever with --gpu-busy-ok; 'unknown' when it cannot tell. Another owner, process user or physical GPU since = exit 6
if [ "$BUSY" = unknown ]; then BUSYOK=unknown
elif [ -n "$b" ]; then
  BUSYOK=$(set -f -o pipefail; for r in $BROWS; do case ",$b," in *",${r%%:*},"*) printf '%s\n' "$r" ;; esac; done \
    | LC_ALL=C sort -t: -k1,1n -k3,3 -u | paste -sd, -) && [ -n "$BUSYOK" ] || BUSYOK=unknown
fi

# ---- plan / --rs-expect: ONE bound list + hash for both; env_kind/env_name/ENV_HOOK/VENV_DIR/UV_SYNC_ARGS as env.sh
#      resolves them (profile, then the conf; <TAG>_ENV_NAME / <TAG>_VENV_DIR first), read in a child bash without rc
#      files and handed back as data, never eval'd; the hook file is bound by its sha256 -------------------------------
rs_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }   # stdin -> hex
rs_bound() {   # THE bound list (the plan block's lines kind= … env_name=; bound_hash = sha256 of them): what an approval covers;
  local r=n=$NPICK; [ -z "$GPUS" ] || r=ids=$GPUS   # free text %q-quoted, the validated tokens (name, ids, counts) as they are
  printf 'kind=nohup\ntarget=%q\nname=%s\ngpus_req=%s\nexclude=%s\nnice=%s\nbusy_ok=%s\npayload=%q\nenv_kind=%q\nenv_hook=%q\nvenv_dir=%q\nuv_sync_args=%q\nenv_name=%q\n' \
    "$TN" "$NAME" "$r" "$EXCL" "$NICE" "$BUSYOK" "$RUN_CMD" "$EK" "$EH" "$EV" "$EU" "$EN"; }
rs_warn() {   # W_N W_ID: this call's distinct WARNING: lines (out + err; `WARNING (lint):` is not one), every digit run -> #, sorted
  local l; l=$(set -o pipefail; cat "$A/out" "$A/err" | { grep -a '^WARNING: ' || [ "$?" = 1 ]; } | LC_ALL=C sed -E 's/[0-9]+/#/g' | LC_ALL=C sort -u) \
    || { echo "ERROR: cannot read this call's WARNING lines back from $A — nothing launched" >&2; exit 1; }
  W_N=0; W_ID=$(printf '' | rs_sha)   # no warning: the digest of nothing
  if [ -n "$l" ]; then W_N=$(printf '%s\n' "$l" | grep -c .); W_ID=$(printf '%s\n' "$l" | rs_sha); fi; }
rs_changed() {   # rs_changed BOUND HASH: `changed: <keys>` against the approved plan's block in its own journal (newest 500 attempts)
  local d f="" k=""
  if [ "$2" != "$EXPECT" ]; then
    for d in $(ls -t "$PROJ/.rs/attempts" 2>/dev/null | head -n 500); do   # (NONCEs: [A-Za-z0-9._-], never split or globbed)
      [ "$PROJ/.rs/attempts/$d" != "$A" ] && [ -f "$PROJ/.rs/attempts/$d/out" ] && grep -qxF "bound_hash=$EXPECT" "$PROJ/.rs/attempts/$d/out" \
        && { f=$PROJ/.rs/attempts/$d/out; break; }; done
    [ -n "$f" ] || return 0   # not here: rsk compares the card it stored
    k=$(printf '%s\n' "$1" | awk 'NR == FNR { if ($0 == "@@end") e = 1; if (!e) { k = $0; sub(/=.*/, "", k); a[k] = $0 }; next }
      { k = $0; sub(/=.*/, "", k); if (a[k] != $0) printf "%s%s", (n++ ? " " : ""), k }' "$f" -) || return 0
  fi
  [ "$W_ID" = "$RS_WARN" ] || k="${k:+$k }warnings"; [ -z "$k" ] || echo "changed: $k"; }
rs_plan() {   # rs_plan check|print: `check` (--rs-expect) returns when the hash AND the warnings_id (computed at the same point in
  local b h ch=""; b=$(rs_bound) && h=$(printf '%s\n' "$b" | rs_sha) && [ "${#h}" = 64 ] \
    || { echo "ERROR: cannot hash the plan (no sha256sum or shasum here?) — nothing launched" >&2; exit 2; }
  if [ "$1" = check ]; then   # both modes, before the payload is echoed) match; else the block, changed:, ERROR, exit 6
    [ "$h" != "$EXPECT" ] || [ "$W_ID" != "$RS_WARN" ] || { echo "plan: bound_hash=$h = --rs-expect (the approved plan); its $W_N warning(s) = the approved card's (warnings_id)"; return 0; }
    stage expect; ch=$(rs_changed "$b" "$h"); fi
  printf '@@plan v1\napi=3\n%s\ninfo_gpus=%s\ninfo_uuids=%s\ninfo_busy=%s\ninfo_run_gpu=checked\nwarnings=%s\nwarnings_avail=0\nwarnings_id=%s\nbound_hash=%s\n@@end\n' \
    "$b" "$DEV" "$UUIDS" "$BUSY" "$W_N" "$W_ID" "$h"   # warnings_avail=0: a nohup box has no availability -y gate (too few free = exit 1);
  # info_run_gpu=checked: this launch.sh refuses a RUN whose leading words set or clear a GPU variable (an older api=3 one lacks the line)
  [ "$1" = print ] || { VERDICT=refused; [ -z "$ch" ] || echo "$ch" >&2
    if [ "$h" != "$EXPECT" ]; then echo "ERROR: the resolved submission differs from the approved plan (bound_hash $h, --rs-expect $EXPECT) — nothing launched; plan it again" >&2
    else echo "ERROR: the resolved submission differs from the approved plan: its $W_N warning(s) are not the approved card's (warnings_id) — nothing launched; plan it again" >&2; fi
    exit 6; }
  VERDICT=planned; exit 0; }
rs_path() { local RS_USER=${USER:-$(id -un)}; printf %s "$1" | sed -e "s|\\\${HOME}|$HOME|g" -e "s|\\\$HOME|$HOME|g" -e "s|\\\${USER}|$RS_USER|g" -e "s|\\\$USER|$RS_USER|g"; }   # = env.sh's _rs_path
rs_envcheck() {   # D10, plan mode: the env gate's preconditions, READ-ONLY and resolved as env.sh does (profile T_* win; the
  local root v   # conf's ENV_KIND / <TAG>_VENV_DIR / <TAG>_ENV_NAME): exit 1 when the launch's gate would refuse; creates nothing
  [ "$EHM" = 0 ] || { echo "ERROR: ENV_HOOK '${EH%:missing}' not found under $PROJ — env.sh would refuse it at the launch; nothing planned" >&2; exit 1; }
  case "$EK" in
    uv) root=$(rs_path "${T_ENV_ROOT:-}"); [ -n "$root" ] || root=$PROJ
        if [ -n "$EV" ]; then v=$(rs_path "$EV"); elif [ "$root" = "$PROJ" ]; then v=$PROJ/.venv${T_SUFFIX:-}; else v=$root/envs/$(basename "$PROJ")${T_SUFFIX:-}; fi
        [ -x "$v/bin/python" ] || { echo "ERROR: uv venv missing: no $v/bin/python — the launch's env gate would refuse it (run: TARGET=$TN bash ~/.agents/run-skills/bin/run-bootstrap); nothing planned" >&2; exit 1; } ;;
    conda) [ -n "$EN" ] && [ -n "${T_CONDA_INIT:-}" ] && BASH_ENV= "$BASH" --noprofile --norc -c 'eval "$1" && command -v conda && conda activate "$2" \
             && [ "${CONDA_DEFAULT_ENV:-}" = "$2" ]' rs-conda "$(rs_path "$T_CONDA_INIT")" "$EN" </dev/null >/dev/null 2>&1 \
             || { echo "ERROR: conda env '$EN' does not activate here (T_CONDA_INIT, then conda activate, in a throwaway shell) — the launch's env gate would refuse it; nothing planned" >&2; exit 1; } ;;
    none) ;;
    *) echo "ERROR: invalid ENV_KIND='$EK' (uv|conda|none) — env.sh would refuse it at the launch; nothing planned" >&2; exit 1 ;;
  esac; }
if [ "$PLAN" = 1 ] || [ -n "$EXPECT" ]; then
  BASH_ENV= PROJ="$PROJ" TARGET="$TN" "$BASH" --noprofile --norc -c 'unset ENV_KIND ENV_NAME ENV_HOOK VENV_DIR UV_SYNC_ARGS "$3" "$4"
    . "$1" >&2 && . "$2" >&2 || exit 1
    unset -f printf builtin; unalias -a
    builtin printf "%s\0%s\0%s\0%s\0%s\0" "${ENV_KIND:-uv}" "${!3:-${ENV_NAME:-}}" "${ENV_HOOK:-}" "${!4:-${VENV_DIR:-}}" "${UV_SYNC_ARGS:-}"' rs-conf \
    "$SELF/profile.sh" "$PROJ/.ws.conf" "${TAG}_ENV_NAME" "${TAG}_VENV_DIR" </dev/null > "$A/env.kv" \
    && { IFS= read -r -d '' EK && IFS= read -r -d '' EN && IFS= read -r -d '' EH && IFS= read -r -d '' EV && IFS= read -r -d '' EU; } < "$A/env.kv" \
    || die2 "sourcing $PROJ/.ws.conf (after profile.sh) failed — fix it (values with spaces must be double-quoted)"
  rm -f "$A/env.kv"; EHM=0
  if [ -n "$EH" ]; then if [ -f "$PROJ/$EH" ]; then EH="$EH:$(rs_sha < "$PROJ/$EH")"; else EH="$EH:missing"; EHM=1; fi; fi
  rs_warn; [ -n "$RS_WARN" ] || RS_WARN=$(printf '' | rs_sha)   # none given: the approved card showed no warning
  [ -z "$EXPECT" ] || rs_plan check
fi

# ---- launch: env gate in a subshell (the conf/hook cannot touch this shell), then setsid the wrapper ----------------
if [ "$PLAN" = 1 ]; then   # a plan stops here, after the env gate's read-only check (env.sh itself mkdirs: it runs at the launch)
  stage plan; rs_envcheck; echo "[$TN] plan: GPU(s) [$DEV] -> $PROJ/$LOG (nothing is started; the env gate was checked read-only and runs at the launch)"
  echo "          RUN: $RUN_CMD"; rs_plan print; fi
stage launch; echo "[$TN] launching on GPU(s) [$DEV] -> $PROJ/$LOG"
echo "          RUN: $RUN_CMD"
# the wrapper's text is a literal written with printf — never a heredoc (bash <= 5.0 writes those to $TMPDIR: on a full
# one the launch failed); no single quote inside it
RW='# the run wrapper: session + group leader, pid in <log>.pid; starts the payload only once the gate says go
_rw_run=$1; exec >>"$_rw_log" 2>&1 </dev/null || exit 1
_rw_c=""; _rw_term=0
_rw_on_term() { [ "$_rw_term" = 0 ] || return 0; _rw_term=1; [ -z "$_rw_c" ] || kill -TERM "$_rw_c" 2>/dev/null; }
trap _rw_on_term TERM INT
_rw_fin() { echo "[$(date)] EXIT rc=$1 term=$_rw_term pid=$$ attempt=$_rw_n$2"
  printf "rc=%s term=%s at=%s\n" "$1" "$_rw_term" "$(date +%s)" > "$_rw_log.rc.tmp" && mv -f "$_rw_log.rc.tmp" "$_rw_log.rc"; exit "$1"; }
printf "%s\n" "$$" > "$_rw_log.pid.tmp" && mv -f "$_rw_log.pid.tmp" "$_rw_log.pid" || exit 1
_rw_i=0
until _rw_g=$(readlink "$_rw_a/gate" 2>/dev/null); do
  _rw_i=$((_rw_i + 1))
  [ "$_rw_i" -le $((_rw_wait * 10)) ] || { ln -s abort "$_rw_a/gate" 2>/dev/null; _rw_g=$(readlink "$_rw_a/gate"); break; }
  sleep 0.1
done
[ "$_rw_g" != go ] || [ "$_rw_term" != 0 ] || [ ! -f "$_rw_a/vars" ] || . "$_rw_a/vars" 2>/dev/null   # the plain conf/hook variables RUN names
rm -f "$_rw_a/vars"   # read (or never to be): no value of the conf or the hook stays on disk
[ "$_rw_g" = go ] || _rw_fin 125 " (not started: the launch was never confirmed)"
[ "$_rw_term" = 0 ] || _rw_fin 143 " (TERM before the run started)"
echo "[$(date)] target=$_rw_t job=$$ restart=0 attempt=$_rw_n gpus=$_rw_dev"
_rw_go() {   # the payload, started as `env <RUN>`: here with RUN expanded once (by the eval below), so "$@" = exactly the words env
  # gets — refused (rc 2, nothing started) when they set or clear a GPU variable: the GPUs are picked by launch.sh, never RUN
  _rw_y=$(rs_gpuenv "$@") || { echo "[$(date)] ERROR: RUN $_rw_y — not started (the GPUs are picked by launch.sh: -d / -n)" >> "$_rw_log"; exit 2; }
  exec nohup ${_rw_nice:+nice -n "$_rw_nice"} env "$@"; }
eval "_rw_go $_rw_run" &
_rw_c=$!; [ "$_rw_term" = 0 ] || kill -TERM "$_rw_c" 2>/dev/null
while :; do   # >128 = the status of the payload OR a trap interrupting wait: while it exists, wait again
  wait "$_rw_c"; _rw_rc=$?; [ "$_rw_rc" -gt 128 ] || break
  kill -0 "$_rw_c" 2>/dev/null || { wait "$_rw_c" 2>/dev/null; _rw_rc=$?; break; }
done
_rw_fin "$_rw_rc" ""'
{ printf '_rw_a=%q _rw_log=%q _rw_nice=%q _rw_t=%q _rw_n=%q _rw_dev=%q _rw_wait=120\n' "$A" "$PROJ/$LOG" "$NICE" "$TN" "$NONCE" "$DEV"
  declare -f rs_gpuenv && printf '%s\n' "$RW"; } > "$A/run" || { echo "ERROR: cannot write $A/run" >&2; exit 1; }
(
  exec 3>&- 4>&- 9>&-; trap - TERM INT   # nothing below (env.sh, a hook's helper, the run) holds the ssh channel or the lock
  # env.sh sources the conf and the hook into THIS shell: from here on only _rl_ copies are read (a conf may set LOG=, A=, …)
  _rl_a=$A _rl_log=$PROJ/$LOG _rl_dev=$DEV _rl_n=$NONCE _rl_t=$TN _rl_proj=$PROJ _rl_cmd=$RUN_CMD _rl_bash=$BASH _rl_p="" _rl_v="" _rl_f=""
  _rl_env=$SELF/env.sh _rl_w=" $(printf %s "$RUN_CMD" | tr -c '[:alnum:]_' ' ') "   # RUN's words: the names it can expand
  unset RUN_ENV_READY HPC_ENV_READY WS_ENV_READY CONDA_DEFAULT_ENV   # the sentinel shape: judge THIS env.sh run
  for _rl_k in ENV_KIND ENV_NAME ENV_HOOK VENV_DIR WANDB_MODE; do unset "$_rl_k" "${TAG}_$_rl_k"; done   # the conf alone sets them
  _rl_e=" $(compgen -e 2>/dev/null | tr '\n' ' ') "   # launch.sh's own unexported globals (NAME TAG LOG A DEV …) leave: a conf/hook value
  for _rl_v in $(compgen -v 2>/dev/null); do   # of one of those names is then new below, and reaches RUN as in a login shell
    case "$_rl_v" in _*|BASH*|FUNCNAME|PIPESTATUS|COMP_*|OLDPWD) continue ;; esac
    case "$_l0$_rl_e" in *" $_rl_v "*) ;; *) unset "$_rl_v" 2>/dev/null || : ;; esac
  done
  compgen -v > "$_rl_a/vars.before" 2>/dev/null || : > "$_rl_a/vars.before"
  set +u; . "$_rl_env"; set -u
  [ "${RUN_ENV_READY:-}" = "$_rl_proj" ] || { echo "ERROR: containment env not loaded (RUN_ENV_READY unset)" >&2; exit 1; }
  case "${ENV_KIND:-uv}" in
    conda) [ "${CONDA_DEFAULT_ENV:-}" = "${ENV_NAME:-}" ] \
             || { echo "ERROR: conda env '${ENV_NAME:-}' not active (got '${CONDA_DEFAULT_ENV:-none}')" >&2; exit 1; } ;;
    none) ;;   # no managed env: the payload brings its own runtime (containment env vars still apply)
    *) _rl_p=$(command -v python || true); [ -n "$_rl_p" ] && [ "$_rl_p" -ef "${RS_VENV:-/nonexistent}/bin/python" ] \
         || { echo "ERROR: uv venv not active (python=${_rl_p:-none}, want ${RS_VENV:-?}/bin/python; run: TARGET=$_rl_t bash ~/.agents/run-skills/bin/run-bootstrap)" >&2; exit 1; } ;;
  esac
  ( set -C; : > "$_rl_log" ) 2>/dev/null || { echo "ERROR: $_rl_log appeared meanwhile — retry" >&2; exit 2; }
  export CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES="$_rl_dev" PYTHONUNBUFFERED=1   # no RS_ATTEMPT: env.sh drops it outside Slurm
  # the new plain (unexported) variables that RUN names: its expansion sees them as in a login shell. After the exports
  # above (a plain CUDA_VISIBLE_DEVICES in the conf/hook is exported now: the harness's wins). Mode 600, and the wrapper
  # deletes the file once read: an unexported token from a hook or .wandb_env never stays on disk.
  if [ -s "$_rl_a/vars.before" ] && ( umask 077 && : > "$_rl_a/vars" ); then
    for _rl_v in $(compgen -v | grep -vxF -f "$_rl_a/vars.before"); do
      case "$_rl_v" in _*|BASH*|FUNCNAME|PIPESTATUS|COMP_*) continue ;; esac
      case "$_rl_w" in *" $_rl_v "*) ;; *) continue ;; esac
      _rl_f=$(declare -p "$_rl_v" 2>/dev/null) || continue; _rl_k=${_rl_f#declare -}
      case "${_rl_k%% *}" in *x*) ;; *) printf '%s\n' "$_rl_f" >> "$_rl_a/vars" ;; esac
    done
  fi
  rm -f "$_rl_a/vars.before"
  : > "$_rl_a/env.ok"
  _rl_f=$_rl_a/run; [ "$PWD" != "$_rl_proj" ] || _rl_f=.rs/attempts/$_rl_n/run   # short in `ps`; the run keeps env.sh's cwd
  exec setsid "$_rl_bash" "$_rl_f" "$_rl_cmd" </dev/null >/dev/null 2>&1
) &
SUB=$!; subrc=""; i=0
while [ ! -f "$LOG.pid" ]; do   # env.sh takes as long as it takes; once it is through, the pid file has 30 s
  if [ -z "$subrc" ] && ! kill -0 "$SUB" 2>/dev/null; then
    wait "$SUB"; subrc=$?
    [ -f "$LOG.pid" ] || [ "$subrc" = 0 ] || { [ "$subrc" = 2 ] || VERDICT=failed; exit "$subrc"; }   # gate refused: the messages are above
  fi
  if [ -f "$A/env.ok" ]; then i=$((i + 1)); [ "$i" -le 300 ] || { echo "ERROR: the run recorded no pid within 30 s — not started (the gate is closed)" >&2; exit 1; }; fi
  sleep 0.1
done
PID=$(head -n 1 "$LOG.pid" | tr -d ' \t\r'); case "$PID" in ''|*[!0-9]*) echo "ERROR: unreadable $LOG.pid" >&2; exit 1 ;; esac
cur=$(pstat "$PID") || { echo "ERROR: the run's wrapper (pid $PID) vanished before its receipt — not started" >&2; exit 1; }
{ printf 'pid=%s\npgid=%s\nstart=%s\nboot_id=%s\ngpus=%s\nlog=%s\nname=%s\nnonce=%s\nat=%s\n' \
    "$PID" "${cur#* }" "${cur%% *}" "$BOOT" "$UUIDS" "$LOG" "$NAME" "$NONCE" "$(date +%s)"
  printf 'gpu_ids=%s\ntarget=%s\nhost=%s\n' "$DEV" "$TN" "$(uname -n)"; } > "$A/receipt.tmp" && mv -f "$A/receipt.tmp" "$A/receipt" \
  || { echo "ERROR: cannot write the receipt — not started (the gate is closed)" >&2; exit 1; }
ln -s go "$A/gate" 2>/dev/null || { echo "ERROR: the run gave up waiting for its confirmation — not started" >&2; exit 1; }
stage done
echo "[$TN] started PID $PID on GPU(s) $DEV ; log $PROJ/$LOG ; pid file $PROJ/$LOG.pid"
exit 0
