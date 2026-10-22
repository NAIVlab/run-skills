#!/usr/bin/env bash
# tests/70-docs.sh — phase A: the shipped docs/skills are consistent with the code: SKILL.md descriptions short
# and angle-bracket free, committed INDEX.md stubs byte-equal to rs_gen_index output, every shipped target has
# its files, forbidden private words absent, header comments and line budgets kept.  bash tests/70-docs.sh
set -u
. "$RS_HOME/tests/lib.sh"
C() { ( . "$RS_HOME/lib/common.sh"; eval "$1" ) 2>&1; }

if [ ! -d "$RS_HOME/skills" ]; then   # installed harness copy (no skills/ templates/ docs/): these are clone-only checks
  echo "-- docs: skipped ($RS_HOME has no skills/ — run selftest from the git clone for the doc checks) --"; return 0 2>/dev/null || exit 0
fi
echo "-- skills --"
for s in hpc-run ws-run; do
  f=$RS_HOME/skills/$s/SKILL.md
  [ -f "$f" ] || { bad "$s/SKILL.md exists"; continue; }
  d=$(grep -m1 '^description:' "$f"); n=${#d}
  [ "$n" -gt 20 ] && [ "$n" -lt 1024 ] && ok "$s description present, < 1024 chars ($n)" || bad "$s description present, < 1024 chars ($n)"
  hasnt "$d" '[<>]' "$s description has no < >"
  S=$(cat "$f"); has "$S" "^name: $s\$" "$s frontmatter name"; has "$S" '^allowed-tools: Bash, Read, Write, Edit$' "$s allowed-tools"
  has "$S" 'references/INDEX.md' "$s body points at references/INDEX.md"
  for r in INDEX.md conf-keys.md experiment-conventions.md; do [ -f "$RS_HOME/skills/$s/references/$r" ] && ok "$s references/$r" || bad "$s references/$r"; done
done
[ -f "$RS_HOME/skills/hpc-run/references/procedure-slurm.md" ] && ok "procedure-slurm.md" || bad "procedure-slurm.md"
[ -f "$RS_HOME/skills/ws-run/references/procedure-nohup.md" ] && ok "procedure-nohup.md" || bad "procedure-nohup.md"
[ "$(readlink "$RS_HOME/skills/ws-run/references/experiment-conventions.md")" = "../../hpc-run/references/experiment-conventions.md" ] \
  && ok "ws-run experiment-conventions.md -> hpc-run's (one copy)" || bad "ws-run experiment-conventions.md -> hpc-run's (one copy)"
E=$(cat "$RS_HOME/skills/hpc-run/references/experiment-conventions.md" 2>/dev/null)
has "$E" 'WANDB_MODE=disabled' "conventions: smoke tracker isolation"; has "$E" '--requeue' "conventions: slurm auto-resume"
has "$E" '<task>--<stage>--<variant>--<origin>' "conventions: structured name shape"
has "$E" 'anomaly or restart' "conventions: anomalies and restarts need closer reviews"
has "$E" 'probe frequency and review frequency may differ' "conventions: probes need not wake the model each time"
has "$E" 'Detect, don.t act' "conventions: monitoring is detect-only"; has "$E" 'dependency=singleton' "conventions: segment chains"
has "$E" 'not enough evidence holds the interval' "conventions: widen only on evidence"
has "$E" 'missed transition deadline is a finding' "conventions: an expected transition has a deadline"
has "$E" 'routine review time merely schedules a check' "conventions: a scheduled review is not itself an anomaly"
has "$E" 'counts, not an event stream' "conventions: hints do not promise complete event coverage"
has "$E" 'Failed or incomplete probes do not establish run state' "conventions: observation failure is not run failure"
has "$E" 'atomic (temp name, then rename' "conventions: atomic saves"; has "$E" 'resumes from a committed' "conventions: chain precondition (resume)"
has "$E" 'exits 0 without training' "conventions: chain precondition (exit 0 when complete)"; has "$E" 'Do not promise unattended monitoring' "conventions: no unattended-monitoring promise"
# §6's Slurm claims, from the sbatch manual (https://slurm.schedmd.com/sbatch.html, read 2026-09-11; checked against Slurm 25.05.8):
#   --dependency=singleton "can begin execution after any previously launched jobs sharing the same job name and user
#   have terminated" (any termination, TIMEOUT included);
#   --requeue "eligible for requeuing … by a system administrator, after node failure, or upon preemption by a higher
#   priority job" (a walltime TIMEOUT is not in that list); "Environment variables will override any options set in a
#   batch script, and command line options will override any environment variables" (so SBATCH_EXTRA's --signal wins);
#   afterok is NOT usable for a chain: "Once a job dependency fails due to the termination state of a preceding job,
#   the dependent job will never be run, even if the preceding job is requeued".
has "$E" 'after a FAILURE' "conventions: singleton continues after a failure (said)"; has "$E" 'Every finding is reported' "conventions: every finding reported"
has "$E" 'wake-up mechanism' "conventions: the wake-up mechanism is stated, never assumed"
for f in skills/hpc-run/SKILL.md skills/ws-run/SKILL.md; do has "$(cat "$RS_HOME/$f")" 'wake-up mechanism' "$f rail: state the wake-up mechanism"; done
for f in skills/hpc-run/references/procedure-slurm.md skills/ws-run/references/procedure-nohup.md; do
  has "$(cat "$RS_HOME/$f")" 'resume=unverified' "$f: ckpt_entry is not proof of resume"; has "$(cat "$RS_HOME/$f")" 'Never read a log unbounded' "$f: byte-bounded reads rail"
  has "$(cat "$RS_HOME/$f")" 'hints, not diagnoses' "$f: the digest's counts are hints, so 0 is not 'no errors'"
  has "$(cat "$RS_HOME/$f")" 'the deploy predates it' "$f: what to do when the digest is not deployed yet"
done
for f in skills/hpc-run/SKILL.md skills/ws-run/SKILL.md skills/hpc-run/references/procedure-slurm.md \
         skills/ws-run/references/procedure-nohup.md; do
  hasnt "$(cat "$RS_HOME/$f")" 'tail -f' "$f keeps monitoring examples byte-bounded"
  hasnt "$(cat "$RS_HOME/$f")" 'tail -n [0-9]' "$f never tells the agent to read a log unbounded"
  has "$(cat "$RS_HOME/$f")" 'status\.sh' "$f monitors through the bounded status digest"
done
for f in skills/hpc-run/SKILL.md skills/ws-run/SKILL.md skills/hpc-run/references/procedure-slurm.md \
         skills/ws-run/references/procedure-nohup.md; do
  has "$(cat "$RS_HOME/$f")" 'experiment-conventions' "$f points at experiment-conventions.md"
done
[ "$(readlink "$RS_HOME/skills/ws-run/references/project-setup.md")" = "../../hpc-run/references/project-setup.md" ] \
  && ok "ws-run project-setup.md -> hpc-run's (one copy)" || bad "ws-run project-setup.md -> hpc-run's (one copy)"
PS=$(cat "$RS_HOME/skills/hpc-run/references/project-setup.md" 2>/dev/null)
for f in skills/hpc-run/SKILL.md skills/ws-run/SKILL.md; do
  has "$(cat "$RS_HOME/$f")" 'references/project-setup.md' "$f: a project without a conf goes through project-setup.md"
  has "$(cat "$RS_HOME/$f")" 'INSTALL.md' "$f: registering a target points at INSTALL.md"
done
has "$PS" 'never guess' "project-setup: never guess the remote dir"; has "$PS" 'never create it' "project-setup: never create a conda env"
has "$PS" 'run-sync -n' "project-setup: dry-run before the first sync"; has "$PS" 'Never launch it unasked' "project-setup: no launch without the user"
has "$PS" 'Remote-only edits' "project-setup: checks an existing remote copy before syncing"; has "$PS" '.run-skills-proj' "project-setup: a foreign venv is not adopted silently"
has "$PS" 'git/info/exclude' "project-setup: a shared repo keeps the conf untracked"
I=$(cat "$RS_HOME/INSTALL.md" 2>/dev/null)
has "$I" 'Read-only on remote machines' "INSTALL rail: read-only on servers"; has "$I" 'BatchMode=yes' "INSTALL rail: never wait at a password prompt"
has "$I" 'Secrets never enter the conversation' "INSTALL rail: secrets stay out"; has "$I" 'need an explicit OK' "INSTALL rail: ~/.ssh/config needs an OK"
has "$I" 'Do not invent facts' "INSTALL rail: no invented facts"; has "$I" 'never into the clone' "INSTALL rail: site facts stay out of the engine"
has "$I" 'at most four questions' "INSTALL rail: small question batches"; has "$I" 'project-setup.md' "INSTALL hands existing projects to project-setup.md"
has "$I" 'ask who the user is there' "INSTALL asks a pack member's identity"; has "$I" 'reference.local.md' "INSTALL writes pack identity to the overlay"
has "$(cat "$RS_HOME/templates/pack/README.md")" 'Personal facts' "pack template lists the placeholders the install asks for"
for c in 'run-probe hosts' 'run-probe <alias>' 'run-probe wandb' 'run-probe wandb --import-netrc'; do has "$I" "$c" "INSTALL uses: $c"; done
for c in 'run-probe hosts ' 'run-probe <alias> ' 'run-probe wandb \[--import-netrc\] '; do
  has "$(sed -n '2,8p' "$RS_HOME/bin/run-probe")" "$c" "run-probe header documents: $c"; done
has "$(cat "$RS_HOME/install.sh")" '"$RS_HOME/INSTALL.md" "$DEST/"' "install.sh ships INSTALL.md next to the harness (skills point at \$ROOT/INSTALL.md)"
has "$(cat "$RS_HOME/skills/hpc-run/SKILL.md")" 'run-sync\|run-bootstrap' "hpc-run names the bin/ commands"
has "$(cat "$RS_HOME/skills/ws-run/SKILL.md")" 'run-launch' "ws-run names run-launch"
for f in skills/hpc-run/SKILL.md skills/ws-run/SKILL.md skills/hpc-run/references/procedure-slurm.md \
         skills/ws-run/references/procedure-nohup.md; do
  has "$(cat "$RS_HOME/$f")" 'run-pull' "$f: results come back through run-pull"
  has "$(cat "$RS_HOME/$f")" 'hand-roll' "$f rail: files move only through run-sync / run-pull"
done
for f in skills/hpc-run/SKILL.md skills/ws-run/SKILL.md skills/hpc-run/references/INDEX.md skills/ws-run/references/INDEX.md \
         skills/hpc-run/references/procedure-slurm.md skills/ws-run/references/procedure-nohup.md; do
  has "$(cat "$RS_HOME/$f")" 'run-avail' "$f: an open placement starts with run-avail"; done
has "$(cat "$RS_HOME/skills/hpc-run/references/INDEX.md")" 'The user fixed it' "INDEX: a fixed placement is used as given (no fleet check)"
for f in skills/hpc-run/SKILL.md skills/ws-run/SKILL.md skills/hpc-run/references/procedure-slurm.md skills/ws-run/references/procedure-nohup.md; do
  has "$(cat "$RS_HOME/$f")" 'run-watch' "$f: many jobs or long waits go through run-watch"
  hasnt "$(cat "$RS_HOME/$f")" 'Monitor(\|/loop\|CronCreate\|ScheduleWakeup\|run_in_background' "$f names no runtime-specific waiting tool"; done
for f in skills/hpc-run/references/procedure-slurm.md skills/ws-run/references/procedure-nohup.md; do
  has "$(tr '\n' ' ' < "$RS_HOME/$f")" 'Never  *detach it (no `nohup`, `setsid`, cron)' "$f: run-watch stays owned by the session"; done
has "$(tr '\n' ' ' < "$RS_HOME/skills/hpc-run/SKILL.md")" 'One exception: `run-watch --act` first-submits or resubmits only table rows the user  *approved' "hpc-run rail: the one detect-only exception, user-approved rows only"
hasnt "$(cat "$RS_HOME/skills/hpc-run/SKILL.md")" 'only clears availability' "hpc-run rail: -y also confirms policy warnings (not just availability)"
has "$(tr '\n' ' ' < "$RS_HOME/skills/hpc-run/references/procedure-slurm.md")" 'only after their explicit OK run `run-watch <table> --approve' "procedure-slurm: --approve only after the user's OK"
has "$E" 'sole exception: `run-watch --act`' "conventions: detect-only names its one exception"
for f in skills/hpc-run/references/conf-keys.md skills/ws-run/references/conf-keys.md; do
  has "$(cat "$RS_HOME/$f")" 'T_XFER_HOST.*profile' "$f: the transfer host is a profile fact"
  hasnt "$(cat "$RS_HOME/$f")" '^| `XFER_HOST`' "$f: no XFER_HOST conf key (one per conf would misroute other targets)"; done
for t in _template-slurm _template-nohup; do has "$(cat "$RS_HOME/targets/$t/profile.sh")" '^T_XFER_HOST=' "$t profile documents T_XFER_HOST"; done
for y in hpc-run ws-run; do [ -f "$RS_HOME/codex/$y.openai.yaml" ] && ok "codex/$y.openai.yaml" || bad "codex/$y.openai.yaml"; done

echo "-- INDEX stubs == rs_gen_index (no overlay, root placeholder) --"
for k in slurm:hpc-run nohup:ws-run; do
  kind=${k%%:*}; s=${k#*:}
  RS_USER_DIR=/nonexistent RS_PACKS_DIR=/nonexistent C "rs_gen_index $kind '$T/idx-$kind.md' '~/.agents/run-skills'" >/dev/null
  if cmp -s "$T/idx-$kind.md" "$RS_HOME/skills/$s/references/INDEX.md"; then ok "$s/references/INDEX.md matches rs_gen_index"
  else bad "$s/references/INDEX.md matches rs_gen_index"; diff "$T/idx-$kind.md" "$RS_HOME/skills/$s/references/INDEX.md" | head -12 | sed 's/^/    | /'; fi
done
has "$(cat "$T/idx-slurm.md")" '^## Routing' "slurm INDEX carries a Routing section"

echo "-- shipped targets --"
SHIPPED=$(RS_USER_DIR=/nonexistent RS_PACKS_DIR=/nonexistent C 'rs_targets')
[ -z "$SHIPPED" ] && ok "no site target ships in the engine (sites live in packs / the overlay)" || bad "no site target ships in the engine: $SHIPPED"
for t in $SHIPPED; do
  for f in profile.sh reference.md tests.sh; do [ -f "$RS_HOME/targets/$t/$f" ] && ok "targets/$t/$f" || bad "targets/$t/$f"; done
  K=$(RS_USER_DIR=/nonexistent RS_PACKS_DIR=/nonexistent C "rs_load_target $t; echo \$T_KIND")
  [ "$K" = slurm ] && { [ -f "$RS_HOME/targets/$t/policy.sh" ] && ok "targets/$t/policy.sh" || bad "targets/$t/policy.sh"; }
  has "$(cat "$T/idx-$K.md")" "^| $t | " "INDEX row for $t"
  [ "$(wc -l < "$RS_HOME/targets/$t/reference.md")" -le 80 ] && ok "targets/$t/reference.md <= 80 lines" || bad "targets/$t/reference.md <= 80 lines"
done
for t in _template-slurm _template-nohup; do
  for f in profile.sh reference.md; do [ -f "$RS_HOME/targets/$t/$f" ] && ok "targets/$t/$f" || bad "targets/$t/$f"; done
done
[ -f "$RS_HOME/targets/_template-slurm/policy.sh" ] && ok "targets/_template-slurm/policy.sh" || bad "targets/_template-slurm/policy.sh"

echo "-- forbidden words / hygiene --"
# the forbidden words themselves are private, so the LIST lives outside the repo: the overlay's forbidden-words
# file (one grep -E pattern per line, #-comments, matched case-insensitively). Phase A runs with a fixture
# RS_USER_DIR — fall back to the real overlay (selftest.sh exports RS_USER_DIR_REAL) so the check still runs.
PFW="$RS_USER_DIR/forbidden-words"
[ -f "$PFW" ] || PFW="${RS_USER_DIR_REAL:-$HOME/.config/run-skills}/forbidden-words"
if [ -f "$PFW" ]; then
  PW=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$PFW" | tr '\n' '|' | sed 's/|*$//')
  if [ -n "$PW" ]; then
    SCAN=""; for x in bin lib remote targets skills templates tests docs codex .github selftest.sh install.sh README.md AGENTS.md INSTALL.md LICENSE; do
      [ -e "$RS_HOME/$x" ] && SCAN="$SCAN $x"; done
    FW=$(cd "$RS_HOME" && grep -rIli -E -e "$PW" -- $SCAN 2>/dev/null); RC=$?
    if [ "$RC" -ge 2 ]; then bad "no forbidden words in the repo (overlay list) — grep rejected a pattern in $PFW"
    elif [ -z "$FW" ]; then ok "no forbidden words in the repo (overlay list)"
    else bad "no forbidden words in the repo (overlay list)"; echo "$FW" | sed 's/^/    | /'; fi
  else
    ok "overlay forbidden-words file holds no patterns (comments only)"
  fi
else
  ok "no overlay forbidden-words file (nothing private to screen for)"
fi
[ -L "$RS_HOME/CLAUDE.md" ] && [ "$(readlink "$RS_HOME/CLAUDE.md")" = AGENTS.md ] && ok "CLAUDE.md -> AGENTS.md symlink" || bad "CLAUDE.md -> AGENTS.md symlink"
for f in templates/hpc.conf.example templates/ws.conf.example templates/ssh_config templates/wandb_env templates/pack/README.md README.md AGENTS.md INSTALL.md LICENSE docs/DESIGN.md docs/packs.md; do
  [ -f "$RS_HOME/$f" ] && ok "$f" || bad "$f"
done
for f in "$RS_HOME"/bin/* "$RS_HOME"/lib/*.sh "$RS_HOME"/remote/* "$RS_HOME"/targets/*/*.sh "$RS_HOME"/tests/*.sh "$RS_HOME"/selftest.sh "$RS_HOME"/install.sh; do
  [ -f "$f" ] || continue
  head -3 "$f" | grep -q '^#[^!]' && ok "header comment: ${f#"$RS_HOME"/}" || bad "header comment: ${f#"$RS_HOME"/}"
done
budget() { [ -f "$RS_HOME/$1" ] || { bad "$1 exists"; return; }; local n; n=$(wc -l < "$RS_HOME/$1")
  [ "$n" -le "$2" ] && ok "$1 within $2 lines ($n)" || bad "$1 within $2 lines ($n)"; }
budget lib/common.sh 130; budget remote/env.sh 170; budget remote/bootstrap.sh 90; budget remote/submit.sh 190; budget remote/job.sbatch 65
budget remote/status.sh 175   # generous on purpose: every lookup has an explicit failure branch; compressing them hides bugs
budget tests/lib.sh 130; budget selftest.sh 65; budget install.sh 130; budget README.md 240; budget AGENTS.md 165; budget INSTALL.md 230
budget skills/hpc-run/SKILL.md 60; budget skills/ws-run/SKILL.md 60; budget bin/run-watch 700
budget skills/hpc-run/references/experiment-conventions.md 134;   # +4: the run-watch exception (§3, §6, §7)
budget skills/hpc-run/references/project-setup.md 100
for d in hpc-run ws-run; do [ -d "$RS_HOME/$d" ] && bad "legacy $d/ tree removed" || ok "legacy $d/ tree removed"; done
