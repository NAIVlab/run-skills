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
budget lib/common.sh 141; budget remote/env.sh 170; budget remote/bootstrap.sh 100; budget remote/submit.sh 407; budget remote/job.sbatch 70   # common +3: rs_ref, rs_deploy_profile; +8: rs_legacy_routing (a legacy rule keeps its kind)
# P2 (the attempt journal): submit.sh +75 (claim/replay, the body in a subshell, child-shell conf, duplicate guard, lint, receipt); bootstrap.sh +10, job.sbatch +5 (snapshots)
# P3 (api=3): submit.sh +40 (the --rs-mode/--rs-expect/--rs-chain pre-scan, rs_bound + rs_plan = the block and the expect check, the chain conflict)
# P3 review: submit.sh +25 (--rs-warnings + the recount, SBATCH_EXTRA --time vs MaxTime, env_hook/venv_dir/uv_sync_args bound, squeue fail-closed under --rs-expect)
# round 3: submit.sh +60 lines (327 → 387) — D2 time checks (no limit of none, a parser without here-strings, EVERY --time/-t sbatch could read, a dangling
# one), the D3 policy probe, warnings_id + `changed:`, conf_extra (+46), the sbatch value-option list and the bare-word / dangling refusal (+14)
# round 4: submit.sh +20 (387 → 407) — R4-11/R4-12 rs_probe (t_policy AND t_partition probed without -y; a silent gate's output, digits
# masked, joins warnings_id) +13, R4-9 the lint reads the scan's words (an option's value is never linted as an option) +2, R4-6 flags= +0,
# the probe passes each gate's exit 1 (a function named exit) so a function's first -y gate hides none after it +5
budget remote/status.sh 175   # generous on purpose: every lookup has an explicit failure branch; compressing them hides bugs
budget tests/lib.sh 130; budget selftest.sh 65; budget install.sh 130; budget README.md 257; budget AGENTS.md 294; budget INSTALL.md 237 # AGENTS +10: rsk, +1: the hpc-run/ws-run uninstall, +16: the attempt journal, +13: api=3 (plan, --rs-expect, --rs-chain, busy GPUs, the rsk redirect); INSTALL +2: which rsk, setup without rsk
# P3-P7 docs: AGENTS +25 (the rsk modules, tests/62, the authorisation model, the P7 nudge, the new rails); README +10 (what is asked and
# what is not, the honest limit, the rsk launch step, src/); INSTALL +5 (doctor --legacy-refs, earlier permissions, standing words)
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
budget skills/remote-run/SKILL.md 131; budget bin/run-watch 1057   # round 3: SKILL +11 (the -y rule with grant kinds, --allow-warnings availability|any,
# derived actions and the sticky class, relaunch only after an infrastructure end, cancel approvals bound / 1 h / used up, rsk watch --act vs
# denies (also in §3), `plan <id> is free again`); run-watch +116 lines (881 → 997), D11 — target column and same-target inheritance, sticky unknowns from any state file
# (foreign/settled/R_FU, the journal hands back the row's own status), fail-stop inherited with rows plus --release of a non-row trigger, pending
# cancels gated on --act and an approved fail-stop, settle-path JobName check, base-10 numbers, lock exit 6, unreadable '#@ ok' and header messages.
# round 4: SKILL +5 (rsk watch <table> --approve and --act only through rsk, denies match what they cannot rule out, policy flags never
# grant-covered, the latest attempt a relaunch resumes, exit 6 grants unreadable, the run command never picks GPUs).
# round 4: run-watch +60 (997 → 1057) — R4-7 the rsk steer for --act/--approve and RS_WATCH_PARENT (exit 7 once rsk watch is gone, checked
# before every ssh that acts) with its header lines +38, R4-13 fail-stop looked up every round in every state file + #failstop-released +12,
# R4-14 a pre-target state line's target inferred or unknown, the settle-path WorkDir and the submit ssh's identity re-check +10.
# P3 review +55: a row's state across renamed/copied tables, fail-stop of a row once its unknown submit is tracked, no --rs-* row words; SKILL: one entry for both kinds (the two it replaced: 62 + 61) + the rsk reads; +20 (P3-P7): the rsk command set, the launch flow (card, exit codes), §3 authorisation (the user's table); run-watch +130 (P3): attempt nonces + the journal read, --adopt and fail-stop identity checks, conf= binding, lock holder, sticky unknowns across tables
budget skills/remote-run/references/experiment-conventions.md 140;   # +4: the run-watch exception (§3, §6, §7); +1: a USR1 death is FAILED; +3: the authorised exceptions (§5, §6, §7)
budget skills/remote-run/references/project-setup.md 100
for d in hpc-run ws-run; do [ -e "$RS_HOME/$d" ] || [ -e "$RS_HOME/skills/$d" ] && bad "legacy $d/ trees removed" || ok "legacy $d/ trees removed"; done
