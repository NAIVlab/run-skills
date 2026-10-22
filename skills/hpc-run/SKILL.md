---
name: hpc-run
description: Run, submit, monitor, or cancel code on the user's Slurm clusters listed in references/INDEX.md, for any local project with a .hpc.conf. Rsyncs the project to its remote dir, bootstraps a contained uv or conda env, checks free GPUs on every cluster and workstation when the user leaves the placement open, and submits an availability-checked sbatch job with every cache and output kept inside the project dir. Use whenever the user wants to run, launch, sbatch, train, or eval on a cluster, HPC, Slurm, or a named partition, or wants job status, logs, results copied back, or to cancel a job.
allowed-tools: Bash, Read, Write, Edit
---

# Run a project on a Slurm cluster — pick the target, read its reference, drive the harness

## 1. Pick the target
Read `references/INDEX.md` **now**. Its line 1 is `root: <dir>` — the installed harness dir, `$ROOT` below. The table
lists every Slurm target: name, ssh host, GPUs, default partition / GPU type, walltime cap, and its reference file.
Pick the target from the user's words (its name or trigger words). For a new launch whose placement they did not
fix (only a range like "an H200" / "4 GPUs", or nothing), run `run-avail` first and place by what is free now (INDEX Routing:
Placement); `DEFAULT_CLUSTER` in `.hpc.conf` is preferred when it can start the job. **Then read exactly that target's
reference file** (the path in its table row): partitions, caps, storage model, gotchas, and a card of its values.
If INDEX says no cluster is registered yet (or the user wants another one), register it with the user: Steps 2–6 of
`$ROOT/INSTALL.md` (read-only discovery with `$ROOT/bin/run-probe`, then `~/.config/run-skills/targets/<name>/` from
`$ROOT/targets/_template-slurm/`, then `install.sh`) — or install the user's lab target pack. A project runs on a
target when its repo root has a `.hpc.conf`; if it is missing (or the user asks to set the project up), follow
`references/project-setup.md` — it asks for `REMOTE_DIR`; never guess it.

## 2. Commands (cwd = the project root; `<t>` = target name, `<host>` = its host column)
```
bash $ROOT/bin/run-avail [--type T] [--min N] # free GPUs on EVERY target (clusters + workstations), read-only
TARGET=<t> bash $ROOT/bin/run-sync             # push code + deploy the harness to <REMOTE_DIR>/.<t>/ (-n dry-run, -D prune)
TARGET=<t> bash $ROOT/bin/run-bootstrap        # first run / deps changed: uv sync the target venv, or verify the conda env
# >>> print a one-line plan (target / partition / GPUs / time / run command) and wait for an explicit go, then:
ssh <host> 'bash <REMOTE_DIR>/.<t>/submit.sh -p <partition> -g <ngpu> [-G <gputype>] -t <time> [-y] -- <RUN>'
ssh <host> 'squeue -u $USER -o "%.10i %.3t %.11M %R %j"'        # monitor: %R = pending reason, %j last = full name
ssh <host> 'bash <REMOTE_DIR>/.<t>/status.sh <jobid>'          # start a review: bounded digest (state, attempt/footer, hints, last lines); -n 40 = deep read
TARGET=<t> bash $ROOT/bin/run-pull [-n] <path>...  # copy results back (paths relative to REMOTE_DIR; -n = count + size first)
bash $ROOT/bin/run-watch <table> [--act]   # many jobs or long waits: one batch watch (procedure §5); acts only on approved rows
```

## 3. Procedure
Follow `references/procedure-slurm.md` (sync → bootstrap → confirm → submit → monitor, the storage model, what
`submit.sh` checks). Every conf key, and which accept a `<TAG>_` prefix, is in `references/conf-keys.md`. Run
classes, naming, the wandb project/group/name mapping and the checkpoint/resume contract:
`references/experiment-conventions.md` — read it before naming or submitting any real experiment.

## Safety rails (always)
- **Confirm before every submit.** Never `scancel` any job — the user's or anyone else's — without an explicit OK.
- Partition and QOS are `submit.sh`'s decision: no raw `sbatch`/`srun`/`salloc`, no `scontrol update`, no
  `--partition` inside `SBATCH_EXTRA`. A policy refusal (exit 3) is final; `-y` also confirms policy warnings (availability, occupancy, SU cost).
- wandb uses the **user's own key** (the deployed `.wandb_env`), never a cluster's `~/.netrc`; no key → offline.
  Never `wandb login` on a cluster.
- Never create a conda env: if `ENV_NAME` is missing on the target, stop and ask. uv venvs are different —
  `run-bootstrap` builds them from the project's own `pyproject.toml`, so running it is safe.
- Everything a run produces stays under `REMOTE_DIR` (the harness pins caches, tmp, logs, ckpts there).
- Files cross the wire only through `run-sync` (up) and `run-pull` (back): they use the target's transfer host
  where the site requires one. Never hand-roll `rsync`/`scp`/`sftp` to `<host>`; ssh is for commands and bounded reads.
- Experiments checkpoint and resume: jobs go out with `--requeue`, so the run command must pick up from its
  latest checkpoint when re-run (confirm before a long submit); smoke tests always run `WANDB_MODE=disabled`.
- Monitoring (`experiment-conventions.md` §7): widen review intervals only with evidence; anomalies and milestones
  need closer attention. Choose low-cost waiting or notifications supported by the runtime; state the wake-up mechanism
  and coverage, or report a snapshot and the next check time. Start reviews with `status.sh`; keep log reads
  byte-bounded. Report every finding promptly, healthy status in one line. Detect-only — stopping or resubmitting
  a job is the user's call. One exception: `run-watch --act` first-submits or resubmits only table rows the user
  approved (rows + budget shown, their words recorded with `--approve`), within the table's `#@ allow` budget.
