#!/usr/bin/env bash
# run-skills remote/bootstrap.sh — one-time, idempotent env bootstrap. Runs ON the target (login node or
# workstation), deployed next to env.sh:  export PROJ=<remote project dir> TARGET=<name>; bash $PROJ/.<target>/bootstrap.sh
# uv (default): sources env.sh, refuses a venv outside $PROJ / T_ENV_ROOT / VENV_DIR, finds uv (PATH, ~/.local/bin,
#   else installs into $RS_ENV_ROOT/bin), then `uv sync` — or runs BOOTSTRAP_HOOK instead.
# conda: only verifies ENV_NAME exists via T_CONDA_INIT — never creates envs (torch/cuda are the user's call).
set -euo pipefail
: "${PROJ:?export PROJ=<remote project dir> first}"
TARGET=${TARGET:-${CLUSTER:-}}
if [ -n "$TARGET" ] && [ -d "$PROJ/.$TARGET" ]; then D=$PROJ/.$TARGET; else D=$PROJ/.ws; fi
[ -f "$D/profile.sh" ] || { echo "ERROR: MISSING $D/profile.sh (partial sync?) — run run-sync first." >&2; exit 2; }
. "$D/profile.sh"
TARGET=${TARGET:-${T_NAME:-}}
[ -n "$TARGET" ] || { echo "ERROR: no target: export TARGET=<name> first." >&2; exit 2; }
case "${T_KIND:-}" in slurm) CONF=$PROJ/.hpc.conf ;; nohup) CONF=$PROJ/.ws.conf ;;
  *) echo "ERROR: T_KIND='${T_KIND:-}' in $D/profile.sh must be slurm|nohup." >&2; exit 2 ;; esac
[ -f "$CONF" ] || { echo "ERROR: MISSING $CONF (partial sync?) — run run-sync first." >&2; exit 2; }
. "$CONF" || { echo "ERROR: failed sourcing $CONF (unquoted spaces?) — fix it first." >&2; exit 2; }
RS_USER=${USER:-$(id -un)}
TAG=$(printf %s "$TARGET" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]')
rs_path() { printf %s "$1" | sed -e "s|\\\${HOME}|$HOME|g" -e "s|\\\$HOME|$HOME|g" -e "s|\\\${USER}|$RS_USER|g" -e "s|\\\$USER|$RS_USER|g"; }
eval "ENV_NAME=\${${TAG}_ENV_NAME:-\${ENV_NAME:-}}"
eval "VENV_CONF=\${${TAG}_VENV_DIR:-\${VENV_DIR:-}}"
# allowed venv roots, snapshotted from profile + conf BEFORE env.sh (an ENV_HOOK cannot move the guard)
ROOTS=$PROJ
[ -n "${T_ENV_ROOT:-}" ] && ROOTS="$ROOTS $(rs_path "$T_ENV_ROOT")"
[ -n "$VENV_CONF" ] && ROOTS="$ROOTS $(rs_path "$VENV_CONF")"
cd "$PROJ"
case "${ENV_KIND:-uv}" in
  uv)
    # an inherited sentinel from an earlier good run must not certify a NOW-broken env.sh
    unset RUN_ENV_READY HPC_ENV_READY WS_ENV_READY CONDA_DEFAULT_ENV
    set +eu; . "$D/env.sh"; set -eu
    [ "${RUN_ENV_READY:-}" = "$PROJ" ] || { echo "ERROR: env.sh did not complete (see its message above) — fix that, then re-run." >&2; exit 1; }
    VENV=${UV_PROJECT_ENVIRONMENT:-}; contained=0
    for r in $ROOTS; do case "$VENV" in "$r"|"$r"/*) contained=1 ;; esac; done
    [ "$contained" = 1 ] || { echo "ERROR: UV_PROJECT_ENVIRONMENT='${VENV:-unset}' is outside $PROJ / T_ENV_ROOT / VENV_DIR (ENV_HOOK?) — refusing to sync an uncontained venv." >&2; exit 1; }
    # bare ssh has a bare PATH: reuse an existing ~/.local/bin/uv before downloading one into $RS_ENV_ROOT/bin
    if ! command -v uv >/dev/null 2>&1 && [ -x "$HOME/.local/bin/uv" ]; then export PATH="$HOME/.local/bin:$PATH"; fi
    if ! command -v uv >/dev/null 2>&1; then
      echo "installing uv -> $RS_ENV_ROOT/bin ..."
      curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$RS_ENV_ROOT/bin" INSTALLER_NO_MODIFY_PATH=1 sh
    fi
    echo "uv: $(command -v uv)  ($(uv --version 2>/dev/null));  venv=$VENV"
    if [ -n "${BOOTSTRAP_HOOK:-}" ]; then
      [ -f "$PROJ/$BOOTSTRAP_HOOK" ] || { echo "ERROR: BOOTSTRAP_HOOK '$BOOTSTRAP_HOOK' not found under $PROJ." >&2; exit 1; }
      echo "running BOOTSTRAP_HOOK $BOOTSTRAP_HOOK (instead of uv sync) ..."; bash "$PROJ/$BOOTSTRAP_HOOK"
    else
      [ -f pyproject.toml ] || { echo "no pyproject.toml in $PROJ — run 'uv init' + 'uv add <deps>' first, then re-run." >&2; exit 1; }
      OWNER=$VENV/.run-skills-proj      # a derived venv belongs to one project; an explicit VENV_DIR is shared on purpose
      if [ -z "$VENV_CONF" ] && [ -f "$OWNER" ] && [ "$(cat "$OWNER")" != "$PROJ" ]; then
        echo "ERROR: venv $VENV belongs to $(cat "$OWNER") — set VENV_DIR to share it on purpose." >&2; exit 1
      fi
      # shellcheck disable=SC2086  # UV_SYNC_ARGS is word-split on purpose
      echo "uv sync ($TARGET venv) ..."; uv sync ${UV_SYNC_ARGS:-}
      mkdir -p "$VENV"; printf '%s\n' "$PROJ" > "$OWNER"
    fi
    uv cache prune -q || true
    du -sh "$UV_PROJECT_ENVIRONMENT" "$UV_CACHE_DIR" 2>/dev/null || true
    ;;
  conda)
    [ -n "${T_CONDA_INIT:-}" ] || { echo "ERROR: T_CONDA_INIT is empty in $D/profile.sh (needed for ENV_KIND=conda)." >&2; exit 1; }
    [ -n "$ENV_NAME" ] || { echo "ERROR: ENV_NAME required in $CONF for ENV_KIND=conda (the conda env to activate)." >&2; exit 1; }
    eval "$(rs_path "$T_CONDA_INIT")"
    if conda env list | awk '{print $1}' | grep -qx "$ENV_NAME"; then
      echo "conda env '$ENV_NAME' present ($(conda env list | awk -v e="$ENV_NAME" '$1==e{print $NF}'))."
    else
      echo "ERROR: conda env '$ENV_NAME' MISSING on $TARGET. Create it yourself (torch/cuda are yours), then re-run." >&2; exit 1
    fi
    ;;
  *) echo "ERROR: invalid ENV_KIND='${ENV_KIND:-}' (use uv|conda)." >&2; exit 2 ;;
esac
echo "bootstrap done ($TARGET)."
