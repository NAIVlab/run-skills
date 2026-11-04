#!/usr/bin/env bash
# run-skills remote/submit.sh — generic Slurm submit. Runs ON the login node from <REMOTE_DIR>/.<target>/ (deployed
# by run-sync next to profile.sh, policy.sh, job.sbatch). Partition limits and gates come from the target's policy.sh
# (t_partition / t_policy, contract in targets/_template-slurm/policy.sh); this file names no cluster.
#   submit.sh [--rs-attempt NONCE] [--rs-mode plan] [--rs-expect HASH] [--rs-chain] [-p partition] [-g ngpu] [-G gputype]
#             [-t time] [-m mem] [-c cpus] [-n name] [-y] [--same-name-ok] [--<policy-flag>] -- <cmd...>
# Defaults from ../.hpc.conf: <TAG>_KEY beats KEY (DEFAULT_GPUS/CPUS/MEM/TIME ACCOUNT SBATCH_EXTRA JOB_NAME); CLI beats both.
# -y queues past an availability/occupancy warning. Exit 1 = warning, 2 = usage/data error, 3 = policy refusal,
# 6 = a job of this name from this project is still live, or not the --rs-expect plan; 75 = NONCE already claimed; sbatch's own rc.
# Attempt journal: <PROJ>/.rs/attempts/<NONCE>/ (mkdir = the claim; NONCE generated without --rs-attempt) gets out, err,
# stage, result, the submit-time snapshots (conf, hook, profile.sh, env.sh) and, once the job exists, its receipt —
# all written BEFORE anything reaches the caller (the EXIT trap replays out/err), so a dead ssh loses nothing.
# Protocol api=3 (../API): --rs-mode plan runs every check (-y gates count as acknowledged: WARNING, go on), prints ONE
# `@@plan v1` … `@@end` block (the bound fields + bound_hash) and stops before the snapshots and sbatch; --rs-expect HASH
# submits only if that hash is still the one rs_bound gives (else the block + ERROR, exit 6); --rs-chain = a singleton segment.
set -euo pipefail
unset RS_ATTEMPT RS_CONF_FILE RS_RUN RS_ACKS     # a submit from inside a job (--export=ALL) never inherits its attempt
trap '' HUP                                      # a session that hangs up (ssh -t) cannot stop it between decide and record
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$SELF/.." && pwd)"
NONCE=""; _ra=0; _dd=0; _av=(); PLAN=0; EXPECT=""; CHAIN=0   # pre-scan, before --: each value a SEPARATE word (an old
while [ "$#" -gt 0 ]; do                                      # parser exits 2 on the bare word: unknown arg, nothing submitted)
  case "$_dd:$1" in
    0:--rs-attempt) [ "$_ra" = 0 ] && [ "$#" -ge 2 ] || { echo "ERROR: --rs-attempt takes one NONCE, once" >&2; exit 2; }
                    NONCE=$2; _ra=1; shift 2; continue ;;
    0:--rs-mode) [ "$PLAN" = 0 ] && [ "$#" -ge 2 ] && [ "$2" = plan ] || { echo "ERROR: --rs-mode takes one value, plan, once" >&2; exit 2; }
                 PLAN=1; shift 2; continue ;;
    0:--rs-expect) [ -z "$EXPECT" ] && [ "$#" -ge 2 ] && [ "${#2}" = 64 ] && [ -n "${2##*[!0123456789abcdef]*}" ] \
                     || { echo "ERROR: --rs-expect takes one bound_hash (64 lowercase hex), once" >&2; exit 2; }
                   EXPECT=$2; shift 2; continue ;;
    0:--rs-chain) CHAIN=1; shift; continue ;;
    0:--rs-*) echo "ERROR: '$1' is not a flag of this submit.sh (api=3: --rs-attempt NONCE, --rs-mode plan, --rs-expect HASH, --rs-chain; values as separate words)" >&2; exit 2 ;;
    0:--) _dd=1 ;;
  esac; _av+=("$1"); shift
done
set -- ${_av[@]+"${_av[@]}"}
AN=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789   # spelled out: [A-Z] ranges follow the locale
if [ "$_ra" = 1 ]; then case "$NONCE" in [$AN]*) ;; *) NONCE=/ ;; esac   # never '.', '..' or a leading '-' (an old parser's flag)
  case "$NONCE" in *[!$AN._-]*) echo "ERROR: --rs-attempt NONCE must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}" >&2; exit 2 ;; esac
  [ "${#NONCE}" -le 64 ] || { echo "ERROR: --rs-attempt NONCE is longer than 64 characters" >&2; exit 2; }; fi
mkdir -p "$PROJ/.rs/attempts" 2>/dev/null || { echo "ERROR: cannot create $PROJ/.rs/attempts (the attempt journal) — nothing submitted" >&2; exit 2; }
for _try in 1 2 3 4 5; do   # mkdir (never -p) of the leaf is the atomic claim
  [ "$_ra" = 1 ] || NONCE="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  A="$PROJ/.rs/attempts/$NONCE"; mkdir "$A" 2>/dev/null && break
  [ -e "$A" ] || { echo "ERROR: cannot create $A — nothing submitted" >&2; exit 2; }
  [ "$_ra" = 0 ] || { echo "ERROR: attempt $NONCE is already claimed ($A) — nothing done" >&2; exit 75; }; A=""
done
[ -n "$A" ] || { echo "ERROR: no free attempt name under $PROJ/.rs/attempts — nothing submitted" >&2; exit 75; }
{ exec 3>&1; } 2>/dev/null || exec 3>/dev/null; exec 4>&2 || exec 4>/dev/null   # the caller's channels (closed: /dev/null)
exec >>"$A/out" 2>>"$A/err" </dev/null
rs_stage() { printf '%s\n' "$1" > "$A/stage.tmp" && mv -f "$A/stage.tmp" "$A/stage"; }
rs_finish() {   # EXIT trap: the result (from what the submit left in $A), then the replay; the exit status is unchanged
  local rc=$? v st; set +e; st=$(cat "$A/stage" 2>/dev/null)
  if [ -f "$A/receipt" ]; then v=submitted
  elif [ "$st:$rc" = plan:0 ]; then v=planned
  elif [ "$st" = sbatch ]; then v=unknown   # sbatch ran and may have made the job: refused only on its explicit rejection
    [ "$rc" = 0 ] || ! grep -qE 'Invalid partition|Invalid qos|Invalid account|Requested node configuration is not available|QOSMax|AssocMax|violates accounting/QOS policy|Batch job submission failed: Invalid' "$A/sbatch.err" 2>/dev/null || v=refused
  else case "$rc" in 1|2|3|6) v=refused ;; *) v=failed ;; esac; fi
  printf 'stage=%s rc=%s verdict=%s at=%s\n' "$st" "$rc" "$v" "$(date +%s)" > "$A/result.tmp" && mv -f "$A/result.tmp" "$A/result"
  trap '' PIPE; cat "$A/out" >&3 2>/dev/null; cat "$A/err" >&4 2>/dev/null; exit "$rc"
}
trap rs_finish EXIT; rs_stage pre-policy; echo "attempt: .rs/attempts/$NONCE"
# The submit runs in a SUBSHELL (to the end of the file): what policy code does in there (an EXIT trap, `exit N`, `exec 3<f
# … exec 3<&-`) ends with it, never reaching this shell's trap or the caller's fds (closed in there); its status is ours.
( exec 3>&- 4>&-; RECEIPT=0; . "$SELF/profile.sh"
[ -f "$SELF/policy.sh" ] && . "$SELF/policy.sh"
[ -f "$SELF/policy.local.sh" ] && . "$SELF/policy.local.sh"
CLUSTER="${T_NAME:?$SELF/profile.sh lacks T_NAME — deploy with run-sync}"
[ -z "${T_REF:-}" ] || echo "reference: $T_REF — re-read it (not a summary) before acting on any warning or refusal below"
TAG=$(printf %s "$CLUSTER" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]')
# trust only .hpc.conf for conf-owned keys — never stale login-shell exports (which --export=ALL would also forward)
_keys=""; for _k in DEFAULT_PARTITION DEFAULT_GPU_TYPE DEFAULT_GPUS DEFAULT_CPUS DEFAULT_MEM DEFAULT_TIME ACCOUNT SBATCH_EXTRA \
          JOB_NAME VENV_DIR ENV_KIND ENV_NAME ENV_HOOK WANDB_MODE ${T_CONF_KEYS:-}; do unset "$_k" "${TAG}_$_k"; _keys="$_keys $_k ${TAG}_$_k"; done
[ -f "$PROJ/.hpc.conf" ] || { echo "ERROR: MISSING $PROJ/.hpc.conf (partial sync?) — run run-sync first." >&2; exit 2; }
# snapshot the conf (the job's env.sh reads this copy), source it after profile.sh (PROJ CLUSTER TARGET TAG set, as env.sh) in a CHILD
# bash (no rc files/BASH_ENV/stdin, its stdout to stderr) that hands back those keys as NUL-separated pairs, read as data, never eval'd
cp "$PROJ/.hpc.conf" "$A/conf" || { echo "ERROR: cannot snapshot .hpc.conf into $A" >&2; exit 2; }
BASH_ENV= PROJ="$PROJ" CLUSTER="$CLUSTER" TARGET="$CLUSTER" TAG="$TAG" "${BASH:-bash}" --noprofile --norc -c 'set -euo pipefail
  . "$1" >&2; . "$2" >&2; shift 2; unset -f printf builtin; unalias -a
  for k in "$@"; do [ -z "${!k+x}" ] || builtin printf "%s\0%s\0" "$k" "${!k}"; done' rs-conf "$SELF/profile.sh" "$A/conf" $_keys </dev/null > "$A/conf.kv" \
  || { echo "ERROR: sourcing $PROJ/.hpc.conf failed (exit $?) — fix it (values with spaces must be double-quoted)" >&2; exit 2; }
while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do for _x in $_keys; do [ "$_x" != "$_k" ] || printf -v "$_k" %s "$_v"; done; done < "$A/conf.kv"; rm -f "$A/conf.kv"
ovr() { local _k="${TAG}_$1" _v; _v="${!_k:-}"; [ -n "$_v" ] || _v="${!1:-}"; printf %s "${_v:-${2:-}}"; }
_k="${TAG}_DEFAULT_PARTITION"; PART="${!_k:-${T_DEFAULT_PARTITION:-}}"     # generic DEFAULT_PARTITION is ignored
_k="${TAG}_DEFAULT_GPU_TYPE";  GTYPE="${!_k:-${T_DEFAULT_GPU_TYPE:-any}}"  # (a partition is a per-target choice)
NGPU=$(ovr DEFAULT_GPUS 1); DEF_CPUS=$(ovr DEFAULT_CPUS); DEF_MEM=$(ovr DEFAULT_MEM)
TIME=$(ovr DEFAULT_TIME 1-00:00:00); ACCOUNT=$(ovr ACCOUNT); SB_EXTRA=$(ovr SBATCH_EXTRA)
NAME=$(ovr JOB_NAME "$(basename "$PROJ")")
MEM=""; NCPU=""; FORCE=0; ACK=0; SAME_OK=0; PART_FROM_CLI=""; GTYPE_FROM_CLI=""; T_FLAGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) PART="$2"; PART_FROM_CLI=1; shift 2 ;; -g) NGPU="$2"; shift 2 ;; -G) GTYPE="$2"; GTYPE_FROM_CLI=1; shift 2 ;;
    -t) TIME="$2"; shift 2 ;; -m) MEM="$2"; shift 2 ;; -c) NCPU="$2"; shift 2 ;;
    -n) NAME="$2"; shift 2 ;; -y|--force) FORCE=1; shift ;; --same-name-ok) SAME_OK=1; shift ;;
    --) shift; break ;;
    --partition*|--gres*|--time*|--mem*|--cpus*|--job-name*|--account*|--qos*|--nodelist*|--exclude*)   # sbatch spellings
      echo "ERROR: '$1' is an sbatch flag — use -p/-g/-t/-m/-c/-n, or SBATCH_EXTRA in .hpc.conf" >&2; exit 2 ;;
    --?*) echo "NOTE: passing '$1' through to policy.sh (not an sbatch flag)" >&2      # policy-owned flags
          T_FLAGS+=("$1"); case "$1" in *-user-asked) ACK=1 ;; esac; shift ;;
    *) echo "ERROR: unknown arg '$1' (flags: -p -g -G -t -m -c -n -y [--<policy-flag>], then -- <cmd>)" >&2; exit 2 ;;
  esac
done
[ "$#" -ge 1 ] || { echo "ERROR: no run command after --" >&2; exit 2; }
case "$NGPU" in ''|*[!0-9]*) echo "ERROR: -g '$NGPU' must be a positive integer" >&2; exit 2 ;; esac
[ "$PLAN" = 0 ] || FORCE=1   # plan mode: every -y gate (the policy's too: PLAN=1 is visible) prints its WARNING and goes on
# --requeue FIRST so SBATCH_EXTRA may override it with --no-requeue (sbatch: the last of the pair wins)
SB_ARGS=(--job-name="$NAME" --chdir="$PROJ" --time="$TIME" --requeue --export=ALL,PROJ="$PROJ",CLUSTER="$CLUSTER",TARGET="$CLUSTER")
[ -z "$ACCOUNT" ] || SB_ARGS+=(--account="$ACCOUNT")
SB_H=("${SB_ARGS[@]}")   # the harness's own words: bound as fields (name time account), so `extra` = what follows them

# policy gate first (its exit code is the verdict: 1 warning, 2 error, 3 refusal), then the partition's limits
rs_stage policy
if declare -f t_policy >/dev/null; then
  t_policy || { rc=$?; echo "ERROR: t_policy returned $rc (a policy that does not refuse must end with 'return 0')" >&2; exit "$rc"; }
fi
declare -f t_partition >/dev/null || { echo "ERROR: $SELF/policy.sh does not define t_partition" >&2; exit 2; }
P_GPUS=""; P_CPU_PER_GPU=""; P_MEM_PER_GPU=""; P_GTYPE=""; P_GTYPE_DEFAULT=""; P_PREEMPT=""; P_MAXTIME=""; P_CPU_ONLY=""; P_MEM_PER_CPU=""; P_NOTE=""
t_partition "$PART" || { echo "ERROR: unknown $CLUSTER partition '$PART' (${T_PARTITIONS:-})" >&2; exit 2; }
if [ "$P_CPU_ONLY" = 1 ]; then
  [ -n "$NCPU" ] || NCPU="${DEF_CPUS:-8}"; [ -n "$MEM" ] || MEM="${DEF_MEM:-$(( NCPU*${P_MEM_PER_CPU:-4} ))G}"
else
  : "${P_GPUS:?policy.sh: t_partition '$PART' must set P_GPUS=min-max}"
  _min="${P_GPUS%%-*}"; _max="${P_GPUS##*-}"
  { [ "$NGPU" -ge "$_min" ] && [ "$NGPU" -le "$_max" ]; } || { echo "ERROR: $PART -g must be $_min..$_max" >&2; exit 2; }
  [ -z "$P_GTYPE" ] || GTYPE="$P_GTYPE"
  if [ -n "$P_GTYPE_DEFAULT" ] && [ -z "$GTYPE_FROM_CLI" ] && [ "$GTYPE" = "${T_DEFAULT_GPU_TYPE:-}" ]; then GTYPE="$P_GTYPE_DEFAULT"; fi
  [ -n "$NCPU" ] || NCPU="${DEF_CPUS:-$(( NGPU*${P_CPU_PER_GPU:-8} ))}"
  [ -n "$MEM" ] || MEM="${DEF_MEM:-$(( NGPU*${P_MEM_PER_GPU:-40} ))G}"
fi

# slurm time spec -> minutes (D-HH[:MM[:SS]] | HH:MM:SS | MM[:SS] | MM); -1 if unparsable (skip check).
t_min() {
  printf '%s' "$1" | grep -Eq '^([0-9]+-)?[0-9]+(:[0-9]{1,2}){0,2}$' || { echo -1; return; }
  local d="" rest="$1" a b c
  case "$rest" in *-*) d="${rest%%-*}"; rest="${rest#*-}" ;; esac
  IFS=: read -r a b c <<< "$rest"
  if [ -n "$d" ]; then echo $(( 10#$d*1440 + 10#${a:-0}*60 + 10#${b:-0} + (10#${c:-0}>0 ? 1 : 0) ))
  elif [ -n "${c:-}" ]; then echo $(( 10#$a*60 + 10#$b + (10#$c>0 ? 1 : 0) ))
  elif [ -n "${b:-}" ]; then echo $(( 10#$a + (10#$b>0 ? 1 : 0) ))
  else echo $(( 10#$a )); fi
}
# reject -t beyond the partition's MaxTime NOW (sbatch accepts it and the job pends forever)
_cap="${P_MAXTIME:-${T_MAXTIME:-}}"
if [ -n "$_cap" ]; then
  _req=$(t_min "$TIME"); _max=$(t_min "$_cap")
  if [ "$_req" -gt 0 ] && [ "$_max" -gt 0 ] && [ "$_req" -gt "$_max" ]; then
    echo "ERROR: -t $TIME exceeds '$PART' MaxTime $_cap on $CLUSTER — the job would pend forever. Lower -t." >&2; exit 2
  fi
fi
# the run command must not be a Slurm submission itself: partition/QOS are this script's decision
case "$1" in sbatch|srun|salloc) echo "ERROR: run command must not itself call sbatch/srun/salloc ('$1')" >&2; exit 2 ;; esac
# SBATCH_EXTRA: space-separated sbatch flags (set -f keeps globs literal), ONE option per word: short flags are never
# bundled (`-vW` is refused; `-qNAME` / `-D/path` attached values are fine). Rejected in any getopt spelling (long-option
# prefixes included): the partition, the job name / output files, arrays, --wait, hetjob ':', a forbidden QOS
# (-q NAME, -qNAME, --qos=NAME, --qo=NAME) and a dangling value flag.
_bad() { echo "ERROR: SBATCH_EXTRA must not contain '$_w' — partition, name/output, arrays, --wait, ':' and bundled short flags are not accepted here. Fix .hpc.conf." >&2; exit 2; }
if [ -n "$SB_EXTRA" ]; then
  set -f; _prev=""
  for _w in $SB_EXTRA; do
    _q=""; case "$_prev" in -q|--qo|--qos) _q="$_w" ;; esac
    case "$_w" in
      --part*|--j*|--ou*|--er*|--ar*|--wai|--wait|:) _bad ;;
      --qo=*|--qos=*) _q="${_w#*=}" ;;
      -[pJoeaW]*|-[hHOQsvV]?*) _bad ;;          # a forbidden letter, or a no-arg flag with letters glued on (= a bundle)
      -q?*) _q="${_w#-q}" ;;                    # attached QOS value
    esac
    if [ -n "$_q" ]; then case " ${T_FORBIDDEN_QOS:-} " in
      *" $_q "*) echo "ERROR: SBATCH_EXTRA selects QOS '$_q', which is forbidden on $CLUSTER — fix .hpc.conf." >&2; exit 2 ;;
    esac; fi
    SB_ARGS+=("$_w"); _prev="$_w"
  done
  case "$_prev" in -q|--qo|--qos) echo "ERROR: SBATCH_EXTRA ends with a dangling '$_prev' (no value) — fix .hpc.conf." >&2; exit 2 ;; esac
  set +f
fi
if [ "$CHAIN" = 1 ]; then   # --rs-chain: one singleton chain segment; another dependency already set is a conflict, never merged
  _d=""; _prev=""; for _w in "${SB_ARGS[@]}"; do case "$_prev:$_w" in -d:*|--dependency:*|*:--dependency=*|*:-d?*) _d="$_d $_w" ;; esac; _prev=$_w; done
  case "$_d" in "") SB_ARGS+=(--dependency=singleton) ;; *singleton*) ;;
    *) echo "ERROR: --rs-chain sets --dependency=singleton, but SBATCH_EXTRA or the policy already sets a dependency ($_d ) — keep one" >&2; exit 2 ;; esac
fi

# free GPUs of type $2 (or any) in partition $1 -> stdout "FREE<TAB>MAXNODE"; per-node table to stderr.
gpu_avail() {
  sinfo -p "$1" -N -h -O "NodeHost:25,Gres:170,GresUsed:170,StateLong:15" \
   | awk -v T="$2" '
       function cnt(s,  re,a){re=(T=="any")?"gpu:([^:,(]*:)?[0-9]+":"gpu:" T ":[0-9]+"
                              if(match(s,re)){a=substr(s,RSTART,RLENGTH); sub(/.*:/,"",a); return a+0} return 0}
       {cfg=cnt($2); if(cfg==0) next; used=cnt($3); st=$4; free=cfg-used; if(free<0)free=0;
        printf "  %-12s %d/%d  [%s]\n",$1,free,cfg,st > "/dev/stderr";
        if(st ~ /^(idle|mix)/ && st !~ /(drain|down|drng|maint|resv|boot|fail|comp|inval|noresp|plnd|unk)/){tot+=free; if(free>maxn)maxn=free}}
       END{printf "%d\t%d\n",tot+0,maxn+0}'
}
# warn + (unless -y) exit 1 if fewer than NGPU of $2 are free on one node of partition $1.
check_gpu_avail() {
  local out free maxn
  echo "$1 nodes carrying '$2' (free/cfg, state):"
  out=$(gpu_avail "$1" "$2") || true
  free=$(printf '%s' "$out" | cut -f1); maxn=$(printf '%s' "$out" | cut -f2)
  free=${free:-0}; maxn=${maxn:-0}
  echo "  -> $free free now; up to $maxn on one node (a 1-node job needs $NGPU on ONE node)."; AVAIL="free:$free/max_node:$maxn/gpu_type:$2"
  if { [ "$free" -lt "$NGPU" ] || [ "$maxn" -lt "$NGPU" ]; }; then
    [ "$FORCE" = 1 ] || { echo "WARNING: only $free free of '$2' ($maxn on one node). Re-run -y to queue, pick another -G, or lower -g." >&2; exit 1; }
    [ "$PLAN" = 0 ] || echo "WARNING: only $free free of '$2' ($maxn on one node) — the submit needs -y to queue anyway." >&2
  fi
}
GRES=(); AVAIL=cpu-only
rs_stage avail
if [ "$P_CPU_ONLY" = 1 ]; then echo "CPU partition '$PART' (no GPU)."
else
  check_gpu_avail "$PART" "$GTYPE"
  if [ "$GTYPE" = any ]; then GRES=(--gres="gpu:$NGPU"); else GRES=(--gres="gpu:$GTYPE:$NGPU"); fi
fi
# a second live copy of this name from this project would race the first on its logs/ckpts: refuse (exit 6) unless the
# caller says so or SBATCH_EXTRA/policy chains it (--dependency=singleton waits for the first). Same squeue view as run-watch.
_chain=0; _prev=""; for _w in "${SB_ARGS[@]}"; do
  case "$_prev:$_w" in -d:*singleton*|--dependency:*singleton*|*:--dependency=*singleton*|*:-d*singleton*) _chain=1 ;; esac; _prev=$_w; done
if [ "$SAME_OK" = 0 ] && [ "$_chain" = 0 ]; then
  _p2=$(cd "$PROJ" && pwd -P)
  if _q=$(squeue -h -u "${USER:-$(id -un)}" --states=all -O "JobID:0|,Name:0|,State:0|,Reason:0|,RestartCnt:0|,StartTime:0|,WorkDir:0|" 2>"$A/squeue.err"); then
    _live=""   # same name, not finished, WorkDir = this project: either of our paths, or one that resolves to it (a symlink)
    while IFS='|' read -r _j _n _s _x _x _x _w _x; do
      [ "$_n" = "$NAME" ] && [ -n "$_w" ] || continue
      case "$_s" in COMPLETED|CANCELLED|FAILED|TIMEOUT|PREEMPTED|NODE_FAIL|BOOT_FAIL|DEADLINE|OUT_OF_MEMORY|REVOKED) continue ;; esac
      [ "$_w" = "$PROJ" ] || [ "$_w" = "$_p2" ] || [ "$(CDPATH='' cd -- "$_w" 2>/dev/null && pwd -P)" = "$_p2" ] || continue
      _live="$_live$_j $_s"$'\n'
    done <<< "$_q"
    if [ -n "$_live" ]; then _j=$(printf %s "$_live" | head -n 1)
      echo "ERROR: '$NAME' is already ${_j#* } from this project (job ${_j%% *}; live: $(printf %s "$_live" | cut -d' ' -f1 | paste -sd, -)) —" \
        "a second copy would share its logs/ckpts. Follow that job, pick another -n, or pass --same-name-ok if both are wanted." >&2; exit 6
    fi
  elif [ "$FORCE" = 1 ]; then echo "WARNING: squeue failed — no check for a live '$NAME' from this project; -y: submitting anyway" >&2
  else echo "WARNING: squeue failed ($(head -n 1 "$A/squeue.err")) — cannot check for a live '$NAME' from this project. Re-run -y to submit anyway." >&2; exit 1; fi
fi
[ -z "$P_NOTE" ] || echo "NOTE: $P_NOTE"
[ "$P_PREEMPT" != 1 ] || echo "NOTE: $PART is preemptible (the job is requeued — killed, under --no-requeue — possibly abruptly). Ensure checkpoint+resume."
lint_extra() {   # SBATCH_EXTRA lint, WARNINGs only (run after every refusal, so a refusal's first line is always its own)
  local allow=" --qos -q --account -A --exclude -x --dependency -d --requeue --no-requeue --signal --mail-type --mail-user --constraint -C --nice --reservation --comment ${T_SBATCH_EXTRA_ALLOW:-} "
  local w o sp win off last=""; set -f; set -- $SB_EXTRA; set +f
  while [ "$#" -gt 0 ]; do
    w=$1; shift; case "$w" in -?*) last=$w ;; *) last=""; continue ;; esac
    case "$w" in --*) o=${w%%=*} ;; *) o=${w:0:2} ;; esac
    sp=$w; case "$w" in --*=*|-[!-]?*) ;; *) if [ "$#" -gt 0 ]; then case "$1" in -*) ;; *) sp="$w $1" ;; esac; fi ;; esac
    case "$allow" in *" $o "*) off="" ;; *) off=1 ;; esac; win=""
    case "$o" in   # harness-set options: SB_ARGS puts --time/--chdir/--export/--account before SBATCH_EXTRA, cpus/mem/gres after
      --time|-t) win="SBATCH_EXTRA's '$sp' (the harness's --time=$TIME comes earlier)" ;; --chdir|-D) win="SBATCH_EXTRA's '$sp' (the harness's --chdir comes earlier)" ;;
      --export) win="SBATCH_EXTRA's '$sp' (the harness's --export=ALL,PROJ,CLUSTER,TARGET comes earlier; the job needs them)" ;;
      --account|-A) [ -z "$ACCOUNT" ] || win="SBATCH_EXTRA's '$sp' (ACCOUNT's --account=$ACCOUNT comes earlier)" ;;
      --cpus-per-task|-c) win="the harness's --cpus-per-task=$NCPU (it comes later)" ;; --mem) win="the harness's --mem=$MEM (it comes later)" ;;
      --gres) [ "${#GRES[@]}" = 0 ] || win="the harness's ${GRES[0]} (it comes later)" ;;
    esac
    if [ -n "$win" ]; then echo "WARNING (lint): SBATCH_EXTRA repeats $o, which the harness sets too; sbatch takes the last one: $win wins${off:+; it will be refused in a later version (use the submit.sh flag or conf key)}." >&2
    elif [ -n "$off" ]; then echo "WARNING (lint): SBATCH_EXTRA option '$o' is outside the allowed set ($(echo $allow)) — it will be refused in a later version; a target may allow more (T_SBATCH_EXTRA_ALLOW)." >&2; fi
  done
  case "$last" in --qos|-q|--account|-A|--exclude|-x|--dependency|-d|--signal|--mail-type|--mail-user|--constraint|-C|--reservation|--comment)
    echo "WARNING (lint): SBATCH_EXTRA ends with '$last' and no value: sbatch would take the next argument as its value." >&2 ;; esac
}
lint_extra
_c=""; _prev=""; for _w in "${SB_ARGS[@]}"; do   # the job's comment = the last one given (policy or SBATCH_EXTRA) + rs=<NONCE>
  [ "$_prev" != --comment ] || _c=$_w; case "$_w" in --comment=*) _c=${_w#--comment=} ;; esac; _prev=$_w; done
rs_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }   # stdin -> hex
qw() { [ "$#" = 0 ] || { local s; s=$(printf ' %q' "$@"); printf %s "${s# }"; }; }   # words -> one line of %q words
rs_bound() {   # THE bound list (the plan block's lines kind= … chain=; bound_hash = sha256 of them): what an approval covers
  local g=${GRES[0]:-} x=("${SB_ARGS[@]}"); [ "${x[*]:0:${#SB_H[@]}}" != "${SB_H[*]}" ] || x=("${x[@]:${#SB_H[@]}}")
  printf 'kind=slurm\ntarget=%q\npartition=%q\ngres=%q\ncpus=%q\nmem=%q\ntime=%q\naccount=%q\nname=%q\nextra=%s\npayload=%s\nenv_kind=%q\nenv_name=%q\nwandb_mode=%q\nchain=%s\n' \
    "$CLUSTER" "$PART" "${g#--gres=}" "$NCPU" "$MEM" "$TIME" "$ACCOUNT" "$NAME" "$(qw ${x[@]+"${x[@]}"})" "$(qw "$@")" \
    "${ENV_KIND:-uv}" "$(ovr ENV_NAME)" "${WANDB_MODE:-online}" "$_chain"
}
rs_plan() {   # plan mode: the block, exit 0. --rs-expect: the SAME rs_bound hash; a mismatch prints the block + ERROR, exit 6
  local b h w f k v; b=$(rs_bound "$@") && h=$(printf '%s\n' "$b" | rs_sha) && [ "${#h}" = 64 ] \
    || { echo "ERROR: cannot hash the plan (no sha256sum or shasum here?) — nothing submitted" >&2; exit 2; }
  [ "$PLAN" = 1 ] || [ "$h" != "$EXPECT" ] || { echo "plan: bound_hash=$h = --rs-expect (the approved plan)"; return 0; }
  if [ -z "$EXPECT" ] || [ "$h" = "$EXPECT" ]; then rs_stage plan; else rs_stage expect; fi
  w=$(cat "$A/out" "$A/err" | grep -c '^WARNING: ' || true)   # `WARNING (lint):` lines are not counted
  printf '@@plan v1\napi=3\n%s\ninfo_avail=%q\n' "$b" "$AVAIL"
  for f in conf:"$A/conf" profile:"$SELF/profile.sh" policy:"$SELF/policy.sh" policy_local:"$SELF/policy.local.sh"; do
    v=none; [ ! -f "${f#*:}" ] || v=$(rs_sha < "${f#*:}"); printf 'info_%s_sha256=%s\n' "${f%%:*}" "$v"; done
  for k in commit dirty; do v=$(sed -n "s/^$k=//p" "$PROJ/.run-source" 2>/dev/null | head -n 1) || v=""; printf 'info_source_%s=%q\n' "$k" "${v:-none}"; done
  printf 'warnings=%s\nbound_hash=%s\n@@end\n' "${w:-0}" "$h"
  [ -z "$EXPECT" ] || [ "$h" = "$EXPECT" ] || { echo "ERROR: the resolved submission differs from the approved plan (bound_hash $h, --rs-expect $EXPECT) — nothing submitted; plan it again" >&2; exit 6; }
  exit 0
}
[ "$PLAN" = 0 ] && [ -z "$EXPECT" ] || rs_plan "$@"     # (exits unless an --rs-expect matched)
mkdir -p "$PROJ/logs"                                  # job.sbatch writes logs/%x_%j.out
# submit-time snapshots next to the conf: the job's env.sh (job.sbatch sources it), profile, ENV_HOOK — a re-sync or an
# upgrade between submit and a requeued restart cannot change what the job runs with
cp "$SELF/profile.sh" "$A/profile.sh" && cp "$SELF/env.sh" "$A/env.sh" || { echo "ERROR: cannot snapshot profile.sh / env.sh into $A" >&2; exit 2; }
if [ -n "${ENV_HOOK:-}" ] && [ -f "$PROJ/$ENV_HOOK" ]; then cp "$PROJ/$ENV_HOOK" "$A/hook" || { echo "ERROR: cannot snapshot ENV_HOOK into $A" >&2; exit 2; }; fi
# name, ABSOLUTE log paths and the comment go LAST: nothing earlier (SBATCH_EXTRA, SBATCH_* env, --chdir) can falsify them
unset SBATCH_ARRAY_INX SBATCH_WAIT                       # the two env switches no CLI arg can override
cmd=(sbatch "${SB_ARGS[@]}" --partition="$PART" ${GRES[@]+"${GRES[@]}"} --cpus-per-task="$NCPU" --mem="$MEM" --job-name="$NAME" \
     --output="$PROJ/logs/%x_%j.out" --error="$PROJ/logs/%x_%j.out" --comment="${_c:+$_c }rs=$NONCE" "$PROJ/.$CLUSTER/job.sbatch" "$@")
{ printf '+'; printf ' %q' "${cmd[@]}"; echo; } >&2      # the exact argv (what set -x used to show)
rs_stage sbatch                                         # RS_ATTEMPT reaches the job through --export=ALL (the environment)
out=$(RS_ATTEMPT="$NONCE" "${cmd[@]}" 2>"$A/sbatch.err") && rc=0 || rc=$?
cat "$A/sbatch.err" >&2
jid=$(printf %s "$out" | awk '/Submitted batch job/{print $4; exit} /^[0-9]+(;|$)/{sub(/;.*/, ""); print; exit}')
if [ "$rc" = 0 ] && [ -n "$jid" ]; then   # the job exists: its receipt is on disk before a single byte is printed about it
  _argv=$(printf ' %q' "${cmd[@]}")
  printf 'job=%s\nname=%s\npartition=%s\nproj=%s\nnonce=%s\nat=%s\nargv=%s\n' "$jid" "$NAME" "$PART" "$PROJ" "$NONCE" "$(date +%s)" "${_argv# }" > "$A/receipt.tmp" && mv -f "$A/receipt.tmp" "$A/receipt" && RECEIPT=1 \
    || echo "WARNING: job $jid was submitted but its receipt could not be written into $A" >&2
  [ "$RECEIPT" = 0 ] || rs_stage done
fi
[ -z "$out" ] || echo "$out"
[ "$rc" = 0 ] || exit "$rc"                              # sbatch's own status, as before (verdict refused|unknown)
[ -z "$jid" ] || echo "log: $PROJ/logs/${NAME}_${jid}.out   (status: sacct -j $jid -X -o State%20,Elapsed,ExitCode)"
)
