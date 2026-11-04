#!/usr/bin/env bash
# tests/75-install.sh — phase A: install.sh end to end in a scratch HOME, from a copy of the engine whose selftest.sh is
# a stub (no recursion). One remote-run skill: INDEX of both kinds + legacy pack routing, every target's T_TRIGGERS,
# the Claude Code link. The replaced hpc-run / ws-run skills leave every root an agent scans (~/.claude/skills,
# $CODEX_HOME/skills, $PI_HOME/skills, $RS_SKILLS_ROOT): links into the shared root, dangling links and the copies an
# install generated in the shared root are removed; anything else (a generated-looking copy elsewhere too: it may hold the
# user's edits) is moved out to <root>.pre-v2/ intact, never over an older backup, a dangling link included. A second run
# changes nothing.  bash tests/75-install.sh
set -u
. "$RS_HOME/tests/lib.sh"
command -v rsync >/dev/null || { echo "  SKIP: install.sh needs rsync"; exit 0; }
rsync -a --exclude=.git --exclude=__pycache__ "$RS_HOME/" "$T/eng/"
printf '#!/usr/bin/env bash\necho "stub selftest: RESULT 0 fail"\n' > "$T/eng/selftest.sh"
cp -R "$RS_USER_DIR" "$T/user"; printf "T_TRIGGERS='wsnick'\n" >> "$T/user/targets/ws-box/profile.sh"
H=$T/home; SR=$H/.agents/skills; CX=$H/codex; PI=$H/.pi/agent; CS=$H/.claude/skills
inst() { env HOME="$H" RS_HARNESS_ROOT="$H/.agents/run-skills" RS_SKILLS_ROOT="$SR" CODEX_HOME="$CX" PI_HOME="$PI" \
  RS_USER_DIR="$T/user" RS_PACKS_DIR="$T/user/packs" PATH="$T/bin:$PATH" bash "$T/eng/install.sh" 2>&1; }   # $T/bin: stub ssh
gen() { mkdir -p "$1/references"; printf -- '---\nname: %s\n---\n' "${1##*/}" > "$1/SKILL.md"; printf 'root: /old\n' > "$1/references/INDEX.md"; }

echo "-- install.sh over an install of the replaced skills, in all four roots --"
mkdir -p "$CS" "$CX/skills/hpc-run" "$CX/skills/other" "$PI/skills" "$T/elsewhere"
gen "$SR/hpc-run"; gen "$SR/ws-run"                         # the shared copies an earlier install.sh generated
ln -s "$SR/hpc-run" "$CS/hpc-run"; ln -s "$T/nowhere/ws-run" "$CS/ws-run"   # Claude: a link into the shared root, a dangling one
printf -- '---\nname: hpc-run\n---\nthe user'"'"'s own\n' > "$CX/skills/hpc-run/SKILL.md"; echo notes > "$CX/skills/hpc-run/NOTES.md"   # foreign
ln -s "$SR/ws-run" "$CX/skills/ws-run"; : > "$CX/skills/other/SKILL.md"                          # Codex: a link; an unrelated skill
gen "$PI/skills/ws-run"; echo mine > "$PI/skills/ws-run/MY-NOTES.md"   # pi: an old generated copy the user added to
: > "$T/elsewhere/SKILL.md"; ln -s "$T/elsewhere" "$PI/skills/hpc-run"  # ...and a link elsewhere
O=$(inst); RC=$?
[ "$RC" = 0 ] && ok "install.sh exits 0" || { bad "install.sh exits 0 (rc=$RC)"; echo "$O" | tail -15 | sed 's/^/    | /'; }
left=""; for r in "$CS" "$CX/skills" "$PI/skills" "$SR"; do for s in hpc-run ws-run; do
  { [ -e "$r/$s" ] || [ -L "$r/$s" ]; } && left="$left $r/$s"; done; done
[ -z "$left" ] && ok "no hpc-run / ws-run left in any root an agent scans" || bad "no hpc-run / ws-run left in any root an agent scans:$left"
for p in "$SR/hpc-run" "$SR/ws-run"; do has "$O" "^  removed $p (installed copy" "an installed copy in the shared root is removed: $p"; done
[ "$(cat "$PI/skills.pre-v2/ws-run/MY-NOTES.md" 2>/dev/null)" = mine ] && ok "a generated-looking copy outside the shared root is moved out, not deleted" \
  || bad "a generated-looking copy outside the shared root is moved out, not deleted"
for p in "$CS/hpc-run" "$CS/ws-run" "$CX/skills/ws-run"; do has "$O" "^  removed $p (link" "a link into the shared root / a dangling link is removed: $p"; done
[ "$(cat "$CX/skills.pre-v2/hpc-run/NOTES.md" 2>/dev/null)" = notes ] && ok "a foreign dir is moved out of the root, contents intact" \
  || bad "a foreign dir is moved out of the root, contents intact"
has "$O" "^  moved $CX/skills/hpc-run -> $CX/skills.pre-v2/hpc-run " "...and install.sh says where"
[ "$(readlink "$PI/skills.pre-v2/hpc-run")" = "$T/elsewhere" ] && [ -f "$T/elsewhere/SKILL.md" ] \
  && ok "a link elsewhere is moved out as a link; its target is untouched" || bad "a link elsewhere is moved out as a link; its target is untouched"
[ -f "$CX/skills/other/SKILL.md" ] && ok "an unrelated skill is untouched" || bad "an unrelated skill is untouched"

echo "-- the one skill --"
[ -f "$SR/remote-run/SKILL.md" ] && ok "remote-run installed in the shared root" || bad "remote-run installed in the shared root"
[ "$(readlink "$CS/remote-run")" = "$SR/remote-run" ] && ok "~/.claude/skills/remote-run -> the shared copy" || bad "~/.claude/skills/remote-run -> the shared copy"
has "$(cat "$SR/remote-run/agents/openai.yaml" 2>/dev/null)" '\$remote-run' "Codex metadata: agents/openai.yaml"
[ ! -e "$CX/skills/remote-run" ] && [ ! -e "$PI/skills/remote-run" ] && ok "no per-agent copy (it would be listed twice)" || bad "no per-agent copy"
I=$(cat "$SR/remote-run/references/INDEX.md" 2>/dev/null)
has "$I" "^root: $H/.agents/run-skills$" "INDEX root: is the harness copy"
has "$I" '^| fx-slurm | slurm | ' "INDEX lists a Slurm target"; has "$I" '^| ws-box | nohup | ' "...and a workstation, in the same table"
has "$I" '^| fx-packed | slurm | ' "...and a pack's target"
has "$(printf '%s\n' "$I" | sed -n '/^## Routing/,$p' | grep -A1 '^- For `slurm` targets only')" '^  - fixture pack routing rule$' "a pack's legacy routing/hpc-run.md is honoured, scoped to slurm"
D=$(grep -m1 '^description:' "$SR/remote-run/SKILL.md")
for w in fx fxpacked wsnick; do has "$D" "^description: [^.]*\<$w\>[^.]*\. Run, submit" "description starts with the triggers of every target: $w"; done
hasnt "$D" '[<>]' "description has no < >"; [ $(( ${#D} - 13 )) -lt 1024 ] && ok "description < 1024 chars" || bad "description < 1024 chars (${#D})"

echo "-- a second run is a no-op --"
L1=$(cd "$H" && find . | LC_ALL=C sort)
O=$(inst); RC=$?
[ "$RC" = 0 ] && ok "second install.sh exits 0" || bad "second install.sh exits 0 (rc=$RC)"
hasnt "$O" '^  removed \|^  moved ' "second run: nothing removed or moved"
L2=$(cd "$H" && find . | LC_ALL=C sort)
[ "$L1" = "$L2" ] && ok "second run: the same files under HOME" || { bad "second run: the same files under HOME"; diff <(echo "$L1") <(echo "$L2") | head | sed 's/^/    | /'; }

echo "-- a backup name taken by a dangling link --"
rm -rf "$T/elsewhere"; mkdir -p "$PI/skills/hpc-run"; echo again > "$PI/skills/hpc-run/NOTES.md"   # pre-v2/hpc-run now dangles
O=$(inst); RC=$?
[ "$RC" = 0 ] && ok "install.sh exits 0 when <root>.pre-v2/<name> is a dangling link" || { bad "install.sh exits 0 when <root>.pre-v2/<name> is a dangling link (rc=$RC)"; echo "$O" | tail -5 | sed 's/^/    | /'; }
[ ! -e "$PI/skills/hpc-run" ] && [ "$(cat "$PI/skills.pre-v2"/hpc-run.*/NOTES.md 2>/dev/null)" = again ] && [ -L "$PI/skills.pre-v2/hpc-run" ] \
  && ok "...the dir goes to a timestamped backup, the old link stays" || bad "...the dir goes to a timestamped backup, the old link stays"
