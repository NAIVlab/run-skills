#!/usr/bin/env bash
# run-skills install.sh — install the harness copy + the hpc-run / ws-run skills for Claude Code, Codex and pi. LOCAL.
#   bash install.sh            (RS_HARNESS_ROOT / RS_SKILLS_ROOT override the two install dirs under ~/.agents)
# Copies bin lib remote targets tests selftest.sh INSTALL.md -> ~/.agents/run-skills/ (ONE harness copy; skills reach it through
# INDEX's `root:` line). Installs ONE copy of each skill into $RS_SKILLS_ROOT — read natively by Codex and pi — and
# symlinks ~/.claude/skills/<s> to it (Claude Code follows symlinks). Per-agent copies under ~/.codex/skills and
# ~/.pi/agent/skills are retired (a second copy would be listed twice). The v1 {hpc-run,ws-run} harness dirs of each
# agent root are moved aside with exec forwarders left behind (project runbooks call those paths). Scaffolds
# ~/.config/run-skills/, checks ssh aliases, runs the clone's selftest. Idempotent: re-run after `git pull`.
# Never touches ~/.ssh/config or an existing wandb key.
set -euo pipefail
RS_HOME=$(cd "$(dirname "$0")" && pwd)
. "$RS_HOME/lib/common.sh"
DEST="${RS_HARNESS_ROOT:-$HOME/.agents/run-skills}"; SKILLS="${RS_SKILLS_ROOT:-$HOME/.agents/skills}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"; PI_HOME="${PI_HOME:-$HOME/.pi/agent}"
[ "$#" -eq 0 ] || { echo "usage: bash install.sh   (env: RS_SKILLS_ROOT=<dir>)" >&2; exit 2; }
command -v rsync >/dev/null || { echo "ERROR: rsync is required (the harness itself needs it too)." >&2; exit 1; }

triggers_for() {   # triggers_for KIND -> the T_TRIGGERS of every target of that kind, space-joined (head of the description)
  local t; for t in $(rs_targets); do
    ( rs_load_target "$t"; [ "$T_KIND" = "$1" ] && printf '%s ' "${T_TRIGGERS:-}"; true ); done | tr -s ' ' | sed 's/^ //; s/ $//'
}
install_skill() {   # install_skill NAME KIND: the one copy every agent reads (allowed-tools for Claude, agents/openai.yaml for Codex)
  local s=$1 kind=$2 dir=$SKILLS/$1 desc trig w
  mkdir -p "$dir"; rsync -a --delete "$RS_HOME/skills/$s/" "$dir/"; chmod -R u+rwX "$dir"
  rs_gen_index "$kind" "$dir/references/INDEX.md" "$DEST"
  desc=$(sed -n 's/^description: *//p' "$RS_HOME/skills/$s/SKILL.md"); trig=""
  for w in $(triggers_for "$kind"); do   # prepend only trigger words the shipped description does not already carry
    case " $desc$trig " in *" $w "*|*" $w."*|*" $w,"*) ;; *) trig="$trig $w" ;; esac   # each word once
  done
  [ -z "$trig" ] || desc="${trig# }. $desc"
  case "$desc" in *'<'*|*'>'*) echo "ERROR: $s description contains < or > (a T_TRIGGERS/T_DESC value?)" >&2; exit 1 ;; esac
  [ "${#desc}" -lt 1024 ] || { echo "ERROR: $s description is ${#desc} chars (limit 1024) — shorten T_TRIGGERS." >&2; exit 1; }
  { sed '/^description:/,$d' "$dir/SKILL.md"; echo "description: $desc"; sed '1,/^description:/d' "$dir/SKILL.md"; } > "$dir/SKILL.md.tmp"
  mv "$dir/SKILL.md.tmp" "$dir/SKILL.md"
  mkdir -p "$dir/agents"; install -m 644 "$RS_HOME/codex/$s.openai.yaml" "$dir/agents/openai.yaml"
  echo "  $dir  (description ${#desc} chars; INDEX: $(( $(grep -c '^| ' "$dir/references/INDEX.md") - 1 )) target row(s))"
}
retire() {   # retire PATH: move a stale skill copy OUT of its skills root (<root>.pre-v2/<name>, else it is still discovered)
  { [ -e "$1" ] || [ -L "$1" ]; } || return 0
  [ "$(readlink -f "$1" 2>/dev/null)" = "$(readlink -f "$SKILLS/$(basename "$1")")" ] && return 0
  local bk; bk="$(dirname "$1").pre-v2/$(basename "$1")"; [ -e "$bk" ] && bk="$bk.$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$(dirname "$bk")"; mv "$1" "$bk"; echo "  moved $1 -> $bk (superseded by $SKILLS/$(basename "$1"))"
}
link_skill() {   # link_skill NAME: Claude Code reads only ~/.claude/skills -> symlink it to the shared copy
  local t="$HOME/.claude/skills/$1"
  [ "$(readlink -f "$t" 2>/dev/null)" = "$(readlink -f "$SKILLS/$1")" ] && return 0
  retire "$t"; ln -s "$SKILLS/$1" "$t"; echo "  $t -> $SKILLS/$1"
}
legacy() {   # legacy ROOT: move a v1 harness dir aside once; leave exec forwarders (project runbooks call these paths)
  local d f bk fw; for d in hpc-run ws-run; do
    [ -d "$1/$d" ] || continue                       # never had v1 here: nothing to forward
    if ! grep -qs 'run-skills/bin/run-' "$1/$d/sync.sh"; then
      bk="$1/$d.pre-v2"; [ -e "$bk" ] && bk="$bk.$(date +%Y%m%d-%H%M%S)"
      mv "$1/$d" "$bk"; mkdir -p "$1/$d"; echo "  moved $1/$d -> $bk (v1 harness; delete when no longer needed)"
    fi
    [ "$d" = hpc-run ] && fw="sync.sh:run-sync" || fw="sync.sh:run-sync run.sh:run-launch"
    for f in $fw; do
      printf '#!/usr/bin/env bash\n# run-skills v2 forwarder (written by install.sh): the harness moved to ~/.agents/run-skills/bin/.\n# CLUSTER= / STATION= still work (run-* accept them as aliases of TARGET=).\nexec "$HOME/.agents/run-skills/bin/%s" "$@"\n' \
        "${f#*:}" > "$1/$d/${f%%:*}"; chmod +x "$1/$d/${f%%:*}"
    done
  done
}

echo "== harness -> $DEST =="
mkdir -p "$DEST"
rsync -a --delete "$RS_HOME/bin" "$RS_HOME/lib" "$RS_HOME/remote" "$RS_HOME/targets" "$RS_HOME/tests" "$RS_HOME/selftest.sh" "$RS_HOME/INSTALL.md" "$DEST/"
chmod -R u+rwX "$DEST"   # a read-only clone must not poison the $HOME copy
# earlier v2 installs (and runbooks written then) used ~/.claude/run-skills: keep that path as a symlink to $DEST
if [ "$DEST" != "$HOME/.claude/run-skills" ] && [ "$(readlink -f "$HOME/.claude/run-skills" 2>/dev/null)" != "$DEST" ]; then
  [ ! -e "$HOME/.claude/run-skills" ] || rm -rf "$HOME/.claude/run-skills"   # a generated copy, never user data
  mkdir -p "$HOME/.claude"; ln -s "$DEST" "$HOME/.claude/run-skills"; echo "  ~/.claude/run-skills -> $DEST (compat symlink)"
fi
echo "  targets: $(rs_targets | tr '\n' ' ')(yours: $RS_USER_DIR/targets; packs: $RS_PACKS_DIR/*/targets; templates: $RS_HOME/targets)"

echo "== skills -> $SKILLS (one copy: Codex and pi read it directly, Claude Code via ~/.claude/skills) =="
mkdir -p "$SKILLS" "$HOME/.claude/skills"
install_skill hpc-run slurm; install_skill ws-run nohup
link_skill hpc-run; link_skill ws-run
for r in "$CODEX_HOME/skills" "$PI_HOME/skills"; do for s in hpc-run ws-run; do retire "$r/$s"; done; done
echo "== v1 harness dirs (moved aside, forwarders left) =="
legacy "$HOME/.claude"
[ ! -d "$CODEX_HOME" ] || legacy "$CODEX_HOME"
[ ! -d "$PI_HOME" ] || legacy "$PI_HOME"

echo "== user overlay: $RS_USER_DIR =="
mkdir -p "$RS_USER_DIR/targets" "$RS_PACKS_DIR"
if [ -f "$RS_USER_DIR/wandb_env" ]; then
  echo "  wandb_env exists — left untouched."
elif [ -f "$HOME/.config/hpc-run/wandb_env" ]; then   # v1 location: carry the key over rather than shadow it with an empty file
  install -m 600 "$HOME/.config/hpc-run/wandb_env" "$RS_USER_DIR/wandb_env"; echo "  wandb_env copied from ~/.config/hpc-run/wandb_env."
else
  install -m 600 "$RS_HOME/templates/wandb_env" "$RS_USER_DIR/wandb_env"
  echo "  scaffolded $RS_USER_DIR/wandb_env (mode 600)."
  echo "  ACTION: put YOUR OWN key in it (wandb.ai/authorize) — empty key = runs go wandb-offline."
fi

echo "== ssh aliases =="
missing=""
for h in $(for t in $(rs_targets); do (rs_load_target "$t"; echo "$T_HOST ${T_XFER_HOST:-}"); done | tr ' ' '\n' | sort -u); do
  # control host + transfer host; `ssh -G` resolves the full config (Include/Match too); an undefined alias resolves to itself.
  hn=$(ssh -G "$h" 2>/dev/null | awk '/^hostname /{print $2; exit}') || hn=""
  un=$(ssh -G "$h" 2>/dev/null | awk '/^user /{print $2; exit}') || un=""
  case "$un" in *'<'*) hn="" ;; esac   # unedited "<user>" placeholder = not configured
  [ -n "$hn" ] && [ "$hn" != "$h" ] || missing="$missing $h"
done
if [ -n "$missing" ]; then
  echo "  ACTION: no ssh alias for:$missing. Add a Host block per alias to ~/.ssh/config (templates/ssh_config,"
  echo "          or the ssh_config your target pack ships; replace <user>), then ssh-copy-id each alias."
else
  echo "  all target aliases found."
fi

echo "== selftest (stubbed slurm/ssh — nothing leaves this machine) =="
bash "$RS_HOME/selftest.sh"   # from the clone: tests/70-docs.sh needs skills/ templates/ docs/, which $DEST omits
echo
echo "Install OK. Open Claude Code, Codex or pi and say e.g.: \"run this project on <target>\"."
[ -n "$(rs_targets)" ] || echo "No targets yet: ask your agent to register your servers — $DEST/INSTALL.md, Steps 2-6."
