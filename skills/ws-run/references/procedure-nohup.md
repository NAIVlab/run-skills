# Workstation procedure (any target of kind `nohup`)

`$ROOT` = line 1 of `INDEX.md`; `<t>` = the target name (its `<TAG>` = the name uppercased, non-alphanumerics
dropped: `ws-box` → `WSBOX_`); `<host>` = its ssh alias from the table. Run everything with the **project root as
cwd** (where `.ws.conf` lives). `TARGET=<t>` selects the target (`STATION=<t>` is accepted too). No scheduler: the run
is `nohup`'d over one ssh and tracked by PID + log. The harness is deployed to `~/<WS_REMOTE_DIR>/.ws/` on every sync.

`.ws.conf` (sourced as shell; double-quote values with spaces) is the only per-project state: `WS_REMOTE_DIR`
(relative to the box's `$HOME`, e.g. `projects/<name>`; `<TAG>_REMOTE_DIR` per box), `ENV_KIND` (uv default | conda,
then `ENV_NAME`), `RUN`; full list in `conf-keys.md`. Missing → follow `project-setup.md`; never guess the remote dir.

## 1. Sync — push code, deploy the harness
```
TARGET=<t> bash $ROOT/bin/run-sync        # additive; -n dry-run; -D also delete remote files gone locally
```
First line printed: `[<t>] remote: <host>:<dir>  tag: <TAG>  deploy: .ws`. Never deletes remote `.venv* .cache
.local .config bin tmp wandb wandb-artifacts logs run_logs ckpts checkpoints runs outputs videos data .wandb_env`
or any `.<target>/` dir. Pushes the conf, the profile and your wandb key file as `.wandb_env` (mode 600).
With a transfer host (`T_XFER_HOST`) it prints `transfer host: <xfer>` and ends `sync done -> … ; files via <xfer>`.

## 2. Bootstrap the env — first run, and after any dependency change (idempotent)
```
TARGET=<t> bash $ROOT/bin/run-bootstrap   # = ssh <host> "cd <WS_REMOTE_DIR> && export PROJ=$PWD TARGET=<t> && bash .ws/bootstrap.sh"
```
uv (default): puts `uv` on PATH (the box's own, `~/.local/bin/uv`, else a private copy in `<project>/bin`) and
`uv sync`s the per-box venv (`.venv`, never rsynced, so each box compiles its own wheels) — or runs `BOOTSTRAP_HOOK`
instead. conda: only *verifies* `ENV_NAME` exists in the box's conda (`T_CONDA_INIT` in its profile) — **never
creates it**; on `conda env 'X' MISSING`, stop and ask. Ends with `bootstrap done (<t>).`

## 3. Check GPUs, then CONFIRM (required)
Unless the user fixed the placement, `run-avail` first (INDEX Routing: Placement) — it also shows the Slurm clusters,
which may fit better; the plan cites what is free there. On the chosen box:
```
ssh <host> "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader"
ssh <host> "ps -eo pid,etime,cmd | grep -i '[p]ython'"      # what is already running, and whose
```
Auto-pick takes the **idlest** GPUs by `memory.used`, not necessarily free ones: read the table and use `-d` when the
pick would land on a busy card. **Print a one-line plan (target / GPU ids / run command) and wait for an explicit
go.** Never launch onto a GPU another job is using without the user's OK.
Classify and name the run per `experiment-conventions.md` (run class, structured `-N` name, wandb mapping). A smoke
goes out with `WANDB_MODE=disabled` (prepend `env WANDB_MODE=disabled` to the payload). A pilot/train/ablate must
checkpoint and resume: nothing restarts a nohup run after a crash or reboot. A relaunch must use the logical run's
checkpoint dir even when its attempt suffix changes; confirm that resume behavior before the first long launch.

## 4. Launch (nohup, detached)
```
TARGET=<t> bash $ROOT/bin/run-launch [-d 0,1 | -n <count>] [-N <name>] -- <RUN>
```
`-d ids` uses exactly those GPUs (bypasses `GPU_EXCLUDE`); `-n N` picks the N idlest, skipping `GPU_EXCLUDE` (default
`DEFAULT_NGPU`, 1; positive integer; fewer than N ids left is a hard error, never a silent smaller world size); `-N`
names the run (default `JOB_NAME`, else the remote dir's basename); without `--`, `RUN` from the conf is used; `NICE` (0-19)
applies `nice -n`. Over ONE ssh: `cd` project → `export PROJ TARGET` → `. .ws/env.sh` → refuse unless `RUN_ENV_READY=$PROJ`
and `python` *is* `$RS_VENV (uv only)/bin/python` (`uv venv not active (run: … run-bootstrap)`) or the conda env is active →
`nohup env CUDA_VISIBLE_DEVICES=<ids> PYTHONUNBUFFERED=1 <RUN> > logs/<name>-<timestamp>.log 2>&1 &`; it prints
`[<t>] started PID … ; log …` + a `verify:` line. Report PID + log path. Address GPUs as `cuda:0…` in the program.

## 5. Monitor / manage — start reviews with a bounded digest; cadence, milestones, detect-only: `experiment-conventions.md` §7
```
ssh <host> "bash ~/<WS_REMOTE_DIR>/.ws/status.sh logs/<name>-<timestamp>.log [<ckpt-dir>]"   # review digest (~2 KB): PID alive/gone/reused, log size/age, hints, last 5 lines, ckpt-dir activity
ssh <host> "bash ~/<WS_REMOTE_DIR>/.ws/status.sh -n 40 logs/<name>-<timestamp>.log"          # deep read on an anomaly: 40 lines × 200 chars, still byte-bounded
ssh <host> "nvidia-smi --query-gpu=index,uuid,utilization.gpu,memory.used --format=csv,noheader; nvidia-smi --query-compute-apps=pid,gpu_uuid,used_memory --format=csv,noheader"   # join on the uuid
```
`status.sh` takes the PID from `<log>.pid` (written by `run-launch` beside the log, so a later session finds the run
without the launch output) and reports `proc=alive pid= etime= cpu= cmd=`, `gone`, `zombie`, or `unknown` (ps failed, or the process is
much younger than the launch: a reused pid or clock skew — never assumed to be the run). Then the log: size/age, `scan=full|partial hints: …` counted over the
last 256 KiB (hints, not diagnoses; `partial` = older bytes were not scanned, so 0 is not "no errors"), `last_hint=`,
`wandb=`, the last lines (CR-normalised, 200 chars each) and, given a ckpt dir, `ckpt_entry` + its age. This is directory
activity, possibly a temporary save or metadata; `resume=unverified` requires trainer evidence (conventions §6).
Never read a log unbounded (`cat`, `tail -n`, `grep` over the whole file): bound the input by bytes first. No
`.ws/status.sh` on the box = the deploy predates it: say so, read bounded (`tail -c 20000 <log> | tr '\r' '\n'`), and
re-sync only with the user's OK (a sync also pushes local code). The log holds
only the trainer's own output (no harness header) and nothing records an exit status: `proc=gone` + the last lines + the final
artifact ARE the evidence (a normal end shows the trainer's own final line). Idle = ALL of the run's GPUs under ~5 % util
AND the log not advancing across two checks — never one sample. A nohup'd run survives ssh disconnect, not a reboot:
relaunch with the next `a<attempt>` (conventions §3) and confirm it resumed. **Never `kill` a process without explicit approval**; after an
OK: `ssh <host> "kill <pid>"`.

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

## Storage model (the deployed `.ws/env.sh` enforces it; the box's profile chooses the policy)
Everything under the project dir by default: HF/torch caches (`$PROJ/.cache/…`), wandb dirs, `logs/`, `ckpts/`,
`tmp/` (`TMPDIR` — workstation `/tmp` is often tiny), compile caches (`$PROJ/.cache/{triton,torch_ext,inductor,vllm,
flashinfer,nv}`), the uv venv `$PROJ/.venv` (or the conf's `VENV_DIR`), uv caches and small-file state (`XDG_*`, pip,
matplotlib); a profile may move env state (`T_ENV_ROOT`/`T_TMPDIR`/`T_COMPILE_CACHE`) and must set `T_CUDA_HOME` if builds need it (an inherited `CUDA_HOME` is unset). Ray: `RAY_TMPDIR=/tmp/ray_$USER`
stays node-local (socket path limit). `PATH` starts with the venv's `bin`, so bare `python` is the project's. Exported
for scripts: `TARGET`, `WS_TAG=<tag, lowercase>` (never `CLUSTER`), `RS_TARGET`, `RS_KIND=nohup`, `RS_CUDA_ARCH`,
`RS_ENV_ROOT`, `RS_VENV`, `ENV_NAME`; `ENV_HOOK` is sourced last. Sentinel `RUN_ENV_READY=$PROJ` (+ `WS_ENV_READY`)
is exported only when every step succeeded; the launch chain refuses without it.

## Safety rails (every time)
- Files move only through `run-sync` / `run-pull` (the target's transfer host, if any); no hand-rolled `rsync`/`scp`.
- Confirm before every launch; never launch onto a busy GPU or `kill` a run without an OK (shared boxes).
- wandb: your key only (`.wandb_env`), never the box's `~/.netrc`; no key → offline. Never create conda envs.
  Keep outputs/caches under the project dir; report PID + log after every launch.
- Every pilot/train/ablate checkpoints + resumes (a relaunch must not retrain from step 0); smokes run
  `WANDB_MODE=disabled`; classes, names and the wandb mapping follow `experiment-conventions.md`.
