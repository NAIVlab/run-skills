# Slurm procedure (any target of kind `slurm`)

`$ROOT` = line 1 of `INDEX.md`; `<t>` = the target name (its `<TAG>` = the name uppercased, non-alphanumerics
dropped: `my-hpc` → `MYHPC_`); `<host>` = its ssh alias from the table. Run everything with the **project root as cwd**
(where `.hpc.conf` lives). `TARGET=<t>` selects the target for the local commands (`CLUSTER=<t>` is accepted too).
The deployed copy of the harness lives at `<REMOTE_DIR>/.<t>/` — `env.sh status.sh submit.sh job.sbatch bootstrap.sh
profile.sh [policy.sh policy.local.sh]` — and is refreshed by every sync.

## 0. `.hpc.conf` — the only per-project state
Sourced as shell: values with spaces MUST be double-quoted or sync/submit abort. Minimum: `REMOTE_DIR` (absolute
remote project dir; `<TAG>_REMOTE_DIR` per target when targets do not share a filesystem), `ENV_KIND` (uv default |
conda, then `ENV_NAME`), `RUN` (default command). Full list, defaults and prefix rules: `conf-keys.md`. Missing conf →
follow `project-setup.md` (ask for `REMOTE_DIR`, env kind, run command); local and remote names differ, so never guess the dir.

## 1. Sync — push code, deploy the harness
```
TARGET=<t> bash $ROOT/bin/run-sync        # additive; -n dry-run; -D also delete remote files gone locally; --also <path>
```
First line printed: `[<t>] remote: <host>:<dir>  tag: <TAG>  deploy: .<t>` — check it on a new project (use `-n`). With a
transfer host it also prints `transfer host: <xfer>` and ends `sync done -> … ; files via <xfer>`.
Never deletes remote `.venv* .cache .local .config bin tmp wandb wandb-artifacts logs run_logs ckpts checkpoints runs
outputs videos data .wandb_env` or any `.<target>/` dir; `EXTRA_EXCLUDES` adds patterns, `SYNC_ALSO` force-pushes
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
TARGET=<t> bash $ROOT/bin/run-bootstrap   # = ssh <host> "cd <REMOTE_DIR> && export PROJ=$PWD TARGET=<t> && bash .<t>/bootstrap.sh"
TARGET=<t> bash $ROOT/bin/run-bootstrap --job [-p <partition> -c <cpus> -m <mem> -t <time>]   # the same, as a batch job
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
which partition qualifies. It is a job: state the plan and wait for the go as in §3, then follow it with
`status.sh <jobid>` until the log shows `bootstrap done (<t>).` `job.sbatch` lets exactly this payload start without a venv.

## 3. Decide resources, then CONFIRM (required)
Collect partition / GPU count / GPU type / walltime / run command from the user's words, the target's reference and
the conf defaults. Unless the user fixed the placement, `run-avail` comes first (INDEX Routing: Placement):
the plan then cites what is free (`max/node` = GPUs on one node; `planned` = held by backfill for a pending job; free is
not schedulable — QOS and per-user caps apply), and why this target and partition. **Print a one-line plan and wait for an explicit "go" / "确认" / "跑".** Never submit on implicit
consent. Prefer the target's default partition unless the user or the reference says otherwise.
Classify and name the run per `experiment-conventions.md` (run class, structured `-n` name, wandb mapping). A smoke
goes out with `WANDB_MODE=disabled` (prepend `env WANDB_MODE=disabled` to the payload). For a pilot/train/ablate,
confirm the command checkpoints AND auto-resumes — jobs are submitted `--requeue`, so a requeued job re-runs the
same command; if it cannot resume, say so in the plan (`SBATCH_EXTRA="--no-requeue"` opts it out). Longer than the
partition's MaxTime → a singleton segment chain (conventions §6): the plan states the segment count and walltime.

## 4. Submit (runs on the login node)
```
ssh <host> 'bash <REMOTE_DIR>/.<t>/submit.sh -p <partition> -g <ngpu> [-G <gputype>] [-t <time>] [-m <mem>] [-c <cpus>] [-n <name>] [-y] -- <RUN>'
```
Defaults: `-p`/`-G` ← `<TAG>_DEFAULT_PARTITION` / `<TAG>_DEFAULT_GPU_TYPE` else the profile's; `-g -c -m -t -n` ←
`DEFAULT_GPUS/CPUS/MEM/TIME`, `JOB_NAME` (`<TAG>_` form wins); `ACCOUNT`, `SBATCH_EXTRA` are appended. CLI flags win.
Unset cpus/mem fall back to the partition's per-GPU heuristics (policy.sh). `submit.sh` then, in order: runs the
target's `t_policy` (a refusal propagates its exit code, typically 3, and `-y` does not unlock it), validates the
partition and `-g` range, rejects a `-t` beyond the partition MaxTime (`exceeds … MaxTime` = it would pend forever; lower `-t`),
rejects a payload that calls `sbatch/srun/salloc` and an `SBATCH_EXTRA` carrying `-p/--partition` or a forbidden QOS,
prints per-node availability and stops with `WARNING: only N free … Re-run -y` when the GPUs are not free (`-y`
queues anyway), then `sbatch --requeue --export=ALL,PROJ,CLUSTER,TARGET … --mem=… .<t>/job.sbatch <RUN>` (the
early `--requeue` lets a later `SBATCH_EXTRA` `--no-requeue` win).
Report the job id. Unknown `--word` flags pass through to policy (`--…-user-asked` sets `ACK=1` for it).

## 5. Monitor / manage — start reviews with a bounded digest; cadence, milestones, detect-only: `experiment-conventions.md` §7
```
ssh <host> 'bash <REMOTE_DIR>/.<t>/status.sh <jobid> [<ckpt-dir>]'     # review digest (~2 KB): job state, attempt/footer, hints, last 5 lines, ckpt-dir activity
ssh <host> 'bash <REMOTE_DIR>/.<t>/status.sh -n 40 <jobid>'            # deep read on an anomaly: 40 lines × 200 chars, still byte-bounded
ssh <host> 'squeue -u $USER -o "%.10i %.12P %.3t %.11M %.11L %R %j"'   # everything of yours; %R = pending reason, %j last = full name
ssh <host> 'sacct -j <jobid> -X -o JobID,State%20,Elapsed,ExitCode'     # accounting (status.sh shows it once the job left the queue); memory: sacct -j <jobid>.batch -o MaxRSS
```
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
Every attempt opens with the `target=… restart=N` header line, `RUN:` precedes the payload, and `EXIT rc=N usr1=… term=…`
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
the earlier attempts) — confirm the trainer's own resume line after every restart. `scancel` only with explicit approval.

**Many jobs or long waits: `run-watch`** (cwd = project root; `bin/run-watch` header = the full contract). A table
`#@ run-watch v1` lists rows `name target done-path submit.sh-args -- cmd` (or `-`: watch only; `-p` required, no
`-n`, no `*-user-asked`, no shell quoting). Each round: one read-only ssh per target, one dated event per change
(LAUNCH REQUEUE RESUBMIT RETRY DONE STALL WARN ATTENTION …). Without `--act` it never submits. To let it act, show
the user the rows plus `#@ allow launch preempt=N errors=N timeout=N` (no default: absent = 0; paid partitions:
the cost of first submits plus N resubmits); only after their explicit OK run `run-watch <table> --approve "<their
words>"`. Any later edit to those rows or the budget makes them detect-only again. It resubmits only a job the
controller has purged with a terminal sacct state, never a CANCELLED one, never past an unknown submit outcome; a
requeued job keeps its id and is only counted. A job ending within min(15 min, a tenth of its limit) of the time limit
counts as `timeout` even when sacct says FAILED (killed by the USR1 warning) or COMPLETED without its done-path; one
COMPLETED there with done `-` waits for a human (a save-and-exit is not proof the run finished). Run it as this session's background task with a lease (`--for`,
default 2 h) and follow its output; every exit is a review point (`status.sh` spot-check, then restart). Without
that, run `--once` at each review. Never detach it (no `nohup`, `setsid`, cron). After REQUEUE/RESUBMIT confirm the
resume (or set `#@ resume /<the trainer's resume line>/`); ATTENTION is a finding — report it.

## 6. Pull results back — only with `run-pull`
```
TARGET=<t> bash $ROOT/bin/run-pull -n <path>...   # dry run: file count + total size (rsync --stats); writes nothing
TARGET=<t> bash $ROOT/bin/run-pull <path>...      # copy them into the local project
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
- Confirm before every submit. Never `scancel` without an explicit OK. Partition/QOS are submit.sh's call only.
- wandb: your key only (`.wandb_env`), never the cluster's `~/.netrc`; no key → offline. Never `wandb login` there.
- Always `--mem` (cons_tres) — submit.sh sets it. Never create conda envs. Keep outputs/caches under `REMOTE_DIR`.
- Every pilot/train/ablate checkpoints + resumes (jobs go out `--requeue`); smokes run `WANDB_MODE=disabled`;
  classes, names and the wandb project/group/name mapping follow `experiment-conventions.md`.
