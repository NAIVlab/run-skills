#!/usr/bin/env bash
# run-skills remote/submit.sh — generic Slurm submit. Runs ON the login node from <REMOTE_DIR>/.<target>/ (deployed
# by run-sync next to profile.sh, policy.sh, job.sbatch). Partition limits and gates come from the target's policy.sh
# (t_partition / t_policy, contract in targets/_template-slurm/policy.sh); this file names no cluster.
#   submit.sh [-p partition] [-g ngpu] [-G gputype] [-t time] [-m mem] [-c cpus] [-n name] [-y] [--<policy-flag>] -- <cmd...>
# Defaults from ../.hpc.conf: <TAG>_KEY beats KEY (DEFAULT_GPUS/CPUS/MEM/TIME ACCOUNT SBATCH_EXTRA JOB_NAME); CLI beats both.
# -y queues past an availability/occupancy warning. Exit 1 = warning, 2 = usage/data error, 3 = policy refusal.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$SELF/.." && pwd)"
. "$SELF/profile.sh"
[ -f "$SELF/policy.sh" ] && . "$SELF/policy.sh"
[ -f "$SELF/policy.local.sh" ] && . "$SELF/policy.local.sh"
CLUSTER="${T_NAME:?$SELF/profile.sh lacks T_NAME — deploy with run-sync}"
TAG=$(printf %s "$CLUSTER" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]')
# trust only .hpc.conf for conf-owned keys — never stale login-shell exports (which --export=ALL would also forward)
for _k in DEFAULT_PARTITION DEFAULT_GPU_TYPE DEFAULT_GPUS DEFAULT_CPUS DEFAULT_MEM DEFAULT_TIME ACCOUNT SBATCH_EXTRA \
          JOB_NAME VENV_DIR ENV_KIND ENV_NAME ENV_HOOK WANDB_MODE ${T_CONF_KEYS:-}; do unset "$_k" "${TAG}_$_k"; done
[ -f "$PROJ/.hpc.conf" ] || { echo "ERROR: MISSING $PROJ/.hpc.conf (partial sync?) — run run-sync first." >&2; exit 2; }
. "$PROJ/.hpc.conf"
ovr() { local _k="${TAG}_$1" _v; _v="${!_k:-}"; [ -n "$_v" ] || _v="${!1:-}"; printf %s "${_v:-${2:-}}"; }
_k="${TAG}_DEFAULT_PARTITION"; PART="${!_k:-${T_DEFAULT_PARTITION:-}}"     # generic DEFAULT_PARTITION is ignored
_k="${TAG}_DEFAULT_GPU_TYPE";  GTYPE="${!_k:-${T_DEFAULT_GPU_TYPE:-any}}"  # (a partition is a per-target choice)
NGPU=$(ovr DEFAULT_GPUS 1); DEF_CPUS=$(ovr DEFAULT_CPUS); DEF_MEM=$(ovr DEFAULT_MEM)
TIME=$(ovr DEFAULT_TIME 1-00:00:00); ACCOUNT=$(ovr ACCOUNT); SB_EXTRA=$(ovr SBATCH_EXTRA)
NAME=$(ovr JOB_NAME "$(basename "$PROJ")")
MEM=""; NCPU=""; FORCE=0; ACK=0; PART_FROM_CLI=""; GTYPE_FROM_CLI=""; T_FLAGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) PART="$2"; PART_FROM_CLI=1; shift 2 ;; -g) NGPU="$2"; shift 2 ;; -G) GTYPE="$2"; GTYPE_FROM_CLI=1; shift 2 ;;
    -t) TIME="$2"; shift 2 ;; -m) MEM="$2"; shift 2 ;; -c) NCPU="$2"; shift 2 ;;
    -n) NAME="$2"; shift 2 ;; -y|--force) FORCE=1; shift ;;
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
# --requeue FIRST so SBATCH_EXTRA may override it with --no-requeue (sbatch: the last of the pair wins)
SB_ARGS=(--job-name="$NAME" --chdir="$PROJ" --time="$TIME" --requeue --export=ALL,PROJ="$PROJ",CLUSTER="$CLUSTER",TARGET="$CLUSTER")
[ -z "$ACCOUNT" ] || SB_ARGS+=(--account="$ACCOUNT")

# policy gate first (its exit code is the verdict: 1 warning, 2 error, 3 refusal), then the partition's limits
if declare -f t_policy >/dev/null; then
  t_policy || { rc=$?; echo "ERROR: t_policy returned $rc (a policy that does not refuse must end with 'return 0')" >&2; exit "$rc"; }
fi
declare -f t_partition >/dev/null || { echo "ERROR: $SELF/policy.sh does not define t_partition" >&2; exit 2; }
P_GPUS=""; P_CPU_PER_GPU=""; P_MEM_PER_GPU=""; P_GTYPE=""; P_GTYPE_DEFAULT=""; P_PREEMPT=""; P_MAXTIME=""; P_CPU_ONLY=""; P_NOTE=""
t_partition "$PART" || { echo "ERROR: unknown $CLUSTER partition '$PART' (${T_PARTITIONS:-})" >&2; exit 2; }
if [ "$P_CPU_ONLY" = 1 ]; then
  [ -n "$NCPU" ] || NCPU="${DEF_CPUS:-8}"; [ -n "$MEM" ] || MEM="${DEF_MEM:-$(( NCPU*4 ))G}"
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
  echo "  -> $free free now; up to $maxn on one node (a 1-node job needs $NGPU on ONE node)."
  if { [ "$free" -lt "$NGPU" ] || [ "$maxn" -lt "$NGPU" ]; } && [ "$FORCE" -ne 1 ]; then
    echo "WARNING: only $free free of '$2' ($maxn on one node). Re-run -y to queue, pick another -G, or lower -g." >&2
    exit 1
  fi
}
GRES=()
if [ "$P_CPU_ONLY" = 1 ]; then echo "CPU partition '$PART' (no GPU)."
else
  check_gpu_avail "$PART" "$GTYPE"
  if [ "$GTYPE" = any ]; then GRES=(--gres="gpu:$NGPU"); else GRES=(--gres="gpu:$GTYPE:$NGPU"); fi
fi
[ -z "$P_NOTE" ] || echo "NOTE: $P_NOTE"
[ "$P_PREEMPT" != 1 ] || echo "NOTE: $PART is preemptible (the job is requeued — killed, under --no-requeue — possibly abruptly). Ensure checkpoint+resume."
mkdir -p "$PROJ/logs"                                  # job.sbatch writes logs/%x_%j.out
# name + ABSOLUTE log paths go LAST: nothing earlier (SBATCH_EXTRA, SBATCH_* env, --chdir) can falsify the printed path
unset SBATCH_ARRAY_INX SBATCH_WAIT                       # the two env switches no CLI arg can override
cmd=(sbatch "${SB_ARGS[@]}" --partition="$PART" ${GRES[@]+"${GRES[@]}"} --cpus-per-task="$NCPU" --mem="$MEM" \
     --job-name="$NAME" --output="$PROJ/logs/%x_%j.out" --error="$PROJ/logs/%x_%j.out" "$PROJ/.$CLUSTER/job.sbatch" "$@")
{ printf '+'; printf ' %q' "${cmd[@]}"; echo; } >&2      # the exact argv (what set -x used to show)
out=$("${cmd[@]}"); echo "$out"                          # a failing sbatch exits here (set -e) with its own stderr
jid=$(printf %s "$out" | awk '/Submitted batch job/{print $4; exit} /^[0-9]+(;|$)/{sub(/;.*/, ""); print; exit}')
[ -z "$jid" ] || echo "log: $PROJ/logs/${NAME}_${jid}.out   (status: sacct -j $jid -X -o State%20,Elapsed,ExitCode)"
