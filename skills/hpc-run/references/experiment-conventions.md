# Experiment conventions (both kinds) — classify, name, track, resume

Discipline for every run launched through hpc-run / ws-run. The harness supplies the mechanics (wandb dirs and
key handling, `--requeue`, log names); the agent supplies the naming and the checks below. Nothing here is
target-specific, and none of it renames existing wandb projects/runs — apply it to new launches only.

## 1. Classify the run before naming it
Pick ONE class, by purpose, never by duration:
- `smoke` — wiring/import/env check, a few updates, a failure repro. No comparable learning curve comes out.
- `pilot` — bounded probe whose metrics are intentionally kept and compared.
- `train` — full optimization run.  `eval` — checkpoint evaluation, no optimization.
- `ablate` — controlled causal comparison (still `ablate` even when it runs as long as a train).
- `bench` — throughput / memory / scaling measurement.
Never relabel a smoke as a train because it ran longer than expected: if the purpose changed, stop it and
launch a separately named run.

## 2. Name = structured identity (`-n` on submit.sh, `-N` on run-launch, or `JOB_NAME`)
```
<task>--<stage>--<variant>--<origin>--s<seed>--a<attempt>
mytask-v3--train--lr-cosine--scratch--s0--a01
```
- `task`: readable task family + version (`mytask-v3`).  `stage`: the class from §1.
- `variant`: the ONE hypothesis or change being tried (`lr-cosine`) — not a serialized hyperparameter dump.
- `origin`: model lineage — `scratch` | `fork-<ckpt>` | `finetune-<source>` | `none` (no lineage applies).
- `seed`: `s0`, `s1`, …  `attempt`: `a01`, `a02`, … — separately approved launches of the SAME logical run (§3).
Lowercase ASCII; hyphens inside a field, `--` between fields; the same word for the same concept everywhere;
no opaque `new`/`final`/`best`/`r2`, no bare checkpoint number without its origin role. No timestamp field:
the harness already makes logs unique (slurm `logs/<name>_<jobid>.out`, nohup `logs/<name>-<timestamp>.log`).

## 3. Lineage: restart vs fork
- Same task, config, seed and objective → the SAME logical run; resume the same wandb run when supported.
  Bump only `a<attempt>` for a separately approved resubmit/relaunch; a `run-watch` resubmit within an approved
  budget continues the same attempt and keeps the name. A Slurm requeue keeps the full job name;
  its `restart=N` header records the restart. An approved segment chain (§6) also keeps one full name, including
  `a<attempt>`, for all segments; distinguish them by job id. Neither case requires renaming a running job.
- Any meaningful change (config, data, reward, objective, seed) starting from a checkpoint → a NEW run: new
  name (`origin` = fork/finetune), a new wandb run, and `parent_run` plus the EXACT parent checkpoint path
  (never a glob) recorded in the wandb config. A directory name like `fromscratch` is not lineage metadata.

## 4. Map formal runs into wandb (pilot / train / eval / ablate / bench)
- `project`: the stable task family (`mytask`) — never one project per version or per run.
- `group`: one comparison cohort (`v3-lr-sweep`): the sibling variants answering the same question. No seeds
  or leaf variants in the group name.
- `job_type`: the class from §1.  `name`: `<version>--<stage>--<variant>--<origin>--s<seed>` — drop attempt
  and timestamp (wandb stores both), and do not repeat the project name inside it.
- `notes`: the question being tested and the single expected behavioral change.
- `tags`: low-cardinality `key:value`, one dimension each — `task:mytask`, `version:v3`, `stage:ablate`,
  `variant:lr-cosine`, `origin:scratch` — never compound (`task:mytask-v3`); omit dimensions that don't apply.
- `config` carries the exact facts: the harness job name (`run_name`), `source_commit`, `source_dirty`,
  `command`, `run_class`, `origin`, `seed`, `parent_run`, `parent_checkpoint`, GPU count / world size.
Prefer the trainer's native fields; when it exposes none, prepend wandb's standard env vars to the payload —
`env WANDB_PROJECT=mytask WANDB_RUN_GROUP=v3-lr-sweep WANDB_JOB_TYPE=ablate WANDB_NAME=… <cmd>` (they win
over env.sh's exports). If a required field cannot be set without a code change, report the gap instead of
encoding the metadata into the name. After init, open the printed run URL once and check project / group /
name / tags actually landed — metrics arriving is not verification.

## 5. Smoke runs never reach the tracker
Every smoke goes out with `WANDB_MODE=disabled`: prepend `env WANDB_MODE=disabled` to the payload (or set the
conf key while smoking), plus the trainer's own logger-off flag when it has one. `offline` is NOT enough — it
creates a syncable local run; never `wandb sync` a smoke dir later. Disable any other remote tracker the
project uses the same way. If the startup log still prints a wandb URL / run id, report it, get the OK to
stop it, fix the isolation, rerun. Smoke evidence lives in the log file, not on the experiment dashboard.

## 6. Checkpoint + resume (every pilot / train / ablate)
The run must write periodic checkpoints under the project dir (`ckpts/` or the trainer's own dir) AND resume
from the latest one when re-executed with the same command. Verify that resume flag/behavior exists before
the first long submit; if the command cannot resume, say so in the plan line and let the user decide. Saves are
atomic (temp name, then rename; keep the previous one): a signal or time limit landing mid-save otherwise
corrupts the only resume point.
- slurm: jobs are submitted with `--requeue` (auto-resume by default): preemption or a node failure re-runs
  the SAME command — same job id, log appended, a `restart=N` header line marks the attempt. A partition that
  preempts by cancel ends the job PREEMPTED instead: resuming is a new submit (new id, same name). The harness forwards
  Slurm's `USR1` warning (~120 s before the time limit; on preemption only where the site sends it) and its `TERM`
  (cancel / preempt / final kill, then SIGKILL) to the trainer — handle them (a second TERM may follow on sites
  that signal children too), or rely on periodic saves. A payload without a USR1 handler (a wrapper shell too) dies of
  the warning: sacct says FAILED, not TIMEOUT (only a job still running at the limit is TIMEOUT). A run that cannot
  resume yet goes out with `SBATCH_EXTRA="--no-requeue"` rather than silently retraining from step 0.
- slurm, longer than the partition's walltime: `--requeue` does not restart a job at its walltime, so chain segments —
  one full `-n` name (including `a<attempt>`) for all segments plus `SBATCH_EXTRA="--dependency=singleton"`: only one
  job of that name runs at a time, the next starts when the previous one terminates (TIMEOUT included), a preempted
  segment re-queues into the same chain (so the chain can run one segment more than planned, which the exit-0
  precondition absorbs). Two trainer preconditions, verified before the first submit: it resumes from a committed
  checkpoint, and it exits 0 without training once the run is complete (else the spare retrains).
  Singleton also lets the next segment start after a FAILURE (OOM, config error), so a broken run fails once per
  segment: the segment boundary is a monitoring milestone (§7) — on a failure, report and ask to cancel the rest.
  The plan states the segment count (MaxTime minus a margin each, plus one spare) and the per-segment walltime. A
  save slower than the 120 s warning: `--signal=B:USR1@600` in `SBATCH_EXTRA` (command-line flags override the
  script's `#SBATCH` line).
- nohup: nothing restarts the run for you (it survives ssh disconnect, not a crash or reboot). An approved relaunch
  bumps `a<attempt>` (§3); keep the logical run's checkpoint dir and wandb identity so the new process resumes.

## 7. Monitor — cadence, milestones, what a check may decide
An agent review normally starts with one deployed `status.sh` digest (procedure §5); investigate further as needed.
Use your runtime's waiting and notification mechanisms; state the wake-up mechanism and its coverage. For many
jobs or long waits, follow one `run-watch` (procedure §5) instead of polling job by job.
Waiting inside a command does not itself arrange a later review. Without a way to return later, report a snapshot
and the next check time for re-invocation. Do not promise unattended monitoring without a working wake-up mechanism.
- **Choose the cadence from evidence.** Start with frequent reviews and widen as both liveness (training advancing,
  logs and saves fresh) and quality (finite metrics, plausible trends) are verified.
  Minutes near startup and hours in steady state are examples; not enough evidence holds the interval.
  After an anomaly or restart, review frequently until progress, checkpointing and eval are verified again.
  Balance missed detection (a stall keeps consuming its allocation; a crash delays recovery)
  against model wake-ups, context growth and remote I/O.
- **Events can bring a review forward.** Where supported, keep low-cost background probes between agent reviews;
  probe frequency and review frequency may differ. State which signals the bounded probes cover.
  Set the review interval by important signals outside the probe's coverage and the cost of missing them.
  Bound probes so a failed or stalled check cannot indefinitely postpone the next review.
  Hints are window-scoped line counts, not an event stream: errors may leave the window between probes.
  A changing log alone does not prove training progress. Review at the routine time, or sooner on a finding.
  For expected transitions (start, resume, segment boundary, smoke completion), set a deadline;
  without event notifications, check around that time using the available wake-up mechanism.
  A missed transition deadline is a finding; a routine review time merely schedules a check.
- **Milestones beat the clock:** start (job `R` / PID alive; slurm: the header + `RUN:`, nohup: the trainer's own
  first lines; first steps, the requested GPUs, a formal ONLINE run's wandb URL — offline = none, self-hosted = your
  base URL — and a smoke's absence of one); the first checkpoint written AND resumable — check the trainer's
  save/resume evidence: `ckpt_entry` is only directory activity, possibly a temporary file (`resume=unverified`).
  Then the first eval; every restart or segment boundary (resumed from the LATEST checkpoint, the step matches);
  for multi-day runs a daily audit (throughput → ETA, ckpt age within its interval, segments left, disk, wandb curves).
- **Every finding is reported** promptly, nothing filtered: state changes, hints, stalls, resource trouble,
  a URL on a smoke, or a missed expected transition. Healthy = one line: progress and the next review,
  without repeating the plan. Record new findings when observed; choose how urgently to notify the user
  by the cost of waiting. Log reads are byte-bounded (`status.sh -n 40` is the deep read).
  Failed or incomplete probes do not establish run state; require a complete reply, its command's exit status,
  and fields for the expected run. A complete reply can still contain unknown observations.
  Preserve reasons for unknown observations; retry transient failures, report persistent inability to verify.
  Inaccessible logs or wandb are observation failures, not proof of a training failure.
- **A check decides only machine-checkable things** (alive / done / crashed / a non-finite value in the log).
  Done = the expected artifact exists, not a state word. "Is the result good" is judged once, after the run
  ends, raw numbers shown before interpretation.
- **Detect, don't act:** a check never `scancel`s, `kill`s or resubmits (sole exception: `run-watch --act` on rows the
  user approved, within their budget — procedure §5). Clearly-bad → report the evidence (URL,
  last metrics, log lines, reason) plus a recommendation, then wait for the OK. The same failure twice after a
  fix → stop retrying and escalate.
- A new session first lists what is running (`squeue -u $USER`, `ls -t logs/`, `logs/run-watch/`); keep the run's
  receipt (job ids, log path, ckpt dir, URL, ETA; a watched table's state file) where the next session finds it.
