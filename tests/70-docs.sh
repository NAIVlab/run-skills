#!/usr/bin/env bash
# tests/70-docs.sh — phase A: the shipped docs/skills are consistent with the code: SKILL.md descriptions short
# and angle-bracket free, committed INDEX.md stubs byte-equal to rs_gen_index output, every shipped target has
# its files, forbidden private words absent, header comments and line budgets kept.  bash tests/70-docs.sh
set -u
. "$RS_HOME/tests/lib.sh"
C() { ( . "$RS_HOME/lib/common.sh"; eval "$1" ) 2>&1; }

if [ ! -d "$RS_HOME/skills" ] || [ "${RS_PACKAGED:-0}" = 1 ]; then   # installed copy (rsk's wheel keeps no symlinks): clone-only
  echo "-- docs: skipped ($RS_HOME is an installed copy — run selftest from the git clone for the doc checks) --"; return 0 2>/dev/null || exit 0
fi
echo "-- skill --"
SK=skills/remote-run; F=$SK/SKILL.md; PSL=$SK/references/procedure-slurm.md; PNO=$SK/references/procedure-nohup.md
IDX=$SK/references/INDEX.md; CKF=$SK/references/conf-keys.md
[ "$(ls "$RS_HOME/skills")" = remote-run ] && ok "one skill ships: remote-run" || bad "one skill ships: remote-run (got: $(ls "$RS_HOME/skills" | tr '\n' ' '))"
[ "$(ls "$RS_HOME/codex")" = remote-run.openai.yaml ] && ok "codex/remote-run.openai.yaml (and nothing else)" || bad "codex/remote-run.openai.yaml (and nothing else)"
S=$(cat "$RS_HOME/$F" 2>/dev/null); ST=$(tr '\n' ' ' < "$RS_HOME/$F" 2>/dev/null | tr -s ' ')   # wrapped lines joined, one space
d=$(grep -m1 '^description:' "$RS_HOME/$F"); n=${#d}
# install.sh prepends every target's T_TRIGGERS and the result must stay < 1024: keep >= ~150 chars of room for them
[ "$n" -gt 20 ] && [ "$n" -lt 870 ] && ok "description present, < 870 chars ($n; room for T_TRIGGERS)" || bad "description present, < 870 chars ($n)"
hasnt "$d" '[<>]' "description has no < >"
for w in 'Run, submit, launch' monitor 'stop or cancel' Slurm '\.hpc\.conf' '\.ws\.conf' 'GPU workstations' sbatch nohup HPC \
         partition workstation 'GPU server' 'the box' 'job status' logs 'results copied back' 'Replaces the hpc-run and ws-run skills'; do
  has "$d" "$w" "description keeps the trigger vocabulary of both replaced skills: $w"; done
has "$S" '^name: remote-run$' "frontmatter name"; has "$S" '^allowed-tools: Bash, Read, Write, Edit$' "allowed-tools"
has "$S" 'references/INDEX.md' "body points at references/INDEX.md"
for r in INDEX.md conf-keys.md experiment-conventions.md project-setup.md procedure-slurm.md procedure-nohup.md; do
  [ -f "$RS_HOME/$SK/references/$r" ] && [ ! -L "$RS_HOME/$SK/references/$r" ] && ok "references/$r (one copy, no symlink)" || bad "references/$r (one copy, no symlink)"; done
hasnt "$(grep -rn 'hpc-run\|ws-run' "$RS_HOME/$SK" | grep -v ':[0-9]*:description: ')" . "the skill names the replaced skills only in its description"
for k in slurm nohup; do has "$S" "\`$k\`" "SKILL.md: INDEX kind $k explained"; done
has "$ST" 'procedure-slurm\.md' "SKILL.md routes Slurm to procedure-slurm.md"; has "$ST" 'procedure-nohup\.md' "SKILL.md routes workstations to procedure-nohup.md"
E=$(cat "$RS_HOME/$SK/references/experiment-conventions.md" 2>/dev/null)
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
for f in $F $PSL $PNO; do
  has "$(cat "$RS_HOME/$f")" 'summary of' "$f: a summary of the reference is not the reference"; has "$(cat "$RS_HOME/$f")" 'ref: <' "$f: the plan cites the reference"; done
has "$S" 'wake-up mechanism' "$F rail: state the wake-up mechanism"
for f in $PSL $PNO; do
  has "$(cat "$RS_HOME/$f")" 'resume=unverified' "$f: ckpt_entry is not proof of resume"; has "$(cat "$RS_HOME/$f")" 'Never read a log unbounded' "$f: byte-bounded reads rail"
  has "$(cat "$RS_HOME/$f")" 'hints, not diagnoses' "$f: the digest's counts are hints, so 0 is not 'no errors'"
  has "$(cat "$RS_HOME/$f")" 'the deploy predates it' "$f: what to do when the digest is not deployed yet"
  has "$(cat "$RS_HOME/$f")" 'rsk logs -T <t>' "$f: the digest is also one rsk logs away"
done
for f in $F $PSL $PNO; do
  hasnt "$(cat "$RS_HOME/$f")" 'tail -f' "$f keeps monitoring examples byte-bounded"
  hasnt "$(cat "$RS_HOME/$f")" 'tail -n [0-9]' "$f never tells the agent to read a log unbounded"
  has "$(cat "$RS_HOME/$f")" 'status\.sh' "$f monitors through the bounded status digest"
  has "$(cat "$RS_HOME/$f")" 'experiment-conventions' "$f points at experiment-conventions.md"
done
PS=$(cat "$RS_HOME/$SK/references/project-setup.md" 2>/dev/null)
has "$S" 'references/project-setup.md' "$F: a project without a conf goes through project-setup.md"
has "$S" 'INSTALL.md' "$F: registering a target points at INSTALL.md"
has "$ST" '_template-slurm/` or `$ROOT/targets/_template-nohup/' "$F: a new target starts from the template of its kind"
has "$ST" 'installed without rsk: re-run `bash ~/.local/share/run-skills/install.sh`' "$F: registering without rsk re-runs install.sh"
has "$ST" 'never guess them' "$F: never guess REMOTE_DIR / WS_REMOTE_DIR"
echo "-- the rails of both replaced skills, all in remote-run --"
for r in 'Confirm before every submit or launch' 'never `scancel` any job — the user.s or anyone else.s — without an explicit OK' \
         'never launch onto a GPU another job is using' 'never `kill` a running process, without an explicit OK' \
         'Auto-pick takes the \*idlest\* GPUs, not necessarily free ones' 'use `-d` when the pick would land on a busy card' \
         'partition and QOS are `submit.sh`.s decision' 'no raw `sbatch`/`srun`/`salloc`, no `scontrol update`' \
         'no `--partition` inside `SBATCH_EXTRA`' 'A policy refusal (exit 3) is final' '`-y` also confirms policy warnings' \
         'user.s own key\*\* (the deployed `.wandb_env`)' 'no key → offline' 'Never `wandb login` on a cluster' \
         'Never create a conda env: if `ENV_NAME` is missing on the target, stop and ask' 'scaffold new `.ws.conf` files as uv unless the user asks for conda' \
         'stays under the project.s remote dir' 'Files cross the wire only through `run-sync` (up) and `run-pull` (back)' \
         'Never hand-roll `rsync`/`scp`/`sftp`' 'Slurm jobs go out with `--requeue`' 'confirm before a long submit' \
         'nothing restarts a nohup run after a crash or reboot' 'Smoke tests always run `WANDB_MODE=disabled`' \
         'widen review intervals only with evidence' 'state the wake-up mechanism' 'keep log reads byte-bounded' \
         'Report every finding promptly' 'Detect-only' 'stopping, killing or resubmitting a run is the user.s call' \
         'on workstations `run-watch` only detects'; do
  has "$ST" "$r" "rail: $r"; done
has "$ST" 'One exception, Slurm only: `run-watch --act` first-submits or resubmits only table rows the user approved' "rail: the one detect-only exception, user-approved rows only"
hasnt "$S" 'only clears availability' "rail: -y also confirms policy warnings (not just availability)"
echo "-- rsk, the read-only observation path, as the CLI defines it --"
CLI=$(cat "$RS_HOME"/src/remote_run/*.py 2>/dev/null)
for c in status logs exec doctor update; do has "$S" "rsk $c" "$F names rsk $c"; has "$CLI" "add_parser(\"$c\"" "rsk $c is a real subcommand"; done
has "$ST" 'UNOBSERVABLE = unknown, never "none"' "$F: a target that does not answer is unknown, never 'none'"
has "$CLI" 'UNOBSERVABLE' "...and rsk status says UNOBSERVABLE"
for o in '\[-T <t>\]\.\.\. \[--days N\]' 'rsk logs -T <t> <jobid|log> \[<ckpt-dir>\] \[-n 40\]' 'rsk exec -T <t> -- <cmd>'; do has "$S" "$o" "$F rsk usage: $o"; done
for o in '"--days"' '"-n", dest="lines"' '"-T", "--target", required=True' 'UNKNOWN = 5' 'FAILED = 1' 'USAGE = 2'; do
  has "$CLI" "$o" "the CLI has what $F promises: $o"; done
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
# every harness path the runbook, skills and docs name ($H/…, $ROOT/…, ~/.agents/run-skills/…) is under a top-level entry
# install.sh copies there: a later session has the harness copy, not necessarily a clone
SHIP=$(sed -n '/^rsync -a --delete "$RS_HOME\/bin"/,/"$DEST\/"/p' "$RS_HOME/install.sh" | grep -o '"$RS_HOME/[^"]*"' | sed 's/^"$RS_HOME\///; s/"$//')
miss=""; for p in $(cat "$RS_HOME/INSTALL.md" "$RS_HOME/README.md" "$RS_HOME"/docs/*.md "$RS_HOME"/skills/*/SKILL.md "$RS_HOME"/skills/*/references/*.md \
  | grep -o -e '\$H/[A-Za-z0-9_./-]*' -e '\$ROOT/[A-Za-z0-9_./-]*' -e '~/\.agents/run-skills/[A-Za-z0-9_./-]*' | sort -u); do
  r=${p#*run-skills/}; r=${r#\$H/}; r=${r#\$ROOT/}; [ -z "$r" ] || echo "$SHIP" | grep -qx "${r%%/*}" || miss="$miss $p"; done
echo "$SHIP" | grep -qx bin && [ -z "$miss" ] && ok "every harness path the docs name is shipped by install.sh ($(echo $SHIP))" \
  || bad "every harness path the docs name is shipped by install.sh ($(echo $SHIP)); missing:$miss"
hasnt "$I" '\$E/' "INSTALL: no \$E/ paths (the engine clone is not guaranteed; \$H is)"
has "$I" 'uv tool dir --bin' "INSTALL: rsk is found when uv's tool bin dir is off PATH"
has "$I" 'Installed without rsk' "INSTALL Step 6: a setup without rsk re-runs install.sh"
has "$I" '^- updating: `rsk update`' "INSTALL Step 7: updating is rsk update (re-running uv tool install is a no-op)"
has "$(cat "$RS_HOME/README.md")" '`rsk update --to main` follows main' "README: --to pins, --to main follows main again"
has "$S" 'run-sync' "$F names run-sync"; has "$S" 'run-bootstrap' "$F names run-bootstrap"; has "$S" 'run-launch' "$F names run-launch"
has "$S" 'submit\.sh' "$F names submit.sh"
for f in $F $PSL $PNO; do
  has "$(cat "$RS_HOME/$f")" 'run-pull' "$f: results come back through run-pull"
  has "$(cat "$RS_HOME/$f")" 'hand-roll' "$f rail: files move only through run-sync / run-pull"
done
for f in $F $IDX $PSL $PNO; do
  has "$(cat "$RS_HOME/$f")" 'run-avail' "$f: an open placement starts with run-avail"; done
has "$(cat "$RS_HOME/$IDX")" 'The user fixed it' "INDEX: a fixed placement is used as given (no fleet check)"
for f in $F $PSL $PNO; do
  has "$(cat "$RS_HOME/$f")" 'run-watch' "$f: many jobs or long waits go through run-watch"
  hasnt "$(cat "$RS_HOME/$f")" 'Monitor(\|/loop\|CronCreate\|ScheduleWakeup\|run_in_background' "$f names no runtime-specific waiting tool"; done
for f in $PSL $PNO; do
  has "$(tr '\n' ' ' < "$RS_HOME/$f")" 'Never  *detach it (no `nohup`, `setsid`, cron)' "$f: run-watch stays owned by the session"; done
has "$(tr '\n' ' ' < "$RS_HOME/$PSL")" 'only after their explicit OK run `run-watch <table> --approve' "procedure-slurm: --approve only after the user's OK"
has "$E" 'sole exception: `run-watch --act`' "conventions: detect-only names its one exception"
CK=$(cat "$RS_HOME/$CKF" 2>/dev/null)
has "$CK" 'T_XFER_HOST.*profile' "conf-keys: the transfer host is a profile fact"
hasnt "$CK" '^| `XFER_HOST`' "conf-keys: no XFER_HOST conf key (one per conf would misroute other targets)"
for h in '^## Keys of both confs$' '^## `.hpc.conf` only (kind `slurm`)$' '^## `.ws.conf` only (kind `nohup`)$'; do has "$CK" "$h" "conf-keys section: $h"; done
# every key of both confs survives the merge: the prefixable lists the code reads, plus the generic-only keys (AGENTS.md)
for k in $(C 'echo $RS_PREFIXABLE_SLURM $RS_PREFIXABLE_NOHUP' | tr ' ' '\n' | sort -u) ENV_KIND ENV_HOOK BOOTSTRAP_HOOK UV_SYNC_ARGS \
         WANDB_MODE EXTRA_EXCLUDES SYNC_ALSO REMOTE_HOST DEFAULT_CLUSTER DEFAULT_STATION WS_REMOTE_DIR; do
  [ "$(printf '%s\n' "$CK" | grep -c "^| \`$k\` |")" = 1 ] && ok "conf-keys: one row for $k" || bad "conf-keys: one row for $k"; done
for t in _template-slurm _template-nohup; do has "$(cat "$RS_HOME/targets/$t/profile.sh")" '^T_XFER_HOST=' "$t profile documents T_XFER_HOST"; done

echo "-- INDEX stub == rs_gen_index (no overlay, root placeholder) --"
RS_USER_DIR=/nonexistent RS_PACKS_DIR=/nonexistent C "rs_gen_index '$T/idx.md' '~/.agents/run-skills'" >/dev/null
if cmp -s "$T/idx.md" "$RS_HOME/$IDX"; then ok "$IDX matches rs_gen_index"
else bad "$IDX matches rs_gen_index"; diff "$T/idx.md" "$RS_HOME/$IDX" | head -12 | sed 's/^/    | /'; fi
has "$(cat "$T/idx.md")" '^## Routing' "INDEX carries a Routing section"
has "$(cat "$T/idx.md")" '^| target | kind | ' "INDEX: one table, a kind column"

echo "-- shipped targets --"
SHIPPED=$(RS_USER_DIR=/nonexistent RS_PACKS_DIR=/nonexistent C 'rs_targets')
[ -z "$SHIPPED" ] && ok "no site target ships in the engine (sites live in packs / the overlay)" || bad "no site target ships in the engine: $SHIPPED"
for t in $SHIPPED; do
  for f in profile.sh reference.md tests.sh; do [ -f "$RS_HOME/targets/$t/$f" ] && ok "targets/$t/$f" || bad "targets/$t/$f"; done
  K=$(RS_USER_DIR=/nonexistent RS_PACKS_DIR=/nonexistent C "rs_load_target $t; echo \$T_KIND")
  [ "$K" = slurm ] && { [ -f "$RS_HOME/targets/$t/policy.sh" ] && ok "targets/$t/policy.sh" || bad "targets/$t/policy.sh"; }
  has "$(cat "$T/idx.md")" "^| $t | $K | " "INDEX row for $t"
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
    if git -C "$RS_HOME" rev-parse --is-inside-work-tree >/dev/null 2>&1; then   # every tracked or new (not ignored) file
      FW=$(cd "$RS_HOME" && git grep --untracked -Ili -E -e "$PW" 2>/dev/null); RC=$?
    else
      FW=$(cd "$RS_HOME" && grep -rIli -E -e "$PW" -- . 2>/dev/null); RC=$?
    fi
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
budget lib/common.sh 141; budget remote/env.sh 170; budget remote/bootstrap.sh 100; budget remote/submit.sh 265; budget remote/job.sbatch 70   # common +3: rs_ref, rs_deploy_profile; +8: rs_legacy_routing (a legacy rule keeps its kind)
# P2 (the attempt journal): submit.sh +75 (claim/replay, the body in a subshell, child-shell conf, duplicate guard, lint, receipt); bootstrap.sh +10, job.sbatch +5 (snapshots)
budget remote/status.sh 175   # generous on purpose: every lookup has an explicit failure branch; compressing them hides bugs
budget tests/lib.sh 130; budget selftest.sh 65; budget install.sh 130; budget README.md 240; budget AGENTS.md 192; budget INSTALL.md 232 # AGENTS +10: rsk, +1: the hpc-run/ws-run uninstall, +16: the attempt journal; INSTALL +2: which rsk, setup without rsk
budget skills/remote-run/SKILL.md 95; budget bin/run-watch 700   # one entry for both kinds (the two it replaced: 62 + 61) + the rsk reads
budget skills/remote-run/references/experiment-conventions.md 135;   # +4: the run-watch exception (§3, §6, §7); +1: a USR1 death is FAILED
budget skills/remote-run/references/project-setup.md 100
for d in hpc-run ws-run; do [ -e "$RS_HOME/$d" ] || [ -e "$RS_HOME/skills/$d" ] && bad "legacy $d/ trees removed" || ok "legacy $d/ trees removed"; done
