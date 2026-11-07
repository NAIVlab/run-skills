# Slurm procedure (any target of kind `slurm`)

`$ROOT` = line 1 of `INDEX.md`; `<t>` = the target name (its `<TAG>` = the name uppercased, non-alphanumerics
dropped: `my-hpc` → `MYHPC_`); `<host>` = its ssh alias from the table. Run everything with the **project root as cwd**
(where `.hpc.conf` lives). `TARGET=<t>` selects the target for the local commands (`CLUSTER=<t>` is accepted too);
`rsk sync|bootstrap|pull|avail -T <t> …` run the same scripts with the same arguments, and `rsk launch` / `rsk cancel`
wrap `submit.sh` / `scancel` with the plan card, the authorisation check and the ledger (SKILL.md §3).
The deployed copy of the harness lives at `<REMOTE_DIR>/.<t>/` — `env.sh status.sh submit.sh job.sbatch bootstrap.sh
profile.sh MANIFEST [policy.sh policy.local.sh]` — and is refreshed by every sync (`MANIFEST`, the sha256 of each file, last).

## 0. `.hpc.conf` — the only per-project state
Sourced as shell: values with spaces MUST be double-quoted or sync/submit abort. Minimum: `REMOTE_DIR` (absolute
remote project dir; `<TAG>_REMOTE_DIR` per target when targets do not share a filesystem), `ENV_KIND` (uv default |
conda, then `ENV_NAME`), `RUN` (default command). Full list, defaults and prefix rules: `conf-keys.md`. Missing conf →
follow `project-setup.md` (ask for `REMOTE_DIR`, env kind, run command); local and remote names differ, so never guess the dir.

## 1. Sync — push code, deploy the harness
```
rsk sync -T <t> [-n] [--also <path>]      # = TARGET=<t> bash $ROOT/bin/run-sync …; additive; -n dry-run; -D also delete
                                          #   remote files gone locally: only on the user's words at the time, never a grant
```
First line printed: `[<t>] remote: <host>:<dir>  tag: <TAG>  deploy: .<t>` — check it on a new project (use `-n`). With a
transfer host it also prints `transfer host: <xfer>` and ends `sync done -> … ; files via <xfer>`. `rsk sync -D` runs only
with `--approve "<their words>"` (audited) unless a real `-n` / `--dry-run` makes it a listing — read with run-sync's own
grammar: `--also -n` pushes a path named `-n`, it is no dry run.
Never deletes remote `.venv* .cache .local .config bin tmp wandb wandb-artifacts logs run_logs ckpts checkpoints runs
outputs videos data .wandb_env .rs` or any `.<target>/` dir (`.rs/` = the submit journal, below; `run-pull` refuses it too); `EXTRA_EXCLUDES` adds patterns, `SYNC_ALSO` force-pushes
excluded paths. Also pushes the conf, the profile, and your wandb key file as `<REMOTE_DIR>/.wandb_env` (mode 600),
and warns `WARN: … is not honoured` for a `<TAG>_KEY` line whose KEY is not prefixable.
Every sync stamps `<REMOTE_DIR>/.run-source` (local path, host, branch, commit, dirty-file count, time; never pruned):
it prints `[<t>] source: <branch>@<commit> dirty=N`, jobs see it as `$RS_SOURCE_COMMIT` and the job log header as
`source: …`. A remote dir last synced from **another local checkout** (a second worktree with the same remote dir;
decided by the local path, the host is only reported)
is refused — `ERROR: … was last synced from another checkout: <path> (…)`, exit 2 — because the sync would overwrite
that checkout's code under any job still running from it. Tell the user; with their OK (and no job of the other
checkout running) re-run with `--take-over`. `--also <path>` force-pushes one excluded path for this sync only
(a new container image, a wheelhouse); `SYNC_ALSO` is the every-sync form.

## 2. Bootstrap the env — first run, and after any dependency change (idempotent)
```
rsk bootstrap -T <t>                      # = TARGET=<t> bash $ROOT/bin/run-bootstrap = ssh <host> "cd <REMOTE_DIR> && export PROJ=$PWD TARGET=<t> && bash .<t>/bootstrap.sh"
rsk bootstrap -T <t> --job [-p <partition> -c <cpus> -m <mem> -t <time>] --approve "<the user's words>"   # the same, as a batch job
```
uv: finds `uv` (PATH, `~/.local/bin`, else installs into `$RS_ENV_ROOT/bin`), then `uv sync` into the target's venv
— or runs `BOOTSTRAP_HOOK` instead when the conf sets one. Refuses a venv outside `$PROJ` / `T_ENV_ROOT` / `VENV_DIR`,
and a derived venv owned by another project (`… belongs to … — set VENV_DIR to share it on purpose`).
conda: only *verifies* `ENV_NAME` exists (`conda env 'X' MISSING on <t>` otherwise) — never creates it. Stop and ask.
none: builds nothing (runs `BOOTSTRAP_HOOK` if set). Ends with `bootstrap done (<t>).`; any `ERROR:` or
`env.sh: … refusing to continue` line means fix the conf/profile first.
**On the login node or as a job.** A login node with a virtual-memory cap prints `NOTE: ulimit -v = N GB here …`
before `uv sync`; a torch-sized env then dies with `memory allocation failed`. Build it on a compute node instead:
`--job` submits `bash <REMOTE_DIR>/.<t>/bootstrap.sh` through `submit.sh` (flags as for any job, `-p` required; default
= the profile's `T_BOOTSTRAP_JOB`; name `<JOB_NAME>-bootstrap`) and returns with the job id and log path. A CPU partition
is enough when its nodes reach the internet (uv, PyPI) and share the GPU nodes' OS — the target's reference says
which partition qualifies. It is a job that `rsk launch` neither plans nor ledgers, so it runs only with the user's words
at the time — `rsk bootstrap -T <t> --job … --approve "<their words>"` (audited; any `--job` word makes the call one) —
never under a grant; then follow it with `status.sh <jobid>` until the log shows `bootstrap done (<t>).` `job.sbatch`
lets exactly this payload start without a venv.

## 3. Decide resources, plan, then check the authorisation (required)
Collect partition / GPU count / GPU type / walltime / run command from the user's words, the target's reference and
the conf defaults. Unless the user fixed the placement, `run-avail` (`rsk avail`) comes first (INDEX Routing: Placement):
the plan then cites what is free (`max/node` = GPUs on one node; `planned` = held by backfill for a pending job; free is
not schedulable — QOS and per-user caps apply), and why this target and partition. Prefer the target's default
partition unless the user or the reference says otherwise. **`rsk launch` (§4) plans first and checks whether the
user's recorded words already cover that plan** (SKILL.md §3): covered → it submits and you report which record
covered it; not covered (exit 4) → show its card verbatim with `ref: <reference path>` (re-read it if only a
summary of it is in context) and wait for the user's words ("go" / "确认" / "跑" or anything that approves this card).
Never submit on implicit consent: a description of a run is not an approval of it. Installed without rsk: the same
check against the user's words in the conversation; outside them, print a one-line plan ending `ref: <reference path>`
and wait. A charged partition, more resources or a wider scope than the user authorised always goes back to them.
Classify and name the run per `experiment-conventions.md` (run class, structured `-n` name, wandb mapping; `rsk
launch` refuses a new run's name outside its §2, exit 2). A smoke goes out with `WANDB_MODE=disabled` (prepend `env
WANDB_MODE=disabled` to the payload, or the conf's key when no ENV_HOOK, conda env or wandb_env naming WANDB_MODE can
undo it: rsk refuses a smoke with neither). For a pilot/train/ablate,
confirm the command checkpoints AND auto-resumes — jobs are submitted `--requeue`, so a requeued job re-runs the
same command; if it cannot resume, say so in the plan (`SBATCH_EXTRA="--no-requeue"` opts it out). Longer than the
partition's MaxTime → a singleton segment chain (conventions §6): the plan states the segment count and walltime.

## 4. Submit (runs on the login node)
```
rsk launch -T <t> -p <partition> -g <ngpu> [-G <gputype>] [-t <time>] [-m <mem>] [-c <cpus>] [-n <name>] [--chain N] [--class C] [--<policy-flag>] -- <RUN>
rsk launch --plan <id> [--plan <id>]... --approve "<the user's words>"     # the card(s) the user approved: submit
rsk launch … --check-after 30                                              # + the start milestone: one read 30 s later
ssh <host> 'bash <REMOTE_DIR>/.<t>/submit.sh -p <partition> -g <ngpu> [-G <gputype>] [-t <time>] [-m <mem>] [-c <cpus>] [-n <name>] [-y] -- <RUN>'   # without rsk
```
`rsk launch` drives this `submit.sh`: one ssh with `--rs-mode plan` (below) for the card, then, once a record covers
the plan (an approval made by `--approve`, or a grant), one ssh per submit with `--rs-expect <bound_hash> --rs-warnings
<the card's warnings_id>`. `-y` is never sent as typed: rsk sends it only when the approved card showed warnings or the
covering grant's kind covers the plan's warnings (`--allow-warnings availability|any`, SKILL.md §3), and submit.sh
recomputes which `WARNING:` lines it printed (one that appeared or went away: exit 6), so it never passes a new one;
`--force` / `--rs-*` are never policy flags, and no word before `--` may contain `--rs-`, not even as an option's value
(exit 2; nor may a value of `-p -g -G -t -m -c -n --relaunch` start with `-`). `--chain N` = N singleton segments
(conventions §6) under one approval. Policy flags (`--<word>`, handed to the target's policy) are bound into the plan
(`flags=`) and listed on the card's `policy` line: no standing grant covers a plan with policy flags — only the user's
approval of that card; `--relaunch` replays them. A `--…-user-asked` policy flag is the user's own OK for that gate: the
card shows it, no grant covers it. A name carrying a class (`<exp>--<class>--…`) is that class: a different `--class` is
exit 2, and a run's class is set only at its first attempt (another one later, by name or `--class` — or any one when the
first attempt had none: exit 2, before any ssh). The action is the plan's, never a flag's: a run that already has attempts
that may have run (on any target) is a `relaunch` — attempts in the ledger, or only in the target's journal: the block's
envelope `info_prior` (journal receipts named `<run>` or `<run>--aNN`, plus this WorkDir's squeue rows no receipt names —
run-watch's submits never enter the ledger); `info_prior` missing or `unknown` counts as one too (fail closed). The card
says so: `prior      N earlier attempt(s) of <run> on <t> …` or `prior      unknown — … taken as a relaunch (fail
closed)`. A relaunch grant covers it only when the run's latest attempt that ran
ended with an infrastructure end (PREEMPTED / NODE_FAIL / BOOT_FAIL) and the plan repeats that attempt's configuration
(else `not the configuration of aNN it resumes`; a plan named after an older attempt, `<run>--a01` again, is recorded as
the next aNN) — never a run only the journal shows (`the ledger has no earlier attempt of the run that ran`: the user's
call) —, the user's approval of the card after any end, and a grant recorded with `--relaunch-after any` (the user's
words hand you re-runs too: "fix it and rerun it yourself", "you decide, after a failure too"; the grant allows `launch`
too) after any end too: judged then as a launch — scope, budgets, warnings, denies, whatever the configuration (a fixed
command, another partition) — but never while an earlier attempt rsk can see may still be live (a ledger one live or
SUBMIT_UNKNOWN on any target, or one only the target's journal shows: its `info_prior_here` counts more than the ledger
holds there; the plan at most 10 min old). Before deciding, `rsk launch` re-reads every target where the ledger counts
an attempt of the run as live (the read `rsk status` makes), so a job that just ended is neither refused as a duplicate
nor an unknown end (a target it cannot read changes nothing). `--check-after S` reads each submission (every chain
segment) once more S seconds after the submit: pending / running, COMPLETED, or ended otherwise — its state, exit code
and digest, exit 1 (it was launched; a fix and a relaunch are a new decision). `--approve` words that repeat a standing
grant's quote (or embed it) are exit 4, also for cancel, `rsk watch`, `adopt`, `sync -D`, `bootstrap --job`: an approval
answers this card; a `chain=1` plan (an `SBATCH_EXTRA`
`--dependency=singleton` too) is a `chain`, and every one that applies is checked (a deny of any matches, also one whose
fact is unknown: a run with an attempt recorded without a class matches a class deny; a record must allow all); the
card's header says which (`plan <id> — relaunch on <t> …`). Its
`conf extra` row lists the conf's own `SBATCH_EXTRA` words; a `NO GRANT` line names those outside the grant allowlist
(`conf-keys.md`, `SBATCH_EXTRA`): such a card is the user's call. Its `TIME` line shows an `SBATCH_EXTRA` / policy
`--time` (sbatch takes the last one) — for information: a grant's `max_time` holds for every time limit sbatch could
read, the policy's included, and a limit of 0 / UNLIMITED never fits it. Its `warnings` row reads `N (M of them the
availability gate's)`. Its `source` row compares the deployed `.run-source` commit with this checkout's HEAD: `same
commit` or `DIFFERENT code than this checkout's HEAD` for two real commits, `unknown (not a git checkout, no commit yet,
or no sync stamp) — cannot compare` when either is `none` (a re-sync from the same place does not change that). Before
any ssh it refuses (exit 6) a second live ledger run of the same name (`--same-name-ok` only when the user wants both;
no grant covers it) — and a SUBMIT_UNKNOWN attempt of the run even with it. Exit: 0
submitted (job id, log), 1 failed, 2 usage, 3 refused (policy or a deny: final, with its quote), 4 needs the user
(`needs user: approval — plan <id>`), 5 reply lost (SUBMIT_UNKNOWN: never resubmit; `rsk status` settles it from the
journal below — whatever ssh's own words were, below), 6 a used / superseded / expired plan, drift (`differs from the approved plan`, and what changed:
`time: 1-00:00:00 → 2-00:00:00`, or `the warnings differ from the approved card`) or `needs: sync` (the deployed
`submit.sh` lacks the `# rs-api=3` line, an older one refused rsk's words, or its block lacks a field this rsk binds, such
as `flags=`) — plan again and show the new card; also 6 `grants unreadable — rsk grant recount / restore` (the ledger's
`grants.json` cannot be read, so no deny can be ruled out: nothing is done — tell the user, SKILL.md §3).
When the target proves nothing was submitted (verdict refused / failed with no receipt, or no attempt dir at all) the
attempt is NOT_SUBMITTED, never SUBMIT_UNKNOWN: the use is given back and rsk says `plan <id> is free again` — once the
cause is fixed, `rsk launch --plan <id>` resubmits it under the same record with no new words (`--rs-expect` still
guards drift). ssh's own words never prove it: a submit's ssh exit 255 with no receipt — before the remote's first line
(`@@api`) too — is `SUBMIT_UNKNOWN: <run> aNN (nonce …) — ssh exit 255 (<ssh's last line>) — ssh's own words are no
proof that nothing was sent` (exit 5), whatever that line says: a ProxyCommand's fallback route or a login shell can
print `Connection refused` / `Permission denied` on a session that did open and ran `submit.sh`. The use is kept and the
plan stays used (`rsk launch --plan <id>` again: exit 6 `was used already`); `rsk status` reconciles it from the
journal, and when the journal holds no attempt dir of that nonce, only the user decides it never went out: `rsk adopt
-T <t> --not-submitted <NONCE> --approve "<their words>"`. Silence or a timeout is SUBMIT_UNKNOWN the same way.
Denies: `rsk grant deny --job` is for cancels only (`--action cancel` / `cancel_own`; with a launch action: exit 2 — a
run's launches are denied with `--name '<run>'`). `-T` of `rsk grant add|deny` and every scope target of `rsk grant
import` must be a target the harness knows, spelled as INDEX lists it (else exit 2 `unknown target`, nothing recorded).
A deny compares targets as normalised names (`fx/`, `./fx`, `FX` are `fx`); a spelling that is not one plain name
matches every target deny (fail closed). A `--partition` (import: `scope.partitions`) that no scoped Slurm target's
`T_PARTITIONS` lists (every target the harness knows, without `-T`) is exit 2, nothing recorded: `partition P is not in
the profile's display list (T_PARTITIONS of <t>: a, b) — nothing recorded: check the spelling with the user (a misspelt
partition never matches: the deny would not be enforced, the grant would cover nothing); if it is a real partition the
display list omits (policy.sh decides which exist), record it again with --unlisted-partition` (import:
`(scope.partitions of #i in FILE)` after P, and `… with "unlisted_ok": true in record #i`). `T_PARTITIONS` is the
profile's display list (split on commas and whitespace: `gpu,preempt` is two) and `policy.sh` (`t_partition`) decides
which partitions exist, so check the spelling with the user first; only when they confirm a real partition the list
omits, `--unlisted-partition` (import: that record's `"unlisted_ok": true`, a boolean, never stored) records it as
given, with `NOTE: partition P is not in the profile's display list (T_PARTITIONS of <t>: a, b; <u>: none) — recorded as
given: policy.sh, not the profile, decides which partitions exist; the record matches only a plan whose partition is
spelled exactly so`. No check, the NOTE only, when a scoped Slurm target's profile lists no `T_PARTITIONS` (`<u>: none`)
or only workstations are in scope (` (<t>: a workstation has no partitions — no launch there names one)`). Every list
argument of `rsk grant add|deny` (`-T`, `--partition`, `--gpu-type`, `--class`, `--name`, `--job`, `--run`, `--action`;
repeatable, `a,b`) is split on commas and each item stripped (`--name 'b1, b2'` is b1 and b2); an empty item or one with
whitespace inside is exit 2 naming it, nothing recorded (`--job '101 102': item '101 102' holds whitespace …`, `--job
'101,': an empty item …`) — a space-separated list is never split on a guess; `--job` takes job ids or pids only (`123`,
`123_4`). A stored record (import, a hand edit) with a list item holding whitespace is invalid (`whitespace in a scope
item`): as a deny it matches everything (fail closed), anything else covers nothing. A GPU type has no list anywhere:
never checked, only echoed (`NOTE: GPU type X is not checked … — compare it with the target's reference`). `rsk grant
list`, `rsk status` (its grants block is grant list's) and `rsk doctor`, for every project's ledger (`== grants ==`),
flag every active record naming a TARGET the harness does not know — `WARNING: <id> (<kind>): target X is not one the
harness knows (<known>) — never matches[ there] (the user's deny is not enforced there | it covers nothing there) — fix
or revoke: rsk grant revoke <id> --quote "<the user's words>", then record it again with a scope the harness knows`
(`--json`: `scope_problems`); a stored partition its targets' lists do not name gets the NOTE above in grant list and
status (`--json`: `scope_notes`), never `never matches`: tell the user. A record `validate()` rejects (a hand edit, a
damaged entry) is listed as `<id>  INVALID — <what>: <why>` and, in the `--json` of both `rsk grant list` and `rsk
status`, as `{record, invalid, fail_closed}` — never described; no view fails on one. A deny's `--name` written as an
attempt's job name — `<run>--aNN`, two or more digits, as squeue, sacct and the log show it — or as a glob over attempt
names (`x--a*`, `x--a0?`, `x--a[0-9][0-9]`: an `--a` suffix of digits, `*`, `?` or `[…]` that can match two or more
digits) stands for the whole run: an attempt is launched once, so it matches every attempt of that run (launch,
relaunch, chain, cancel) and `rsk watch` rows of it, and it is that run the deny names below. It is recorded as given,
with `NOTE: name <run>--a02 is an attempt's name (--aNN): the deny stands for run <run> — every attempt of it, the next
one included (an attempt is launched once)` (a glob: `NOTE: name x--a* matches attempts' names (--aNN): the deny stands
for run x — …`), and `rsk grant list` describes it as `names <run>--a02 (= run <run>: every attempt of it)`; `x--a?`,
`x--a[0-9]`, `x--a[!0-9]*` and `--a*` match no attempt's suffix and keep their plain meaning. A deny that names a run (a
`--name` glob matching the plan's name or run id) and lists `relaunch` or `resubmit` stops EVERY launch of that run,
launch and chain included, on any target in its scope: the
refusal adds `— a deny of relaunching a run stops every launch of it, on any target in its scope: rsk cannot see every
earlier attempt (another target, run-watch, an older harness, another checkout)`, `rsk grant list` shows `DENY relaunch
(it names a run: every launch of it too — …)`, and a launch grant recorded right after it gets a `FLAG`. A deny naming
no run keeps the derived action. So a conditional wish ("if a fails, don't relaunch it") becomes a deny only once a has
run: a deny always wins.
Defaults: `-p`/`-G` ← `<TAG>_DEFAULT_PARTITION` / `<TAG>_DEFAULT_GPU_TYPE` else the profile's; `-g -c -m -t -n` ←
`DEFAULT_GPUS/CPUS/MEM/TIME`, `JOB_NAME` (`<TAG>_` form wins); `ACCOUNT`, `SBATCH_EXTRA` are appended. CLI flags win.
Unset cpus/mem fall back to the partition's per-GPU heuristics (policy.sh). `submit.sh` then, in order: runs the
target's `t_policy` (a refusal propagates its exit code, typically 3, and `-y` does not unlock it; in plan mode and under
`--rs-expect` it first probes `( FORCE=0; t_policy )` in a subshell — the policy as a submit without `-y` sees it — and,
right before the partition's real check, `t_partition` the same way with the partition that is submitted, so a gate
that stays silent under `-y`, in either function, still prints its `WARNING:` onto the card; in the probe each `exit 1`
is a `-y` gate that is noted and passed, so every gate of a function shows, not only its first; a gate with no
`WARNING:` of its own gets a fixed one, and what the probe printed then joins the card's `warnings_id`; any other
non-zero exit ends the call with that code), validates the partition and `-g` range,
rejects a time limit that is no limit — 0 in any spelling, `UNLIMITED`, `INFINITE`, `-1` (exit 2, `give an explicit
limit ≤ MaxTime`) — or one it cannot read (an unreadable MaxTime too), and one beyond the partition MaxTime (`exceeds …
MaxTime` = it would pend forever; lower it); that holds for `-t`, `DEFAULT_TIME`, and EVERY `--time`/`-t` sbatch could
read in the policy's or `SBATCH_EXTRA`'s words, which sbatch takes over `-t` (any value form, also a word standing as
another option's value, `--comment -t1`; a trailing `-t`/`--time` with no value is refused). It rejects a payload that
calls `sbatch/srun/salloc`, an `SBATCH_EXTRA` carrying `-p/--partition` or a forbidden QOS, and an `SBATCH_EXTRA` word
that is neither an option nor the value of the option before it, or a value option left without its value at the end
(exit 2, in plan and submit: sbatch would run that word as the batch script, or eat the harness's next option —
`conf-keys.md`), prints per-node availability and stops with `WARNING: only N free … Re-run -y` when the GPUs are not
free (`-y` queues anyway), refuses a second live job of the same name from this project (`ERROR: '<name>' is already
RUNNING from this project (job N …)`, exit 6: follow that job, or pick another `-n`; `--same-name-ok` only when the user
wants both; `--dependency=singleton` chains skip the check), prints `WARNING (lint): SBATCH_EXTRA …` (warnings only,
for now: tell the user) for an option outside its allowed set or one the harness sets itself — reading the words as the
scan does, so an option's separate value is never linted as an option (in `--comment -t1` the `-t1` is the comment) —,
then `sbatch --requeue
--export=ALL,PROJ,CLUSTER,TARGET … --mem=… --comment=… rs=<NONCE> .<t>/job.sbatch <RUN>` (the early `--requeue` lets a later
`SBATCH_EXTRA` `--no-requeue` win). The `.hpc.conf` is read in a child shell: only its keys count, never a function or `PATH` it sets.
Report the job id. Unknown `--word` flags pass through to policy (`--…-user-asked` sets `ACK=1` for it).
**The journal** (rsk status reads it for you). Every call prints `attempt: .rs/attempts/<NONCE>` first and records itself in `<REMOTE_DIR>/.rs/attempts/<NONCE>/`
before printing anything: `out` / `err` (all it printed), `stage`, `result` (`stage= rc= verdict=submitted|refused|failed|unknown`),
`receipt` (`job= name= partition= … argv=`, written the moment the job exists) and the `conf`/`profile.sh`/`env.sh`/`hook` the
job (and every requeued restart) uses. An ssh that died or printed nothing is **never** a reason to resubmit: read
`ssh <host> 'cd <REMOTE_DIR>/.rs/attempts && ls -t | head -n 3'`, then `cat <NONCE>/result <NONCE>/receipt` — `submitted` +
`job=` = queued; `unknown` = sbatch ran but recorded no id: find `rs=<NONCE>` in `squeue -h -u $USER -O 'JobID:0|,Name:0|,Comment:0'` before
anything else; a dir from the call without `result` is still running (read it again shortly); no dir from the call = it
never started. Exit 75 = that NONCE was already used (`--rs-attempt NONCE` callers only).
**rsk's protocol (api=3: the line `# rs-api=3` inside the deployed `.<t>/submit.sh`, which rsk's plan ssh reads before it
runs anything).** `--rs-mode plan` (separate words, like `--rs-attempt`) runs every step above — policy and partition
(probed without `-y` first), limits, MaxTime, availability, duplicate guard, lint — with each `-y` gate acknowledged (it prints its
`WARNING:` and goes on), then prints ONE `@@plan v1` … `@@end` block instead of submitting: the bound fields (`partition gres
cpus mem time account name extra payload env_kind env_name wandb_mode env_hook venv_dir uv_sync_args conf_extra flags
chain`; `extra` = the policy's and `SBATCH_EXTRA`'s words after the harness's own, `conf_extra` = the conf's `SBATCH_EXTRA`
words alone, `flags` = the policy flags, `env_hook` = `<ENV_HOOK>:<sha256 of the file>`), `info_*` lines (availability, sha256 of the conf/profile/policy,
the `.run-source` commit and dirty count, then `info_prior=<n|unknown>`: the run's earlier attempts here — this project's
journal receipts named the run id (the name minus `--aNN`) or `<run id>--aNN`, plus squeue's rows of such a name with this
WorkDir, live or ended and still listed, that no receipt names; `unknown` when squeue failed or a receipt cannot be read;
envelope, not bound — rsk reads n > 0, or no number, as a relaunch), then the envelope `warnings=N` (the distinct `WARNING:` lines, not `WARNING (lint)`),
`warnings_avail=` (how many of them the availability gate printed), `warnings_id=` (the sha256 of those lines, sorted,
every digit run masked as `#`, and of a silent gate's probe output) and `bound_hash=` (result `verdict=planned`; only the
conf is snapshotted, nothing submitted).
`--rs-expect <bound_hash> [--rs-warnings <warnings_id>]` submits only while the resolved submission still hashes the
same and the call's `WARNING:` lines give the same `warnings_id` (none given = no warning at all): a warning that
appeared or went away is a difference. Else the current block, `changed: <keys>` (read from the approved plan's own
entry in the journal, when it is there) and `ERROR: the resolved submission differs from the approved plan`, exit 6,
nothing submitted; a `-y` is still needed when the plan showed warnings, and under
`--rs-expect` a failed squeue is exit 1 (the duplicate check is never a `-y` gate there). `--rs-chain` makes it one singleton chain segment (`--dependency=singleton`;
the duplicate guard lets it through; another dependency in `SBATCH_EXTRA` is exit 2). An older `submit.sh` exits 2 on these
flags (`unknown arg`; rsk reports `needs: sync`); an `--rs-` word as the value of `-p -g -G -t -m -c -n` is exit 2 too. A
plan is a card to show the user, not an approval: the user's words (or a grant recorded from them) are.

## 5. Monitor / manage — start reviews with a bounded digest; cadence, milestones, detect-only: `experiment-conventions.md` §7
```
rsk status -T <t>                                                    # every job of this project: ledger runs, unledgered jobs, needs user:
rsk logs -T <t> <jobid> [<ckpt-dir>] [-n 40]                         # the same digest as below, from the local project root
rsk logs -T <t> <jobid> --grep 'loss|Traceback' [-i] [-n 20]         # only matching lines of the log's last 8 MiB (--bytes B ≤ 64 MiB)
rsk exec -T <t> -- mfsgetquota -h <dir>                              # a directory quota `quota` cannot show, where the target reference names one
ssh <host> 'bash <REMOTE_DIR>/.<t>/status.sh <jobid> [<ckpt-dir>]'     # review digest (~2 KB): job state, attempt/footer, hints, last 5 lines, ckpt-dir activity
ssh <host> 'bash <REMOTE_DIR>/.<t>/status.sh -n 40 <jobid>'            # deep read on an anomaly: 40 lines × 200 chars, still byte-bounded
ssh <host> 'squeue -u $USER -o "%.10i %.12P %.3t %.11M %.11L %R %j"'   # everything of yours; %R = pending reason, %j last = full name
ssh <host> 'sacct -j <jobid> -X -o JobID,State%20,Elapsed,ExitCode'     # accounting (status.sh shows it once the job left the queue); memory: sacct -j <jobid>.batch -o MaxRSS
```
`rsk status` tags run-watch's submits (journal nonces `rw-…`) and the `rsk bootstrap --job` job (its receipt's argv ends
`bash <REMOTE_DIR>/.<t>/bootstrap.sh`) with their tool, never by a name: a job merely named `*-bootstrap` is UNLEDGERED,
with a note. run-watch's runs still never enter the ledger (`rsk status` lists them as `(run-watch's)`): `rsk launch`
sees them only through the plan's `info_prior`, which makes a plan of the same run a `relaunch` (§4). When the ledger cannot be written it says `WARNING: ledger not updated (read-only view)` and still reports.
`status.sh` reads squeue (`state= reason= elapsed= left= restarts=`; sacct once the job is gone) and the log that
`submit.sh` printed as `log: <REMOTE_DIR>/logs/<name>_<jobid>.out` (it appears when the job starts): size/age,
`starts=N restart=N footer=…|none` (harness headers seen = Slurm restarts, not `a<attempt>`; `starts_in_last_64MiB=` past that size), `scan=full|partial hints: traceback= oom= nonfinite= error=` counted over the last
256 KiB (hints, not diagnoses; `partial` = older bytes were not scanned, so 0 is not "no errors"), `last_hint=`, `wandb=`
(the run URL: a `wandb.ai` one, or any host's on the client's own `View run` line; else none), the last lines (CR-normalised, 200 chars each) and, given a ckpt dir, `ckpt_entry` + its age.
That entry is directory activity, possibly a temporary save or metadata; `resume=unverified` requires trainer evidence (§6 of conventions).
Never read a log unbounded (`cat`, `tail -n`, `grep` over the whole file): bound the input by bytes first. No
`.<t>/status.sh` on the target = the deploy predates it: say so, read bounded (`tail -c 20000 <log> | tr '\r' '\n'`),
and re-sync only with the user's OK — a sync also pushes local code into the dir a running job reads. A log old enough
to predate the `target=…` header line reads `starts=0` while `squeue` still shows the job running.
Every start of the job opens with the `target=… restart=N … attempt=<NONCE>` header line (`attempt=` names the submit's journal
entry; a `rs-attempt=<NONCE> job= restart=` line, written before env.sh, precedes it, so even a start env.sh refused names its
submit), `RUN:` precedes the payload, and `EXIT rc=N usr1=… term=…`
closes it once the payload returned — rc is the trainer's OWN status. `usr1` / `term` = what the wrapper observed: `1` =
Slurm's USR1 warning (time limit, or preemption where the site sends it) / SIGTERM (cancel, preempt, final kill) arrived
and was forwarded to the trainer; `lost` = it arrived after the trainer was gone; `pending` = before it started (the job
aborts). `footer=none` = still running, or the attempt ended before writing it (killed). GPU use is judged by the log's
step rate (where `nvidia-smi` is usable is in the target's reference). State → meaning: `PENDING` — read the reason
(Priority/Resources = wait; a QOS/limit reason = a cap, not a stall); `RUNNING`; `COMPLETED` — rc 0, still verify the
final artifact (rc 0 with `usr1=1` = it exited after the signal: find its own save line before resubmitting); `FAILED` —
read the Traceback (`usr1=1` = it was signalled first; rc 138 there usually means no USR1 handler — rely on periodic
saves, then resubmit; sacct may show it as `10:0`); `TIMEOUT` — still running at `-t`; `--requeue` does not restart it (the chain's next segment, or a
resubmit, resumes it); `OUT_OF_MEMORY` — smaller batch or larger `-m`; `PREEMPTED` / `NODE_FAIL` as the latest state = NOT
requeued (`--no-requeue`, or a partition that preempts by cancel): resubmit and resume; `CANCELLED`. A requeued job
instead goes back to `PENDING` and later runs again into the same log with a new `restart=N` header (`sacct -D` lists
the earlier attempts) — confirm the trainer's own resume line after every restart.
**Cancel** through `rsk cancel <run> [--job <jobid>] [--approve "<the user's words>" [--asked "<your question>"]]` (`rsk
cancel --job <jobid> -T <t> …` for a job not in the ledger): the same ssh that runs `scancel` first checks the job's
name, user and WorkDir (exit 6 = mismatch, nothing cancelled; exit 3 = someone else's job: never). It acts on the user's
words naming that job, or — for your own judgment that a run should stop — on a `cancel_own` grant (runs rsk launched
only); else exit 4: ask.
`cancel_own` covers only an attempt the ledger shows live: a job of a run the ledger shows ended needs the user's words.
The words given to `--approve` must name what is cancelled, as a whole word: for `--job J` the job id J or the run's id
or job name; for `rsk cancel <run>` the run id or name, or every job id it cancels (a chain: the run, or all its jobs);
a numeric range names every id in it (`cancel jobs 102-104`, `102 to 104`, `102…104`: 102, 103 and 104).
A token inside a longer one does not count (`101` is not named by `1101` or `101_2`, `sw1` not by `sw10`, `exp--sw1` or
`sw1-b`; trailing punctuation is fine: `cancel job 101.`). When the words answer a question you asked ("sw1 (job 101)
diverged — cancel it?" → "yes"), pass that question verbatim with `--asked "<your question>"`: it may name the job
instead, and is recorded beside the words (the approval's `source`, `asked: "…"`, and the audit's cancel lines) —
never ask the user a second time. "cancel it" with no question naming the job names nothing: exit 4 `needs user: the
words do not name <J|run> — "<words>" names none of: job J = run <run> (<name>) on <t>; nothing recorded or cancelled`
(with `--asked`: `"<words>" (answering "<question>") names none of: …`), no approval and no ssh — ask the user which one
they mean ("the whole sweep" names no run: say which runs that is; the question you ask then is the `--asked`). This is a
check against a slip ("cancel job 101" approving 102, a yes to "cancel sw1?" passed for sw2), not proof of consent: the
asked text is your own bookkeeping, rsk does not read whether the answer was a yes — pass it only when the user agreed.
A `cancel_own` grant (no `--approve`) is unchanged.
A deny of the user's matches a cancel whatever it cannot rule out: a deny of plans (`rsk grant deny --run <hash>`, one
that covers cancels) matches every cancel of a job the ledger has no plan for.
An approval (`--approve`) is bound to the identity it was given for (target, job id, run name, WorkDir), expires after
1 h and is used up by its first cancel that passed the authorisation check, whatever came of it (no refund): a later
cancel of that id needs the user's words again (`rsk grant list`: `jobs used N/M`). A `cancel_own` grant's cancels count
against its `max_launches` (`cancels N/M`, or `uses N/M` on a grant that only cancels); a use comes back only when the
answer proves nothing was signalled. A ledgered job squeue lists as ended is exit 0 `nothing to cancel … ended (<STATE>)`,
recorded in the ledger with that state. A cancel approval recorded before identities were bound covers nothing: ask
again. An answer cut off after the cancel started, or no answer at all (a timeout, ssh's own 255, a signal: the body may
have run there), says `the cancel may have been sent: rsk status` (exit 5; a `cancel_own` use is kept, the job may have
been cancelled): read `rsk status` before anything else. ssh's own exit 255 before the body's first line (`@@start`) is
that too, whatever its stderr says (`… — ssh's own words are no proof that the body never ran; the use is kept`): a
ProxyCommand's fallback route or a login shell can print `Connection refused` / `Permission denied` on a session that
did open and ran the cancel.
A non-zero `scancel` is `UNKNOWN: job J (<run> aNN): scancel exit N (…)` (exit 5): the use is kept and the ledger shows
`CANCELLING?` (not confirmed: a timed-out request may still be applied) until `rsk status` sees the job end; its
`(…)` quotes scancel's line naming job id J, else its last line naming no job id, else nothing — never another job's
line (`UNKNOWN: job J (<run> aNN): scancel exit N (<that line>)`). The exception is scancel's own line for that id
saying `Invalid job id` or `already completing or completed`: `nothing to cancel: … scancel exit N: …` (exit 0), a
`cancel_own` use given back, the ledger `COMPLETING`. The reproduction of
those words is `tests/vgate/slurm-remote.sh` (`scancel_ended=`: scancel's exit and words for its own ended job;
`scancel_invalid=`: the same for id 4000000000, sent only after `squeue -j` lists none). Only those words give a use
back: where scancel words it otherwise (until that reproduction has run on a cluster, no site's wording is confirmed)
the cancel stays unknown — exit 5, the use kept (fail closed). Exit 1 is never a failed scancel (it is only a
workstation kill that left processes).
Without rsk: the job's line in `ssh <host> 'squeue -h -u $USER --states=all -O "JobID:0|,Name:0|,UserName:0|,WorkDir:0|,State:0|"'`
(the read `rsk cancel` makes) must show the run's name, your user and this remote dir; then `scancel <jobid>`, on the same terms.

**Many jobs or long waits: `run-watch`** (cwd = project root; `bin/run-watch` header = the full contract). A table
`#@ run-watch v1` lists rows `name target done-path submit.sh-args -- cmd` (or `-`: watch only; `-p` required, no
`-n`, no `*-user-asked`, no shell quoting; `rsk watch <table> …` runs it under the project's lease). The target column is
a target name exactly as INDEX (`rs_targets`) lists it — letters, digits, `. _ -`: `x/`, `./x`, `x//` or any other
spelling, even one the filesystem still resolves, is exit 2 (`not a target name this harness lists`, or the row's own
error): nothing written by `--approve`, nothing run — rsk's deny check compares names. A table is plain text (LF line
ends; tabs and UTF-8 text are fine): one holding a NUL byte or any control character other than tab — a CR too, so a
CRLF table, which run-watch used to accept by stripping the CR, is refused now: save tables with LF line ends — is exit 2
in `rsk watch` (every mode, before the lease) and in run-watch alike, in the same words: `<table>: line N holds 0xHH, a
NUL byte or a control character other than tab — a run-watch table is plain text (LF line ends); rsk and run-watch both
refuse it`; nothing is written by `--approve` and nothing runs. Both read a table the same way (lines end at LF only,
words split at space / tab only); run-watch checks it at every read and `rsk watch --act` at each lease refresh, so such
a byte written into a table while a watch runs ends that watch (exit 2). The user's words in `rsk watch <table> --approve "…"` may not hold a double quote, a newline or a
control character other than tab (exit 2, nothing written); UTF-8 text such as Chinese is fine. Each round: one
read-only ssh per target, one dated event per change (LAUNCH REQUEUE RESUBMIT RETRY DONE STALL WARN ATTENTION CANCEL …).
Without `--act` it never submits. To let it act, show the user the rows plus `#@ allow launch preempt=N errors=N timeout=N [fail-stop]` (no default: absent = 0; paid partitions:
the cost of first submits plus N resubmits); only after their explicit OK run `rsk watch <table> --approve "<their
words>"`, then `rsk watch <table> --act …`. Acting goes through rsk (it runs run-watch with `RS_VIA_RSK=1` and
`RS_WATCH_PARENT=<its pid>`): a direct `run-watch … --act` or `--approve` while rsk is installed prints `use: rsk watch …`
and exits 2, writing and running nothing (watching without them still runs directly; installed without rsk it acts,
with a NOTE, and no ledger deny is checked). Any later edit to those rows, the budget or `.hpc.conf` makes them detect-only again (the `#@ ok` line
carries `conf=`, and the submit ssh checks the deployed copy; an older line without it stays valid). `rsk watch --act`
(and `rsk watch … --approve`) first checks every row — target, `-g`, `-t`, name / run id, class — against the user's
denies for EVERY action run-watch could take on it (launch, relaunch, resubmit, chain on Slurm rows, cancel), whatever
the table's `#@ allow` says (`--release` and an `SBATCH_EXTRA` singleton act outside it) — except a deny scoped by job
ids (`rsk grant deny --job J --action cancel`), which counts only for a table whose `#@ allow` line has `fail-stop`, the
one cancel run-watch makes, and there matches every row (the row's job is not known here); what a row cannot show
matches: a GPU-type deny matches every row of its target and a partition deny every Slurm row of its target (the policy
may force a type or rewrite `-p`), a deny of plans every row in its scope (a row has no bound hash), a class deny a row
whose class is unknown. A match is exit 3 with the deny's words and why (`<table>: row <name> on <t> (<action>): denied
by …`; a deny naming the row's run with `relaunch` meets it at `(launch)`), nothing started and no `#@ ok` written; an
unreadable `grants.json` is exit 6 (`grants unreadable`); a matching deny recorded while it runs stops run-watch (TERM)
at the next lease refresh, exit 3. Honest limit: that check is static — it reads the row's words, never what the
target's policy makes of them: a policy that rewrites `-p` (or forces a GPU type) is not seen by `rsk watch`'s row
check, which is why those denies match every row of the target; what a job really got is squeue's. `fail-stop` makes
the table one group: once an approved row fails (FAILED/OUT_OF_MEMORY before its time limit) with its `errors` budget
spent, it cancels the table's other live jobs — only those whose name, user and WorkDir it verified in that same ssh;
a failed job counts once Slurm has purged it from the queue (MinJobAge: `scontrol show config`, e.g. 300 s) and sacct
holds its final state, so the stop lands that long after the failure, and a shorter sibling may have ended by then —
and holds the rows not yet submitted; preemption, timeouts and CANCELLED never trigger it, workstation rows are never
touched, and `--release <that row>` resumes the group once no other fail-stop holds the table. A row whose submit outcome was unknown at the stop is cancelled
once it is tracked (its receipt, or `--adopt`), but only by an `--act` run and only while the table's approved `#@ allow`
still has `fail-stop`: a detect-only run reports `fail-stop-not-cancelled why=no-act` and keeps it pending; approving
the table without `fail-stop` drops those pending cancels (`NOTE … fail-stop-pending-dropped`), while the stop itself
still holds the group until `--release <trigger>`. A stopped table's fail-stop goes with its rows: a renamed or copied
table, or any table with a row the stopped group had, is stopped too (`ATTENTION … reason=fail-stop-inherited`) and
inherits the rows' pending cancels — every round, a `#failstop` in ANY other state file with a line naming one of the
table's rows (a removed row's line too) holds that table, whatever state the row has here (`from=<file>`); if another
state file cannot be read for its stop, nothing is submitted that round (`why=fail-stop-unreadable`). A table keeps
EVERY fail-stop that holds it: its own and each other group's whose state file names one of its rows (`ATTENTION …
reason=fail-stop-inherited … also-held-by=<stops>`), and it still forms its own when one of its rows fails while another
group's holds it (both groups stop). `--release <trigger>` clears only the stops that name triggered, with the pending
cancels they made, in every table of this watch, even where the trigger is not a row (`RELEASE table=… fail-stop=…`),
and records `#failstop-released <trigger>:<job>` in their state, so that stop is never taken again from another file; a
table outside this watch keeps its own copy (an older run-watch drops that line, so it may take the stop again: fail
closed). While another stop remains, every row stays held, the trigger's own row too (`RELEASE table=… fail-stop=<name>
held-by=<stops>`, and on that row `ATTENTION … reason=release-held held-by=…`): release each remaining trigger, each
with the user's OK, then `--release <row>` again for the trigger row's one submit. A plain row's `--release` (a name
that triggered no stop) is still that row's one submit past every hold — the holds that exist when the watch starts:
a fail-stop that holds the row's table later in the same watch, before the release was used (a stop formed by a row
failing, or one taken from another state file, e.g. a row of a stopped group added and approved mid-watch), withdraws
it (`ATTENTION … reason=release-withdrawn fail-stop=<trigger>`), and nothing is submitted past that stop: `--release`
again, with the user's OK (a release can wait a round: one submit per target per round). An installed run-watch from before a table
could keep several stops reads only the LAST `#failstop` of a state file holding several (each is written with its own
`#failstop-pending`, so the pair it reads is one stop's own) and writes the file back with that stop alone: run one
harness version per project (`rsk update`, then `rsk setup`). A row is one run by its name: with no state in its
own table it takes it from the newest other `logs/run-watch/*.state` naming it, but its status and job ids only from a
state line of the row's own target (every state line records its target); from another target only the spent budgets carry over (`NOTE … budgets-from=…
target-there=…`), plus any unknown submit. A line from before the target column follows its jobs only when its own file
names exactly one `#target`, the row's, and the row was not removed; else its target is unknown (`NOTE …
target-changed from=?`): only its spent budgets and an unknown submit stay, and a live job of the row's name and this
WorkDir is adopted again (an ended one: held `adopted-terminal`). Spent budgets are never fewer than any state file holds. A row whose target is
edited in its own table drops its jobs and becomes pending (`NOTE … target-changed`), keeping its budgets and any unknown
submit. Row words never carry `--rs-*` (run-watch sends its own `--rs-attempt`). It resubmits only a job the
controller has purged with a terminal sacct state whose row names this row and this project's WorkDir (JobName, and
WorkDir = `pwd` or `pwd -P` — any other spelling, a third symlink path, counts as a mismatch: fail closed; else the
row is held `job-identity-mismatch … workdir=…`, never resubmitted on another job's id), never a CANCELLED one, never
past an unknown submit outcome; the submit ssh checks that job's name and WorkDir again (`submit-skipped …
prev-identity`). Each submit carries its own attempt nonce; an unknown submit held by ANY other state file of the project (its
nonce) makes the row submit-unknown even when the row has its own state, unless that state already settled the attempt
(the same nonce, or a newer submit of its own). The next read settles it from the remote attempt journal — a receipt
gives `ADOPT`; a journal showing nothing was queued gives the row its own status back (`NOTE … queued nothing … back to
<status>`) — and further unsettled attempts block submits (`why=submit-unknown-elsewhere`); else it stays unknown until
`--adopt NAME=JOBID`, which checks the job's name, user and WorkDir, or a user-approved `--release`. A requeued job
keeps its id and is only counted. One watcher per project: a second one refuses (exit 6) and names the holder's pid,
host, start and act; nothing runs (`rsk status` shows the lease and a `run-watch lock:` line). Exit: 0 every row done, 2 table or conf error, 3 lease over or `--once` with rows
still moving (`rsk watch`: 7; its 3 = a deny matches a row), 4 the rest waits on the user, 6 another watcher (the
lease, a live run-watch lock here, or any lock holder on another host; `rsk watch`: also `grants unreadable`), 7 the
`rsk watch` that started it is gone or no longer its parent (`RS_WATCH_PARENT`; checked at the start, every round,
after each read and before each submit or cancel ssh, in every mode): nothing more is submitted or cancelled, the event
is `ATTENTION reason=parent-gone parent=P at=…`, a fail-stop cancel not yet sent stays pending for the next `--act`
run — run `rsk watch` again. Numbers — the flags `--every --for
--stall-after --max-active`, `#@ allow N`, `after=`, `--adopt` job ids — are base 10, leading zeros dropped, at most 9
significant digits: `0060` is 60 (`rsk watch` reads them the same way). An installed run-watch from before `conf=` binding refuses `#@ ok … conf=` lines
(`malformed '#@ ok' line (write it with --approve)`) and its `--approve` cannot repair them: update the installed
harness (`rsk update`, then `rsk setup`), never edit the line. Conversely this one refuses an ok line with keys it does
not know, or a `#@ run-watch vN` header other than v1, naming a newer run-watch and the same update path; a hand-edited
malformed ok line: delete it, then `rsk watch <table> --approve` with the user's words. An older run-watch reads the state files this
one writes as lost (rows held `state-lost`): refresh the installed copy before mixing them. A job ending within min(15 min, a tenth of its limit) of the time limit
counts as `timeout` even when sacct says FAILED (killed by the USR1 warning) or COMPLETED without its done-path; one
COMPLETED there with done `-` waits for a human (a save-and-exit is not proof the run finished). Run it as this session's background task with a lease (`--for`,
default 2 h) and follow its output; every exit is a review point (`status.sh` spot-check, then restart). Without
that, run `--once` at each review. Never detach it (no `nohup`, `setsid`, cron). After REQUEUE/RESUBMIT confirm the
resume (or set `#@ resume /<the trainer's resume line>/`); ATTENTION is a finding — report it.

## 6. Pull results back — only with `run-pull`
```
rsk pull -T <t> -n <path>...      # = TARGET=<t> bash $ROOT/bin/run-pull -n …: dry run, file count + total size (rsync --stats); writes nothing
rsk pull -T <t> <path>...         # copy them into the local project
```
Paths are relative to the project dir and land at the same path locally (`logs/<file>`, `results/`); plain paths
only (no wildcards, no `..`) — for anything outside the project dir, ask the user. Additive: a local file newer than
the remote copy is kept, nothing local is deleted, local symlinked dirs stay symlinks (one on the path itself is
refused); venvs, caches, deploy dirs, the conf, `.wandb_env` and `.git` are refused. It only runs `rsync`, through the
target's transfer host when its profile sets `T_XFER_HOST`. Never hand-roll an `rsync`/`scp` to `<host>` instead —
a site that requires a transfer node need not refuse every copy elsewhere, so a copy that succeeds proves nothing.
Large trees (`ckpts/`, `wandb/`): `-n` first, then pull with the user's OK. `NOTE: run-sync would push N of these
files back` = a later sync would overwrite newer remote results with this copy: add the dir to `EXTRA_EXCLUDES`
(and drop it from `SYNC_ALSO`). Exit 24 = files vanished mid-copy (a running job rotated them): pull again later.

## Storage model (the deployed `env.sh` enforces it; the target's profile chooses the policy)
Blob caches and outputs are always in-project: `HF_HOME=$PROJ/.cache/huggingface`, `TORCH_HOME=$PROJ/.cache/torch`,
wandb dirs under `$PROJ/wandb`, `$PROJ/.cache/wandb*`, `$PROJ/wandb-artifacts`, plus `$PROJ/logs` and `$PROJ/ckpts`.
Env state follows `T_ENV_ROOT` (default `$PROJ`): the uv venv (`$PROJ/.venv<SUF>`, or `$ENV_ROOT/envs/<proj><SUF>`,
or the conf's `VENV_DIR`), `UV_CACHE_DIR`/python/tools under `$ENV_ROOT/.cache/uv*<SUF>`, the uv binary in
`$ENV_ROOT/bin`, and small-file state (`XDG_*`, `PIP_CACHE_DIR`, `MPLCONFIGDIR`) at `$PROJ` or `$ENV_ROOT/state/<proj><SUF>`.
`TMPDIR` is `$PROJ/tmp` (`T_TMPDIR=project`) or the job's own `$TMPDIR` (`inherit`, falling back to
`/tmp/$USER/run-skills<SUF>`); compile caches (triton, torch_ext, inductor, vllm, flashinfer, nv) sit under
`$PROJ/.cache`, `$TMPDIR`, or a profile path (`T_COMPILE_CACHE`). `<SUF>` = `T_SUFFIX`, which tags all arch-specific
state when targets share a filesystem (`.venv-<name>`); `nv` is never suffixed. Ray: `RAY_TMPDIR` stays node-local
(`$TMPDIR/ray` or `/tmp/ray_$USER<SUF>` — the AF_UNIX socket path limit). `CUDA_HOME` is the profile's or unset.
`PATH` starts with the venv's `bin`, so bare `python` is the project's (and `uv run` works: `UV_NO_SYNC=1`).
Exported for project scripts: `TARGET`, `CLUSTER=<t>`, `RS_TARGET`, `RS_KIND=slurm`, `RS_CUDA_ARCH`, `RS_ENV_ROOT`,
`RS_VENV`, `ENV_NAME`. `ENV_HOOK` is sourced last and may override any of this. Sentinel: `RUN_ENV_READY=$PROJ`
(+ `HPC_ENV_READY`) is exported only when every step succeeded; consumers refuse to run without it.

## Safety rails (every time)
- Files move only through `run-sync` / `run-pull` (the target's transfer host, if any); no hand-rolled `rsync`/`scp`.
- Check the user's recorded words before every submit or cancel (`rsk launch` / `rsk cancel`); outside them, ask.
  `scancel` only after the identity check, never someone else's job. Partition/QOS are submit.sh's call only.
- wandb: your key only (`.wandb_env`), never the cluster's `~/.netrc`; no key → offline. Never `wandb login` there.
- Always `--mem` (cons_tres) — submit.sh sets it. Never create conda envs. Keep outputs/caches under `REMOTE_DIR`.
- Every pilot/train/ablate checkpoints + resumes (jobs go out `--requeue`); smokes run `WANDB_MODE=disabled`;
  classes, names and the wandb project/group/name mapping follow `experiment-conventions.md`.
