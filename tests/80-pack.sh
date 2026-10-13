#!/usr/bin/env bash
# tests/80-pack.sh — phase A: templates/pack/install.sh (the installer every target pack copies) with a stub git and
# a fake engine: links the pack into RS_PACKS_DIR (or accepts an in-place clone), refuses a foreign dir of the same
# name, clones the engine when absent / pulls it when present (a non-fast-forward clone stops with a hint), then runs the engine's install.sh with RS_PACKS_DIR.
# Run by selftest.sh with RS_HOME set:  bash tests/80-pack.sh
set -u
. "$RS_HOME/tests/lib.sh"
H=$T/home; mkdir -p "$H"
printf '#!/usr/bin/env bash\necho "git $*" >> "%s/git.log"\n[ -n "${GIT_FAIL:-}" ] && exit 1\n[ "$1" = clone ] && { mkdir -p "$3/.git"; printf %s "echo ENGINE-INSTALL packs=\\$RS_PACKS_DIR" > "$3/install.sh"; }\nexit 0\n' "$T" > "$T/bin/git"
chmod +x "$T/bin/git"
cp -R "$RS_HOME/templates/pack" "$T/mypack"
inst() { local s=$1; shift; : > "$T/git.log"; ( unset RS_USER_DIR RS_PACKS_DIR RS_ENGINE_DIR RS_ENGINE_URL
  env HOME="$H" PATH="$T/bin:$PATH" "$@" bash "$s" 2>&1 ); }

O=$(inst "$T/mypack/install.sh"); RC=$?
[ "$RC" = 0 ] && ok "pack install exits 0 (fresh)" || { bad "pack install exits 0 (fresh, rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
[ "$(readlink "$H/.config/run-skills/packs/mypack")" = "$(cd "$T/mypack" && pwd -P)" ] && ok "pack linked into ~/.config/run-skills/packs/<name>" || bad "pack linked into ~/.config/run-skills/packs/<name>"
has "$(cat "$T/git.log")" "^git clone https://github.com/.*/run-skills.git $H/.local/share/run-skills$" "engine cloned when absent"
has "$O" "ENGINE-INSTALL packs=$H/.config/run-skills/packs$" "engine install.sh runs with RS_PACKS_DIR"
O=$(inst "$T/mypack/install.sh"); RC=$?
[ "$RC" = 0 ] && ok "pack install is idempotent" || bad "pack install is idempotent (rc=$RC)"
has "$(cat "$T/git.log")" "^git -C $H/.local/share/run-skills pull --ff-only$" "engine pulled when present"
O=$(inst "$T/mypack/install.sh" GIT_FAIL=1); RC=$?
[ "$RC" = 1 ] && has "$O" 'cannot fast-forward .*Move it away' "a non-fast-forward engine clone stops with a hint" || bad "non-ff engine clone stops (rc=$RC)"
hasnt "$O" 'ENGINE-INSTALL' "...and the engine install does not run"
mkdir -p "$H/.config/run-skills/packs/other"; cp -R "$RS_HOME/templates/pack" "$T/other"
O=$(inst "$T/other/install.sh"); RC=$?
[ "$RC" = 1 ] && has "$O" 'already exists and is not this clone' "a foreign dir with the pack's name is refused" || bad "foreign dir refused (rc=$RC)"
cp -R "$RS_HOME/templates/pack" "$H/.config/run-skills/packs/inplace"
O=$(inst "$H/.config/run-skills/packs/inplace/install.sh"); RC=$?
[ "$RC" = 0 ] && has "$O" 'cloned in place' "a pack cloned straight into the packs dir is accepted" || bad "in-place pack accepted (rc=$RC)"
O=$(inst "$T/mypack/install.sh" RS_PACKS_DIR="$T/custom" RS_ENGINE_DIR="$T/eng" RS_ENGINE_URL=https://example.invalid/e.git); RC=$?
[ -L "$T/custom/mypack" ] && ok "RS_PACKS_DIR honoured" || bad "RS_PACKS_DIR honoured"
has "$(cat "$T/git.log")" "^git clone https://example.invalid/e.git $T/eng$" "RS_ENGINE_URL / RS_ENGINE_DIR honoured"
