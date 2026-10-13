# run-skills remote/env.sh — ONE containment env for both kinds (slurm + nohup). Deployed as
# <REMOTE_DIR>/.<target>/env.sh (slurm) or .ws/env.sh (nohup) and SOURCED on the remote by job.sbatch,
# bootstrap.sh, the nohup launch chain, project scripts and interactive shells (bash or zsh).
#   export PROJ=<remote project dir> [TARGET=<name>|CLUSTER=<name>]; . $PROJ/.<target>/env.sh
# Reads <deploy dir>/profile.sh (T_* storage policy) + .hpc.conf/.ws.conf, pins caches/tmp/venv per that policy,
# activates uv|conda, sources ENV_HOOK last, then exports RUN_ENV_READY=$PROJ (+ HPC_/WS_ENV_READY).
# zsh-safe: no arrays, [[ ]], ${var^^}, ${!var}, BASH_SOURCE. Never set -e; every failure withholds READY.
# Scratch state is _rs_-prefixed and unset at the end: only the documented exports reach the caller's shell.
_rs_fail() { echo "env.sh: $1 — refusing to continue" >&2; return 1; }
_rs_path() { printf %s "$1" | sed -e "s|\\\${HOME}|$HOME|g" -e "s|\\\$HOME|$HOME|g" -e "s|\\\${USER}|$_rs_user|g" -e "s|\\\$USER|$_rs_user|g"; }
_rs_env() {
  # 1. target -> deploy dir (.<target>/, else .ws/) -> profile -> conf
  : "${PROJ:?export PROJ=<remote project dir> before sourcing env.sh}"
  TARGET=${TARGET:-${CLUSTER:-}}; _rs_d=$PROJ/.ws; _rs_alt=""
  if [ -n "$TARGET" ]; then
    if [ -d "$PROJ/.$TARGET" ]; then _rs_d=$PROJ/.$TARGET; else _rs_alt=" (no $PROJ/.$TARGET/ either)"; fi; fi
  [ -f "$_rs_d/profile.sh" ] || { _rs_fail "MISSING $_rs_d/profile.sh$_rs_alt (partial sync?)"; return 1; }
  . "$_rs_d/profile.sh" || { _rs_fail "FAILED sourcing $_rs_d/profile.sh"; return 1; }
  TARGET=${TARGET:-${T_NAME:-}}
  [ -n "$TARGET" ] || { _rs_fail "no target: export TARGET=<name> (or CLUSTER=) before sourcing env.sh"; return 1; }
  [ -z "${T_NAME:-}" ] || [ "$T_NAME" = "$TARGET" ] || { _rs_fail "$_rs_d/profile.sh is for target '$T_NAME', not '$TARGET'"; return 1; }
  case "${T_KIND:-}" in slurm) _rs_conf=$PROJ/.hpc.conf ;; nohup) _rs_conf=$PROJ/.ws.conf ;;
    *) _rs_fail "T_KIND='${T_KIND:-}' in $_rs_d/profile.sh must be slurm|nohup"; return 1 ;; esac
  [ -f "$_rs_conf" ] || { _rs_fail "MISSING $_rs_conf (partial sync?)"; return 1; }
  . "$_rs_conf" || { _rs_fail "FAILED sourcing $_rs_conf (unquoted spaces?)"; return 1; }
  # 2. identity exports: CLUSTER (slurm) xor WS_TAG (nohup), never both
  _rs_user=${USER:-$(id -un)}
  _rs_tag=$(printf %s "$TARGET" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]')
  _rs_suf=${T_SUFFIX:-}
  export TARGET RS_TARGET="$TARGET" RS_KIND="$T_KIND" RS_CUDA_ARCH="${T_CUDA_ARCH:-}"
  if [ "$T_KIND" = slurm ]; then export CLUSTER="$TARGET"; unset WS_TAG
  else WS_TAG=$(printf %s "$_rs_tag" | tr '[:upper:]' '[:lower:]'); export WS_TAG; unset CLUSTER; fi
  # 3. storage roots
  _rs_root=$(_rs_path "${T_ENV_ROOT:-}"); [ -n "$_rs_root" ] || _rs_root=$PROJ
  export RS_ENV_ROOT="$_rs_root"
  _rs_pname=$(basename "$PROJ")
  # 4. blob caches + wandb dirs always in-project; small-file state follows ENV_ROOT
  export HF_HOME="$PROJ/.cache/huggingface" TORCH_HOME="$PROJ/.cache/torch"
  export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub" HF_DATASETS_CACHE="$HF_HOME/datasets" TRANSFORMERS_CACHE="$HF_HOME/hub"
  export WANDB_DIR="$PROJ/wandb" WANDB_CACHE_DIR="$PROJ/.cache/wandb" WANDB_CONFIG_DIR="$PROJ/.config/wandb"
  export WANDB_DATA_DIR="$PROJ/.cache/wandb-data" WANDB_ARTIFACT_DIR="$PROJ/wandb-artifacts" WANDB_MODE="${WANDB_MODE:-online}"
  unset WANDB_API_KEY WANDB_ENTITY            # never the host's system creds; ours is resolved in step 8
  if [ "$_rs_root" = "$PROJ" ]; then _rs_state=$PROJ; else _rs_state=$_rs_root/state/$_rs_pname$_rs_suf; fi
  export XDG_CACHE_HOME="$_rs_state/.cache" XDG_DATA_HOME="$_rs_state/.local/share" XDG_STATE_HOME="$_rs_state/.local/state"
  export PIP_CACHE_DIR="$_rs_state/.cache/pip" MPLCONFIGDIR="$_rs_state/.cache/matplotlib"
  # 5. tmp + compiled/arch-specific caches (suffixed by T_SUFFIX; nv is arch-keyed, never suffixed)
  case "${T_TMPDIR:-project}" in
    project) TMPDIR=$PROJ/tmp ;;
    inherit) { [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && [ -w "$TMPDIR" ]; } || TMPDIR=/tmp/$_rs_user/run-skills$_rs_suf ;;
    *) _rs_fail "T_TMPDIR='$T_TMPDIR' in $_rs_d/profile.sh must be project|inherit"; return 1 ;;
  esac
  export TMPDIR TMP="$TMPDIR" TEMP="$TMPDIR"
  case "$TMPDIR" in /tmp/*) _rs_local=1 ;; *) _rs_local=0 ;; esac
  case "${T_COMPILE_CACHE:-project}" in
    project) _rs_cc=$PROJ/.cache ;; tmp) _rs_cc=$TMPDIR ;; *) _rs_cc=$(_rs_path "$T_COMPILE_CACHE") ;;
  esac
  export TRITON_CACHE_DIR="$_rs_cc/triton$_rs_suf" TORCH_EXTENSIONS_DIR="$_rs_cc/torch_ext$_rs_suf" TORCHINDUCTOR_CACHE_DIR="$_rs_cc/inductor$_rs_suf"
  export VLLM_CACHE_ROOT="$_rs_cc/vllm$_rs_suf" FLASHINFER_WORKSPACE_BASE="$_rs_cc/flashinfer$_rs_suf" CUDA_CACHE_PATH="$_rs_cc/nv"
  if [ "$_rs_local" = 1 ]; then export RAY_TMPDIR="$TMPDIR/ray"; else export RAY_TMPDIR="/tmp/ray_$_rs_user$_rs_suf"; fi
  export RAY_ENABLE_UV_RUN_RUNTIME_ENV=0 RAY_DEDUP_LOGS=0     # AF_UNIX socket path limit: keep RAY_TMPDIR short
  # 6. CUDA_HOME: set when the target needs it, else UNSET any inherited one (wheels bundle CUDA)
  if [ -n "${T_CUDA_HOME:-}" ]; then export CUDA_HOME="$(_rs_path "$T_CUDA_HOME")"; else unset CUDA_HOME; fi
  # 7. env manager
  eval "ENV_NAME=\${${_rs_tag}_ENV_NAME:-\${ENV_NAME:-}}"; export ENV_NAME
  case "${ENV_KIND:-uv}" in
    uv)
      eval "_rs_venv=\${${_rs_tag}_VENV_DIR:-\${VENV_DIR:-}}"
      if [ -n "$_rs_venv" ]; then _rs_venv=$(_rs_path "$_rs_venv")
      elif [ "$_rs_root" = "$PROJ" ]; then _rs_venv=$PROJ/.venv$_rs_suf
      else _rs_venv=$_rs_root/envs/$_rs_pname$_rs_suf; fi
      export UV_PROJECT_ENVIRONMENT="$_rs_venv" RS_VENV="$_rs_venv" UV_NO_SYNC=1 UV_CACHE_DIR="$_rs_root/.cache/uv$_rs_suf"
      export UV_PYTHON_INSTALL_DIR="$_rs_root/.cache/uv-python$_rs_suf" UV_TOOL_DIR="$_rs_root/.cache/uv-tools$_rs_suf"
      export PATH="$_rs_venv/bin:$_rs_root/bin:$PATH"       # venv first: bare `python` IS the project's python
      ;;
    conda)
      [ -n "${T_CONDA_INIT:-}" ] || { _rs_fail "ENV_KIND=conda but T_CONDA_INIT is empty in $_rs_d/profile.sh"; return 1; }
      eval "$(_rs_path "$T_CONDA_INIT")" || { _rs_fail "T_CONDA_INIT failed ($T_CONDA_INIT)"; return 1; }
      command -v conda >/dev/null 2>&1 || { _rs_fail "conda not found after T_CONDA_INIT ($T_CONDA_INIT)"; return 1; }
      [ -n "$ENV_NAME" ] || { _rs_fail "ENV_NAME required in $_rs_conf for ENV_KIND=conda"; return 1; }
      export PATH="$_rs_root/bin:$PATH"                  # before activate: the conda env's bin stays first
      conda activate "$ENV_NAME" || { _rs_fail "conda activate '$ENV_NAME' failed"; return 1; }
      ;;
    *) _rs_fail "invalid ENV_KIND='${ENV_KIND:-}' (use uv|conda)"; return 1 ;;
  esac
  # 8. wandb creds: OUR key only
  [ -f "$PROJ/.wandb_env" ] && . "$PROJ/.wandb_env"
  if [ -z "${WANDB_API_KEY:-}" ] && [ "$WANDB_MODE" != disabled ]; then
    echo "env.sh: no WANDB_API_KEY (missing $PROJ/.wandb_env) -> WANDB_MODE=offline (refusing system creds)" >&2
    export WANDB_MODE=offline
  fi
  # 9. materialise (compile caches are skipped when they live in a per-job $TMPDIR)
  mkdir -p "$HF_HOME/hub" "$HF_DATASETS_CACHE" "$TORCH_HOME" "$WANDB_DIR" "$WANDB_CACHE_DIR" "$WANDB_CONFIG_DIR" \
    "$WANDB_DATA_DIR" "$WANDB_ARTIFACT_DIR" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$PIP_CACHE_DIR" \
    "$MPLCONFIGDIR" "$TMPDIR" "$RAY_TMPDIR" "$PROJ/logs" "$PROJ/ckpts" "$_rs_root/bin" \
    || { _rs_fail "mkdir failed under $PROJ / $_rs_root (quota/perms?)"; return 1; }
  [ "$_rs_cc" = "$TMPDIR" ] || mkdir -p "$TRITON_CACHE_DIR" "$TORCH_EXTENSIONS_DIR" "$TORCHINDUCTOR_CACHE_DIR" \
    "$VLLM_CACHE_ROOT" "$FLASHINFER_WORKSPACE_BASE" "$CUDA_CACHE_PATH" \
    || { _rs_fail "mkdir failed under $_rs_cc (quota/perms?)"; return 1; }
  # 10. project hook, sourced LAST so it may override anything above (branch on RS_TARGET/RS_CUDA_ARCH inside)
  if [ -n "${ENV_HOOK:-}" ]; then
    [ -f "$PROJ/$ENV_HOOK" ] || { _rs_fail "ENV_HOOK '$ENV_HOOK' not found under $PROJ"; return 1; }
    . "$PROJ/$ENV_HOOK" || { _rs_fail "FAILED sourcing ENV_HOOK '$ENV_HOOK'"; return 1; }
  fi
}
_rs_env || return 1 2>/dev/null || exit 1
unset _rs_d _rs_alt _rs_conf _rs_tag _rs_suf _rs_root _rs_pname _rs_state _rs_cc _rs_local _rs_venv _rs_user
# 11. sentinels — only reached when every step above succeeded (consumers unset them before sourcing)
export RUN_ENV_READY="$PROJ"
if [ "$RS_KIND" = slurm ]; then export HPC_ENV_READY="$PROJ"; else export WS_ENV_READY="$PROJ"; fi
