# Workstation procedure (any target of kind `nohup`)

`$ROOT` = line 1 of `INDEX.md`; `<t>` = the target name (its `<TAG>` = the name uppercased, non-alphanumerics
dropped: `ws-box` → `WSBOX_`); `<host>` = its ssh alias from the table. Run everything with the **project root as
cwd** (where `.ws.conf` lives). `TARGET=<t>` selects the target (`STATION=<t>` is accepted too);
`rsk sync|bootstrap|pull|avail -T <t> …` run the same scripts, and `rsk launch` / `rsk cancel` wrap `run-launch` / the
kill with the plan card, the authorisation check and the ledger (SKILL.md §3). No scheduler: the run is `nohup`'d over
one ssh and tracked by PID + log. The harness is deployed to `~/<WS_REMOTE_DIR>/.ws/` on every sync.

`.ws.conf` (sourced as shell; double-quote values with spaces) is the only per-project state: `WS_REMOTE_DIR`
(relative to the box's `$HOME`, e.g. `projects/<name>`; `<TAG>_REMOTE_DIR` per box), `ENV_KIND` (uv default | conda,
then `ENV_NAME`), `RUN`; full list in `conf-keys.md`. Missing → follow `project-setup.md`; never guess the remote dir.

## 1. Sync — push code, deploy the harness
```
rsk sync -T <t> [-n] [--also <path>]      # = TARGET=<t> bash $ROOT/bin/run-sync …; additive; -n dry-run; -D also delete
                                          #   remote files gone locally: only on the user's words at the time, never a grant
```
First line printed: `[<t>] remote: <host>:<dir>  tag: <TAG>  deploy: .ws`. Never deletes remote `.venv* .cache
.local .config bin tmp wandb wandb-artifacts logs run_logs ckpts checkpoints runs outputs videos data .wandb_env .rs`
(the launch journal) or any `.<target>/` dir. Pushes the conf, the profile and your wandb key file as `.wandb_env` (mode 600).
`rsk sync -D` runs only with `--approve "<their words>"` (audited) unless a real `-n` / `--dry-run` makes it a listing —
read with run-sync's own grammar: `--also -n` pushes a path named `-n`, it is no dry run.
With a transfer host (`T_XFER_HOST`) it prints `transfer host: <xfer>` and ends `sync done -> … ; files via <xfer>`.
Every sync stamps `<REMOTE_DIR>/.run-source` (local path, host, branch, commit, dirty-file count, time; never pruned):
it prints `[<t>] source: <branch>@<commit> dirty=N`, and every run sees it as `$RS_SOURCE_COMMIT` (env.sh). A remote
dir last synced from **another local checkout** (decided by the local path; the host is only reported) (a second worktree with the same remote dir)
is refused — `ERROR: … was last synced from another checkout: <path> (…)`, exit 2 — because the sync would overwrite
that checkout's code under any job still running from it. Tell the user; with their OK (and no job of the other
checkout running) re-run with `--take-over`. `--also <path>` force-pushes one excluded path for this sync only
(a new container image, a wheelhouse); `SYNC_ALSO` is the every-sync form.

## 2. Bootstrap the env — first run, and after any dependency change (idempotent)
```
rsk bootstrap -T <t>                      # = TARGET=<t> bash $ROOT/bin/run-bootstrap = ssh <host> "cd <WS_REMOTE_DIR> && export PROJ=$PWD TARGET=<t> && bash .ws/bootstrap.sh"
```
uv (default): puts `uv` on PATH (the box's own, `~/.local/bin/uv`, else a private copy in `<project>/bin`) and
`uv sync`s the per-box venv (`.venv`, never rsynced, so each box compiles its own wheels) — or runs `BOOTSTRAP_HOOK`
instead. conda: only *verifies* `ENV_NAME` exists in the box's conda (`T_CONDA_INIT` in its profile) — **never
creates it**; on `conda env 'X' MISSING`, stop and ask. none: builds nothing (runs `BOOTSTRAP_HOOK` if set; the
payload brings its own runtime). Ends with `bootstrap done (<t>).`

## 3. Check GPUs, plan, then check the authorisation (required)
Unless the user fixed the placement, `run-avail` (`rsk avail`) first (INDEX Routing: Placement) — it also shows the Slurm
clusters, which may fit better; the plan cites what is free there. On the chosen box:
```
rsk exec -T <t> -- nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader   # no rsk: ssh <host> "nvidia-smi …"
ssh <host> "ps -eo pid,etime,cmd | grep -i '[p]ython'"      # what is already running, and whose
```
Auto-pick takes the **idlest** GPUs by `memory.used` among those with no compute process (`launch.sh` asks
`nvidia-smi --query-compute-apps` once and names them `GPU(s) in use (id:user:pid)`); memory alone is not "free": read the
table and use `-d` when the pick would land on a busy card. **`rsk launch` (§4) plans first and checks whether the
user's recorded words already cover that plan** (SKILL.md §3): covered → it launches and you report which record
covered it; not covered (exit 4) → show its card verbatim (GPU request, `busy now` = who uses which GPU) with `ref:
<reference path>` (re-read it if only a summary of it is in context) and wait for the user's words. Installed
without rsk: the same check against the user's words; outside them, print a one-line plan (target / GPU ids / run
command / `ref: <reference path>`) and wait for their go. Never launch onto a GPU another job is using without the
user's words naming it: with `-d <ids> --gpu-busy-ok` (rsk takes it only with `-d`), a card that lands on one (`ON A BUSY GPU`) is never grant-covered.
Its `busy ok` row binds who is on each accepted busy GPU (`<id>:<uuid>:<user>`): their approval is for those occupants.
Classify and name the run per `experiment-conventions.md` (run class, structured `-N` name, wandb mapping). A smoke
goes out with `WANDB_MODE=disabled` (prepend `env WANDB_MODE=disabled` to the payload). A pilot/train/ablate must
checkpoint and resume: nothing restarts a nohup run after a crash or reboot. A relaunch must use the logical run's
checkpoint dir even when its attempt suffix changes; confirm that resume behavior before the first long launch.

## 4. Launch (nohup, detached)
```
rsk launch -T <t> [-d 0,1 [--gpu-busy-ok] | -g <count>] [-N <name>] [--nice N] [--same-name-ok] [--class C] [-- <RUN>]
rsk launch --plan <id> [--plan <id>]... --approve "<the user's words>"     # the card(s) the user approved: launch
TARGET=<t> bash $ROOT/bin/run-launch [-d 0,1 | -n <count>] [-N <name>] [--same-name-ok] [--gpu-busy-ok] -- <RUN>   # without rsk
```
`rsk launch` runs `run-launch` (with `RS_VIA_RSK=1`) twice: `--rs-mode plan` for the card, then, once a record covers
the plan, the launch with `--rs-expect <bound_hash> --rs-warnings <the card's warnings_id>` (`--gpu-busy-ok` only when the
approved card's own landing was on a busy GPU, pinned to it with `-d`). The busy set is bound as its occupants
(`busy_ok=<id>:<uuid>:<user>,…`): a different owner on an approved GPU, a newly busy GPU in the landing, or another
physical GPU behind the same id is exit 6, and the refusal names what changed (`busy_ok: 1:GPU-…:me → 1:GPU-…:root`).
No word before `--` may contain `--rs-`, not even as an option's value, and a value of `-g -d -N --nice --relaunch` never
starts with `-` (exit 2). The action is the plan's: a run that already has attempts that may have run is a `relaunch`
(a relaunch grant covers it only after a REBOOT of the box; the user's approval of the card after any end). Exit as for
Slurm (procedure-slurm §4: 0 launched, 1 failed — also a plan whose env would fail the gate —, 3 refused, 4 needs the
user, 5 reply lost = SUBMIT_UNKNOWN, 6 stale plan / drift / a live ledger run of that name / a busy `-d` GPU / `needs:
sync`; a launch the target proves never started — refused or failed with no receipt, or `run-launch` failing before its
launch ssh — is NOT_SUBMITTED: the use comes back and `plan <id> is free again`), plus 8: too few free GPUs now. `run-launch` called directly while rsk is installed (on PATH, or in `uv tool dir --bin`)
prints `use: rsk launch -T <t> …` and exits 2; installed without rsk it launches as below, with a one-line NOTE. That steers; it is not a guard.
`-d ids` uses exactly those GPUs (bypasses `GPU_EXCLUDE`); `-n N` picks the N idlest free ones (no compute process),
skipping `GPU_EXCLUDE` (default `DEFAULT_NGPU`, 1; positive integer; fewer than N free is a hard error, exit 1, never a
silent smaller world size). A `-d` GPU with a compute process is exit 6, and a failed `--query-compute-apps` (busy state
unknown) exit 1 — `--gpu-busy-ok` overrides both (it then prints a `WARNING:`), only when the user named those GPUs; `-N`
names the run (default `JOB_NAME`, else the remote dir's basename); without `--`, `RUN` from the conf is used; `NICE` (0-19)
applies `nice -n`. It prints the GPU table (one read-only ssh), then ONE ssh runs the deployed `.ws/launch.sh`: claim
`<project>/.rs/attempts/<NONCE>/` (printed `attempt: .rs/attempts/<NONCE>`) → refuse a run of the same name from this
project that is still alive (exit 6; `--same-name-ok` runs both — only with the user's OK) → GPU ids checked against
`nvidia-smi` (`CUDA_VISIBLE_DEVICES=<ids>` + `CUDA_DEVICE_ORDER=PCI_BUS_ID`; UUIDs in the receipt) → `. .ws/env.sh`, refuse unless
`RUN_ENV_READY=$PROJ` and `python` *is* `$RS_VENV (uv only)/bin/python` (`uv venv not active (run: … run-bootstrap)`) or
the conda env is active → start `<RUN>` detached (`setsid` + `nohup`, `PYTHONUNBUFFERED=1`) into
`logs/<name>-<timestamp>.log`; it prints `[<t>] started PID … ; log …` + a `verify:` line. Report PID + log path.
Address GPUs as `cuda:0…` in the program. Exit: 0 launched, 1 failed (env gate, nvidia-smi, start) or too few free GPUs,
2 usage, 6 same name alive / a busy `-d` GPU / not the approved plan, 75 that attempt already ran, 255 ssh.
rsk's protocol (api=3: the line `# rs-api=3` inside the deployed `.ws/launch.sh`; with any `--rs-` word, run-launch's one
ssh checks that line first and, on an older `launch.sh`, exits 2 `does not speak rs-api=3`, nothing run — rsk: `needs:
sync`): `--rs-mode plan` runs every step above and checks the env gate read-only — the venv's `python` must be
executable (resolved as env.sh resolves it: `VENV_DIR`, `T_ENV_ROOT`, `T_SUFFIX`), a conda env must activate in a
throwaway shell, the `ENV_HOOK` file must exist and `ENV_KIND` be valid — exiting 1 with no card when the launch's gate
would refuse; it creates nothing outside `.rs/` (env.sh itself mkdirs the project's caches: the real gate runs at the
launch). It then prints ONE `@@plan v1` … `@@end` block and starts nothing (bound: `name gpus_req exclude nice busy_ok payload env_kind env_hook venv_dir
uv_sync_args env_name` — `busy_ok` = `<id>:<uuid>:<user>` of each busy GPU the landing accepts with `--gpu-busy-ok`
(sorted by id; empty, or `unknown`), `env_hook` = `<ENV_HOOK>:<sha256 of the file>`; `info_gpus=` `info_uuids=`
`info_busy=<id:user:pid,…>|unknown`; `warnings=N` (the distinct `WARNING:` lines) `warnings_avail=0` (a box has no
availability `-y` gate: too few free GPUs is exit 1) `warnings_id=` (their sha256, digit runs masked) `bound_hash=`;
result `verdict=planned`). `--rs-expect <bound_hash> [--rs-warnings <warnings_id>]` launches only while the request
still hashes the same and the call's `WARNING:` lines give the same `warnings_id` (none given = no warning at all) —
else the current block, `changed: <keys>` (from the approved plan's own journal entry, when it is there) and `ERROR: the
resolved submission differs from the approved plan`, exit 6, before anything starts. The picked ids are envelope: a GPU
that got busy since the plan moves the pick, never the request. A plan is a card for the user, not an approval.

launch.sh records before it prints: the attempt dir holds `out`/`err` (every line it printed), `stage`, `result`
(`stage= rc= verdict=launched|refused|failed`) and `receipt` (`pid pgid start boot_id gpus log name nonce at`); the run
starts only once its receipt exists. **ssh died mid-launch (exit 255, a NOTE names the attempt): never relaunch blind** —
read `ssh <host> "cat ~/<WS_REMOTE_DIR>/.rs/attempts/<NONCE>/result"`: `verdict=launched` = it runs (its `receipt` names
the log); no file = not started or still starting (read again shortly). A retry with `--rs-attempt <NONCE>` can never
launch twice (exit 75 = that attempt already ran). A launch of the same name within the same second finds its log name
taken (exit 2): retry.

## 5. Monitor / manage — start reviews with a bounded digest; cadence, milestones, detect-only: `experiment-conventions.md` §7
```
rsk logs -T <t> logs/<name>-<timestamp>.log [<ckpt-dir>] [-n 40]                             # the same digest as below, from the local project root (rsk status: all of its runs)
ssh <host> "bash ~/<WS_REMOTE_DIR>/.ws/status.sh logs/<name>-<timestamp>.log [<ckpt-dir>]"   # review digest (~2 KB): PID alive/gone/reused, log size/age, hints, last 5 lines, ckpt-dir activity
ssh <host> "bash ~/<WS_REMOTE_DIR>/.ws/status.sh -n 40 logs/<name>-<timestamp>.log"          # deep read on an anomaly: 40 lines × 200 chars, still byte-bounded
ssh <host> "nvidia-smi --query-gpu=index,uuid,utilization.gpu,memory.used --format=csv,noheader; nvidia-smi --query-compute-apps=pid,gpu_uuid,used_memory --format=csv,noheader"   # join on the uuid
```
`status.sh` takes the PID from `<log>.pid` (written beside the log by the run's wrapper — the process-group leader —
so a later session finds the run without the launch output) and reports `proc=alive pid= etime= cpu= cmd=`, `gone`, `zombie`, or `unknown` (ps failed, or the process is
much younger than the launch: a reused pid or clock skew — never assumed to be the run). Then the log: size/age, `scan=full|partial hints: …` counted over the
last 256 KiB (hints, not diagnoses; `partial` = older bytes were not scanned, so 0 is not "no errors"), `last_hint=`,
`wandb=`, the last lines (CR-normalised, 200 chars each) and, given a ckpt dir, `ckpt_entry` + its age. This is directory
activity, possibly a temporary save or metadata; `resume=unverified` requires trainer evidence (conventions §6).
Never read a log unbounded (`cat`, `tail -n`, `grep` over the whole file): bound the input by bytes first. No
`.ws/status.sh` on the box = the deploy predates it: say so, read bounded (`tail -c 20000 <log> | tr '\r' '\n'`), and
re-sync only with the user's OK (a sync also pushes local code). The log opens
with a harness header (`[<date>] target=<t> job=<pid> restart=0 attempt=<NONCE> gpus=<ids>`) and ends with
`[<date>] EXIT rc=N term=0|1 …`; `<log>.rc` holds `rc= term= at=` (`term=1`: stopped by TERM/INT, rc 143; rc 125: never
started, its launch was not confirmed). Once the pid is gone status.sh reads them: `proc=gone pid=… exit=N term=0|1 (<log>.rc)`
(else `(the log's EXIT footer)`, which must name that pid; `exit=unknown` when neither exists); a run
launched before launch.sh existed has neither: there `proc=gone` + the last lines + the final artifact ARE the evidence. Idle = ALL of the run's GPUs under ~5 % util
AND the log not advancing across two checks — never one sample. A nohup'd run survives ssh disconnect, not a reboot:
relaunch with the next `a<attempt>` (`rsk launch --relaunch <run>`, conventions §3) and confirm it resumed. `rsk status`
shows that end as `REBOOT` (pid gone, no `.rc`, the box's boot id is not the run's) — the one end a `relaunch` grant
resumes after.
**Stop a run only through `rsk cancel <run> [--job <pid>] [--approve "<the user's words>"]`**: the same ssh first checks
the pid against the run's receipt (pid, process start time, boot id, your user, the group leader); someone else's
process: never (exit 3). A ledgered run whose pid is gone, reused by another process (its start time differs) or whose
box rebooted (boot id differs) has ended: exit 0 `nothing to cancel … ended`, nothing signalled, its end recorded in the
ledger now (REBOOT for a changed boot id); exit 6 = its identity is not proven (the receipt and the ledger disagree,
no receipt, not the group leader), nothing signalled. Then it sends TERM to the run's process group, waits
`--grace` (30 s) and KILLs what is left; `<log>.rc` is read back. It acts on the user's words naming that run — an
approval bound to its identity (target, pid, start, boot id), for 1 h, used up by its first cancel whatever came of it
— or, for your own judgment that it should stop, on a `cancel_own` grant (runs rsk launched only); else exit 4: ask.
A `cancel_own` grant's cancels count against its `max_launches`. An answer cut off after the cancel started says `the
cancel may have been sent: rsk status` (exit 5). Without
rsk, on the same terms: `ssh <host> "kill <pid>"` (the `<log>.pid` wrapper: it forwards TERM to the run once and records
`term=1`), and only if the run's group outlives that, `ssh <host> "kill -- -<pid>"` (the whole process group).

**Many runs or long waits: `run-watch`** (cwd = project root; `bin/run-watch` header = the contract). A table
`#@ run-watch v1` lists rows `name target done-path -` (the name = the log prefix `logs/<name>-<timestamp>.log`;
`rsk watch <table> …` runs it under the project's lease). Each
round: one read-only ssh per box, one dated event per change (ADOPT DONE STALL WARN ATTENTION). On workstations it
only detects: it never launches, relaunches or kills. Run it as this session's background task with a lease (`--for`,
default 2 h) and follow its output; every exit is a review point. Without that, run `--once` at each review. Never
detach it (no `nohup`, `setsid`, cron). One watcher per project: a second one exits 6 and names the holder (pid, host,
start). ATTENTION is a finding — report it.

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

## Storage model (the deployed `.ws/env.sh` enforces it; the box's profile chooses the policy)
Everything under the project dir by default: HF/torch caches (`$PROJ/.cache/…`), wandb dirs, `logs/`, `ckpts/`,
`tmp/` (`TMPDIR` — workstation `/tmp` is often tiny), compile caches (`$PROJ/.cache/{triton,torch_ext,inductor,vllm,
flashinfer,nv}`), the uv venv `$PROJ/.venv` (or the conf's `VENV_DIR`), uv caches and small-file state (`XDG_*`, pip,
matplotlib); a profile may move env state (`T_ENV_ROOT`/`T_TMPDIR`/`T_COMPILE_CACHE`) and must set `T_CUDA_HOME` if builds need it (an inherited `CUDA_HOME` is unset). Ray: `RAY_TMPDIR=/tmp/ray_$USER`
stays node-local (socket path limit). `PATH` starts with the venv's `bin`, so bare `python` is the project's. Exported
for scripts: `TARGET`, `WS_TAG=<tag, lowercase>` (never `CLUSTER`), `RS_TARGET`, `RS_KIND=nohup`, `RS_CUDA_ARCH`,
`RS_ENV_ROOT`, `RS_VENV`, `ENV_NAME`; `ENV_HOOK` is sourced last. Sentinel `RUN_ENV_READY=$PROJ` (+ `WS_ENV_READY`)
is exported only when every step succeeded; launch.sh refuses without it.

## Safety rails (every time)
- Files move only through `run-sync` / `run-pull` (the target's transfer host, if any); no hand-rolled `rsync`/`scp`.
- Check the user's recorded words before every launch or stop (`rsk launch` / `rsk cancel`); outside them, ask. Never
  launch onto a busy GPU without the user's words naming it; never signal someone else's process (shared boxes).
- wandb: your key only (`.wandb_env`), never the box's `~/.netrc`; no key → offline. Never create conda envs.
  Keep outputs/caches under the project dir; report PID + log after every launch.
- Every pilot/train/ablate checkpoints + resumes (a relaunch must not retrain from step 0); smokes run
  `WANDB_MODE=disabled`; classes, names and the wandb mapping follow `experiment-conventions.md`.
