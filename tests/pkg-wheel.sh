#!/usr/bin/env bash
# tests/pkg-wheel.sh — the uv-tool life cycle, end to end, in a scratch HOME (NOT in selftest: it needs uv, and the
# network once for the hatchling build backend). Builds the wheel and checks it carries the harness with exec bits;
# installs rsk from a scratch git remote holding this working tree; runs rsk setup (over an install of the replaced
# hpc-run / ws-run skills, which it uninstalls) and doctor; commits a version bump
# to that remote and checks `rsk update` installs it and re-runs setup; `rsk update --to` goes back and stays there
# (a plain update keeps the pinned commit) until `rsk update --to main`.
# Usage: bash tests/pkg-wheel.sh   (PASS/FAIL lines; exit = failures). Never touches the real ~/.agents or ~/.config.
set -u
RS_HOME=$(cd "$(dirname "$0")/.." && pwd); export RS_HOME
. "$RS_HOME/tests/lib.sh"
command -v uv >/dev/null || { bad "uv on PATH"; exit 1; }
export UV_CACHE_DIR="${UV_CACHE_DIR:-$(uv cache dir)}"   # reuse the real cache (a cache only): no second hatchling download
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
SB=$T/sb; W=$SB/work; mkdir -p "$SB/home" "$W"

echo "-- wheel --"
uv build -q --wheel --out-dir "$SB/dist" "$RS_HOME" >/dev/null 2>&1 && ok "uv build --wheel" || bad "uv build --wheel"
WHL=$(ls "$SB"/dist/*.whl 2>/dev/null | head -1)
Z=$(python3 -c 'import sys, zipfile
for i in zipfile.ZipFile(sys.argv[1]).infolist(): print(oct((i.external_attr >> 16) & 0o777), i.filename)' "$WHL" 2>&1)
for f in bin/run-sync bin/run-watch lib/common.sh remote/env.sh remote/submit.sh remote/job.sbatch install.sh selftest.sh \
         INSTALL.md skills/remote-run/SKILL.md skills/remote-run/references/procedure-nohup.md codex/remote-run.openai.yaml \
         templates/pack/install.sh templates/ssh_config targets/_template-slurm/policy.sh tests/lib.sh tests/py/run.py docs/packs.md; do
  has "$Z" " remote_run/_harness/$f\$" "wheel carries $f"; done
has "$Z" "^0o755 remote_run/_harness/bin/run-sync\$" "wheel keeps bin/* executable"
hasnt "$Z" "__pycache__\|\.github/\|/\.claude/" "wheel carries no caches or CI files"
hasnt "$Z" "_harness/skills/hpc-run\|_harness/skills/ws-run\|_harness/codex/hpc-run\|_harness/codex/ws-run" "wheel carries only the remote-run skill"

echo "-- install from a git remote (scratch) --"
rsync -a --exclude=.git --exclude=__pycache__ --exclude=/dist "$RS_HOME/" "$W/"
git -C "$W" init -q -b main && git -C "$W" add -A && git -C "$W" commit -q -m v1 && git clone -q --bare "$W" "$SB/origin.git"
C1=$(git -C "$W" rev-parse HEAD)
fail_sections() { awk '/^== /{ if (f) printf "%s", b; b = ""; f = 0 } { b = b "    | " $0 "\n" } /^  FAIL: /{ f = 1 } END { if (f) printf "%s", b }'; }
sbx() { env HOME="$SB/home" UV_TOOL_DIR="$SB/tools" UV_TOOL_BIN_DIR="$SB/bin" RS_USER_DIR="$SB/home/.config/run-skills" \
  RS_PACKS_DIR="$SB/home/.config/run-skills/packs" RS_STATE_DIR="$SB/home/.local/state/run-skills" \
  RS_HARNESS_ROOT="$SB/home/.agents/run-skills" RS_SKILLS_ROOT="$SB/home/.agents/skills" CODEX_HOME="$SB/home/.codex" \
  PI_HOME="$SB/home/.pi/agent" PATH="$SB/bin:$PATH" "$@"; }   # every root install.sh writes to or uninstalls from
sbx uv tool install -q "git+file://$SB/origin.git" >/dev/null 2>&1 && ok "uv tool install git+file://…" || bad "uv tool install git+file://…"
V=$(sbx rsk --version 2>&1); has "$V" '^rsk ' "rsk on the tool bin dir ($V)"
H=$(find "$SB/tools" -path '*remote_run/_harness/bin/run-sync' | head -1)
[ -x "$H" ] && ok "installed harness keeps exec bits" || bad "installed harness keeps exec bits ($H)"
OLD=$SB/home/.agents/skills; mkdir -p "$OLD/hpc-run/references" "$OLD/ws-run/references" "$SB/home/.claude/skills"   # an earlier install
for s in hpc-run ws-run; do echo "name: $s" > "$OLD/$s/SKILL.md"; echo "root: /old" > "$OLD/$s/references/INDEX.md"
  ln -s "$OLD/$s" "$SB/home/.claude/skills/$s"; done
O=$(sbx rsk doctor 2>&1); RC=$?; [ "$RC" = 2 ] && ok "doctor before setup: exit 2" || bad "doctor before setup: exit 2 (got $RC)"
has "$O" 'run: rsk setup' "doctor says what to run"
has "$O" "FAIL skill hpc-run (replaced by remote-run) is still installed: $SB/home/.claude/skills/hpc-run" "doctor names a replaced skill still installed"

echo "-- rsk setup --"
O=$(sbx rsk setup 2>&1); RC=$?
[ "$RC" = 0 ] && ok "rsk setup exits 0" || { bad "rsk setup exits 0 (got $RC)"; echo "$O" | fail_sections; }
has "$O" 'Install OK' "setup ran install.sh to the end"; has "$O" 'RESULT: [0-9]* pass, 0 fail' "setup's selftest passed"
L=$(cat "$SB/home/.agents/run-skills/selftest.log" 2>/dev/null); hasnt "$O" '^  PASS: ' "setup's selftest is quiet (-q)"
has "$L" 'docs: skipped' "packaged selftest skips the clone-only doc checks"; has "$L" 'PASS: py test_install' "packaged selftest ran the python tests"
[ -x "$SB/home/.agents/run-skills/bin/run-sync" ] && ok "harness copy installed and executable" || bad "harness copy installed and executable"
[ -f "$SB/home/.agents/run-skills/templates/ssh_config" ] && [ -f "$SB/home/.agents/run-skills/docs/packs.md" ] \
  && ok "harness copy carries templates/ and docs/ (INSTALL.md's \$H paths)" || bad "harness copy carries templates/ and docs/"
[ -f "$SB/home/.agents/skills/remote-run/SKILL.md" ] && [ -L "$SB/home/.claude/skills/remote-run" ] && ok "skill + Claude link" || bad "skill + Claude link"
ls -d "$OLD"/*-run "$SB"/home/.claude/skills/*-run > "$T/left" 2>/dev/null
[ "$(sed 's|.*/||' "$T/left" | sort -u)" = remote-run ] && ok "setup uninstalled hpc-run / ws-run (remote-run alone)" || bad "setup uninstalled hpc-run / ws-run: $(cat "$T/left")"
O=$(sbx rsk doctor 2>&1); RC=$?; [ "$RC" = 0 ] && ok "doctor after setup: exit 0" || { bad "doctor after setup: exit 0 (got $RC)"; echo "$O" | grep FAIL | sed 's/^/    | /'; }

echo "-- rsk update (new commit upstream) --"
sed -i.bak 's/^__version__ = .*/__version__ = "99.0.0.dev9"/' "$W/src/remote_run/__init__.py" && rm -f "$W/src/remote_run/__init__.py.bak"
git -C "$W" commit -qam v2 && git -C "$W" push -q "$SB/origin.git" main
O=$(sbx rsk update --tool-only 2>&1); RC=$?
[ "$RC" = 0 ] && ok "rsk update exits 0" || { bad "rsk update exits 0 (got $RC)"; echo "$O" | fail_sections; echo "$O" | grep '^rsk:' | sed 's/^/    | /'; }
has "$O" 'uv tool upgrade --reinstall remote-run' "update ran uv tool upgrade"; has "$O" ' -> 99.0.0.dev9' "the NEW rsk re-ran setup"
has "$(sbx rsk --version 2>&1)" '99.0.0.dev9' "rsk is the new version"
has "$(cat "$SB/home/.local/state/run-skills/update-history.jsonl" 2>/dev/null)" "\"from_commit\": \"$C1\"" "update history records the commit it left"
has "$(cat "$SB/home/.local/state/run-skills/install.json" 2>/dev/null)" '"version": "99.0.0.dev9"' "install record names the new version"

echo "-- rsk update --to (roll back) --"
O=$(sbx rsk update --tool-only --to "$C1" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "rsk update --to <old commit> exits 0" || { bad "rsk update --to exits 0 (got $RC)"; echo "$O" | fail_sections; echo "$O" | grep '^rsk:' | sed 's/^/    | /'; }
hasnt "$(sbx rsk --version 2>&1)" '99.0.0.dev9' "rolled back to the old version"
O=$(sbx rsk update --tool-only 2>&1); RC=$?   # pinned at that commit now: a plain update stays there
[ "$RC" = 0 ] && ok "update while pinned exits 0" || bad "update while pinned exits 0 (got $RC)"
hasnt "$(sbx rsk --version 2>&1)" '99.0.0.dev9' "a plain update stays on the --to commit"
has "$O" "pinned to $C1 .*rsk update --to main" "update says it is pinned, and how to follow main again"
has "$O" 'nothing to set up again' "update while pinned skips setup"
O=$(sbx rsk update --tool-only --to main 2>&1); RC=$?
[ "$RC" = 0 ] && has "$(sbx rsk --version 2>&1)" '99.0.0.dev9' "rsk update --to main follows main again" \
  || { bad "rsk update --to main exits 0 (got $RC)"; echo "$O" | grep '^rsk:' | sed 's/^/    | /'; }
rm -f "$SB/home/.local/state/run-skills/install.json"   # tool current, but no record of a setup from it (uv upgrade alone)
O=$(sbx rsk update --tool-only 2>&1); RC=$?
[ "$RC" = 0 ] && ok "update with no setup record exits 0" || bad "update with no setup record exits 0 (got $RC)"
has "$O" 'no successful rsk setup from it' "update notices the missing setup"; has "$O" ' -> 99.0.0.dev9' "and re-runs setup"
[ -f "$SB/home/.local/state/run-skills/install.json" ] && ok "setup wrote install.json again" || bad "setup wrote install.json again"
echo; echo "===== pkg-wheel: $PASS pass, $FAIL fail ====="
exit "$FAIL"
