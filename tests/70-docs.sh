#!/usr/bin/env bash
# tests/70-docs.sh — phase A: the shipped docs/skills are consistent with the code: SKILL.md descriptions short
# and angle-bracket free, committed INDEX.md stubs byte-equal to rs_gen_index output, every shipped target has
# its files, forbidden private words absent, header comments and line budgets kept; the rails, including the user's
# authorisation policy (check first, ask only outside it), cannot be trimmed.  bash tests/70-docs.sh
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
# P3-P7: "confirm before every submit/launch, never scancel/kill without an OK" became the user's policy:
# check the existing authorisation first, ask only outside it (docs/DESIGN.md "Authorization"); the other rails stay
for r in 'Check the existing authorisation before every submit, launch or cancel; ask only outside it' \
         'never launch onto a GPU another job is using without the user.s words naming it' \
         'auto-pick takes the idlest GPUs with no compute process; read the card.s busy line' \
         'Cancel only after the identity check (`rsk cancel`)' \
         'partition and QOS are `submit.sh`.s decision' 'no raw `sbatch`/`srun`/`salloc`, no `scontrol update`' \
         'no `--partition` inside `SBATCH_EXTRA`' 'A policy refusal (exit 3) is final' '`-y` also confirms policy warnings' \
         'user.s own key\*\* (the deployed `.wandb_env`)' 'no key → offline' 'Never `wandb login` on a cluster' \
         'Never create a conda env: if `ENV_NAME` is missing on the target, stop and ask' 'scaffold new `.ws.conf` files as uv unless the user asks for conda' \
         'stays under the project.s remote dir' 'Files cross the wire only through `run-sync` (up) and `run-pull` (back)' \
         'Never hand-roll `rsync`/`scp`/`sftp`' 'Slurm jobs go out with `--requeue`' 'check it before a long submit' \
         'nothing restarts a nohup run after a crash or reboot' 'Smoke tests always run `WANDB_MODE=disabled`' \
         'widen review intervals only with evidence' 'state the wake-up mechanism' 'keep log reads byte-bounded' \
         'Report every finding promptly' 'Detect-only' 'stopping, killing or resubmitting a run is the user.s call' \
         'on workstations `run-watch` only detects'; do
  has "$ST" "$r" "rail: $r"; done
has "$ST" 'except what they authorised and a tool checks: `run-watch --act` (Slurm) first-submits or resubmits only table rows the user approved' \
  "rail: detect-only exception 1: run-watch --act, user-approved rows only"
has "$ST" '`rsk cancel` / `rsk launch --relaunch` under a grant that covers them' "rail: detect-only exception 2: an rsk action a grant covers"
# round 3 (D3): -y goes out only for warnings the approved card showed or the covering grant's allow_warnings kind covers
has "$ST" 'rsk sends it only when the approved card showed warnings or the covering grant.s kind covers the plan.s warnings' "rail: -y only for warnings an approved card showed or a grant's kind covers"
hasnt "$ST" 'rsk adds it only to a card the user approved' "rail: the pre-D3 -y wording (no grant kinds) is gone"
hasnt "$S" 'only clears availability' "rail: -y also confirms policy warnings (not just availability)"
echo "-- the user's authorisation policy: check first, ask only outside it --"
for r in 'check for an existing authorisation first' 'act when it covers the action, ask only when it does not' \
         'exactly the scope and limits they stated (`none` where they set none; unclear → ask)' 'Never invent a grant, never widen one' \
         'a deny always wins' 'A sweep they approved shares one approval, never one question each' \
         'Preemption recovery they authorised runs within its budget' '"Stop the rest of the group if one fails" = `#@ allow … fail-stop`' \
         'Ask first: a charged partition, more resources or a wider scope than authorised' \
         'never grant-covered unless their words allowed it (`--allow-warnings availability` = only the harness.s availability gate' \
         '`any` = every -y gate, a charged partition.s too — only when their words say so' \
         'only after an infrastructure end — Slurm PREEMPTED / NODE_FAIL / BOOT_FAIL, box REBOOT; never CANCELLED, COMPLETED, FAILED, TIMEOUT, OUT_OF_MEMORY or unknown' \
         'The action is the plan.s, never a flag.s: a run that ran before = `relaunch`, a singleton chain = `chain`' \
         'the approval is bound to it, lasts 1 h and is used up by its first cancel, whatever came of it' \
         'its cancels count against `--max-launches`' \
         '(`rsk watch --act` first refuses rows a deny of theirs matches)' \
         '`plan <id> is free again` = the target proved nothing went out' \
         'cancelled once its identity checks out (Slurm: name, WorkDir, user; box: pid, start time, boot id)' \
         'Your own judgment that a run should stop → ask, unless the user authorised that kind of decision (`cancel_own`' \
         'Never someone else.s job or process, whatever was approved' 'Only the user.s words at the time, never a grant' \
         'A grant records the user.s words; it is bookkeeping, not proof of consent' 'constrains only what goes through it' \
         'Record only what the user said' 'show the card verbatim, wait for the user.s words' 'say so in your report' \
         'Exit 5 after a submit = SUBMIT_UNKNOWN, never resubmitted' \
         'The flow: `rsk status` → `rsk avail` (placement open) → `rsk sync` / `rsk bootstrap` → `rsk launch` → monitor (`rsk status`, `rsk logs`, `rsk watch`) → `rsk cancel` → `rsk pull`'; do
  has "$ST" "$r" "authorisation rail: $r"; done
for r in 'Confirm before every submit' 'without an explicit OK'; do
  hasnt "$ST" "$r" "the replaced rail is gone from $F (it contradicts the user's policy): $r"; done
for f in $PSL $PNO; do X=$(tr '\n' ' ' < "$RS_HOME/$f" | tr -s ' ')   # wrapped lines joined
  has "$X" 'plans first and checks whether the user.s recorded words already cover that plan' "$f: plan, then check the authorisation"
  has "$X" 'show its card verbatim' "$f: an uncovered card is shown verbatim"; has "$X" 'rsk cancel <run>' "$f: stopping goes through rsk cancel"
  has "$X" 'on a `cancel_own` grant (runs rsk launched only); else exit 4: ask' "$f: the agent's own stop needs cancel_own"
  has "$X" 'Check the user.s recorded words before every' "$f rail: check the recorded words first"
  hasnt "$X" 'Confirm before every' "$f: the replaced confirm-every-time rail is gone"; done
PSLT=$(tr '\n' ' ' < "$RS_HOME/$PSL" | tr -s ' '); PNOT=$(tr '\n' ' ' < "$RS_HOME/$PNO" | tr -s ' ')
has "$PSLT" 'first checks the job.s name, user and WorkDir (exit 6 = mismatch, nothing cancelled; exit 3 = someone else.s job: never)' "procedure-slurm: cancel after the identity check"
has "$PSLT" 'Never submit on implicit consent' "procedure-slurm: never on implicit consent"
has "$PSLT" 'A charged partition, more resources or a wider scope than the user authorised always goes back to them' "procedure-slurm: the §U ask-cases"
has "$PSLT" 'no grant covers it' "procedure-slurm: a --*-user-asked gate is never a grant's call"
has "$PNOT" 'checks the pid against the run.s receipt (pid, process start time, boot id, your user, the group leader)' "procedure-nohup: cancel after the identity check"
has "$PNOT" 'someone else.s process: never' "procedure-nohup: never someone else's process"
has "$PNOT" 'a card that lands on one (`ON A BUSY GPU`) is never grant-covered' "procedure-nohup: a busy GPU is the user's words, never a grant"
has "$PNOT" 'use: rsk launch -T <t>' "procedure-nohup: run-launch points at rsk launch (P7)"; has "$(cat "$RS_HOME/bin/run-launch")" 'use: rsk launch -T ' "...and bin/run-launch prints it"
has "$PNOT" 'That steers; it is not a guard' "procedure-nohup: the P7 redirect is a nudge, not a guard"
SUB=$(cat "$RS_HOME/remote/submit.sh"); LSH=$(cat "$RS_HOME/remote/launch.sh"); RL=$(cat "$RS_HOME/bin/run-launch"); CK=$(cat "$RS_HOME/$CKF" 2>/dev/null)
# round 3 (D3/D9): --rs-warnings carries the card's warnings_id (which warnings, not how many); api=3 is the marker line
for f in "$PSLT" "$PNOT"; do has "$f" '--rs-warnings <warnings_id>' "a procedure: --rs-warnings carries the card's warnings_id"
  hasnt "$f" '--rs-warnings N\|the card.s count' "...never a count any more"
  has "$f" 'warnings_avail=' "a procedure: the plan block's warnings_avail"; has "$f" '`changed: <keys>`' "a procedure: a refused --rs-expect names what changed"; done
has "$SUB" '0:--rs-warnings)' "...and submit.sh pre-scans it"; has "$LSH" '--rs-warnings)' "...launch.sh too"
has "$SUB" 'warnings_id=%s' "...submit.sh prints warnings_id"; has "$LSH" 'warnings_id=%s' "...launch.sh too"; has "$SUB" 'echo "changed: $k"' "...and submit.sh says changed:"
has "$PSLT" 'the line `# rs-api=3` inside the deployed `.<t>/submit.sh`' "procedure-slurm: api=3 is the marker line in submit.sh"
has "$PNOT" 'the line `# rs-api=3` inside the deployed `.ws/launch.sh`' "procedure-nohup: api=3 is the marker line in launch.sh"
has "$SUB" '^# rs-api=3$' "...submit.sh carries it"; has "$LSH" '^# rs-api=3$' "...launch.sh carries it"
has "$RL" 'does not speak rs-api=3' "...run-launch checks it"; has "$PNOT" '`does not speak rs-api=3`' "procedure-nohup: run-launch's refusal of an older launch.sh"
hasnt "$PSLT$PNOT" 'the deployed `\.<t>/API`\|the deployed `\.ws/API`' "the procedures no longer name the API file as the protocol marker"
# D2: no time limit of none; EVERY --time/-t sbatch could read is held to MaxTime
has "$PSLT" 'EVERY `--time`/`-t` sbatch could read in the policy.s or `SBATCH_EXTRA`.s words, which sbatch takes over `-t`' "procedure-slurm: every --time sbatch could read is held to MaxTime"
has "$PSLT" 'a time limit that is no limit — 0 in any spelling, `UNLIMITED`, `INFINITE`, `-1` (exit 2, `give an explicit limit ≤ MaxTime`)' "procedure-slurm: a limit of none is refused"
has "$SUB" 'give an explicit limit' "...and submit.sh says so"; has "$CK" '`UNLIMITED`, `INFINITE`, `-1`' "conf-keys: DEFAULT_TIME of none is refused"
# D3: the policy probe
has "$PSLT" 'it first probes `( FORCE=0; t_policy )` in a subshell' "procedure-slurm: the policy is probed as a submit without -y"
has "$SUB" '( FORCE=0; t_policy )' "...and submit.sh does"; has "$(cat "$RS_HOME/targets/_template-slurm/policy.sh")" 'must have no side effects' "policy template: t_policy may run twice"
has "$(cat "$RS_HOME/docs/packs.md")" 'may run twice and must have no side effects' "packs.md: t_policy may run twice"
# D10: a nohup plan checks the env gate read-only (no card when the launch's gate would refuse)
hasnt "$PNOT" 'except the env gate' "procedure-nohup: the plan no longer skips the env gate"
has "$PNOT" 'checks the env gate read-only' "procedure-nohup: a plan checks the env gate read-only"
has "$PNOT" 'exiting 1 with no card when the launch.s gate would refuse; it creates nothing outside `.rs/`' "procedure-nohup: ...exit 1, no card, nothing created"
has "$LSH" 'rs_envcheck' "...and launch.sh's plan runs that check"
# D4: busy_ok binds the occupants
has "$PNOT" '`busy_ok=<id>:<uuid>:<user>,…`' "procedure-nohup: busy_ok binds who is on each accepted GPU"; has "$LSH" 'busy_ok=%s' "...launch.sh binds it"
# r1-7: a reused / gone pid or a rebooted box = ended (exit 0), never the old 'exit 6 = a reused pid'
has "$PNOT" 'reused by another process (its start time differs) or whose box rebooted (boot id differs) has ended: exit 0 `nothing to cancel … ended`' "procedure-nohup: a reused pid is an ended run (exit 0)"
hasnt "$PNOT" '(a reused pid), nothing signalled' "procedure-nohup: the wrong 'exit 6 = a reused pid' is gone"
# D6: cancel approvals bound, 1 h, used up
has "$PSLT" 'expires after 1 h and is used up by its first cancel that passed the authorisation check, whatever came of it (no refund)' "procedure-slurm: a cancel approval is bound, 1 h, used up"
has "$PNOT" 'an approval bound to its identity (target, pid, start, boot id), for 1 h, used up by its first cancel' "procedure-nohup: the same, by pid identity"
# D7 / r1-8: sync -D read with run-sync's grammar; bootstrap --job only with the user's words at the time
for f in "$PSLT" "$PNOT"; do has "$f" '`--also -n` pushes a path named `-n`, it is no dry run' "a procedure: rsk sync -D's gate reads run-sync's grammar"; done
has "$PSLT" 'runs only with the user.s words at the time — `rsk bootstrap -T <t> --job … --approve' "procedure-slurm: bootstrap --job is --approve-only"
has "$PSLT" 'never under a grant; then follow it' "procedure-slurm: ...never a grant's call"; hasnt "$PSLT" 'or their words covering it, §3' "procedure-slurm: the old 'a grant may cover bootstrap --job' is gone"
# D1: SBATCH_EXTRA vs grants; the getopt refusal
has "$PSLT" 'a `NO GRANT` line names those outside the grant allowlist' "procedure-slurm: the card's NO GRANT line"
hasnt "$PSLT$ST" '`RESOURCES`\|RESOURCES (SBATCH_EXTRA)' "the old RESOURCES card line is gone from the docs"
has "$CK" 'Every word must be an option or the value of the option before it' "conf-keys: SBATCH_EXTRA's getopt rule"
has "$CK" '`T_SBATCH_EXTRA_ALLOW` extends only the lint, never what a grant covers' "conf-keys: the lint allowlist is not the grant allowlist"
hasnt "$CK" 'trailing `-q/--qos` without a value' "conf-keys: any dangling value option is refused now, not only -q"
echo "-- rsk (reads, launch / cancel / watch, grants), as the CLI defines it --"
CLI=$(cat "$RS_HOME"/src/remote_run/*.py 2>/dev/null)
for c in status logs exec doctor update launch cancel watch grant; do has "$S" "rsk $c" "$F names rsk $c"; has "$CLI" "add_parser(\"$c\"" "rsk $c is a real subcommand"; done
for c in sync bootstrap pull avail; do has "$S" "rsk $c" "$F names rsk $c"; has "$CLI" "\"$c\": \"run-$c\"" "rsk $c wraps bin/run-$c"; done
has "$ST" 'UNOBSERVABLE = unknown, never "none"' "$F: a target that does not answer is unknown, never 'none'"
has "$CLI" 'UNOBSERVABLE' "...and rsk status says UNOBSERVABLE"
for o in '\[-T <t>\]\.\.\. \[--days N\]' 'rsk logs -T <t> <jobid|log> \[<ckpt-dir>\] \[-n 40\]' 'rsk exec -T <t> -- <cmd>'; do has "$S" "$o" "$F rsk usage: $o"; done
for o in '"--days"' '"-n", dest="lines"' '"-T", "--target", required=True' 'UNKNOWN = 5' 'FAILED = 1' 'USAGE = 2' 'REFUSED = 3' \
         'NEEDS_USER = 4' 'CONFLICT = 6' 'PLACEMENT = 8' '"--plan", dest="plans", action="append"' '"--approve"' '"--relaunch"' '"--chain"' \
         '"--max-live", required=True' '"--max-launches", required=True' '"--expires", required=True' '"--allow-warnings"' \
         'needs user: approval — plan ' 'covered by {d.record' '"--gpu-busy-ok"'; do
  has "$CLI" "$o" "the CLI has what $F promises: $o"; done
# round 3: what the docs now promise, as the code spells it (a code change that moves one of these must move the docs)
for o in 'WARN_KINDS = ("availability", "any")' 'choices=WARN_KINDS' 'INFRA_END = ("PREEMPTED", "NODE_FAIL", "BOOT_FAIL", "REBOOT")' \
         'CANCEL_TTL_S = 3600' 'EXTRA_VALUE_LONG = ("qos", "account", "exclude", "constraint", "reservation", "signal", "mail-type", "mail-user", "comment")' \
         'EXTRA_VALUE_SHORT = "qAxC"' 'EXTRA_FLAGS = ("requeue", "no-requeue")' 'is free again: once the cause is fixed' 'revoked: matches nothing' \
         'jobs used ' 'the cancel may have been sent: rsk status' 'nothing to cancel: ' 'of them the availability gate' \
         '("conf extra",' 'NO GRANT   SBATCH_EXTRA word(s)' 'an SBATCH_EXTRA / policy --time comes after' 'ledger not updated (read-only view)' \
         'run-watch lock: pid' 'def plan_actions(' 'def sticky_class('; do
  has "$CLI" "$o" "the CLI has what the docs promise (round 3): $o"; done
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
RT=$(tr '\n' ' ' < "$RS_HOME/README.md" | tr -s ' ')
has "$RT" 'Check your existing authorisation before every submit, launch or cancel; ask only outside it' "README rail: check first, ask only outside it"
has "$RT" 'it is bookkeeping, not proof that you agreed, and it cannot make an agent comply' "README: the honest limit of a record"
hasnt "$RT" 'Confirm before every submit' "README: the replaced confirm-every-time rail is gone"
DT=$(tr '\n' ' ' < "$RS_HOME/docs/DESIGN.md" | tr -s ' ')
has "$(cat "$RS_HOME/docs/DESIGN.md")" '^## Authorization: check first, ask only outside scope$' "DESIGN: the authorization section"
for r in '| the user approved a sweep | the whole set shares one approval' '| a charged partition, more resources, or a wider experiment scope | confirm |' \
         '| the user said "cancel job 123" | cancel once the job.s identity is verified |' \
         '| the agent decides on its own that a run is not worth continuing | confirm — unless the user authorised that kind of judgment |' \
         'is bookkeeping, not proof of consent' 'an agent can write anything' 'rsk constrains only the actions that go through it' \
         'Nothing here guarantees that an agent complies' 'Both steer; neither is a guard'; do has "$DT" "$r" "DESIGN: $r"; done
has "$(tr '\n' ' ' < "$RS_HOME/AGENTS.md" | tr -s ' ')" 'check the existing authorisation before every submit/launch/cancel and ask only outside it' "AGENTS: the editing rule names the new rail"
# round 3: README / DESIGN / AGENTS say what the code now does
for r in 'rsk sends it only when the approved card showed warnings or the covering grant.s kind covers the plan.s warnings' \
         'a resume only after an infrastructure end' '`rsk watch --act` first checks every row against your "never"s'; do has "$RT" "$r" "README: $r"; done
hasnt "$RT" 'rsk adds it only to a card you approved' "README: the pre-D3 -y wording is gone"
for r in 'rsk sends `-y` only when the approved card showed warnings or the covering grant.s kind covers the plan.s warnings' \
         '`availability` covers a plan whose only warnings are the harness.s own availability gate' \
         'A `relaunch` grant covers a relaunch only after the run.s latest attempt that ran ended with positive evidence of an infrastructure end' \
         'it expires after an hour and is used up by the first cancel that passed authorisation' \
         'binds run-watch to the user.s denies' 'No remote parsing goes through a here-string or a heredoc' \
         'the line `# rs-api=3` inside the deployed `submit.sh` / `launch.sh`' 'Fail-stop goes with the rows, and cancels only under `--act`'; do
  has "$DT" "$r" "DESIGN: $r"; done
for r in '`rsk watch` only adds the lease' 'on a workstation not the env gate'; do hasnt "$DT" "$r" "DESIGN: the outdated '$r' is gone"; done
AT=$(tr '\n' ' ' < "$RS_HOME/AGENTS.md" | tr -s ' ')
for r in 'last_attempt fulltmp fulltmp_ok' 'Remote parsing uses no here-string or heredoc' 'so both may run twice and must have no side effects' \
         'api=3\*\* = the line `# rs-api=3` inside the deployed `submit.sh` / `launch.sh`' '`allow_warnings` = `availability`' \
         'a relaunch whose latest attempt that ran did not end in `INFRA_END`'; do has "$AT" "$r" "AGENTS: $r"; done
has "$(cat "$RS_HOME/tests/lib.sh")" '^fulltmp(){' "...tests/lib.sh defines fulltmp"; has "$(cat "$RS_HOME/tests/lib.sh")" '^fulltmp_ok(){' "...and fulltmp_ok"
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
has "$(tr '\n' ' ' < "$RS_HOME/$PSL")" 'only after their explicit OK run `rsk watch <table> --approve' "procedure-slurm: --approve only after the user's OK (through rsk watch: R4-7)"
RW=$(cat "$RS_HOME/bin/run-watch")
for r in 'only by an `--act` run and only while the table.s approved `#@ allow` still has `fail-stop` @@ fail-stop-not-cancelled' \
         'reports `fail-stop-not-cancelled why=no-act` @@ why=no-act' 'drops those pending cancels (`NOTE … fail-stop-pending-dropped`) @@ fail-stop-pending-dropped' \
         'reason=fail-stop-inherited`) and inherits the rows. pending cancels @@ reason=fail-stop-inherited' '`RELEASE table=… fail-stop=…` @@ RELEASE table=' \
         'its status and job ids only from a state line of the row.s own target @@ target-there=' '`NOTE … target-changed` @@ target-changed' \
         'never resubmitted on another job.s id @@ job-identity-mismatch' '(`why=submit-unknown-elsewhere`) @@ submit-unknown-elsewhere' \
         'One watcher per project: a second one refuses (exit 6) @@ # 6 another run-watch holds the project.s lock' '`0060` is 60 @@ ^dec10()'; do
  has "$PSLT" "${r%% @@ *}" "procedure-slurm run-watch: ${r%% @@ *}"; has "$RW" "${r#* @@ }" "...bin/run-watch: ${r#* @@ }"; done
has "$(cat "$RS_HOME/src/remote_run/watch.py")" '6 another watcher holds the lease' "...rsk watch's exit list has 6 too"
has "$PSLT" 'update the installed harness (`rsk update`, then `rsk setup`), never edit the line' "procedure-slurm: an older run-watch vs conf= ok lines: update, never edit"
# ...the older copies' behaviour it describes, from the history (skipped when the clone lacks those commits)
if O1=$(git -C "$RS_HOME" show 8560838:bin/run-watch 2>/dev/null) && O2=$(git -C "$RS_HOME" show 2fd4991:bin/run-watch 2>/dev/null); then
  has "$O1" "malformed '#@ ok' line (write it with --approve)" "8560838's run-watch: the message procedure-slurm quotes"
  hasnt "$(printf '%s\n' "$O1" | grep 'ok_re=')" 'conf=' "8560838's run-watch: its ok-line pattern has no conf= (refuses rsk watch --approve's lines)"
  has "$O2" '!= 17 && NF != 15) { lost = 1' "2fd4991's run-watch: a state line of another width (this one's 18) is lost"
  has "$PSLT" "malformed '#@ ok' line (write it with --approve)" "procedure-slurm quotes it"
else ok "older run-watch copies not in this clone's history: SKIP"; fi
echo "-- round 4: what the docs now promise, each beside the code that does it (docs @@ code) --"
LP=$(cat "$RS_HOME/src/remote_run/launch.py"); GP=$(cat "$RS_HOME/src/remote_run/grants.py"); CP=$(cat "$RS_HOME/src/remote_run/cancel.py")
WP=$(cat "$RS_HOME/src/remote_run/watch.py"); TPL=$(tr '\n' ' ' < "$RS_HOME/targets/_template-slurm/policy.sh" | tr -s ' ')
PKT=$(tr '\n' ' ' < "$RS_HOME/docs/packs.md" | tr -s ' '); RT=$(tr '\n' ' ' < "$RS_HOME/README.md" | tr -s ' ')
DT=$(tr '\n' ' ' < "$RS_HOME/docs/DESIGN.md" | tr -s ' '); AT=$(tr '\n' ' ' < "$RS_HOME/AGENTS.md" | tr -s ' ')
CKT=$(tr '\n' ' ' < "$RS_HOME/$CKF" | tr -s ' ')
# 2026-11-06 follow-ups: the numbers and flags the docs now promise, as the code spells them
for o in 'GREP_BYTES = 8 << 20' 'GREP_MAX_BYTES = 64 << 20' 'GREP_CAP = 1 << 16' 'CHECK_MAX_S = 600' 'RECYCLE_MIN = 24' \
         'RECYCLE_AGE_S = 3600' 'RELAUNCH_AFTER = ("infra", "any")' '"--check-after"' '"--grep"' '"--relaunch-after"' \
         'def refuse_recycled(' 'def _any_misses(' 'def refresh(' '"mfsgetquota": ("nhHkmg", "", "", True)' \
         'ANY_PLAN_MAX_AGE_S = 600'; do
  has "$CLI" "$o" "the CLI has what the docs promise (2026-11-06): $o"; done
has "$ST" '--relaunch-after any' "SKILL §3: --relaunch-after any for re-runs the user's words hand over"
has "$ST" 'never earlier words' "SKILL §3: an --approve is the answer on screen, never earlier words"
has "$PSLT" "the log's last 8 MiB" "procedure-slurm: --grep searches the last 8 MiB (GREP_BYTES)"
has "$PSLT" 'reads each submission (every chain segment)' "procedure-slurm: --check-after judges every submission"
has "$DT" 'weighing 24 or more, a CJK character 2' "DESIGN: the recycled-quote weight (RECYCLE_MIN)"
# R4-7: acting goes through rsk watch (the steer), and a run-watch whose rsk watch is gone stops (exit 7)
has "$ST" 'rsk watch <table> --approve "<the user.s words>"' "$F: the table's OK is recorded with rsk watch <table> --approve"
has "$ST" '--act / --approve go through rsk watch only' "$F: --act / --approve only through rsk watch"
hasnt "$ST$PSLT$PNOT" 'run `run-watch <table> --approve' "no doc tells the agent to run run-watch --approve directly"
for r in 'a direct `run-watch … --act` or `--approve` while rsk is installed prints `use: rsk watch …` and exits 2 @@ use: rsk watch ' \
         'is `ATTENTION reason=parent-gone parent=P at=…` @@ reason=parent-gone parent=' \
         'a fail-stop cancel not yet sent stays pending for the next `--act` run @@ orphan_stop cancel' \
         'records `#failstop-released <trigger>:<job>` in their state @@ #failstop-released ' \
         'nothing is submitted that round (`why=fail-stop-unreadable`) @@ fail-stop-unreadable' \
         'target-changed from=?`) @@ from=?: a state line' '(`submit-skipped … prev-identity`) @@ @@fail prev-identity' \
         'held `job-identity-mismatch … workdir=…` @@ job-identity-mismatch "name=.* workdir='; do
  has "$PSLT" "${r%% @@ *}" "procedure-slurm (R4-7/13/14): ${r%% @@ *}"; has "$RW" "${r#* @@ }" "...bin/run-watch: ${r#* @@ }"; done
has "$WP" 'env\["RS_WATCH_PARENT"\] = str(os.getpid())' "...and rsk watch sets RS_WATCH_PARENT to its own pid"; has "$PNOT" 'exit 7 = the `rsk watch` that started it is gone' "procedure-nohup: exit 7"
# R4-4 + R4-1: every action, every row; a deny matches what it cannot rule out
has "$PSLT" 'denies for EVERY action run-watch could take on it (launch, relaunch, resubmit, chain on Slurm rows, cancel)' "procedure-slurm: rsk watch checks every action of every row"
has "$WP" 'ROW_ACTIONS = ("launch", "relaunch", "resubmit", "chain", "cancel")' "...watch.py checks those"
has "$PSLT" 'a GPU-type deny matches every row of its target and a partition deny every Slurm row of its target' "procedure-slurm: GPU-type / partition denies match every row of their target"
has "$ST" 'matches what it cannot rule out (a job without a plan, a watch row, a run of unknown class)' "$F: a deny fails closed on unknown facts"
has "$GP" 'that cannot be read or is not known counts as matching' "...grants.py says so"
# R4-6: policy flags are bound and never grant-covered
has "$ST" 'nor is a card with policy flags' "$F: no grant covers a card with policy flags"
has "$PSLT" 'no standing grant covers a plan with policy flags' "procedure-slurm: policy flags are bound, never grant-covered"
has "$DT" 'no standing grant covers a plan with policy flags' "DESIGN: the same"; has "$PKT" 'no standing grant covers a plan that has one' "packs.md: the same"
has "$TPL" 'no standing grant covers a plan with one' "policy template: the same"; has "$AT" 'then `flags` = `T_FLAGS`' "AGENTS: flags= in the bound list"
has "$SUB" 'conf_extra=%s\\nflags=%s\\nchain=%s' "...submit.sh binds flags= right before chain="; has "$LP" 'no standing grant covers a plan ' "...launch.py's card says so"
has "$GP" 'no standing grant covers a plan with policy flags' "...grants.py refuses to cover one"; has "$GP" '"conf_extra", "flags", "warnings_avail"' "...and needs flags= (needs: sync)"
# R4-11/12: t_partition probed too; every gate passes; a silent gate's output in warnings_id
has "$PSLT" '`t_partition` the same way with the partition that is submitted' "procedure-slurm: t_partition is probed too"
has "$PSLT" 'every gate of a function shows, not only its first' "procedure-slurm: every gate of a function shows"
has "$PSLT" 'what the probe printed then joins the card.s `warnings_id`' "procedure-slurm: a silent gate's output joins warnings_id"
has "$TPL" 'probes t_partition the same way' "policy template: t_partition is probed"; has "$TPL" 'So BOTH may run twice and must have no side effects' "policy template: both run twice"
has "$TPL" 'code after a gate must not assume the gate stopped the run' "policy template: a gate is passed in the probe"
has "$PKT" 'probes `t_partition` the same way' "packs.md: t_partition is probed"; has "$AT" 'a function.s first gate hides none after it' "AGENTS: every gate passes"
has "$DT" '`t_partition` can hold such a gate too, so it is probed the same way' "DESIGN: t_partition probed"
has "$SUB" 'rs_probe "t_partition' "...submit.sh probes t_partition"; has "$SUB" '\[ "$1" = 1 \] || builtin exit "$@"' "...and passes each gate's exit 1"
has "$SUB" 'W_SIL="$W_SIL@@probe' "...and binds a silent gate's output (W_SIL) into warnings_id"
# the bash facts the probe rests on (AGENTS, DESIGN, the template cite them; tests/vgate bash_exit_fn= reproduces the first on a login node)
X=$(bash -c 'exit() { [ "${1-}" = 1 ] && return 0; builtin exit "$@"; }; f() { exit 1; echo continued; }; f; exit 3' 2>&1; echo "rc=$?")
[ "$(printf '%s' "$X" | tr '\n' ' ')" = "continued rc=3" ] && ok "bash fact: a function named exit outranks the builtin (continued rc=3)" || bad "bash fact: a function named exit ($X)"
X=$(bash -c 'set -o posix; ( exit() { return 0; }; echo defined ); echo "rc=$?"' 2>/dev/null)
[ "$X" = "rc=2" ] && ok "bash fact: under set -o posix bash refuses a function named exit (the subshell exits 2)" || bad "bash fact: posix refuses a function named exit ($X)"
cp -R "$RS_USER_DIR" "$T/user-px" && printf 'set -o posix\n' > "$T/user-px/targets/fx-slurm/policy.local.sh"
PX=$(RS_USER_DIR=$T/user-px mk_proj fx-slurm 'REMOTE_DIR=/x'); O=$(PATH="$T/bin:$PATH" bash "$PX/.fx-slurm/submit.sh" --rs-mode plan -n px -- echo hi 2>&1); RC=$?
[ "$RC" = 2 ] && has "$O" '^ERROR: t_policy returned 2' "...so a policy that turns on set -o posix makes the plan fail closed (exit 2), as the docs say" || bad "posix policy: plan exit 2 (rc=$RC)"
hasnt "$O" '^@@plan' "...no card"
# R4-5: RUN never picks the GPUs (workstations); the honest limit: the payload is code
for v in CUDA_VISIBLE_DEVICES CUDA_DEVICE_ORDER NVIDIA_VISIBLE_DEVICES HIP_VISIBLE_DEVICES ROCR_VISIBLE_DEVICES; do
  has "$PNOT" "\`$v\`" "procedure-nohup: RUN may not set or clear $v"; has "$CKT" "\`$v\`" "conf-keys RUN row: $v"; has "$LSH" "$v" "...launch.sh checks $v"; done
has "$PNOT" 'RUN never picks the GPUs' "procedure-nohup: RUN never picks the GPUs"; has "$CKT" 'It never picks the GPUs (`-d` / `-n` do)' "conf-keys: the RUN row says so"
has "$PNOT" 'an `env` option other than `-v`/`--debug`, `-C DIR` or `-u OTHER` is refused too' "procedure-nohup: env options that may touch them are refused"
has "$PNOT" 'exit 2 before the claim (`ERROR: RUN … — the GPUs are launch.sh.s choice`), nothing launched, no card' "procedure-nohup: a literal one: exit 2 before the claim"
has "$LSH" "the GPUs are launch.sh's choice" "...launch.sh's refusal"; has "$LSH" 'not started (the GPUs are picked by launch.sh' "...and the wrapper's, after expansion"
has "$PNOT" 'the wrapper never starts the payload (`ERROR: RUN … — not started` in the log, `<log>.rc` rc=2)' "procedure-nohup: an expanded one never starts"
has "$PNOT" 'the payload is code — what it does once it starts' "procedure-nohup: the honest limit"
has "$PNOT" '`info_run_gpu=checked`' "procedure-nohup: the envelope line"; has "$LSH" 'info_run_gpu=checked' "...launch.sh prints it"; has "$GP" '"info_run_gpu", "warnings_avail"' "...rsk needs it (needs: sync)"
has "$ST" 'On a box the run command never picks GPUs' "$F rail: on a box the run command never picks GPUs"
has "$RT" 'What the payload does once it starts is its own code — no harness can check that' "README: the honest limit"
has "$DT" 'what it does once it starts — set its own environment' "DESIGN: the honest limit"; has "$AT" 'What the payload.s own code does is beyond any check' "AGENTS: the honest limit"
# R4-15: an unreadable grants.json refuses
has "$ST" 'Exit 6 `grants unreadable`: no deny can be ruled out' "$F: an unreadable grants.json refuses"
has "$PSLT" '`grants unreadable — rsk grant recount / restore`' "procedure-slurm: the refusal's words"; has "$GP" 'grants unreadable — rsk grant recount / restore' "...grants.py says them"
has "$DT" 'may hold a deny, so `rsk launch`, `rsk cancel` and `rsk watch --act/--approve` refuse (exit 6' "DESIGN: the same"
has "$GP" 'raise RskError(why, CONFLICT)' "...check() refuses with exit 6"; has "$WP" 'raise RskError(bad, CONFLICT)' "...and rsk watch's row check"
# R4-2 / R4-3 / R4-8 / R4-9 / R4-10
has "$PSLT" 'else `not the configuration of aNN it resumes`' "procedure-slurm: a relaunch grant repeats the latest attempt that ran"; has "$GP" 'not the configuration of ' "...grants.py's refusal"
has "$PSLT" 'or any one when the first attempt had none: exit 2, before any ssh' "procedure-slurm: a class only at the first attempt"; has "$LP" 'a run.s class is set only at its first attempt' "...launch.py refuses it"
has "$PNOT" 'a launch.sh killed after its gate said go is launched' "procedure-nohup: the journal decides a killed launch"; has "$LP" 'launch.sh killed after its' "...launch.py reads it"
has "$CKT" 'The lint parses the words as the scan does' "conf-keys: the lint reads SBATCH_EXTRA as the scan"; has "$SUB" 'w=${_cx\[$i\]}' "...submit.sh's lint walks the scan's words"
has "$PNOT" '`nothing to cancel … had ended already`' "procedure-nohup: an ended run's pid is checked against its own receipt"; has "$CP" 'had ended already' "...cancel.py says it"
has "$PNOT" '(several: exit 6 `ambiguous`)' "procedure-nohup: several receipts for one pid"; has "$CP" 'ambiguous receipts=' "...cancel.py's body"
has "$PSLT" 'or no answer at all (a timeout, ssh.s own 255, a signal' "procedure-slurm: no answer at all may have been sent"; has "$CP" 'no answer at all: the job may have been cancelled' "...cancel.py"
ET=$(tr '\n' ' ' < "$RS_HOME/$SK/references/experiment-conventions.md" | tr -s ' ')
has "$ET" 'the exceptions are what the user authorised and a tool checks first: `run-watch --act`' "conventions: detect-only names its exceptions"
has "$ET" 'your own judgment that a run should stop is the user.s call unless they authorised that kind of decision (`cancel_own`)' "conventions: the agent's own stop needs the user"
echo "-- round 5: what the docs now promise, each beside the code that does it (docs @@ code) --"
STP=$(cat "$RS_HOME/src/remote_run/status.py"); VG=$(cat "$RS_HOME/tests/vgate/slurm-remote.sh" 2>/dev/null); VL=$(cat "$RS_HOME/tests/vgate/launchers.sh" 2>/dev/null)
PSR=$(cat "$RS_HOME/$PSL"); PST=$(tr '\n' ' ' < "$RS_HOME/$SK/references/project-setup.md" | tr -s ' ')
# R5-4: info_prior (envelope) — a run only the target's journal shows (run-watch's) is a relaunch; none readable = a relaunch
has "$PSLT" 'then `info_prior=<n|unknown>`: the run.s earlier attempts here' "procedure-slurm: info_prior in the block, after the source lines"
[ "$(grep -n "info_source_%s=" "$RS_HOME/remote/submit.sh" | head -n 1 | cut -d: -f1)" -lt "$(grep -n "printf 'info_prior=%s" "$RS_HOME/remote/submit.sh" | head -n 1 | cut -d: -f1)" ] \
  && ok "...submit.sh prints info_prior after info_source_dirty" || bad "...submit.sh prints info_prior after info_source_dirty"
has "$PNOT" '`info_run_gpu=checked` (above) `info_prior=<n|unknown>`' "procedure-nohup: info_prior right after info_run_gpu"; has "$LSH" 'info_run_gpu=checked\\ninfo_prior=%s' "...launch.sh prints it there"
for f in "$AT" "$DT"; do has "$f" '`info_prior=<n|unknown>`' "AGENTS / DESIGN: the info_prior key"; done
has "$AT" 'slurm after `info_source_dirty`, nohup after `info_run_gpu`' "AGENTS: where each block carries it"
has "$PSLT" 'plus squeue.s rows of such a name with this WorkDir, live or ended and still listed, that no receipt names; `unknown` when squeue failed or a receipt cannot be read' "procedure-slurm: what info_prior counts"
has "$SUB" 'rs_prior() {' "...submit.sh's rs_prior"; has "$LSH" 'rs_prior() {' "...launch.sh's"
has "$ST" 'run-watch.s runs never enter the ledger: the plan.s `info_prior` —, and a deploy that cannot say counts as one: fail closed' "$F: a journal-only run is a relaunch, fail closed"
has "$PSLT" 'missing or `unknown` counts as one too (fail closed)' "procedure-slurm: no number = relaunch"; has "$PNOT" 'a block without it, or `unknown`, counts as one too (fail closed' "procedure-nohup: the same"
has "$DT" 'OR `info_prior` > 0 in the plan.s block' "DESIGN: the derivation (a)"; has "$DT" 'OR no readable `info_prior`' "DESIGN: ...fail closed"
has "$AT" '`info_prior` > 0, or no readable `info_prior` (`launch.info_prior`) → relaunch' "AGENTS: the derivation"
has "$LP" 'def info_prior(' "...launch.py reads it"; has "$LP" 'prior is None$' "...None (missing / unknown) is a relaunch"
has "$PSR" 'prior      N earlier attempt(s) of <run> on <t>' "procedure-slurm: the card's prior line"; has "$LP" 'prior      {prior} earlier attempt(s) of ' "...launch.py's card"
has "$PSLT" 'prior unknown — … taken as a relaunch (fail closed)' "procedure-slurm: the card's unknown line"; has "$LP" 'prior      unknown — .*: taken as a "$' "...launch.py's card"; has "$LP" '^ *"relaunch (fail closed)")$' "...(its second half)"
has "$PSLT" 'never a run only the journal shows (`the ledger has no earlier attempt of the run that ran`' "procedure-slurm: a relaunch grant never resumes a journal-only run"
has "$GP" 'the ledger has no earlier attempt of the run that ran' "...grants.py's refusal"; has "$DT" 'it never resumes a run only the target.s journal shows' "DESIGN: the same"
has "$PSLT" 'run-watch.s runs still never enter the ledger (`rsk status` lists them as `(run-watch.s)`)' "procedure-slurm: run-watch's runs: tagged, unledgered"
has "$STP" "({tools\[k\]}'s)" "...status.py tags them with the tool"; has "$DT" 'run-watch.s runs never enter it' "DESIGN: the same, in the honest limits"
# R6-4 (R5-6 reverted): ssh's own words are no proof — a ProxyCommand's fallback route or a login shell prints "Connection refused"
# on a session that ran: a submit's ssh 255 with no receipt is SUBMIT_UNKNOWN (the use kept, the plan used), a cancel's 255
# before @@start "may have been sent" (the use kept)
has "$LP" "ssh's own words are no proof that nothing was sent" "R6-4: launch.py's settle: a submit's 255 is SUBMIT_UNKNOWN whatever ssh's stderr says"
has "$CP" "ssh's own words are no proof that the body never ran" "R6-4: cancel.py: a cancel's 255 before @@start may have been sent"
hasnt "$LP" 'not_reached' "R6-4: launch.py no longer reads ssh's words as proof (no cancel.not_reached)"; hasnt "$CP" 'not_reached\|NOT_REACHED' "...nor cancel.py"
has "$(cat "$RS_HOME/tests/py/test_cancel.py")" 'def test_r6_4_ssh_255_before_start_may_have_been_sent_whatever_its_stderr_says' "...test_cancel.py pins the cancel"
has "$(cat "$RS_HOME/tests/py/test_cancel.py")" 'SSH_FALLBACK' "...with its fallback-route stub (the body runs, then 255)"
has "$(cat "$RS_HOME/tests/py/test_launch.py")" 'def test_r6_4_a_slurm_submit_s_ssh_255_is_unknown_whatever_its_stderr_says' "...test_launch.py the submit"
has "$(cat "$RS_HOME/tests/62-rsk-launch.sh")" 'R6-4 for rsk launch' "...tests/62 the end-to-end submit"; has "$(cat "$RS_HOME/tests/62-rsk-launch.sh")" "R6-4: a fallback route's" "...and the fallback route (\$T/ssh.fallback)"
has "$ST" 'Exit 5 after a submit = SUBMIT_UNKNOWN, never resubmitted (it blocks that run until `rsk status` settles it), whatever ssh.s own words were' "$F: a submit's exit 5 is unknown whatever ssh said"
has "$ST" 'the plan stays used' "$F: ...the plan stays used"
has "$PSLT" "ssh's own words are no proof that nothing was sent" "procedure-slurm: a submit's 255 is SUBMIT_UNKNOWN"
has "$PSLT" 'The use is kept and the plan stays used (`rsk launch --plan <id>` again: exit 6 `was used already`)' "procedure-slurm: ...the use kept, the plan used"; has "$LP" 'was used already' "...launch.py's refusal"
has "$PSLT" '`rsk adopt -T <t> --not-submitted <NONCE> --approve "<their words>"`' "procedure-slurm: only the user's words close an attempt the journal never saw"
has "$(cat "$RS_HOME/src/remote_run/adopt.py")" 'rsk adopt -T t --not-submitted NONCE --approve' "...rsk adopt takes them"
for f in "$PSLT" "$PNOT"; do has "$f" "ssh's own words are no proof that the body never ran; the use is kept" "a procedure: a cancel's 255 before @@start may have been sent"; done
has "$DT" "ssh's own words are never that proof" "DESIGN: ssh's words never prove a submit unsent"; has "$AT" "SUBMIT_UNKNOWN whatever ssh's stderr says" "AGENTS: the same"
has "$DT" "\`tests/62\` with \`\$T/ssh.fallback\`" "DESIGN cites the end-to-end reproduction"; has "$DT" '`SSH_FALLBACK` stub' "DESIGN cites test_cancel's stub"
has "$(cat "$RS_HOME/tests/62-rsk-launch.sh")" 'ssh.fallback' "...tests/62 has \$T/ssh.fallback"
for f in "$ST" "$PSLT" "$PNOT" "$DT" "$AT" "$RT"; do hasnt "$f" 'not reached — nothing sent' "the R5-6 'not reached — nothing sent' proof is gone from the docs"; done
# R5-5: a non-zero scancel is unknown, unless scancel's own line says there was nothing to cancel
has "$PSLT" 'A non-zero `scancel` is `UNKNOWN: job J (<run> aNN): scancel exit N (…)` (exit 5): the use is kept and the ledger shows `CANCELLING?`' "procedure-slurm: a failing scancel is unknown"
has "$CP" 'out(f"UNKNOWN: {what}: scancel exit {src}"' "...cancel.py prints it"; has "$CP" '"CANCELLING?"' "...and records CANCELLING?"
has "$PSLT" 'scancel.s own line for that id saying `Invalid job id` or `already completing or completed`: `nothing to cancel: … scancel exit N: …` (exit 0)' "procedure-slurm: the one refund"
has "$CP" 'invalid job id|already completing or completed' "...cancel.py's MOOT words"; has "$CP" '"COMPLETING"' "...ledger COMPLETING"
has "$PSLT" 'Exit 1 is never a failed scancel' "procedure-slurm: exit 1 is no scancel failure"; has "$CP" '1 kill failed (processes left in the group)' "...cancel.py's exit list"
has "$PNOT" 'Exit 1 = processes left in the run.s group' "procedure-nohup: exit 1"; has "$CP" 'process(es) still in its group after TERM' "...cancel.py's line"
for k in scancel_ended= scancel_invalid=; do has "$PSLT" "\`$k\`" "procedure-slurm cites tests/vgate $k"; has "$AT$DT" "\`$k\`" "AGENTS / DESIGN cite $k"
  has "$VG" "echo \"$k" "...tests/vgate/slurm-remote.sh prints $k"; done
has "$PSLT" 'sent only after `squeue -j` lists none' "procedure-slurm: the unknown id is checked first"; has "$VG" 'squeue -h -j 4000000000 -O JobID:0' "...the script asks squeue"
has "$PSLT" 'no site.s wording is confirmed' "procedure-slurm: unconfirmed wording fails closed"
# R5-1 / R5-9 / R5-8: denies
has "$ST" '`--job` is for cancels only: a run.s launches are denied with `--name .<run>.` (exit 2 otherwise)' "$F: deny --job is for cancels only"
has "$GP" 'a deny by job id (scope.jobs) is for cancels only' "...grants.py validate()"; has "$GP" "a deny of a run's launches names the run: " "...and rsk grant deny --job's refusal"
has "$ST" '`-T` must name a target the harness knows (exit 2 `unknown target`)' "$F: -T must be a known target"; has "$GP" 'raise RskError(f"unknown target ' "...grants.py check_targets"
has "$PSLT" 'a run.s launches are denied with `--name .<run>.`' "procedure-slurm: deny a run's launches by name"
has "$PSLT" 'must be a target the harness knows, spelled as INDEX lists it (else exit 2 `unknown target`, nothing recorded)' "procedure-slurm: unknown targets refused"
has "$PSLT" 'a spelling that is not one plain name matches every target deny (fail closed)' "procedure-slurm: deny targets compared as names"
has "$GP" 'def target_key(' "...grants.target_key"; has "$DT" 'a deny by job id is for cancels only' "DESIGN: the same"
has "$DT" 'refuse a target the harness does not list (exit 2 `unknown target`' "DESIGN: unknown targets"; has "$DT" 'a stored jobs + launch deny included' "DESIGN: a stored one is invalid (matches everything)"
has "$AT" '`scope.jobs` only with cancel actions, else invalid' "AGENTS: scope.jobs"; has "$AT" 'refuse a target `rs_targets` does not list, exit 2' "AGENTS: unknown targets"
has "$PSLT" 'The target column is a target name exactly as INDEX (`rs_targets`) lists it' "procedure-slurm: a row target is a listed name"
has "$PSLT" '`not a target name this harness lists`' "...the refusal's words"; has "$RW" 'not a target name this harness lists' "...bin/run-watch says them"
has "$RW" 'only A-Za-z0-9._- (a target.s name, no /: R5-8)' "...and refuses other bytes"; has "$AT" 'row targets: exact `rs_targets` names, else exit 2' "AGENTS: the same"
has "$DT" 'Its target is a plain name `rs_targets` lists, spelled exactly' "DESIGN: the same"; has "$WP" 'def kind_of(' "...rsk watch reads a row's target as a normalised name"
# R5-7: a table keeps every fail-stop; --release clears only its trigger's; the older copy reads one
for r in 'resumes the group once no other fail-stop holds the table @@ pending again only once no stop remains' \
         'reason=fail-stop-inherited … also-held-by=<stops>`) @@ also-held-by=' \
         'clears only the stops that name triggered, with the pending cancels they made @@ every stop of the table NAME triggered is cleared' \
         '`RELEASE table=… fail-stop=<name> held-by=<stops>` @@ fail-stop=$RELEASE held-by=$h' \
         'and on that row `ATTENTION … reason=release-held held-by=…` @@ reason=release-held held-by=$h' \
         'it still forms its own when one of its rows fails while another group.s holds it (both groups stop) @@ ! fs_own' \
         'A plain row.s `--release` (a name that triggered no stop) is still that row.s one submit past every hold @@ one submit past the budget or the hold' \
         'reads only the LAST `#failstop` of a state file holding several @@ an older run-watch keeps only the last pair'; do
  has "$PSLT" "${r%% @@ *}" "procedure-slurm (R5-7): ${r%% @@ *}"; has "$RW" "${r#* @@ }" "...bin/run-watch: ${r#* @@ }"; done
hasnt "$PSLT" 'clears the stop in every table of this watch' "procedure-slurm: the pre-R5-7 'clears the stop' wording is gone"
has "$AT" 'every fail-stop from any state file naming the row (a table keeps all of them; `--release` clears only its trigger.s)' "AGENTS: the run-watch line"
has "$DT" 'A table keeps every stop that holds it as a set' "DESIGN: stops as a set"; has "$DT" 'so one release never resumes rows another stop holds' "DESIGN: one release, one stop"
has "$DT" 'reads only the last `#failstop` of a file' "DESIGN: the older copy (transitional)"
# R5-3: RUN's TEXT anywhere; the old 'bash -c / a wrapper is beyond any check' is now false
has "$PNOT" 'RUN.s TEXT, anywhere — its leading words, a later command, a pipeline element, `bash -c .….`, a wrapper such as `timeout` / `nice` before `env`, a container.s `--env NAME=` / `-e NAME=` — must not assign or clear' "procedure-nohup: the text rule"
has "$PNOT" '`NAME=` and `NAME+=`; `-u NAME` and `--unset\[= \]NAME`; `unset … NAME`; `export -n NAME`; `declare` / `typeset +x NAME` — also quoted or backslashed' "procedure-nohup: the forms"
has "$PNOT" 'A mention as data counts too' "procedure-nohup: data counts"; has "$PNOT" 'reading them is fine (`$NAME`, `printenv NAME`)' "procedure-nohup: reads are fine"
has "$LSH" 'why=$(rs_gputext "$RUN_CMD")' "...launch.sh checks RUN's whole text before the claim"
for f in "$PNOT" "$DT"; do hasnt "$f" "bash -c 'CUDA_VISIBLE_DEVICES" "the false 'bash -c CUDA_VISIBLE_DEVICES=… is beyond any check' is gone"; done
hasnt "$PNOT" 'wrapper in front of its command) is outside' "procedure-nohup: a wrapper before env is no longer beyond the check"
hasnt "$ST" 'in front of it is refused' "$F: no longer only 'in front of it'"; hasnt "$RT" 'leading words set `CUDA_VISIBLE_DEVICES`' "README: no longer only the leading words"
hasnt "$CKT" '^.*It never picks the GPUs (`-d` / `-n` do): leading words' "conf-keys: no longer only the leading words"
has "$ST" 'RUN.s text that sets or clears `CUDA_VISIBLE_DEVICES` or a sibling, anywhere, is refused (exit 2)' "$F rail: the text rule"
has "$RT" 'text sets or clears `CUDA_VISIBLE_DEVICES` (or a sibling variable) anywhere is refused' "README: the text rule"
has "$CKT" 'its text, anywhere (a later command, a pipeline element, `bash -c .….`, a container.s `--env NAME=`; quoted, backslashed or as data too)' "conf-keys: the text rule"
has "$PST" 'a `RUN` whose text sets a GPU variable is refused' "project-setup: the text rule"
# ...the examples the docs give, run through launch.sh's own rs_gputext (refused / fine / the honest limit)
GT=$(sed -n '/^rs_gputext() {/,/^}/p' "$RS_HOME/remote/launch.sh"); gt() { ( eval "$GT"; rs_gputext "$1" >/dev/null ); }
for r in 'p --note "CUDA_VISIBLE_DEVICES=0"' "'CUDA_VISIBLE_DEVICES'=0 p" 'C\UDA_VISIBLE_DEVICES=0 p' 'echo x | CUDA_VISIBLE_DEVICES=0,1 p' "bash -c 'CUDA_VISIBLE_DEVICES=0 p'" \
         'timeout 1h env CUDA_VISIBLE_DEVICES=0 p' 'docker run --env NVIDIA_VISIBLE_DEVICES=all i' 'docker run -e CUDA_VISIBLE_DEVICES=0 i' 'env --unset=HIP_VISIBLE_DEVICES p' \
         'env -u ROCR_VISIBLE_DEVICES p' 'a; unset -v CUDA_DEVICE_ORDER; p' 'export -n CUDA_VISIBLE_DEVICES; p' 'typeset +x CUDA_VISIBLE_DEVICES; p' 'CUDA_VISIBLE_DEVICES+=,1 p'; do
  gt "$r" && bad "rs_gputext refuses the doc's example: $r" || ok "rs_gputext refuses the doc's example: $r"; done
for r in 'p $CUDA_VISIBLE_DEVICES' 'printenv CUDA_VISIBLE_DEVICES' 'x | env $PRE y'; do
  gt "$r" && ok "rs_gputext lets through (a read, or the honest limit): $r" || bad "rs_gputext lets through: $r"; done
# R5-2: launchers that pick GPUs from their own flags: a counted WARNING, never a refusal
has "$PNOT" '\*\*Launchers that pick GPUs from their own flags\*\* MAY ignore `CUDA_VISIBLE_DEVICES`' "procedure-nohup: the launcher paragraph"
has "$PNOT" 'such a launcher may ignore CUDA_VISIBLE_DEVICES and pick GPUs itself' "procedure-nohup: the WARNING's words"; has "$LSH" 'such a launcher may ignore CUDA_VISIBLE_DEVICES and pick GPUs itself' "...launch.sh's"
has "$PNOT" 'Only the user.s approval of that card covers it — never a standing grant, whatever its `--allow-warnings` (`any` too' "procedure-nohup: only the card covers a launcher WARNING (NF8: not an any grant)"
hasnt "$PNOT$DT$AT" 'or a grant whose `--allow-warnings` is `any`, covers it\|or a grant of kind `any`\|or an `any` grant\|grant kind `any` only' "NF8: no doc says an any grant covers a launcher / container WARNING"
has "$PNOT" "\`tests/61\` 'R5-2'" "procedure-nohup cites tests/61 R5-2"; has "$(cat "$RS_HOME/tests/61-launch-remote.sh")" 'fact: argparse takes --num_g for --num_gpus' "...which reproduces the argparse facts"
for f in "$PNOT" "$AT" "$DT"; do has "$f" 'tests/vgate/launchers.sh' "a doc cites tests/vgate/launchers.sh"; done
[ -f "$RS_HOME/tests/vgate/launchers.sh" ] && ok "tests/vgate/launchers.sh exists" || bad "tests/vgate/launchers.sh exists"
has "$(cat "$RS_HOME/tests/88-vgate.sh")" 'launchers.sh' "...tests/88 checks its plumbing"
has "$DT" "ssh <alias> .bash -s <dir>/.venv/bin/python. < tests/vgate/launchers.sh" "DESIGN: how it is run (with the user's OK)"; has "$VL" "ssh <alias> 'bash -s <dir>/.venv/bin/python' < tests/vgate/launchers.sh" "...as its header says"
for k in ds_abbrev ds_short ds_alias ds_ignores_cvd ds_hostfile acc_hyphen acc_abbrev acc_sets_cvd; do has "$DT" "$k" "DESIGN lists launchers.sh's $k"; has "$VL" "$k=" "...launchers.sh prints $k="; done
# round 6 (R6-3): accelerate's config and /job/hostfile are now CHECKED, so they left the honest limits; what is still not read is listed
# (round 7: an HF_HOME the ENV_HOOK may set is a WARNING (R7-4) and a relative --config_file after a cd is read as unknown (R7-5): checked too)
for w in 'launcher flags that only an expansion or a script supplies' \
         'docker `--env-file`' 'compose files' '`.deepspeed_env`' 'a docker daemon whose default runtime is nvidia' '`docker_default_runtime=`'; do
  has "$PNOT" "$w" "procedure-nohup honest limit: $w"; has "$DT" "$w" "DESIGN honest limit: $w"; done
for w in 'an `HF_HOME` the `ENV_HOOK` sets' 'a relative `--config_file` after a `cd` in RUN'; do
  hasnt "$PNOT$DT" "$w" "no longer an honest limit (round 7 checks it): $w"; done
hasnt "$PNOT" 'accelerate.s config file (`gpu_ids` in `--config_file` or its default config)' "procedure-nohup: accelerate's config is no longer an unchecked limit"
hasnt "$DT" 'read accelerate.s config file or deepspeed.s `/job/hostfile`\|a launcher.s config file or hostfile' "DESIGN: nor the config / hostfile"
has "$PNOT" '`deepspeed` without `--hostfile`/`-H` warns when `/job/hostfile` exists' "procedure-nohup: /job/hostfile is checked"
has "$DT" 'deepspeed.s runner reads `/job/hostfile` when no `--hostfile` is given' "DESIGN: the same"; has "$VL" 'DLTS_HOSTFILE' "...launchers.sh reads its path from the installed runner"
LA=$(sed -n '/^rs_launchers() {/,/^}/p' "$RS_HOME/remote/launch.sh"); la() { ( DEV=0; eval "$LA"; rs_launchers "$1" 2>&1 ); }
for r in 'deepspeed --include localhost:1 t.py' 'deepspeed -i localhost:1 t.py' 'deepspeed --exclude localhost:0 t.py' 'deepspeed -e localhost:0 t.py' 'ds --num_gpus 2 t.py' \
         'deepspeed.pt --num_accelerators 2 t.py' 'python -m deepspeed.launcher.runner --num_nodes 1 t.py' 'deepspeed -H hf t.py' 'deepspeed --hostfile hf t.py' \
         'deepspeed --master_addr h t.py' 'deepspeed --num_g 2 t.py' 'accelerate launch --gpu_ids 0 t.py' 'accelerate-launch --gpu-ids 0 t.py' \
         'python -m accelerate.commands.launch --num_processes 2 t.py' 'accelerate launch --num-processes 2 t.py'; do
  has "$(la "$r")" '^WARNING: RUN runs .* with ' "rs_launchers warns for the doc's: $r"; done
for r in 'deepspeed t.py' 'accelerate launch t.py' 'accelerate launch --gpu_i 0 t.py'; do hasnt "$(la "$r")" 'WARNING' "rs_launchers: no warning for $r (the landing; accelerate takes no abbreviations)"; done
has "$ST" 'a launcher given its own GPU flags (deepspeed `--num_gpus`…, `accelerate launch --gpu_ids`…) is a card WARNING' "$F rail: the launcher WARNING"
has "$RT" 'a launcher given its own GPU flags (`deepspeed --num_gpus`, `accelerate launch --gpu_ids`) is a warning on the plan you approve' "README: the same"
has "$CKT" 'A launcher given its own GPU flags' "conf-keys RUN row: the same"
# R5-10: the policy-gate idiom; the payload is code; rsk watch's row check is static
has "$PKT" "print the WARNING, then test FORCE: \`echo 'WARNING: … Re-run -y …' >&2; \\[ \"\$FORCE\" = 1 \\] || exit 1\`" "packs.md: the gate idiom (print, then test FORCE)"
has "$PKT" 'so a plan shows every gate, from the real call too' "packs.md: why"; has "$PKT" "Never the P2 form" "packs.md: never the P2 form"
has "$PKT" "silent under \`-y\` and found only by the probe below (\`tests/52\` 'R5-10')" "packs.md: the P2 form is silent under -y (tests/52 R5-10)"
has "$TPL" 'print the WARNING, THEN test FORCE' "...the policy template says the same"; has "$TPL" 'Never the P2 form' "...and forbids the P2 form"
has "$(cat "$RS_HOME/tests/52-attempt.sh")" "R5-10: the policy template's gate idiom" "...tests/52 R5-10 runs both forms"
has "$AT" 'print, then test FORCE' "AGENTS: the idiom"; has "$DT" 'a gate prints its WARNING, then tests FORCE' "DESIGN: the idiom"
for f in "$PNOT" "$DT"; do has "$f" 'the payload is code — what it does once it starts is outside what rsk can check' "the R4-5 honest-limit line (the payload is code)"; done
has "$DT" '\*\*The honest limits\.\*\*.*the payload is code — what it does once it starts is outside what rsk can check' "...in DESIGN's honest limits"
for f in "$PSLT" "$DT"; do has "$f" 'is not seen by `rsk watch`.s row check' "rsk watch's static row check misses a policy that rewrites -p (honest limit)"; done
has "$PSLT" '(`--release` and an `SBATCH_EXTRA` singleton act outside it)' "procedure-slurm: denies are checked for --release too"; has "$WP" 'VALUE_FLAGS = (.*"--release"' "...rsk watch reads --release"
echo "-- round 6: what the docs now promise, each beside the code that does it (docs @@ code) --"
HP=$(cat "$RS_HOME/src/remote_run/harness.py"); VC=$(cat "$RS_HOME/tests/vgate/containers.sh" 2>/dev/null); VLO=$(cat "$RS_HOME/tests/vgate/local.sh" 2>/dev/null)
T61=$(cat "$RS_HOME/tests/61-launch-remote.sh"); TG=$(cat "$RS_HOME/tests/py/test_grants.py"); TC=$(cat "$RS_HOME/tests/py/test_cancel.py")
# info_launchers (envelope): this launch.sh has the round-6 checks; rsk needs it (an older card lacks those WARNINGs)
has "$LSH" 'info_prior=%s\\ninfo_launchers=checked' "launch.sh prints info_launchers=checked right after info_prior"
has "$GP" '"info_launchers")}' "...grants.NEEDED (nohup) needs it: needs: sync"; has "$LP" 'its plan block lacks {' "...launch.py's needs: sync names what is missing"
has "$PNOT" 'as a relaunch) `info_launchers=checked` (above' "procedure-nohup: info_launchers in the envelope, after info_prior"
has "$PNOT" '`needs: sync … lacks info_launchers`, a plan stored without it is refused at `--plan`' "procedure-nohup: a block / stored plan without it"
has "$AT" 'after `info_prior`, `info_launchers=checked`' "AGENTS: the envelope key"; has "$DT" 'after `info_prior`, `info_launchers=checked`' "DESIGN: the envelope key"
has "$DT" 'a grant would cover, say, `docker run --gpus all`' "DESIGN: why rsk needs it"
has "$(cat "$RS_HOME/tests/py/test_launch.py")" 'def test_r6_a_box_whose_launch_sh_predates_the_launcher_and_container_checks_needs_a_sync' "...test_launch.py pins it"
# R6-2 / R6-6 / exec -c: APPTAINERENV_ assignments and an emptied environment are refused (exit 2 before the claim)
has "$LSH" '(APPTAINERENV_|SINGULARITYENV_)?' "launch.sh: APPTAINERENV_/SINGULARITYENV_ + a GPU name is an assignment"
has "$LSH" 'empties the whole environment in its text' "launch.sh: an emptied environment is refused"
has "$PNOT" '`APPTAINERENV_NAME=` / `SINGULARITYENV_NAME=` count as `NAME=` (apptainer sets NAME inside the container from it, `--cleanenv` or not)' "procedure-nohup: APPTAINERENV_ counts"
has "$PNOT" 'Nor may RUN.s text empty the whole environment, anywhere' "procedure-nohup: the empty-environment rule"
has "$PNOT" "ERROR: RUN empties the whole environment in its text ('env -i': the harness's CUDA_VISIBLE_DEVICES and CUDA_DEVICE_ORDER would go" "procedure-nohup: its message"
has "$PNOT" "(env's options end at its command: \`env A=1 cmd -i\` and \`cmd -i\` are fine)" "procedure-nohup: env's options end at its command"
has "$PNOT" "\`tests/61\` R6-6 and 'round-6 integration: bash's \`exec -c\`'" "procedure-nohup cites the facts' reproductions"; has "$T61" "round-6 integration: bash's \`exec -c\`" "...tests/61 reproduces them"
for f in "$PNOT" "$DT" "$AT"; do has "$f" 'env_anywhere=' "a doc cites tests/vgate/local.sh env_anywhere="; done; has "$VLO" 'echo "env_anywhere=' "...local.sh prints it"
has "$ST" 'as `APPTAINERENV_<name>=` too, and so is one emptying the environment (`env -i`, `exec -c`)' "$F rail: APPTAINERENV_ and an emptied environment"
has "$RT" 'as is one that empties the environment (`env -i`, `exec -c`)' "README: the same"
has "$CKT" '`APPTAINERENV_NAME=` / `SINGULARITYENV_NAME=` count as `NAME=`' "conf-keys RUN row: APPTAINERENV_"; has "$CKT" 'nor empty the whole environment anywhere' "conf-keys RUN row: the empty-environment rule"
has "$PST" 'and so is one that empties the environment, `env -i` / `exec -c`' "project-setup: the same"
has "$DT" 'Emptying the whole environment anywhere takes the harness.s `CUDA_VISIBLE_DEVICES` and `CUDA_DEVICE_ORDER` with it' "DESIGN: why env -i is refused"
for r in 'APPTAINERENV_CUDA_VISIBLE_DEVICES=0 apptainer exec img p' 'SINGULARITYENV_NVIDIA_VISIBLE_DEVICES=all singularity run img' 'env -i PATH=/bin p' 'env -vi p' 'env -0i p' \
         'env - p' 'env -- - p' 'x | env --ignore-environment y' 'x | env --i y' 'timeout 1h env -i p' 'nice -n 5 env -i p' 'env -v -i p' 'env -u NAME -i p' 'env -C /tmp -i p' \
         "env -S'-i p'" 'exec -c p' 'x; exec -c p' 'x | exec -c p' '(exec -c p)' '{ exec -c p; }' '`exec -c p`' "'exec' -c p" 'if x; then exec -c p; fi' 'while x; do exec -c p; done' \
         'if x; then y; else exec -c p; fi' 'time exec -c p' '! exec -c p' 'builtin exec -c p' 'command exec -c p' 'A=1 exec -c p' 'exec -l -c p' 'exec -a n -c p'; do
  gt "$r" && bad "rs_gputext refuses the doc's example: $r" || ok "rs_gputext refuses the doc's example: $r"; done
for r in 'env A=1 cmd -i' 'cmd -i' 'exec -ac y' 'exec -a -c y' 'exec -- -c' 'apptainer exec -c img p' 'singularity exec -c img p' 'kubectl exec -c ctr pod -- p'; do
  gt "$r" && ok "rs_gputext lets through the doc's: $r" || bad "rs_gputext lets through the doc's: $r"; done
# R6-2 / R6-3: container runtimes and launcher configs are counted WARNINGs
has "$LSH" 'local dsh=/job/hostfile' "launch.sh looks for deepspeed's default hostfile at /job/hostfile"
for w in "a container started so does not get this launch's CUDA_VISIBLE_DEVICES and may see GPUs its runtime picks" 'drop those flags and settings (it then uses these), or name the GPUs it will use to the user' \
         'drop those flags (it then keeps these), or' '(present: its default hostfile, read without --hostfile)'; do
  has "$PNOT" "$w" "procedure-nohup: the WARNING's words: $w"; has "$LSH" "$w" "...launch.sh's: $w"; done
has "$PNOT" '`with a config it cannot read here (…)`' "procedure-nohup: the unreadable-config form"; has "$LSH" 'a config it cannot read here (' "...launch.sh's"
has "$PNOT" '`--config_file FILE` (relative to the project dir), else `$PROJ/.cache/huggingface/accelerate/default_config.yaml`' "procedure-nohup: which config is read"
has "$PNOT" 'so no grant covers a GPU container run (`docker run --gpus …`) either' "procedure-nohup: no grant covers a container run (NF8)"
has "$ST" 'a container runtime picking GPUs (`docker run --gpus`…, `apptainer --cleanenv`…)' "$F rail: containers"; has "$ST" '(accelerate.s `gpu_ids`, `/job/hostfile`; no `--config_file` while `ENV_HOOK`, `ENV_KIND=conda`, `HF_HOME` or `ACCELERATE_…` may move it)' "$F rail: launcher settings (R7-4: a config it cannot locate too; R8-4: conda)"
has "$RT" 'a container started with GPUs of its own (`docker run --gpus`, `apptainer --cleanenv`)' "README: containers"
has "$CKT" 'a container runtime that picks GPUs' "conf-keys RUN row: containers"; has "$PST" '`docker run --gpus` / `apptainer --cleanenv`' "project-setup: containers"
has "$DT" 'A container does not inherit the landing at all' "DESIGN: containers"; has "$AT" '`rs_launchers`: deepspeed / accelerate launch' "AGENTS: rs_launchers"
mkdir -p "$T/la6"; la6() { ( DEV=0; PROJ=$T/la6; eval "$LA"; rs_launchers "$1" 2>&1 ); }
for r in 'docker run --gpus all img' 'docker run --gpus "device=$CUDA_VISIBLE_DEVICES" img' 'docker run --runtime=nvidia img' 'docker run --runtime runc img' \
         'podman run --device nvidia.com/gpu=all img' 'docker run --device /dev/nvidia0 img' 'docker run --device $D img' 'docker run --privileged img' \
         'docker run -e NVIDIA_VISIBLE_DEVICES img' 'docker run --env NVIDIA_VISIBLE_DEVICES img' 'nvidia-docker run img'; do
  has "$(la6 "$r")" "^WARNING: RUN runs .* — a container started so does not get this launch's CUDA_VISIBLE_DEVICES .*: name the GPUs it will use to the user\$" "rs_launchers warns for the doc's container: $r"; done
for r in 'apptainer exec --cleanenv img p' 'singularity exec -e img p' 'apptainer exec --containall img p' 'apptainer exec -C img p' 'apptainer exec -ce img p'; do
  has "$(la6 "$r")" '^WARNING: RUN runs .* a container started so .*: drop those flags (it then keeps these), or name' "rs_launchers warns for the doc's: $r"; done
for r in 'accelerate launch --config_file $X t.py' 'accelerate launch --config_file ~bob/c.yaml t.py' 'accelerate launch --config_file missing.yaml t.py' 'HF_HOME=/x accelerate launch t.py' 'unset HF_HOME; accelerate launch t.py'; do
  has "$(la6 "$r")" '^WARNING: RUN runs accelerate launch with a .*config it cannot read here (.*drop those flags and settings' "rs_launchers warns (config not readable here): $r"; done
for c in 'gpu_ids: 0,1' 'gpu_ids: "1"' 'gpu_ids:
  - 0'; do printf '%s\n' "$c" > "$T/la6/c.yaml"
  has "$(la6 'accelerate launch --config_file c.yaml t.py')" '^WARNING: RUN runs accelerate launch with gpu_ids: .* in c\.yaml' "rs_launchers warns for the doc's config: $(printf %s "$c" | tr '\n' ' ')"; done
for c in 'gpu_ids: all' 'gpu_ids: null' 'gpu_ids: ~' 'gpu_ids:' 'gpu_ids: "all"'; do printf '%s\n' "$c" > "$T/la6/c.yaml"
  hasnt "$(la6 'accelerate launch --config_file c.yaml t.py')" 'WARNING' "rs_launchers: no warning for the doc's config: $c"; done
for r in 'docker run img' 'docker run -e CUDA_VISIBLE_DEVICES img' 'apptainer exec --nv img p' 'accelerate launch t.py'; do hasnt "$(la6 "$r")" 'WARNING' "rs_launchers: no warning for $r"; done
[ -e /job/hostfile ] && ok "deepspeed's no-flag case: /job/hostfile exists on this machine (SKIP)" || hasnt "$(la6 'deepspeed t.py')" 'WARNING' "rs_launchers: deepspeed with no flags and no /job/hostfile: no warning"
# tests/vgate: launchers.sh's round-6 keys, containers.sh, and how they are run
for k in ds_pool_cvd acc_all acc_cfg_gpu_ids acc_cfg_hyphen acc_cfg_default acc_cfg_json_only; do has "$DT" "$k" "DESIGN lists launchers.sh's $k"; has "$VL" "$k=" "...launchers.sh prints $k="; done
[ -f "$RS_HOME/tests/vgate/containers.sh" ] && ok "tests/vgate/containers.sh exists" || bad "tests/vgate/containers.sh exists"
has "$(cat "$RS_HOME/tests/88-vgate.sh")" 'containers.sh' "...tests/88 checks its plumbing"
has "$DT" "ssh <alias> .bash -s <docker-image|-> <apptainer-image|->. < tests/vgate/containers.sh" "DESIGN: how containers.sh is run (with the user's OK)"; has "$VC" "ssh <alias> 'bash -s <docker-image|-> <apptainer-image|->' < tests/vgate/containers.sh" "...as its header says"
for k in '_version' '_gpus_flag' '_env_e' '_cleanenv' '_containall' '_prefix' 'docker_default_runtime'; do has "$DT" "$k" "DESIGN lists containers.sh's $k"; has "$VC" "$k=" "...containers.sh prints $k="; done
for f in "$PNOT" "$AT"; do has "$f" 'containers.sh' "a doc cites tests/vgate/containers.sh"; done
# R6-1: a deny that names a run and lists relaunch / resubmit stops every launch of it, on any target in its scope
has "$GP" 'def run_deny(' "grants.run_deny"; has "$GP" 'RUN_DENY_NOTE = ("a deny of relaunching a run stops every launch of it, on any target in its scope: rsk cannot see "' "...its refusal's note"
has "$PSLT" '— a deny of relaunching a run stops every launch of it, on any target in its scope: rsk cannot see every earlier attempt (another target, run-watch, an older harness, another checkout)' "procedure-slurm: the refusal's words"
has "$GP" '"every earlier attempt (another target, run-watch, an older harness, another checkout)")' "...grants.py says them"
has "$PSLT" '`DENY relaunch (it names a run: every launch of it too — …)`' "procedure-slurm: grant list's line"; has "$GP" '(it names a run: every launch of it too — rsk cannot see every earlier attempt)' "...grants.describe"
has "$PSLT" 'a launch grant recorded right after it gets a `FLAG`' "procedure-slurm: a launch grant after it is flagged"
has "$PSLT" 'A deny naming no run keeps the derived action' "procedure-slurm: a deny naming no run"
has "$PSLT" 'becomes a deny only once a has run: a deny always wins' "procedure-slurm: a conditional wish waits"
has "$PSLT" 'a deny naming the row.s run with `relaunch` meets it at `(launch)`' "procedure-slurm: rsk watch meets it at (launch)"; has "$WP" '({a}): {why}' "...watch.py names the action"
has "$ST" 'A deny naming a run with `relaunch`/`resubmit` stops every launch of it on any target in its scope (rsk cannot see every earlier attempt)' "$F: the R6-1 rule"
has "$ST" 'record "if a fails, don.t relaunch it" only once a has run' "$F: a conditional wish waits"
has "$PNOT" 'A deny that names the run and lists `relaunch` or `resubmit` stops every launch of it' "procedure-nohup: the same"
has "$DT" 'matches EVERY launch-type action of that run — launch and chain included — on any target in its scope' "DESIGN: the rule"
has "$DT" 'becomes a deny only once a has run: a deny always wins' "DESIGN: the conditional wish"; has "$AT" '`grants.run_deny`' "AGENTS: run_deny"
has "$RT" '"never relaunch a" stops every launch of a in its scope' "README: the same"
has "$TG" 'def test_r6_1_a_relaunch_deny_that_names_a_run_stops_every_launch_of_it' "...test_grants.py pins it"; has "$(cat "$RS_HOME/tests/62-rsk-launch.sh")" 'round 6 R6-1' "...tests/62 end to end"
# R6-5 → R7-2 → R8-3: T_PARTITIONS is the profile's DISPLAY list (policy.sh decides): a --partition it lacks is exit 2 unless
# --unlisted-partition (the user confirmed it is real), then recorded with a NOTE; the list splits on commas and whitespace;
# a GPU type is echoed, never checked (the R8-3 refusal itself: the round 8 section below)
hasnt "$GP" 'raise RskError(f"unknown partition ' "R7-2: grants.check_scope no longer refuses a partition"
hasnt "$PSLT$ST$DT$AT$PKT$I" '`unknown partition`\|unknown partition .P. (--partition)' "R7-2: no doc promises the partition refusal any more"
has "$PSLT" "\`NOTE: partition P is not in the profile's display list (T_PARTITIONS of <t>: a, b; <u>: none) — recorded as given: policy.sh, not the profile, decides which partitions exist; the record matches only a plan whose partition is spelled exactly so\`" "procedure-slurm: the R7-2 NOTE"
has "$GP" 'f"NOTE: partition {' "...grants.partition_note"; has "$GP" "is not in the profile's display list" "...its words"; has "$GP" 'def partition_note(' "...grants.partition_note"
has "$GP" '"decides which partitions exist; the record matches only a plan whose partition is spelled exactly so"' "...the rest of them"
has "$PSLT" '` (<t>: a workstation has no partitions — no launch there names one)`' "procedure-slurm: a workstation-only scope"; has "$GP" 'a workstation has no partitions — no launch there names one' "...grants.py"
has "$PSLT" '`(scope.partitions of #i in FILE)` after P' "procedure-slurm: import's NOTE names the record"; has "$GP" 'f"scope.partitions of #{i} in {args.file}"' "...grants.py"
has "$PSLT" 'split on commas and whitespace: `gpu,preempt` is two' "procedure-slurm: commas separate"
has "$HP" 'partitions=split_partitions(f\[6\])' "...harness.targets reads each profile's T_PARTITIONS"; has "$HP" 're.split(r"\[\\s,\]+", text)' "...split on commas and whitespace"
has "$PSLT" '`NOTE: GPU type X is not checked' "procedure-slurm: a GPU type is echoed"; has "$GP" 'f"NOTE: GPU type {' "...grants.py"
has "$ST" 'a `--partition` the target.s `T_PARTITIONS` display list lacks is exit 2 too: check the spelling with the user — one they confirm is real (policy.sh decides) takes `--unlisted-partition` and is recorded with a NOTE (GPU types are never checked)' "$F: --partition: exit 2 unless --unlisted-partition, then a NOTE (R8-3)"
has "$DT" 'A partition is checked against `T_PARTITIONS`, the profile.s display list' "DESIGN: the same"; has "$DT" "\`tests/62\` 'round 7 R7-2' records and enforces such a deny; 'round 8 R8-3' refuses the typo" "DESIGN cites tests/62"
has "$AT" 'a partition no scoped Slurm target.s `T_PARTITIONS` lists, unless `--unlisted-partition`' "AGENTS: the same"; has "$AT" '`T_PARTITIONS` is a display list, `harness.split_partitions`' "AGENTS: split_partitions"; has "$AT" '`grants.partition_note`' "AGENTS: partition_note"
has "$(tr '\n' ' ' < "$RS_HOME/targets/_template-slurm/profile.sh")" 'a display list (error messages, run-avail.s sinfo -p; spaces or commas separate); policy.sh is the authority: rsk grant refuses a --partition this lacks (exit 2) unless --unlisted-partition, then records it with a NOTE' "slurm template: T_PARTITIONS is a display list"
hasnt "$(cat "$RS_HOME/targets/_template-slurm/profile.sh")" 'what `rsk grant` checks a --partition against' "slurm template: the R6-5 'checked against' wording is gone"
has "$PKT" '`T_PARTITIONS` is a display list (error messages, `run-avail`.s `sinfo -p`; spaces or commas separate): `policy.sh`.s `t_partition` decides which partitions exist' "packs.md: the same"
has "$I" '`T_PARTITIONS` is a display list (spaces or commas; `policy.sh` decides which partitions exist — `rsk grant` refuses a `--partition` it lacks, exit 2, unless `--unlisted-partition`: list every partition the user may name)' "INSTALL: the same"
for f in "$PSLT" "$ST" "$DT" "$AT" "$PKT" "$I" "$(cat "$RS_HOME/targets/_template-slurm/profile.sh")"; do   # R8-3: the R7-2 promise is gone everywhere
  hasnt "$f" 'is never refused\|never refuses a --partition\|never refuses one the list lacks\|only NOTEs a `--partition`\|never a partition (' "R8-3: no doc says a partition the display list lacks is never refused"; done
has "$(cat "$RS_HOME/bin/run-avail")" "tr ' ' ','" "...run-avail hands sinfo -p a comma list (why commas separate)"
has "$TG" 'def test_r7_2_a_partition_the_profile_does_not_list_is_recorded_with_a_note' "...test_grants.py pins it"; has "$TG" 'def test_r7_2_t_partitions_splits_on_commas_and_whitespace' "...and the split"
has "$(cat "$RS_HOME/tests/62-rsk-launch.sh")" 'round 7 R7-2' "...tests/62 end to end (a policy partition the profile omits: recorded, enforced)"
# R6-9, narrowed by R7-2 / R7-6: rsk grant list, rsk status and rsk doctor flag a stored record naming an unknown TARGET (never a partition)
has "$PSLT" '— never matches\[ there\] (the user.s deny is not enforced there | it covers nothing there) — fix or revoke: rsk grant revoke <id> --quote "<the user.s words>", then record it again with a scope the harness knows' "procedure-slurm: grant list's WARNING"
has "$GP" "the user's deny is not enforced there" "...grants.scope_warning"; has "$GP" 'fix or revoke: rsk grant revoke {rid} --quote' "...its fix"
has "$PSLT" 'flag every active record naming a TARGET the harness does not know' "procedure-slurm: targets only"
has "$PSLT" '`rsk grant list`, `rsk status` (its grants block is grant list.s) and `rsk doctor`' "procedure-slurm: list, status and doctor"
has "$PSLT" '`--json`: `scope_problems`' "procedure-slurm: --json scope_problems"; has "$GP" '"scope_problems": scope_problems(r, tl)' "...grants.py's --json"
has "$PSLT" 'NOTE above in grant list and status (`--json`: `scope_notes`), never `never matches`' "procedure-slurm: a stored partition is a NOTE"
has "$GP" '"scope_notes": scope_notes(r, tl)' "...grant list --json"; has "$STP" '"scope_notes": grants.scope_notes(g, tl)' "...status --json"; has "$GP" 'def scope_notes(' "...grants.scope_notes"
has "$STP" 'grants.lines(st, known=tl)' "R7-6: rsk status prints the grants block with the flags (known=)"
has "$PSLT" '(`== grants ==`)' "procedure-slurm: rsk doctor's section"; has "$CLI" 'out("== grants ==")' "...cli.py's doctor"
has "$CLI" 'names a target the "$' "...doctor's ok line: targets only"; hasnt "$CLI" 'names a target or "$' "...the R6-9 'target or partition' ok line is gone"
has "$ST" '`rsk grant list`, `rsk status` and `rsk doctor` flag a record naming a target the harness does not know (`never matches`)' "$F: the flag"
has "$DT" '`== grants ==`; its exit code is unaffected' "DESIGN: doctor's section, exit code unaffected"; has "$CLI" 'fails += level == "FAIL"' "...doctor counts only FAIL lines"
has "$DT" 'so it is never "never matches"' "DESIGN: a partition is a NOTE, never 'never matches'"
has "$RT" 'flags a recorded permission or "never" naming a target the harness does not know' "README: rsk doctor flags them"
has "$I" 'a `== grants ==` WARN = a recorded permission or deny naming a target the harness does not know' "INSTALL: the doctor section"; has "$AT" '`grants.scope_problems`' "AGENTS: scope_problems"
has "$AT" 'list / status NOTE an unlisted partition (`grants.scope_notes`' "AGENTS: scope_notes"
has "$TG" 'def test_r7_2_r6_9_list_status_and_doctor_flag_only_unknown_targets' "...test_grants.py pins it"
has "$(cat "$RS_HOME/tests/py/test_status.py")" 'def test_r7_6_status_flags_a_stored_record_naming_a_target_the_harness_does_not_know' "...test_status.py pins rsk status (R7-6)"
# R6-7: a deny by job ids counts for rsk watch rows only under fail-stop
has "$PSLT" 'except a deny scoped by job ids (`rsk grant deny --job J --action cancel`), which counts only for a table whose `#@ allow` line has `fail-stop`, the one cancel run-watch makes, and there matches every row' "procedure-slurm: R6-7"
has "$WP" 'st if a != "cancel" or "cancel" in acts else no_jobs' "...watch.deny_hit"
has "$DT" 'only a deny scoped by job ids, which is for cancels, counts just for a table whose `#@ allow` has `fail-stop`' "DESIGN: the same"
has "$AT" 'a deny scoped by job ids only for a table whose `#@ allow` has `fail-stop`' "AGENTS: the same"
has "$(cat "$RS_HOME/tests/py/test_watch.py")" 'def test_r6_7_a_deny_by_job_id_counts_only_under_fail_stop' "...test_watch.py pins it"
# R6-8: the UNKNOWN cancel line quotes scancel's line for that job, never another job's
has "$PSLT" 'quotes scancel.s line naming job id J, else its last line naming no job id, else nothing — never another job.s line' "procedure-slurm: R6-8"
has "$CP" 'def scancel_line(' "...cancel.scancel_line"; has "$CP" 'said = scancel_line(' "...used for the UNKNOWN line"
has "$DT" 'never another job.s (`cancel.scancel_line`)' "DESIGN: the same"; has "$AT" '`cancel.scancel_line`' "AGENTS: the same"
has "$TC" 'def test_r6_8_the_unknown_message_quotes_scancel_s_line_for_that_job' "...test_cancel.py pins it"
# run-watch: a --release not used yet is withdrawn once a fail-stop holds its table later in the same watch
has "$PSLT" '(`ATTENTION … reason=release-withdrawn fail-stop=<trigger>`)' "procedure-slurm: release-withdrawn"; has "$RW" 'reason=release-withdrawn fail-stop=' "...bin/run-watch"
has "$PSLT" 'the holds that exist when the watch starts' "procedure-slurm: a release covers the holds at the start"
has "$DT" 'reason=release-withdrawn fail-stop=<trigger>' "DESIGN: the same"; has "$AT" 'reason=release-withdrawn' "AGENTS: the same"
has "$(cat "$RS_HOME/tests/47-watch.sh")" 'round 6: a --release not used yet is withdrawn' "...tests/47 pins it"
# the consolidated honest limits (R6-10; R7-8: the payload is code — scripts, tools beyond the warned list, values only an expansion
# supplies, launcher settings in unread files —, an older installed run-watch is transitional, rsk constrains only what goes through it)
has "$DT" 'What rsk cannot check, in one place' "DESIGN: one honest-limits list"
for w in 'the payload is code — what it does once it starts is outside what rsk can check' \
         'scripts it calls (one that itself calls tmux or sudo), an `exec -c` the text does not show at a command start, a value only an expansion supplies at run time' \
         'tools that replace the environment beyond the warned list (`su -`, `runuser -l`, `pkexec`, at / cron, a script that itself calls tmux)' \
         'a sudoers `env_delete` (not read' 'launcher settings in files rsk does not read: docker `--env-file`, compose files, deepspeed.s `.deepspeed_env`' \
         'so they can fire on a word that is only an argument (`rsync -e ssh`, an `exec` inside `docker run … sh -c`) — fail closed' \
         'a standing launch grant still covers the first launch, on another target, of a run whose earlier attempts rsk cannot see' \
         'rsk and run-watch read a table.s bytes the same way (lines end at LF, words split at space / tab' 'errs toward checking more' \
         'two detect-only run-watch processes started within the same instant over a stale `logs/run-watch/.lock`' \
         'an older installed run-watch is transitional: it reads only the last `#failstop` of a state file' \
         'a `run-watch` installed without rsk — rsk constrains only what goes through it'; do has "$DT" "$w" "DESIGN honest limit: $w"; done
for f in "$DT" "$PNOT"; do hasnt "$f" 'sudo.s `env_reset`, `systemd-run`' "R7-3: sudo / systemd-run / ssh are warned now, no longer beyond the check"; done
has "$PNOT" 'environment changes beyond the tools warned below (an `exec -c` the text does not show at a command start, `su -`, `runuser -l`, `pkexec`, at / cron, a sudoers `env_delete`)' "procedure-nohup honest limit: environment changes beyond the warned tools"
has "$PNOT" 'launcher settings in files rsk does not read (below); RUN is a command, not a GPU choice, and rsk constrains only what goes through it' "procedure-nohup: the R7-8 sentence ends with what rsk constrains"
has "$PNOT" 'tools that replace the environment beyond the list above (`su -`, `runuser -l`, `pkexec`, at / cron, a script that itself calls tmux) and a sudoers `env_delete` (not read)' "procedure-nohup: the launcher paragraph's honest limits"
has "$ST" 'The payload is code: what it runs once it starts (scripts, tools replacing its environment beyond the warned ones, values only an expansion supplies, launcher settings in files rsk does not read) is outside rsk.s checks, as is an older run-watch' "$F §3: the R7-8 sentence"
echo "-- round 7: what the docs now promise, each beside the code that does it (docs @@ code) --"
VE=$(cat "$RS_HOME/tests/vgate/envdrop.sh" 2>/dev/null); T62=$(cat "$RS_HOME/tests/62-rsk-launch.sh"); TL=$(cat "$RS_HOME/tests/py/test_launch.py")
TW=$(cat "$RS_HOME/tests/py/test_watch.py"); LDG=$(cat "$RS_HOME/src/remote_run/ledger.py")
# R7-1: a deny written with an attempt's job name (<run>--aNN, 2+ digits) or a glob over attempt names stands for the whole run
has "$PSLT" 'stands for the whole run: an attempt is launched once, so it matches every attempt of that run (launch, relaunch, chain, cancel) and `rsk watch` rows of it' "procedure-slurm: R7-1"
has "$PSLT" "\`NOTE: name <run>--a02 is an attempt's name (--aNN): the deny stands for run <run> — every attempt of it, the next one included (an attempt is launched once)\`" "procedure-slurm: the NOTE"
has "$GP" 'the deny stands for run {run_glob(g)} — every attempt of it, "$' "...grants.attempt_name_notes"; has "$GP" '"the next one included (an attempt is launched once)")' "...its end"
has "$PSLT" "\`NOTE: name x--a\* matches attempts' names (--aNN)" "procedure-slurm: the glob's NOTE"; has "$GP" '"matches attempts. names"' "...grants.py"
has "$PSLT" '`names <run>--a02 (= run <run>: every attempt of it)`' "procedure-slurm: grant list's line"; has "$GP" ': every attempt of it)"$' "...grants.describe"
has "$PSLT" '`x--a?`, `x--a\[0-9\]`, `x--a\[!0-9\]\*` and `--a\*` match no attempt.s suffix and keep their plain meaning' "procedure-slurm: what does not stand for a run"
has "$GP" 'def run_glob(' "...grants.run_glob"; has "$GP" 'def run_globs(' "...grants.run_globs"; has "$GP" '_glob(run_globs(names), f.run)' "...deny matching uses it"
has "$ST" 'an attempt.s name (`<run>--a02`, `<run>--a\*`) stands for the run' "$F: R7-1"
has "$PNOT" 'a deny written with an attempt.s name (`<run>--a02`, or a glob over them such as `<run>--a\*`) stands for the whole run' "procedure-nohup: R7-1"
has "$DT" 'so it stands for every attempt of the run — launch, relaunch, chain, cancel, and `rsk watch` rows' "DESIGN: R7-1"; has "$DT" '(`grants.run_glob`)' "DESIGN names run_glob"
has "$DT" 'an attempt.s name standing for its run) and lists `relaunch` or `resubmit` matches EVERY' "DESIGN: R6-1's 'names a run' uses the stripped form"
has "$AT" '(`grants.run_glob(s)`, R7-1' "AGENTS: R7-1"
hasnt "$PSLT$DT" 'whose attempt suffix is itself a glob\|x--a\[0-9\]\[0-9\]) is not stripped' "R7-1: the glob-suffix limit the integrator closed is not documented as a limit"
has "$TG" 'def test_r7_1_a_deny_written_with_an_attempts_name_stands_for_the_whole_run' "...test_grants.py pins the literal form"; has "$TG" 'def test_r7_1_a_deny_glob_over_attempt_names_stands_for_the_run' "...and the glob form"
has "$TG" 'def test_r7_1_rsk_grant_deny_with_an_attempt_name_says_it_stands_for_the_run' "...and the NOTE"; has "$T62" 'round 7 R7-1' "...tests/62 end to end"
# R7-3: a tool that starts the command without this launch's environment, or elsewhere: a counted WARNING
for w in 'RUN starts its command through <tool …> — <reason> — so it may use GPUs other than this launch.s GPU(s) \[<ids>\] (any on the box, another user.s too): run the command directly (launch.sh detaches it), or name the GPUs it will use to the user'; do
  has "$PNOT" "$w" "procedure-nohup: the R7-3 WARNING"; done
has "$LSH" "RUN starts its command through \$w\$e — \$r — so it may use GPUs other than this launch's GPU(s) \[\$DEV\] (any on the box, another user's too): run the command directly (launch.sh detaches it), or name the GPUs it will use to the user" "...launch.sh prints it"
has "$PNOT" '`sudo` unless `-E`, `--preserve-env`, or `--preserve-env=` naming both `CUDA_VISIBLE_DEVICES` and `CUDA_DEVICE_ORDER`' "procedure-nohup: sudo"
has "$PNOT" '`-i` / `--login` always warns, and an abbreviation such as `--preserve-e` is not read' "procedure-nohup: sudo -i, abbreviations"
has "$PNOT" '`doas`, `systemd-run`, `ssh` and `srun` / `salloc` / `sbatch` always' "procedure-nohup: always"
has "$PNOT" '`screen` with a short-option cluster holding `d`, `D`, `m`, `R` or `X`' "procedure-nohup: screen"; has "$LSH" 'r:-\[A-Za-z\]\*) v=""; case "$t" in -\*\[!A-Za-z\]\*) ;; \*\[dDmRX\]\*) v=$t ;; esac ;;' "...launch.sh's screen case"
has "$PNOT" '`setpriv --reset-env` (or a prefix of it from `--res`)' "procedure-nohup: setpriv"; has "$LSH" 'p:--res\*) v=""; case --reset-env in "$t"\*) v=$t ;; esac ;;' "...launch.sh's setpriv case"
has "$PNOT" 'fail closed, the card shows why' "procedure-nohup: the text rule can fire on an argument"
has "$PNOT" "\`tests/61\` 'R7-3'" "procedure-nohup cites tests/61 R7-3"; has "$T61" 'R7-3: ' "...tests/61 R7-3"
for k in tmux_server_env tmux_first_env tmux_session screen_dm_env screen_session setpriv_reset_env setpriv_reset_prefix systemd_run_env; do
  has "$PNOT" "\`$k=\`" "procedure-nohup cites envdrop.sh's $k="; has "$DT" "\`$k=\`" "DESIGN cites envdrop.sh's $k="; has "$VE" "$k=" "...tests/vgate/envdrop.sh prints $k="; done
for f in "$PNOT" "$DT"; do has "$f" "ssh <alias> 'bash -s' < tests/vgate/envdrop.sh" "a doc: how envdrop.sh is run (with the user's OK)"; done
has "$VE" "ssh <alias> 'bash -s' < tests/vgate/envdrop.sh" "...as its header says"; has "$VE" "ssh <alias> 'bash -s tmux screen setpriv systemd-run' < tests/vgate/envdrop.sh" "...systemd-run only when named"
has "$(cat "$RS_HOME/tests/88-vgate.sh")" 'envdrop.sh' "...tests/88 checks its plumbing"; has "$AT" 'envdrop.sh' "AGENTS cites envdrop.sh"
has "$PNOT" "\`containers.sh\`'s \`<rt>_exec_env=\`" "procedure-nohup cites containers.sh's <rt>_exec_env="; has "$DT" '`<rt>_exec_env`' "DESIGN: the same"; has "$VC" '_exec_env=' "...containers.sh prints it"
has "$ST" 'a tool starting the command without this launch.s environment or elsewhere (`docker exec`, `tmux new`, `sudo` without `-E`, `ssh`, `srun`…)' "$F rail: R7-3"
has "$PNOT" 'or a tool that starts the command without this launch.s environment or elsewhere' "procedure-nohup §3: R7-3"
has "$CKT" 'a tool that starts the command without this launch.s environment or elsewhere' "conf-keys RUN row: R7-3"
has "$RT" 'a tool that starts the command elsewhere or without the launch.s environment (`docker exec`, `tmux new`, `sudo` without `-E`, `ssh`, `srun`)' "README: R7-3"
has "$PST" 'is a card WARNING too — it starts the command without the launch.s environment or outside the run' "project-setup: drop tmux (the R7-3 WARNING)"
has "$AT" 'a tool that starts the command without this launch.s environment or elsewhere' "AGENTS: R7-3"; has "$DT" 'A tool that starts the command elsewhere, or without this launch.s environment' "DESIGN: R7-3"
# ...the examples the docs give, through launch.sh's own rs_launchers
for r in 'docker exec dev p' 'podman start -a c' 'nerdctl exec c p' 'docker container exec c p' 'docker compose up' 'docker-compose run t p' 'podman-compose up' \
         'kubectl exec pod -- p' 'tmux new -d p' 'tmux send-keys -t s p Enter' 'screen -dm p' 'screen -d -m p' 'screen -S s -X stuff p' 'setpriv --reset-env p' \
         'setpriv --res p' 'sudo p' 'sudo -i -E p' 'sudo --login --preserve-env p' 'sudo --preserve-e p' 'sudo --preserve-env=CUDA_VISIBLE_DEVICES p' 'doas p' \
         'systemd-run --user p' 'ssh h p' 'srun p' 'salloc p' 'sbatch j.sh' 'rsync -e ssh a h:b' 'docker run img sh -c "exec p"'; do
  has "$(la6 "$r")" "^WARNING: RUN starts its command through .* — so it may use GPUs other than this launch's GPU(s) \[0\]" "rs_launchers warns for the doc's: $r"; done
for r in 'sudo -E p' 'sudo --preserve-env p' 'sudo --preserve-env=CUDA_VISIBLE_DEVICES,CUDA_DEVICE_ORDER p' 'tmux ls' 'screen -ls' 'docker run img p' 'nohup p' 'setsid p'; do
  hasnt "$(la6 "$r")" 'WARNING' "rs_launchers: no warning for $r (the landing reaches it)"; done
has "$(la6 'nerdctl run --gpus all img')" "^WARNING: RUN runs nerdctl with --gpus — a container started so" "rs_launchers: nerdctl joins the container runtimes (R6-2)"
has "$(la6 'python -m accelerate.commands.accelerate_cli launch --gpu_ids 0 t.py')" '^WARNING: RUN runs .* with --gpu_ids — such a launcher' "rs_launchers: python -m accelerate.commands.accelerate_cli launch is accelerate"
has "$PNOT" '`docker` / `podman` / `nerdctl` /' "procedure-nohup: nerdctl"; has "$PNOT" '`python -m accelerate.commands.accelerate_cli launch`' "procedure-nohup: accelerate_cli"
# R7-4: accelerate launch with no --config_file when the config it reads is unknown (an ENV_HOOK, a conf or RUN naming HF_HOME / ACCELERATE_…)
w='with no --config_file: the config accelerate reads is unknown (ENV_HOOK .<hook>. may move it | ENV_KIND=conda: conda activate .<env>. applies the env.s own variables (HF_HOME / ACCELERATE_… among them), which may move it | .ws.conf names <NAME>, which may move it | RUN names <NAME>, which may move it | .ws.conf did not source here | .ws.conf could not be read here | .wandb_env names HF_HOME, which may move it | .wandb_env names an ACCELERATE_… variable, which may move it | .wandb_env could not be read here)'
has "$PNOT" "$w" "procedure-nohup: the R7-4 WARNING"
has "$PNOT" 'give it --config_file FILE (read here, bound in the plan) and drop any GPU flags and settings, or name the GPUs it will use to the user' "...its advice"
has "$LSH" 'give it --config_file FILE (read here, bound in the plan) and drop any GPU flags and settings, or name the GPUs it will use to the user' "...launch.sh's"
for k in "ENV_HOOK '\${EH//" '.ws.conf names ${BASH_REMATCH\[2\]}, which may move it' '.ws.conf did not source here' '.ws.conf could not be read here' 'RUN names ${BASH_REMATCH\[2\]}, which may move it'; do
  has "$LSH" "$k" "...launch.sh's reason: $k"; done
has "$PNOT" 'when the conf sets `ENV_HOOK` (env.sh sources it after setting `HF_HOME`, and it may set anything)' "procedure-nohup: why a hook makes it unknown"
has "$PNOT" 'the project.s own default config is still read, and bound, beside it' "procedure-nohup: the default config is still read"
has "$DT" "\`tests/61\` 'R7-4'" "DESIGN cites tests/61 R7-4"; has "$T61" 'R7-4: ' "...tests/61 R7-4"; has "$CKT" 'this conf sets `ENV_HOOK` or `ENV_KIND=conda`, or it, RUN or the project.s `.wandb_env` names `HF_HOME` / `ACCELERATE_…` other than as an expansion' "conf-keys RUN row: R7-4 (+ R8-4: conda; NF7: .wandb_env)"
la7() { ( DEV=0; PROJ=$T/la6; RS_CFGWHY=$2; eval "$LA"; rs_launchers "$1" 2>&1 ); }
has "$(la7 'accelerate launch t.py' "ENV_HOOK 'h.sh' may move it")" "^WARNING: RUN runs accelerate launch with no --config_file: the config accelerate reads is unknown (ENV_HOOK 'h.sh' may move it) — " "rs_launchers: the doc's hook case"
has "$(la7 'ACCELERATE_USE_CPU=0 accelerate launch t.py' '')" "unknown (RUN names ACCELERATE_USE_CPU, which may move it)" "rs_launchers: the doc's RUN-names-ACCELERATE_ case"
printf 'gpu_ids: all\n' > "$T/la6/c.yaml"
for r in 'accelerate launch --config_file c.yaml t.py' 'accelerate launch --gpu_ids 0 t.py' 'deepspeed t.py'; do
  hasnt "$(la7 "$r" "ENV_HOOK 'h.sh' may move it")" 'the config accelerate reads is unknown' "rs_launchers: not for $r (the config is named, or the ids are flags)"; done
hasnt "$(la7 'accelerate launch t.py --dir ${ACCELERATE_DIR:-x}' '')" 'WARNING' "rs_launchers: an expansion of ACCELERATE_… is a read, no warning"
has "$PNOT" 'every call, in every mode, reads the conf as env.sh resolves it' "procedure-nohup: the conf is read in every mode"; has "$LSH" '</dev/null > "$A/env.kv" 3>&- 4>&- 9>&-' "...launch.sh reads it with fds 3/4/9 closed"
has "$PNOT" 'a plain launch goes on to env.sh.s gate' "procedure-nohup: a plain launch's broken conf goes to the gate"; has "$LSH" '\[ "$PLAN" = 0 \] && \[ -z "$EXPECT" \] || die2 "sourcing $PROJ/.ws.conf' "...launch.sh refuses only a plan / --rs-expect"
has "$T61" "the conf is read without the caller's channel (fds 3/4) or the launch lock (9)" "...tests/61 pins the closed fds"
# R7-5: launch_cfg — every launcher config / hostfile read is bound; an edit after the card is exit 6
has "$PNOT" 'bound: `name gpus_req exclude nice launch_cfg busy_ok payload env_kind env_hook venv_dir uv_sync_args env_name`' "procedure-nohup: the bound list"
has "$LSH" 'launch_cfg=%s\\nbusy_ok=%s' "...launch.sh binds launch_cfg right before busy_ok"; has "$GP" '"nice", "launch_cfg", "busy_ok"' "...grants.NOHUP_BOUND"
has "$GP" '"busy_ok", "launch_cfg", "env_hook"' "...grants.NEEDED (nohup): needs: sync without it"; has "$LDG" 'nice launch_cfg busy_ok' "...ledger.BOUND_KEYS keeps it with each attempt"
has "$PNOT" '`<file>:unreadable` for one it could not read (missing, over 64 KiB, named by an expansion or `~user`, relative after a cd), empty when none, `%q`-quoted only when not plain' "procedure-nohup: launch_cfg's values"
has "$PNOT" 'relative, after a cd in RUN' "procedure-nohup: a relative --config_file after a cd"; has "$LSH" 'relative, after a cd in RUN' "...launch.sh's"
has "$PNOT" '`launch cfg <file> (sha256 <12 hex>) · …`' "procedure-nohup: the card row"; has "$LP" '("launch cfg", _cfgs(' "...launch.py's card"
has "$PNOT" '(UNREADABLE on the box: what the launcher reads there is unknown)' "procedure-nohup: an unreadable one"; has "$LP" '(UNREADABLE on the box: what the launcher reads there is unknown)' "...launch.py"
has "$PNOT" 'exit 6 `changed: launch_cfg`' "procedure-nohup: an edit after the card"; has "$T61" "changed: launch_cfg" "...tests/61 shows it"
has "$PNOT" 'the resolved launch differs from the approved plan — launch_cfg: <file> (sha256 <old>) → <file> (sha256 <new>): plan again — the new card goes to the user' "procedure-nohup: rsk's words"
has "$LP" 'plan again — the new card goes to the user' "...launch.py's"; has "$LP" 'changed("launch")' "...for a launch"
has "$PNOT" '`needs: sync … lacks launch_cfg`' "procedure-nohup: a block without it"; has "$PNOT" 'a nohup plan stored without it is refused at `--plan` (`lacks launch_cfg`)' "...a stored plan without it"
has "$PNOT" 'an edited launcher config is `not the configuration of aNN it resumes: launch_cfg …`' "procedure-nohup: a relaunch grant repeats it"
has "$PNOT" 'an attempt recorded before rsk kept `launch_cfg` has none, so a relaunch whose plan reads a config needs the user once' "...an older attempt"
has "$DT" '`launch_cfg=<path>:<sha256>\[,…\]`' "DESIGN: launch_cfg"; has "$AT" '`launch_cfg=<path>:<sha256>,…`' "AGENTS: launch_cfg"
has "$T61" 'R7-5: ' "...tests/61 R7-5"; has "$T62" 'round 7 R7-5' "...tests/62 R7-5"
has "$TL" 'def test_r7_5_the_launcher_config_is_bound_shown_and_a_change_is_named' "...test_launch.py the card and the drift"
has "$TL" 'def test_r7_5_a_block_without_launch_cfg_needs_a_sync' "...a block without it"; has "$TL" 'def test_r7_5_the_ledger_records_launch_cfg_so_a_relaunch_repeats_it' "...the ledger keeps it"
# R7-7: a run-watch table is plain text — rsk and run-watch refuse a NUL / control character (CR included) in the same words
w='a NUL byte or a control character other than tab — a run-watch table is plain text (LF line ends); rsk and run-watch both refuse it'
has "$PSLT" "\`<table>: line N holds 0xHH, $w\`" "procedure-slurm: the R7-7 refusal"; has "$RW" "$w" "...bin/run-watch's words"; has "$T62" "$w" "...tests/62 checks rsk's (and run-watch's: the same)"
has "$WP" 'a NUL byte or a control character other than tab — a run-watch table is plain text (LF "$' "...watch.py's"
has "$PSLT" 'a CR too, so a CRLF table, which run-watch used to accept by stripping the CR, is refused now: save tables with LF line ends' "procedure-slurm: CRLF tables are refused now"
has "$PSLT" 'in `rsk watch` (every mode, before the lease) and in run-watch alike' "procedure-slurm: both, every mode"; has "$WP" '^    check_tables(proj, argv)' "...rsk watch checks before the lease"
has "$PSLT" 'run-watch checks it at every read and `rsk watch --act` at each lease refresh, so such a byte written into a table while a watch runs ends that watch (exit 2)' "procedure-slurm: during a watch"
has "$RW" 'parse_all; load_targets; reconcile' "...run-watch re-reads every round"; has "$WP" 'denied, denied_code = (str(exc) if exc.code == USAGE else' "...rsk watch's refresh stops it with exit 2"
has "$PSLT" 'may not hold a double quote, a newline or a control character other than tab (exit 2, nothing written); UTF-8 text such as Chinese is fine' "procedure-slurm: the --approve words"
has "$RW" 'no double quote, no control character other than tab' "...run-watch's refusal"
has "$DT" 'One table, one reading' "DESIGN: R7-7"; has "$DT" 'which run-watch used to accept by stripping the CR, is refused now' "DESIGN: the CRLF change"; has "$AT" 'R7-7' "AGENTS: R7-7"
has "$TW" 'def test_r7_7_a_nul_in_the_allow_line_or_a_row_name_is_refused_before_anything_starts' "...test_watch.py pins it"; has "$TW" 'def test_r7_7_every_control_character_but_tab_is_refused_cr_included' "...CR included"
has "$T62" 'round 7 R7-7' "...tests/62 end to end"
X=$(printf 'fail\0-stop\n' | bash -c 'IFS= read -r l; printf %s "$l"' 2>/dev/null)   # the bash fact DESIGN cites
[ "$X" = fail-stop ] && ok "bash fact: read drops a NUL byte (fail\\0-stop reads as fail-stop, which Python keeps apart)" || bad "bash fact: read drops a NUL ($X)"
X=$(printf 'x\r\n' | bash -c 'IFS= read -r l; printf %s "$l"' | od -An -c | tr -d ' ')
[ "$X" = 'x\r' ] && ok "bash fact: read keeps a CR (an older run-watch stripped one per line itself)" || bad "bash fact: read keeps a CR ($X)"
# the wrapper's exit record: rc always 0-255 (a wait that cannot give the run's status keeps the interrupted wait's 143)
has "$PNOT" 'rc is always 0–255' "procedure-nohup: the exit record"; has "$DT" 'rc is always 0–255' "DESIGN: the same"
for f in "$PNOT" "$DT"; do has "$f" 'RS_STRESS_TEST=1 bash selftest.sh' "a doc names the opt-in reproduction"; has "$f" 'bash 5.2.37 returned -1' "a doc names the bash fact"; done
has "$LSH" '\[ "$_rw_w" -lt 0 \] || \[ "$_rw_w" -gt 255 \] || \[ "$_rw_w" = 127 \] || _rw_rc=$_rw_w' "...launch.sh's wrapper keeps 143"
has "$T61" 'RS_STRESS_TEST' "...tests/61's opt-in section"; has "$T61" 'bash 5.2.37 here wrote rc=-1 term=1 in 3 of 60 such runs' "...where the fact was seen"
echo "-- round 8: what the docs now promise, each beside the code that does it (docs @@ code) --"
TST=$(cat "$RS_HOME/tests/py/test_status.py"); T88=$(cat "$RS_HOME/tests/88-vgate.sh"); TPS=$(tr '\n' ' ' < "$RS_HOME/targets/_template-slurm/profile.sh")
# R8-1: every list argument of rsk grant add|deny is split on commas, each item stripped; an empty item or one holding whitespace is
# exit 2 naming it; --job takes job ids / pids; validate() rejects a stored list item with whitespace (an invalid deny matches everything)
has "$PSLT" 'Every list argument of `rsk grant add|deny` (`-T`, `--partition`, `--gpu-type`, `--class`, `--name`, `--job`, `--run`, `--action`; repeatable, `a,b`) is split on commas and each item stripped (`--name .b1, b2.` is b1 and b2)' "procedure-slurm: R8-1, the split"
has "$PSLT" "an empty item or one with whitespace inside is exit 2 naming it, nothing recorded (\`--job '101 102': item '101 102' holds whitespace …\`, \`--job '101,': an empty item …\`)" "procedure-slurm: R8-1, the refusals"
has "$GP" ': item {p!r} holds whitespace — no name, job id, partition, ' "...grants._split's words"; has "$GP" ': an empty item (items are separated by commas' "...the empty item's"
has "$GP" 'FLAGS = {"targets": "-T", "partitions": "--partition", "gpu_types": "--gpu-type", "classes": "--class",' "...every list flag goes through grants._arg"
has "$PSLT" '`--job` takes job ids or pids only (`123`, `123_4`)' "procedure-slurm: --job ids only"; has "$GP" 'JOB_ID = re.compile(r"\[0-9\]+(?:_\[0-9\]+)?")' "...grants.JOB_ID"
has "$PSLT" 'with a list item holding whitespace is invalid (`whitespace in a scope item`): as a deny it matches everything (fail closed), anything else covers nothing' "procedure-slurm: a stored spaced item"
has "$GP" ': whitespace in a scope item (it never matches what it names; ' "...grants.validate's words"; has "$GP" '^SPACE_FREE = ("targets", "partitions", "gpu_types", "classes", "names", "runs", "plans", "jobs")' "...grants.SPACE_FREE"
has "$ST" 'List flags split on commas (`--name .b1, b2.` is two); an empty item or one holding a space is exit 2' "$F §3: R8-1"
has "$DT" 'Every list argument of `rsk grant add|deny` (targets, partitions, GPU types, classes, names, jobs, runs, actions) is split on commas and each item stripped' "DESIGN: R8-1"
has "$DT" 'so such a deny, imported or edited in by hand, is invalid and matches everything (R8-1; cancel identities, which hold a WorkDir, are exempt)' "DESIGN: R8-1, stored items"
has "$AT" 'every list argument split on commas and stripped, an empty or spaced item exit 2, `--job` ids / pids only (`grants._split`, R8-1), a stored spaced item invalid (`grants._spaced`)' "AGENTS: R8-1"
for t in test_r8_1_split_strips_comma_items_and_refuses_empty_or_spaced_ones test_r8_1_a_stored_item_with_whitespace_is_invalid_and_a_deny_then_matches_everything \
         test_r8_1_rsk_grant_lists_split_on_commas_stripped_whitespace_inside_is_exit_2; do has "$TG" "def $t" "...test_grants.py: $t"; done
has "$T62" 'round 8 R8-1' "...tests/62 end to end"
# R8-2: rsk cancel --approve: the user's words must name what is cancelled, as a whole token, else exit 4 and nothing is recorded
has "$ST" 'Their words must name what is cancelled, as a whole word — the job id / pid (or a range holding it: `102-104`) or the run.s id or name (`rsk cancel <run>`: the run, or every job id) — or, when they answer your question ("sw1 diverged — cancel it?" → "yes"), `--asked "<that question>"` may name it (recorded with their words; never ask again) — else exit 4 `needs user: the words do not name …`, nothing recorded: ask which one they mean ("cancel it" names nothing)' "$F §3: R8-2 + NF8 (--asked, ranges)"
has "$ST" 'rsk cancel <run> \[--job <id|pid>\] \[--approve "<their words>" \[--asked "<your question>"\]\]' "$F: the cancel line names --asked"
has "$PSLT" 'The words given to `--approve` must name what is cancelled, as a whole word: for `--job J` the job id J or the run.s id or job name; for `rsk cancel <run>` the run id or name, or every job id it cancels (a chain: the run, or all its jobs)' "procedure-slurm: R8-2"
has "$PSLT" '`needs user: the words do not name <J|run> — "<words>" names none of: job J = run <run> (<name>) on <t>; nothing recorded or cancelled` (with `--asked`: `"<words>" (answering "<question>") names none of: …`), no approval and no ssh' "procedure-slurm: R8-2, its words"
has "$PSLT" 'a numeric range names every id in it (`cancel jobs 102-104`, `102 to 104`, `102…104`: 102, 103 and 104)' "procedure-slurm: NF8 ranges"
has "$PSLT" 'pass that question verbatim with `--asked "<your question>"`: it may name the job instead, and is recorded beside the words (the approval.s `source`, `asked: "…"`, and the audit.s cancel lines) — never ask the user a second time' "procedure-slurm: NF8 --asked"
has "$PSLT" 'the asked text is your own bookkeeping, rsk does not read whether the answer was a yes — pass it only when the user agreed' "procedure-slurm: NF8's honest limit"
has "$PSLT" '(`101` is not named by `1101` or `101_2`, `sw1` not by `sw10`, `exp--sw1` or `sw1-b`; trailing punctuation is fine: `cancel job 101.`)' "procedure-slurm: whole tokens (test_cancel.Named pins these examples)"
has "$PNOT" 'The `--approve` words must name what is stopped, as a whole word: the pid (`--job <pid>`; a numeric range holding it counts: `4101-4103`) or the run.s id or name' "procedure-nohup: R8-2 (+ NF8 ranges)"
has "$PNOT" 'pass that question verbatim with `--asked`: it may name the run instead, and is recorded beside the words (the approval.s `source`, the audit) — never ask the user again' "procedure-nohup: NF8 --asked"
has "$PNOT" 'the question is your own text and rsk does not read whether the answer was a yes' "procedure-nohup: NF8's honest limit"
has "$PNOT" '`needs user: the words do not name <pid|run> — "<words>" names none of: pid P = run <run> (<name>) on <t>; nothing recorded or cancelled`' "procedure-nohup: R8-2, its words"
has "$CP" 'out(f"needs user: the words do not name {what or ' "...cancel.authorize prints them"; has "$CP" '+ f" names none of: {them} on {target}; nothing recorded or cancelled")' "...the rest of them"
has "$CP" '+ (f" (answering \\"{asked}\\")" if asked else "")' "...with the question they answer (NF8)"
has "$CP" 'them = "; ".join(f"{unit} {i.job}" + (f" = run {i.run} ({i.name})"' "...job J = run <run> (<name>)"; has "$CP" 'unit = "job" if kind == "slurm" else "pid"' "...job / pid"
has "$CP" 'def named(' "...cancel.named"; has "$CP" 'def unnamed(' "...cancel.unnamed"; has "$CP" 'miss = unnamed(items, words, asked) if words is not None else \[\]' "...checked before the approval is recorded (the words or the asked question)"
has "$CP" 'def ranges(' "...cancel.ranges (NF8)"; has "$CP" 'p.add_argument("--asked"' "...rsk cancel --asked (NF8)"; has "$GP" "return f'asked: \"{asked}\"'" "...grants.asked_source: the approval's source"
has "$DT" 'Words that answer the agent.s own question name what the question names: `--asked "<the question, verbatim>"`' "DESIGN: NF8 --asked"
has "$DT" 'the asked text is its own (it can write any question; rsk does not read whether the answer was a yes)' "DESIGN: NF8's honest limit"
for t in test_nf8_a_yes_to_the_agents_question_names_what_the_question_names test_nf8_a_numeric_range_names_every_job_id_in_it test_nf8_ranges_the_docs_examples; do
  has "$TC" "def $t" "...test_cancel.py: $t"; done; has "$T62" "NF8: a yes to the agent's own question (--asked)" "...tests/62 end to end"
has "$DT" 'This is a token check against good-faith slips, not proof of consent' "DESIGN: R8-2's honest limit"; has "$DT" '(R8-2, `cancel.named` / `cancel.unnamed`)' "DESIGN: R8-2"
has "$AT" '`cancel.named` / `cancel.unnamed`, R8-2' "AGENTS: R8-2"; has "$RT" '"cancel job 123" must name the job (its id, or the run.s name; or answer the agent.s question naming it)' "README: R8-2 + NF8"
for t in test_r8_2_the_users_words_must_name_what_is_cancelled test_r8_2_a_chain_needs_its_run_or_every_job_and_cancel_own_is_unchanged \
         test_r8_2_nohup_words_name_the_pid_or_the_run test_r8_2_named_takes_whole_tokens_only_the_docs_examples; do has "$TC" "def $t" "...test_cancel.py: $t"; done
has "$T62" 'round 8 R8-2' "...tests/62 end to end"
# R8-3: a partition no scoped Slurm target's T_PARTITIONS lists is exit 2 unless --unlisted-partition (import: "unlisted_ok": true)
has "$PSLT" "is exit 2, nothing recorded: \`partition P is not in the profile's display list (T_PARTITIONS of <t>: a, b) — nothing recorded: check the spelling with the user (a misspelt partition never matches: the deny would not be enforced, the grant would cover nothing); if it is a real partition the display list omits (policy.sh decides which exist), record it again with --unlisted-partition\`" "procedure-slurm: the R8-3 refusal"
has "$GP" "the profile's display list (T_PARTITIONS of {lists}) — nothing recorded: check the \"$" "...grants.check_scope's words"
has "$GP" '"spelling with the user (a misspelt partition never matches: the deny would not be "$' "...the rest"; has "$GP" 'omits (policy.sh decides which exist), record it again with {unlisted_how}", USAGE)' "...record it again with"
has "$GP" '^UNLISTED_FLAG = "--unlisted-partition"$' "...grants.UNLISTED_FLAG"; has "$GP" 'def unlisted_partitions(' "...grants.unlisted_partitions"
has "$PSLT" '`… with "unlisted_ok": true in record #i`' "procedure-slurm: import's form"; has "$GP" "unlisted_how=f'\"unlisted_ok\": true in record #{i}')" "...grants.py's"
has "$PSLT" '(import: that record.s `"unlisted_ok": true`, a boolean, never stored)' "procedure-slurm: unlisted_ok"; has "$GP" 'ok = raw.pop("unlisted_ok", False)' "...import pops it (never stored)"
has "$PSLT" 'No check, the NOTE only, when a scoped Slurm target.s profile lists no `T_PARTITIONS` (`<u>: none`) or only workstations are in scope' "procedure-slurm: where nothing is checked"
has "$GP" 'if unchecked or not any(t.kind != "nohup" for t in scoped):' "...unlisted_partitions: no list, or no Slurm target"
has "$DT" 'The rule now (R8-3): a partition no scoped Slurm target.s list names' "DESIGN: R8-3"; has "$DT" 'a typo (`dbug` for `debug`) left the user.s "never" unenforced' "DESIGN: why"
has "$AT" '(R8-3, `grants.unlisted_partitions`, `grants.check_scope(…, unlisted_ok)`' "AGENTS: R8-3"
has "$PKT" 'refuses one the list lacks (exit 2: a typo would never match) unless the user confirms it is real (`--unlisted-partition`; import: `"unlisted_ok": true`)' "packs.md: R8-3"
has "$TG" 'def test_r8_3_a_partition_the_display_list_lacks_is_exit_2_unless_unlisted_partition' "...test_grants.py pins it"; has "$T62" 'round 8 R8-3' "...tests/62 end to end"
# R8-4: ENV_KIND=conda leaves the config accelerate launch reads (without --config_file) unknown: conda activate runs after HF_HOME
has "$PNOT" 'when `ENV_KIND=conda` (env.sh runs `conda activate` after setting `HF_HOME`, and it applies the env.s own variables' "procedure-nohup: R8-4"
has "$LSH" "RS_CFGWHY=\"ENV_KIND=conda: conda activate '\${EN//\[\[:cntrl:\]\]/?}' applies the env's own variables (HF_HOME / ACCELERATE_… among them), which may move it\"" "...launch.sh's reason, word for word"
has "$DT" 'when `ENV_KIND=conda` (env.sh runs `conda activate` after exporting `HF_HOME`' "DESIGN: R8-4"; has "$DT" "\`tests/61\` 'R8-4'" "DESIGN cites tests/61 R8-4"; has "$T61" 'R8-4: ' "...tests/61 R8-4"
has "$AT" '`ENV_KIND=conda` (R8-4: `conda activate` applies the env.s own variables)' "AGENTS: R8-4"
a=$(grep -n 'export HF_HOME=' "$RS_HOME/remote/env.sh" | head -1 | cut -d: -f1); b=$(grep -n 'conda activate "$ENV_NAME"' "$RS_HOME/remote/env.sh" | head -1 | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok "env.sh fact R8-4 rests on: HF_HOME is exported (line $a) before conda activate (line $b)" || bad "env.sh: HF_HOME before conda activate ($a, $b)"
# R8-5: a hostfile deepspeed's -H / --hostfile names is read and bound in launch_cfg
has "$PNOT" 'A hostfile named by deepspeed.s `-H FILE` / `--hostfile FILE` (`-HFILE`, `-H=FILE`, `--hostfile=FILE`, an argparse prefix such as `--hostf`; every one given) is read too, as `--config_file` is' "procedure-nohup: R8-5"
has "$PNOT" 'deepspeed.s `-H`/`--hostfile` file(s), else `/job/hostfile`)' "procedure-nohup: launch_cfg names it"; has "$LP" "each file deepspeed's -H / --hostfile" "...launch.py's _cfgs says so"
has "$DT" '`ds_hostfile_flag` — want `h1,h2,h3,h4,h5,h7`' "DESIGN: launchers.sh's ds_hostfile_flag"; has "$VL" 'ds_hostfile_flag=' "...launchers.sh prints it"
has "$DT" "\`tests/61\` 'R8-5'" "DESIGN cites tests/61 R8-5"; has "$T61" 'R8-5: ' "...tests/61 R8-5"; has "$AT" 'R8-5: each file deepspeed.s `-H` / `--hostfile` names too' "AGENTS: R8-5"
la8() { ( DEV=0; PROJ=$T/la6; eval "$LA"; rs_launchers "$1" 2>/dev/null; echo "cfg=$LAUNCH_CFG" ); }
printf 'localhost slots=1\n' > "$T/la6/hosts"
for r in 'deepspeed --hostfile hosts t.py' 'deepspeed -Hhosts t.py' 'deepspeed -H=hosts t.py' 'deepspeed --hostf hosts t.py' 'deepspeed --hostfile=hosts t.py'; do
  has "$(la8 "$r")" '^cfg=hosts:[0-9a-f]\{64\}$' "rs_launchers binds the doc's spelling: $r"; done
cp "$T/la6/hosts" "$T/hosts.abs"; has "$(la8 "deepspeed -H $T/hosts.abs t.py")" "^cfg=$T/hosts.abs:[0-9a-f]\{64\}\$" "rs_launchers: an absolute path (outside the project) as given"
has "$(la8 'cd x && deepspeed -H hosts t.py')" '^cfg=hosts:unreadable$' "rs_launchers: relative after a cd: unreadable"
has "$(la8 'deepspeed -H $HF t.py')" '^cfg=\$HF:unreadable$' "rs_launchers: through an expansion: unreadable"
has "$(la8 'deepspeed t.py --hostfile')" "^cfg='':unreadable\$" "rs_launchers: a flag with no value: '':unreadable (the block %q-quotes it)"
# R8-6: tmux runs a command by any unique prefix of its name, an alias or a default command-alias
has "$PNOT" 'or a unique prefix tmux accepts (`split`, `spl`, `sp`, `run-`, `ru`, `i`, `if-`, `pi`; `new-` and `resp` too: a word at least as long as the shortest prefix only these commands share' "procedure-nohup: R8-6"
has "$PNOT" '`s`, `r`, `p`, `ne`, `res`, `display-p` or `send-`, which tmux finds ambiguous with a command not listed here and refuses, do not warn' "procedure-nohup: what does not warn"
hasnt "$PNOT" '`pipe-pane` and their prefixes (a session made' "procedure-nohup: the pre-R8-6 'their prefixes' wording is gone"
has "$DT" 'under any name tmux runs them by — an alias, a default command-alias (`splitp`, `split-pane`) or any unique prefix tmux accepts' "DESIGN: R8-6"
has "$AT" 'tmux — any alias or unique prefix tmux runs as a warned command (R8-6' "AGENTS: R8-6"
has "$LSH" 'for o in new-session:3 new-window:3 split-window:2 respawn-pane:4 respawn-window:4 run-shell:2 if-shell:1 display-popup:10 pipe-pane:2 send-keys:6; do' "...launch.sh's prefix table"
has "$LSH" 'case "$t" in neww|send|splitw|splitp|split-pane|respawnp|respawnw|popup|pipep) v=$t ;; esac' "...and its alias list"
for k in tmux_split_prefix_env tmux_prefix tmux_alias; do
  has "$PNOT" "\`$k=\`" "procedure-nohup cites envdrop.sh's $k="; has "$DT" "\`$k=\`" "DESIGN cites envdrop.sh's $k="; has "$VE" "$k=" "...tests/vgate/envdrop.sh prints $k="; done
has "$T88" "R8-6: each length in launch.sh.s tmux table is the shortest prefix" "...tests/88 checks the table against this machine's tmux"
for r in 'tmux split -d p' 'tmux spl p' 'tmux sp p' 'tmux run- p' 'tmux ru p' 'tmux i p' 'tmux if- p' 'tmux pi p' 'tmux new- p' 'tmux resp p' 'tmux splitp p' 'tmux split-pane p'; do
  has "$(la6 "$r")" "^WARNING: RUN starts its command through tmux" "rs_launchers warns for the doc's: $r"; done
for r in 'tmux s p' 'tmux r p' 'tmux p x' 'tmux ne p' 'tmux res p' 'tmux display-p' 'tmux send- p'; do
  hasnt "$(la6 "$r")" 'WARNING' "rs_launchers: no warning for the doc's $r (tmux finds it ambiguous)"; done
# R8-7: rsk status never crashes on a damaged grants record; --json lists one validate() rejects as {record, invalid, fail_closed}
has "$PSLT" 'in the `--json` of both `rsk grant list` and `rsk status`, as `{record, invalid, fail_closed}` — never described; no view fails on one' "procedure-slurm: R8-7"
has "$STP" '{"record": g, "invalid": grants.valid(g), "fail_closed": grants.fail_closed(g)}' "...status.py's --json"; has "$GP" '{"record": r, "invalid": valid(r), "fail_closed": fail_closed(r)}' "...grant list --json"
has "$DT" 'the `--json` of both as `{record, invalid, fail_closed}` (R8-7' "DESIGN: R8-7"; has "$AT" '`--json` `{record, invalid, fail_closed}`, never described (R8-7)' "AGENTS: R8-7"
has "$TST" 'def test_r8_7_status_never_crashes_on_a_damaged_grants_record' "...test_status.py pins it"
# round 8's honest limits (R7-8's list): tools left unwarned, tmux's own config (a .wandb_env setting HF_HOME left the list: NF7 checks it)
for w in '`byobu`, `lxc` / `incus exec`, `ray job submit`, `mpirun` / `mpiexec` `--host` / `--hostfile`, `su -l`, `pixi run --clean-env`, `run0`' \
         'tmux commands run from a user `command-alias`, a `-f` config, `source-file` or `set-hook`'; do
  has "$DT" "$w" "DESIGN honest limit: $w"; done
has "$PNOT" 'tools not on the list at all (`byobu`, `lxc` / `incus exec`, `ray job submit`, `mpirun` / `mpiexec` `--host`, `su -l`, `pixi run --clean-env`, `run0`); tmux commands it runs from a user `command-alias`, a `-f` config, `source-file` or `set-hook`.' "procedure-nohup: the same honest limits"
hasnt "$PNOT$DT" 'a `.wandb_env` that sets `HF_HOME` (env.sh sources it after\|launch.sh does not read it)' "NF7: a .wandb_env setting HF_HOME is no longer an honest limit (launch.sh reads it)"
a=$(grep -n '\. "$PROJ/.wandb_env"' "$RS_HOME/remote/env.sh" | head -1 | cut -d: -f1); b=$(grep -n 'export HF_HOME=' "$RS_HOME/remote/env.sh" | head -1 | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$b" -lt "$a" ] && ok "env.sh fact NF7's .wandb_env check rests on: it is sourced (line $a) after HF_HOME is exported (line $b)" || bad "env.sh: .wandb_env after HF_HOME ($a, $b)"
for k in '.wandb_env names $l, which may move it' '.wandb_env could not be read here' 'l="an ACCELERATE_… variable"'; do has "$LSH" "$k" "...launch.sh's NF7 reason: $k"; done
has "$PNOT" '.wandb_env names HF_HOME, which may move it' "procedure-nohup: NF7's reason"; has "$PNOT" "\`tests/61\` 'NF7'" "procedure-nohup cites tests/61 NF7"
has "$DT" "\`tests/61\` 'NF7'" "DESIGN cites tests/61 NF7"; has "$T61" 'NF7: a .wandb_env assigning HF_HOME' "...tests/61 NF7"; has "$AT" '`.wandb_env` (NF7; read-only, never printed)' "AGENTS: NF7"
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
  [ -f "$f" ] || continue; [ "$f" != "$RS_HOME/remote/API" ] || continue   # API is data: the one line api=N (no comment to parse around)
  head -3 "$f" | grep -q '^#[^!]' && ok "header comment: ${f#"$RS_HOME"/}" || bad "header comment: ${f#"$RS_HOME"/}"
done
budget() { [ -f "$RS_HOME/$1" ] || { bad "$1 exists"; return; }; local n; n=$(wc -l < "$RS_HOME/$1")
  [ "$n" -le "$2" ] && ok "$1 within $2 lines ($n)" || bad "$1 within $2 lines ($n)"; }
budget lib/common.sh 141; budget remote/env.sh 170; budget remote/bootstrap.sh 100; budget remote/submit.sh 426; budget remote/job.sbatch 70   # common +3: rs_ref, rs_deploy_profile; +8: rs_legacy_routing (a legacy rule keeps its kind)
# P2 (the attempt journal): submit.sh +75 (claim/replay, the body in a subshell, child-shell conf, duplicate guard, lint, receipt); bootstrap.sh +10, job.sbatch +5 (snapshots)
# P3 (api=3): submit.sh +40 (the --rs-mode/--rs-expect/--rs-chain pre-scan, rs_bound + rs_plan = the block and the expect check, the chain conflict)
# P3 review: submit.sh +25 (--rs-warnings + the recount, SBATCH_EXTRA --time vs MaxTime, env_hook/venv_dir/uv_sync_args bound, squeue fail-closed under --rs-expect)
# round 3: submit.sh +60 lines (327 → 387) — D2 time checks (no limit of none, a parser without here-strings, EVERY --time/-t sbatch could read, a dangling
# one), the D3 policy probe, warnings_id + `changed:`, conf_extra (+46), the sbatch value-option list and the bare-word / dangling refusal (+14)
# round 4: submit.sh +20 (387 → 407) — R4-11/R4-12 rs_probe (t_policy AND t_partition probed without -y; a silent gate's output, digits
# masked, joins warnings_id) +13, R4-9 the lint reads the scan's words (an option's value is never linted as an option) +2, R4-6 flags= +0,
# the probe passes each gate's exit 1 (a function named exit) so a function's first -y gate hides none after it +5
# round 5: submit.sh +19 (407 → 426) — R5-4 info_prior: ONE squeue call serves the duplicate guard and the plan / --rs-expect (+3); rs_prior
# counts journal receipts named the run id or <run id>--aNN plus this WorkDir's squeue rows no receipt names, says unknown when squeue failed or a
# receipt is unreadable, and undoes a policy's set -f / failglob (+15); the block line (+1)
budget remote/status.sh 175   # generous on purpose: every lookup has an explicit failure branch; compressing them hides bugs
budget tests/lib.sh 130; budget selftest.sh 65; budget install.sh 130; budget README.md 264; budget AGENTS.md 357; budget INSTALL.md 238 # AGENTS +10: rsk, +1: the hpc-run/ws-run uninstall, +16: the attempt journal, +13: api=3 (plan, --rs-expect, --rs-chain, busy GPUs, the rsk redirect); INSTALL +2: which rsk, setup without rsk
# P3-P7 docs: AGENTS +25 (the rsk modules, tests/62, the authorisation model, the P7 nudge, the new rails); README +10 (what is asked and
# what is not, the honest limit, the rsk launch step, src/); INSTALL +5 (doctor --legacy-refs, earlier permissions, standing words)
# 2026-11-06 follow-ups: AGENTS +6 (relaunch_after, recycled quotes, the refresh, --check-after, logs --grep); README +1 (re-runs handed over)
# P3 review: AGENTS +8 (--rs-warnings, the plan skips launch.sh's env gate, the new bound fields, plan-scoped approvals, the review's never-covered list)
# round 3: AGENTS +38 (the rs-api=3 marker line, warnings_id / warnings_avail / conf_extra / changed:, the policy probe and side-effect-free
# t_policy, explicit time limits and the SBATCH_EXTRA getopt refusal, the read-only nohup env gate, busy_ok occupants, grant kinds, the D1
# allowlist, derived actions, infra-end relaunches, bound cancel approvals, fail-closed records, NOT_SUBMITTED, rsk watch and denies, run-watch's
# target column, fulltmp, no here-strings in remote parsing); README +4 (relaunch only after an infrastructure end, denies bind rsk watch,
# cancel approvals bound, the -y rule with grant kinds)
# round 4: AGENTS +18 (the t_partition probe, every gate passed, the posix fact; flags= and info_run_gpu in the block; the lint on the
# scan's words; the RUN GPU rule and its limit; denies on unknown facts; unreadable grants; the class set at the first attempt; the
# latest attempt a relaunch resumes; the nohup journal; cancel_own live only; run-watch's steer and exit 7); README +3 (the
# workstation RUN rule with its honest limit: the payload is code)
# round 5: AGENTS +16 (info_prior in the block and the derived relaunch; RUN's text anywhere (rs_gputext) and the launcher WARNING
# (rs_launchers, tests/vgate/launchers.sh); denies: target_key names, scope.jobs for cancels only, unknown targets; a submit or cancel
# not reached, a non-zero scancel unknown (scancel_ended= / scancel_invalid=); every fail-stop kept, --release its own, exact row targets;
# the gate idiom); README +1 (the workstation RUN rule on the whole text, the launcher warning)
# round 6: AGENTS +17 (info_launchers in the block; APPTAINERENV_ and the emptied environment in rs_gputext; rs_launchers' configs and
# container runtimes with tests/vgate/containers.sh; release-withdrawn; denies: T_PARTITIONS, scope_problems in list/doctor, run_deny;
# a submit's / cancel's ssh 255 unknown whatever ssh says, scancel_line; job-id denies under fail-stop only); README +4 (a run-naming
# relaunch deny, the emptied environment, launcher configs and containers, rsk doctor's grants check); INSTALL +1 (doctor's grants WARN)
# round 7: AGENTS +11 (run-watch refuses a table that is not plain text (+1); launch_cfg in the nohup block and in needs: sync (+2); the
# conf read in every mode, the accelerate config it cannot locate, the relative --config_file after a cd, nerdctl, the tools that start the
# command elsewhere with envdrop.sh, launch_cfg bound (+6); an attempt's name stands for its run, T_PARTITIONS a display list with
# partition_note / scope_notes, status flags too (+2)); README +1 (the tools that start the command elsewhere are a warning too)
# round 8: AGENTS +10 (rs_launchers: ENV_KIND=conda, tmux by any prefix with its tests/88 check, the -H / --hostfile file bound (+3);
# grants: --unlisted-partition with unlisted_partitions / check_scope(unlisted_ok), list arguments split and checked (_split,
# _spaced), status --json's INVALID records (+5); cancel words naming the job, cancel.named / unnamed (+2)); README +0
# NF8: AGENTS +3 (warnings_gpu in the block and never grant-covered, grants.gpu_warn_miss (+1); a .wandb_env naming HF_HOME /
# ACCELERATE_ (NF7, +1); --asked and ranges in the cancel approval (+1)); README +0
budget skills/remote-run/SKILL.md 161; budget bin/run-watch 1102   # round 3: SKILL +11 (the -y rule with grant kinds, --allow-warnings availability|any,
# derived actions and the sticky class, relaunch only after an infrastructure end, cancel approvals bound / 1 h / used up, rsk watch --act vs
# denies (also in §3), `plan <id> is free again`); run-watch +116 lines (881 → 997), D11 — target column and same-target inheritance, sticky unknowns from any state file
# (foreign/settled/R_FU, the journal hands back the row's own status), fail-stop inherited with rows plus --release of a non-row trigger, pending
# cancels gated on --act and an approved fail-stop, settle-path JobName check, base-10 numbers, lock exit 6, unreadable '#@ ok' and header messages.
# round 4: SKILL +5 (rsk watch <table> --approve and --act only through rsk, denies match what they cannot rule out, policy flags never
# grant-covered, the latest attempt a relaunch resumes, exit 6 grants unreadable, the run command never picks GPUs).
# round 5: SKILL +6 (exit 5 `not reached — nothing sent` after a submit = NOT_SUBMITTED; `rsk grant deny --job` for cancels only, a run's
# launches by --name, -T a known target; a run only the journal shows is a relaunch (info_prior), fail closed; RUN's text anywhere and the
# launcher WARNING in the GPU rail).
# round 6: SKILL +6 (a submit's exit 5 stays unknown whatever ssh said, the plan used (+0); --partition checked against T_PARTITIONS, a
# deny naming a run stops every launch of it (and a conditional wish waits), grant list / doctor flag what never matches (+4);
# APPTAINERENV_, env -i / exec -c, launcher configs and container runtimes in the GPU rail (+2)).
# round 7: SKILL +5 (an attempt's name stands for its run, a --partition recorded with a NOTE (T_PARTITIONS a display list), rsk status
# flags too (+1); the R7-8 sentence: the payload is code, an older run-watch (+2); an accelerate config it cannot locate and a tool
# that starts the command elsewhere in the GPU rail (+2)).
# round 8: SKILL +5 (a --partition the display list lacks is exit 2 unless --unlisted-partition, list flags split on commas
# (+2); the cancel words must name what is cancelled (+2); ENV_KIND=conda in the GPU rail (+1)).
# NF8: SKILL +3 (the cancel words: a range, or --asked with the question they answer — never ask again (+2); a box's launcher /
# container WARNING is NO GRANT whatever the kind (+1); --asked on the cancel line and in the GPU rail (+0)).
# round 4: run-watch +60 (997 → 1057) — R4-7 the rsk steer for --act/--approve and RS_WATCH_PARENT (exit 7 once rsk watch is gone, checked
# before every ssh that acts) with its header lines +38, R4-13 fail-stop looked up every round in every state file + #failstop-released +12,
# R4-14 a pre-target state line's target inferred or unknown, the settle-path WorkDir and the submit ssh's identity re-check +10.
# round 5: run-watch +35 (1057 → 1092) — R5-7 a table's fail-stops as a set (fs_sid fs_has fs_trig fs_own fs_list fs_trigs fsp_add fsp_keep
# fs_lines), pending cancels tagged per stop, fs_others one entry per stop, --release clears only its trigger's stops (release-held / held-by),
# a table's own stop beside another group's (+31); R5-8 a row target is a plain name rs_targets lists, at parse and in load_targets (+2); header +2.
# round 6: run-watch +5 (1092 → 1097) — rel_drop: a fail-stop that holds a table only later in the watch (formed there, or taken from another
# state file) withdraws its rows' --release not used yet, ATTENTION reason=release-withdrawn (+3), its call at the end of reconcile (+1); header +1.
# round 7: run-watch +5 (1097 → 1102) — R7-7 tbl_ctl: a table holding a NUL byte or a control character other than tab (CR
# included) is refused in rsk's words (+2), parse_table's refusal at every read (+1), the --approve words checked alike (+1); header +1.
# P3 review +55: a row's state across renamed/copied tables, fail-stop of a row once its unknown submit is tracked, no --rs-* row words; SKILL: one entry for both kinds (the two it replaced: 62 + 61) + the rsk reads; +20 (P3-P7): the rsk command set, the launch flow (card, exit codes), §3 authorisation (the user's table); run-watch +130 (P3): attempt nonces + the journal read, --adopt and fail-stop identity checks, conf= binding, lock holder, sticky unknowns across tables
# 2026-11-06: SKILL +5 (--relaunch-after any for handed-over re-runs, never earlier words as --approve, the re-read before a relaunch)
budget skills/remote-run/references/experiment-conventions.md 140;   # +4: the run-watch exception (§3, §6, §7); +1: a USR1 death is FAILED; +3: the authorised exceptions (§5, §6, §7)
budget skills/remote-run/references/project-setup.md 100
for d in hpc-run ws-run; do [ -e "$RS_HOME/$d" ] || [ -e "$RS_HOME/skills/$d" ] && bad "legacy $d/ trees removed" || ok "legacy $d/ trees removed"; done
