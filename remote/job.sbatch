#!/bin/bash
# run-skills remote/job.sbatch — generic batch script (requeue-aware; forwards the time-limit USR1, records TERM). Submitted by <REMOTE_DIR>/.<target>/submit.sh,
# which sets resources (partition/gres/cpus/mem/time/name) on the sbatch CLI and exports PROJ + CLUSTER/TARGET. The run
# command is passed as ARGUMENTS after the script name. Sources ../.<target>/env.sh and fails closed unless env.sh
# completed (RUN_ENV_READY) and the requested env (uv venv | conda env; none = nothing to check) actually exists.
#SBATCH --output=logs/%x_%j.out
#SBATCH --requeue
#SBATCH --open-mode=append
#SBATCH --signal=B:USR1@120

set -uo pipefail
: "${PROJ:?PROJ not set — submit via <REMOTE_DIR>/.<target>/submit.sh}"
CLUSTER="${CLUSTER:-${TARGET:-}}"; export CLUSTER TARGET="$CLUSTER"
: "${CLUSTER:?CLUSTER/TARGET not set — submit via <REMOTE_DIR>/.<target>/submit.sh}"
cd "$PROJ"
# Drop any sentinel/conda state inherited via sbatch --export=ALL (e.g. env.sh sourced interactively in the submit
# shell) so the fail-closed gates below judge THIS job's env.sh run.
unset RUN_ENV_READY HPC_ENV_READY WS_ENV_READY CONDA_DEFAULT_ENV 2>/dev/null || true
# shellcheck disable=SC1091
set +u; source "$PROJ/.$CLUSTER/env.sh"; set -u

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

echo "[$(date)] target=$CLUSTER job=${SLURM_JOB_ID:-?} restart=${SLURM_RESTART_COUNT:-0} node=${SLURM_NODELIST:-?} cpus=${SLURM_CPUS_ON_NODE:-?} gpus=${SLURM_JOB_GPUS:-${CUDA_VISIBLE_DEVICES:-?}}"
[ ! -f "$PROJ/.run-source" ] || echo "[$(date)] source: $(awk -F= '$1 ~ /^(branch|commit|dirty|synced)$/ {printf "%s=%s ", $1, substr($0, length($1) + 2)}' "$PROJ/.run-source")(run-sync stamp)"; nvidia-smi -L 2>/dev/null || true

[ "$#" -gt 0 ] || { echo "ERROR: no run command passed to job.sbatch" >&2; exit 2; }
[ "$term" = 0 ] || { echo "[$(date)] EXIT rc=143 usr1=$usr1 term=$term (TERM before the trainer started)"; exit 143; }
echo "[$(date)] RUN: $*"
"$@" &
child=$!; [ "$usr1" != pending ] || { usr1=0; on_usr1; }; [ "$term" != pending ] || { term=0; on_term; }   # replay pre-launch signals
# >128 from `wait` = the trainer's own status OR a trap interrupting it: while the trainer exists (zombies count) wait again
while :; do
  wait "$child"; rc=$?; [ "$rc" -gt 128 ] || break
  [ "$usr1$term" = 00 ] || echo "[$(date)] signal seen (USR1/TERM): usr1=$usr1 term=$term -- forwarded to trainer pid $child"
  kill -0 "$child" 2>/dev/null || { wait "$child" 2>/dev/null; rc=$?; break; }
done
echo "[$(date)] EXIT rc=$rc usr1=$usr1 term=$term job=${SLURM_JOB_ID:-?} restart=${SLURM_RESTART_COUNT:-0}"
exit "$rc"
