#!/usr/bin/env bash
# Target-pack installer (from run-skills templates/pack/): registers this pack with run-skills and installs or
# updates the engine. Idempotent — re-run after `git pull` in this pack.   Usage: bash install.sh
#   RS_ENGINE_URL  engine repo to clone (default: the public run-skills)   RS_ENGINE_DIR  its clone (~/.local/share/run-skills)
#   RS_PACKS_DIR   where run-skills looks for packs (default ~/.config/run-skills/packs)
set -euo pipefail
PACK=$(cd "$(dirname "$0")" && pwd -P); NAME=$(basename "$PACK")
ENGINE_URL=${RS_ENGINE_URL:-https://github.com/NAIVlab/run-skills.git}
ENGINE_DIR=${RS_ENGINE_DIR:-$HOME/.local/share/run-skills}
PACKS=${RS_PACKS_DIR:-${RS_USER_DIR:-$HOME/.config/run-skills}/packs}
command -v git >/dev/null || { echo "ERROR: git is required." >&2; exit 1; }

echo "== pack '$NAME' -> $PACKS/$NAME =="
mkdir -p "$PACKS"
if [ "$(cd "$PACKS" && pwd -P)/$NAME" = "$PACK" ]; then
  echo "  cloned in place — nothing to link."
elif [ -L "$PACKS/$NAME" ] || [ ! -e "$PACKS/$NAME" ]; then
  ln -sfn "$PACK" "$PACKS/$NAME"; echo "  linked $PACKS/$NAME -> $PACK"
else
  echo "ERROR: $PACKS/$NAME already exists and is not this clone — move it away, then re-run." >&2; exit 1
fi

echo "== engine: $ENGINE_DIR =="
if [ -d "$ENGINE_DIR/.git" ]; then
  git -C "$ENGINE_DIR" pull --ff-only || { echo "ERROR: cannot fast-forward $ENGINE_DIR (local commits, or a clone of" \
    "another repo). Move it away (mv $ENGINE_DIR $ENGINE_DIR.old) and re-run; installed skills keep working meanwhile." >&2; exit 1; }
else git clone "$ENGINE_URL" "$ENGINE_DIR"; fi
RS_PACKS_DIR="$PACKS" bash "$ENGINE_DIR/install.sh"
