---
name: remote-run
description: Run, submit, launch, monitor, stop or cancel code on the user's Slurm clusters (project .hpc.conf) and GPU workstations without a scheduler (project .ws.conf) listed in references/INDEX.md. Rsyncs the project to its remote dir, bootstraps a contained uv or conda env, checks free GPUs on every target when the user leaves the placement open, then submits an availability-checked sbatch job or launches a detached nohup run on the idlest GPUs, with every cache and output kept inside the project dir. Use whenever the user wants to run, launch, sbatch, nohup, train or eval on a cluster, HPC, Slurm, a named partition, a workstation, a GPU server or the box, or wants job status, logs, results copied back, or to cancel a job or stop a run. Replaces the hpc-run and ws-run skills, which project docs and older notes may still name.
allowed-tools: Bash, Read, Write, Edit
---

# Run a project on a Slurm cluster or a GPU workstation — pick the target, read its reference, drive the harness

## 1. Pick the target
Read `references/INDEX.md` **now**. Its line 1 is `root: <dir>` — the installed harness dir, `$ROOT` below. The table
lists every registered target with its kind — `slurm` (a cluster) or `nohup` (a GPU workstation, no scheduler) — ssh
host, GPUs, default partition / GPU type, walltime cap, description and its reference file. Pick the target from the
user's words (its name or trigger words). For a new launch whose placement they did not fix (only a range like "an
H200" / "4 GPUs" / "a free box", or nothing), run `run-avail` first and place by what is free now (INDEX Routing:
Placement) — a cluster may fit better than a box, or the reverse; `DEFAULT_CLUSTER` in `.hpc.conf` / `DEFAULT_STATION`
in `.ws.conf` is preferred when it can start the job. **Then read exactly that target's reference file** (the path in
its table row): partitions or GPUs, caps, storage model, gotchas, and a card of its values. A summary of a file is not
the file: once your context was summarized, re-read the reference (every path in the row; the harness re-prints them
as `reference:` / `ref=`) before each plan unless its text is verbatim in context; the plan ends `ref: <path>`.
If INDEX says no target is registered yet (or the user wants another one), register it with the user: Steps 2–6 of
`$ROOT/INSTALL.md` (read-only discovery with `$ROOT/bin/run-probe`, then `~/.config/run-skills/targets/<name>/` from
`$ROOT/targets/_template-slurm/` or `$ROOT/targets/_template-nohup/`, then `rsk setup`; installed without rsk: re-run
`bash ~/.local/share/run-skills/install.sh` or the pack's `install.sh`) — or `rsk pack add` the user's lab target pack.
A project runs on a target when its repo root has that kind's conf, `.hpc.conf` (Slurm) or `.ws.conf` (workstation);
if it is missing (or the user asks to set the project up), follow `references/project-setup.md` — it asks for
`REMOTE_DIR` / `WS_REMOTE_DIR`; never guess them.

## 2. Commands (cwd = the project root; `<t>` = target name, `<host>` = its host column)
Observe through `rsk` first: read-only, one BatchMode ssh per target; exit 5 = no answer (the state is unknown), 1 = the
remote command failed, 2 = refused or a setup gap (no remote dir in the conf, no deployed status.sh). `rsk` is uv's tool
command (off PATH: `$(uv tool dir --bin)/rsk`); installed without it, read through the `ssh <host>` lines below.
```
rsk status [-T <t>]... [--days N]                 # what runs or ran from this project on every target its conf names; UNOBSERVABLE = unknown, never "none"
rsk logs -T <t> <jobid|log> [<ckpt-dir>] [-n 40]  # start a review: the deployed status.sh digest of one run, byte-bounded (-n 40 = deep read)
rsk exec -T <t> -- <cmd> [args]                   # ONE bounded read in the remote project dir instead of a raw ssh: squeue sacct sinfo nvidia-smi
                                                  #   ps df ls stat, head/tail -c N <relative path>, …; no pipes, no $VAR (write values out)
rsk doctor                                        # offline check of this install (skill, packs, targets, ssh aliases); rsk update: when the user asks
```
Both kinds:
```
bash $ROOT/bin/run-avail [--type T] [--min N]     # free GPUs on EVERY target (clusters + workstations), read-only
TARGET=<t> bash $ROOT/bin/run-sync                 # push code + deploy the harness: <REMOTE_DIR>/.<t>/ or ~/<WS_REMOTE_DIR>/.ws/ (-n dry-run, -D prune, --also <path>)
TARGET=<t> bash $ROOT/bin/run-bootstrap            # first run / deps changed: uv sync the target venv, or verify the conda env (Slurm --job: on a compute node)
TARGET=<t> bash $ROOT/bin/run-pull [-n] <path>...  # copy results back (paths relative to the remote project dir; -n = count + size first)
```
Slurm (`.hpc.conf`):
```
# >>> print a one-line plan (target / partition / GPUs / time / run command) and wait for an explicit go, then:
ssh <host> 'bash <REMOTE_DIR>/.<t>/submit.sh -p <partition> -g <ngpu> [-G <gputype>] -t <time> [-y] -- <RUN>'
ssh <host> 'squeue -u $USER -o "%.10i %.3t %.11M %R %j"'        # all your jobs; %R = pending reason, %j last = full name
ssh <host> 'bash <REMOTE_DIR>/.<t>/status.sh <jobid>'          # the review digest without rsk (= rsk logs -T <t> <jobid>)
bash $ROOT/bin/run-watch <table> [--act]   # many jobs or long waits: one batch watch (procedure §5); acts only on approved rows
```
Workstation (`.ws.conf`):
```
rsk exec -T <t> -- nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader   # who uses what (no rsk: ssh <host> "nvidia-smi …")
# >>> print a one-line plan (target / GPU ids / run command) and wait for an explicit go, then:
TARGET=<t> bash $ROOT/bin/run-launch -n 1 -N <name> -- <RUN>     # nohup on the idlest GPU(s); -d 0,1 picks ids explicitly
ssh <host> "bash ~/<WS_REMOTE_DIR>/.ws/status.sh logs/<name>-<timestamp>.log"   # the digest without rsk (= rsk logs -T <t> <log>)
bash $ROOT/bin/run-watch <table>                  # many runs or long waits: one batch watch (procedure §5), detect-only here
```

## 3. Procedure
Slurm: follow `references/procedure-slurm.md` (sync → bootstrap → confirm → submit → monitor, the storage model, what
`submit.sh` checks). Workstation: follow `references/procedure-nohup.md` (sync → bootstrap → check GPUs → confirm →
launch → monitor, the storage model). Every conf key of both confs, and which accept a `<TAG>_` prefix, is in
`references/conf-keys.md`. Run classes, naming, the wandb project/group/name mapping and the checkpoint/resume
contract: `references/experiment-conventions.md` — read it before naming, submitting or launching any real experiment.

## Safety rails (always)
- **Confirm before every submit or launch.** Slurm: never `scancel` any job — the user's or anyone else's — without an
  explicit OK. Workstations are often shared: never launch onto a GPU another job is using, and never `kill` a running
  process, without an explicit OK. Auto-pick takes the *idlest* GPUs, not necessarily free ones — read the printed
  table and use `-d` when the pick would land on a busy card.
- Slurm: partition and QOS are `submit.sh`'s decision — no raw `sbatch`/`srun`/`salloc`, no `scontrol update`, no
  `--partition` inside `SBATCH_EXTRA`. A policy refusal (exit 3) is final; `-y` also confirms policy warnings (availability, occupancy, SU cost).
- wandb uses the **user's own key** (the deployed `.wandb_env`), never a cluster's or the box's `~/.netrc`; no key →
  offline. Never `wandb login` on a cluster.
- Never create a conda env: if `ENV_NAME` is missing on the target, stop and ask. uv venvs are different —
  `run-bootstrap` builds them from the project's own `pyproject.toml`, so running it is safe. `ENV_KIND=uv` is the
  default; scaffold new `.ws.conf` files as uv unless the user asks for conda.
- Everything a run produces stays under the project's remote dir (the harness pins caches, tmp, logs, ckpts there).
- Files cross the wire only through `run-sync` (up) and `run-pull` (back): they use the target's transfer host
  where the site requires one. Never hand-roll `rsync`/`scp`/`sftp` to `<host>`; ssh is for commands and bounded reads.
- Experiments checkpoint and resume: Slurm jobs go out with `--requeue`, so the run command must pick up from its
  latest checkpoint when re-run (confirm before a long submit); nothing restarts a nohup run after a crash or reboot,
  so the command must pick up from its latest checkpoint on relaunch. Smoke tests always run `WANDB_MODE=disabled`.
- Monitoring (`experiment-conventions.md` §7): widen review intervals only with evidence; anomalies and milestones
  need closer attention. Choose low-cost waiting or notifications supported by the runtime; state the wake-up mechanism
  and coverage, or report a snapshot and the next check time. Start reviews with the `status.sh` digest (`rsk logs`);
  keep log reads byte-bounded. Report every finding promptly, healthy status in one line. Detect-only — stopping,
  killing or resubmitting a run is the user's call. One exception, Slurm only: `run-watch --act` first-submits or
  resubmits only table rows the user approved (rows + budget shown, their words recorded with `--approve`), within the
  table's `#@ allow` budget; on workstations `run-watch` only detects.
