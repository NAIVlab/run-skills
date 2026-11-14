#!/bin/bash
# run-skills remote/job.sbatch — generic batch script (requeue-aware; forwards the time-limit USR1, records TERM). Submitted by <REMOTE_DIR>/.<target>/submit.sh,
# which sets resources (partition/gres/cpus/mem/time/name) on the sbatch CLI and exports PROJ + CLUSTER/TARGET + RS_ATTEMPT. The
# run command is passed as ARGUMENTS after the script name. Sources the attempt's env.sh snapshot (.rs/attempts/<NONCE>/), else
# ../.<target>/env.sh, and fails closed unless env.sh completed (RUN_ENV_READY) and the requested env (uv venv | conda env) exists.
# Multi-node (submit.sh --nodes K>1 exports RS_NODES=K RS_SRUN_GRES=<per-node gres>): MASTER_ADDR = the allocation's first host
# (scontrol show hostnames; none = EXIT rc=2), MASTER_PORT = an inherited one or 20000 + job id % 20000, NNODES=K and torchrun's
# PET_NNODES / PET_MASTER_ADDR / PET_MASTER_PORT / PET_NODE_RANK defaults (torch/distributed/run.py: `action=env` reads PET_<DEST>,
# argparse_util.py; pytorch 1a6d2a8), then ONE srun task per node runs the payload with NODE_RANK=$SLURM_NODEID. USR1 goes to srun,
# which relays it unchanged (srun_job.c _srun_signal_mgr: `default: launch_g_fwd_signal(sig)`); TERM never does — srun answers
# it with SIGKILL to the tasks (`case SIGTERM: … launch_g_fwd_signal(SIGKILL)`) — so a TERM is forwarded ONCE with `scancel
# --signal=TERM $SLURM_JOB_ID` (no --batch / --full: every step but the batch one; scancel(1)), srun kept waited for (scancel
# failed: TERM to srun, term=srun). A real cancel / end signals srun too (slurmd _rpc_terminate_job): DESIGN "Multi-node jobs".
# The env checks run on the batch node (PROJ is on the shared filesystem). RS_NODES unset or 1: the single-node path, unchanged.
#SBATCH --output=logs/%x_%j.out
#SBATCH --requeue
#SBATCH --open-mode=append
#SBATCH --signal=B:USR1@120

_rs_a=${RS_ATTEMPT:-}; _rs_an=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789   # NONCE = [A-Za-z0-9][A-Za-z0-9._-]{0,63}
case "$_rs_a" in [$_rs_an]*) case "$_rs_a" in *[!$_rs_an._-]*) _rs_a="" ;; esac ;; *) _rs_a="" ;; esac
[ "${#_rs_a}" -le 64 ] || _rs_a=""; _rs_l=${_rs_a:-none}; [ -n "$_rs_a" ] || [ -z "${RS_ATTEMPT:-}" ] || _rs_l=invalid
echo "[$(date)] rs-attempt=$_rs_l job=${SLURM_JOB_ID:-} restart=${SLURM_RESTART_COUNT:-0}"   # before env.sh: a job it refuses still names its attempt
set -uo pipefail
: "${PROJ:?PROJ not set — submit via <REMOTE_DIR>/.<target>/submit.sh}"
CLUSTER="${CLUSTER:-${TARGET:-}}"; export CLUSTER TARGET="$CLUSTER"
: "${CLUSTER:?CLUSTER/TARGET not set — submit via <REMOTE_DIR>/.<target>/submit.sh}"
cd "$PROJ"
# Drop any sentinel/conda state inherited via sbatch --export=ALL (e.g. env.sh sourced interactively in the submit
# shell) so the fail-closed gates below judge THIS job's env.sh run.
unset RUN_ENV_READY HPC_ENV_READY WS_ENV_READY CONDA_DEFAULT_ENV 2>/dev/null || true
_rs_e="$PROJ/.$CLUSTER/env.sh"; [ -z "$_rs_a" ] || [ ! -f "$PROJ/.rs/attempts/$_rs_a/env.sh" ] || _rs_e="$PROJ/.rs/attempts/$_rs_a/env.sh"
# shellcheck disable=SC1090
set +u; source "$_rs_e"; set -u

# Fail closed (1): env.sh exports RUN_ENV_READY=$PROJ as its LAST line — a partial sync / bad conf would otherwise
# run with caches escaping to $HOME. (An explicit sentinel, so a project ENV_HOOK may legitimately override HF_HOME.)
[ "${RUN_ENV_READY:-}" = "$PROJ" ] || { echo "[$(date)] ERROR: containment env not loaded (RUN_ENV_READY='${RUN_ENV_READY:-}') — aborting." >&2; exit 1; }
case "${ENV_KIND:-uv}" in uv|conda|none) ;; *) echo "[$(date)] ERROR: invalid ENV_KIND='${ENV_KIND:-}' in .hpc.conf — aborting." >&2; exit 1 ;; esac

# Fail closed (2): env.sh cannot abort a sourced job — verify the requested env materialized. uv: the venv must
# EXIST (`uv run` would otherwise AUTO-SYNC on the compute node, burning the allocation). conda: must be ACTIVE.
boot=0; [ "$*" != "bash $PROJ/.$CLUSTER/bootstrap.sh" ] || boot=1   # except `run-bootstrap --job`: it builds the venv
if [ "$boot" = 0 ] && [ "${ENV_KIND:-uv}" = "uv" ] && [ ! -x "${UV_PROJECT_ENVIRONMENT:-$PROJ/.venv}/bin/python" ]; then
  echo "[$(date)] ERROR: uv venv missing (${UV_PROJECT_ENVIRONMENT:-$PROJ/.venv}) — run run-bootstrap first. Aborting." >&2
  exit 1
fi
if [ "${ENV_KIND:-uv}" = "conda" ] && [ "${CONDA_DEFAULT_ENV:-}" != "${ENV_NAME:-}" ]; then
  echo "[$(date)] ERROR: conda env '${ENV_NAME:-?}' not active (CONDA_DEFAULT_ENV='${CONDA_DEFAULT_ENV:-none}') — aborting." >&2
  exit 1
fi

# Signals: --signal=B:USR1@120 = Slurm's ~120 s (60 s resolution) time-limit warning to this shell (on preemption too
# where the site sets PreemptParameters=send_user_signal); TERM = cancel / preempt / final kill, SIGKILL follows after
# KillWait or GraceTime. The traps forward each ONCE (claim before kill, no forks): 0 none, 1 forwarded, lost, pending.
child=; usr1=0; term=0
on_usr1() { [ "$usr1" = 0 ] || return 0; if [ -n "$child" ]; then usr1=1; kill -USR1 "$child" 2>/dev/null || usr1=lost; else usr1=pending; fi; }
on_term() { [ "$term" = 0 ] || return 0; if [ -n "$child" ]; then term=1; kill -TERM "$child" 2>/dev/null || term=lost; else term=pending; fi; }
trap on_usr1 USR1; trap on_term TERM

# vLLM V1 uses a CuMem pool; don't combine expandable_segments with it (override before the run command if needed).
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-max_split_size_mb:128}"

echo "[$(date)] target=$CLUSTER job=${SLURM_JOB_ID:-?} restart=${SLURM_RESTART_COUNT:-0} node=${SLURM_NODELIST:-?} cpus=${SLURM_CPUS_ON_NODE:-?} gpus=${SLURM_JOB_GPUS:-${CUDA_VISIBLE_DEVICES:-?}} attempt=${RS_ATTEMPT:-none}${RS_NODES:+$([ "$RS_NODES" = 1 ] || printf ' nodes=%s' "$RS_NODES")}"
[ ! -f "$PROJ/.run-source" ] || echo "[$(date)] source: $(awk -F= '$1 ~ /^(branch|commit|dirty|synced)$/ {printf "%s=%s ", $1, substr($0, length($1) + 2)}' "$PROJ/.run-source")(run-sync stamp)"; nvidia-smi -L 2>/dev/null || true

[ "$#" -gt 0 ] || { echo "ERROR: no run command passed to job.sbatch" >&2; exit 2; }
_rs_nn=${RS_NODES:-1}; _rs_mok=0   # no RS_NODES on several nodes = a node count the harness did not ask for: never a 1-node run there
[ "$_rs_nn" != 1 ] || [ "${SLURM_NNODES:-1}" = 1 ] || { echo "[$(date)] ERROR: the allocation has SLURM_NNODES=$SLURM_NNODES nodes but the submit asked for one (RS_NODES unset) — aborting." >&2
  echo "[$(date)] EXIT rc=2 usr1=$usr1 term=$term job=${SLURM_JOB_ID:-?} restart=${SLURM_RESTART_COUNT:-0}"; exit 2; }
if [ "$_rs_nn" != 1 ]; then   # multi-node: every failure below is EXIT rc=2 before the payload starts (fail closed)
  rs_mfail() { echo "[$(date)] ERROR: multi-node job: $1 — aborting." >&2; echo "[$(date)] EXIT rc=2 usr1=$usr1 term=$term job=${SLURM_JOB_ID:-?} restart=${SLURM_RESTART_COUNT:-0}"; exit 2; }
  case "$_rs_nn" in [123456789]|[123456789][0123456789]) ;; *) _rs_nn=bad ;; esac
  [ "$_rs_nn" != bad ] && [ "$_rs_nn" -le 64 ] || rs_mfail "RS_NODES='${RS_NODES:-}' is not a node count 2..64"
  [ "${SLURM_NNODES:-$_rs_nn}" = "$_rs_nn" ] || rs_mfail "the allocation has SLURM_NNODES=${SLURM_NNODES:-} nodes, the submit asked for $_rs_nn"
  [ -n "${SLURM_JOB_NODELIST:-}" ] || rs_mfail "SLURM_JOB_NODELIST is empty: no host list to pick MASTER_ADDR from"
  _rs_hl=$(scontrol show hostnames "$SLURM_JOB_NODELIST") || rs_mfail "'scontrol show hostnames $SLURM_JOB_NODELIST' failed"
  MASTER_ADDR=""; _rs_c=0; set -f; for _rs_h in $_rs_hl; do [ -n "$MASTER_ADDR" ] || MASTER_ADDR=$_rs_h; _rs_c=$((_rs_c + 1)); done; set +f
  [ -n "$MASTER_ADDR" ] || rs_mfail "'scontrol show hostnames $SLURM_JOB_NODELIST' named no host"
  [ "$_rs_c" = "$_rs_nn" ] || rs_mfail "'scontrol show hostnames $SLURM_JOB_NODELIST' named $_rs_c host(s), the job has $_rs_nn nodes"
  if [ -z "${MASTER_PORT:-}" ]; then
    case "${SLURM_JOB_ID:-}" in [0123456789]*) case "$SLURM_JOB_ID" in *[!0123456789]*) rs_mfail "SLURM_JOB_ID='$SLURM_JOB_ID' is not a number (MASTER_PORT)" ;; esac ;;
      *) rs_mfail "SLURM_JOB_ID='${SLURM_JOB_ID:-}' is not a number (MASTER_PORT)" ;; esac
    _rs_j=$SLURM_JOB_ID; while [ "${#_rs_j}" -gt 9 ]; do _rs_j=${_rs_j#?}; done   # its last 9 digits (10^9 % 20000 = 0)
    MASTER_PORT=$((20000 + 10#$_rs_j % 20000))
  fi
  case "$MASTER_PORT" in [123456789]|[123456789][0123456789]|[123456789][0123456789][0123456789]|[123456789][0123456789][0123456789][0123456789]|[123456789][0123456789][0123456789][0123456789][0123456789]) [ "$MASTER_PORT" -le 65535 ] || rs_mfail "MASTER_PORT='$MASTER_PORT' is not a port" ;;
    *) rs_mfail "MASTER_PORT='$MASTER_PORT' is not a port" ;; esac
  NNODES=$_rs_nn; PET_NNODES=$_rs_nn; PET_MASTER_ADDR=$MASTER_ADDR; PET_MASTER_PORT=$MASTER_PORT
  export NNODES MASTER_ADDR MASTER_PORT PET_NNODES PET_MASTER_ADDR PET_MASTER_PORT
  _rs_mok=1   # reached only past every check (an expansion error in bash abandons the whole `if`: checked below)
  echo "[$(date)] nodes=$_rs_nn hosts=$(printf '%s' "$_rs_hl" | tr '\n' ',' | sed 's/,$//') master=$MASTER_ADDR:$MASTER_PORT gres/node=${RS_SRUN_GRES:-none}"
fi
[ "$term" = 0 ] || { echo "[$(date)] EXIT rc=143 usr1=$usr1 term=$term job=${SLURM_JOB_ID:-?} restart=${SLURM_RESTART_COUNT:-0} (TERM before the trainer started)"; exit 143; }
[ "$_rs_nn" = 1 ] || [ "$_rs_mok" = 1 ] || { echo "[$(date)] ERROR: multi-node job: the MASTER_ADDR / MASTER_PORT setup did not complete — aborting." >&2
  echo "[$(date)] EXIT rc=2 usr1=$usr1 term=$term job=${SLURM_JOB_ID:-?} restart=${SLURM_RESTART_COUNT:-0}"; exit 2; }
echo "[$(date)] RUN: $*"
if [ "$_rs_nn" = 1 ]; then
"$@" &
else   # one task per node; srun gets USR1 (relayed unchanged), TERM goes to the steps' tasks through scancel (srun would KILL them)
  on_term() { [ "$term" = 0 ] || return 0; if [ -n "$child" ]; then term=1; scancel --signal=TERM "${SLURM_JOB_ID:-}" 2>/dev/null || { term=srun; kill -TERM "$child" 2>/dev/null || term=lost; }; else term=pending; fi; }
  _rs_sr=(srun --nodes="$_rs_nn" --ntasks-per-node=1 --kill-on-bad-exit=1)
  [ -z "${RS_SRUN_GRES:-}" ] || _rs_sr+=(--gres="$RS_SRUN_GRES")
  [ -z "${SLURM_CPUS_PER_TASK:-}" ] || _rs_sr+=(--cpus-per-task="$SLURM_CPUS_PER_TASK")   # the job's per-node cpus, never left to inheritance
  "${_rs_sr[@]}" --export=ALL bash -c '[ -n "${SLURM_NODEID:-}" ] || { echo "ERROR: rs-node: no SLURM_NODEID in this srun task — aborting." >&2; exit 2; }
    NODE_RANK=$SLURM_NODEID; PET_NODE_RANK=$SLURM_NODEID; export NODE_RANK PET_NODE_RANK; exec "$@"' rs-node "$@" &
fi
child=$!; [ "$usr1" != pending ] || { usr1=0; on_usr1; }; [ "$term" != pending ] || { term=0; on_term; }   # replay pre-launch signals
# >128 from `wait` = the trainer's own status OR a trap interrupting it: while the trainer exists (zombies count) wait again
while :; do
  wait "$child"; rc=$?; [ "$rc" -gt 128 ] || break
  [ "$usr1$term" = 00 ] || echo "[$(date)] signal seen (USR1/TERM): usr1=$usr1 term=$term -- forwarded to trainer pid $child"
  kill -0 "$child" 2>/dev/null || { wait "$child" 2>/dev/null; rc=$?; break; }
done
echo "[$(date)] EXIT rc=$rc usr1=$usr1 term=$term job=${SLURM_JOB_ID:-?} restart=${SLURM_RESTART_COUNT:-0}"
exit "$rc"
