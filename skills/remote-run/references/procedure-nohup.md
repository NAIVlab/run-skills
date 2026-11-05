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
The GPUs are `-d` / `-g`'s choice, never the run command's: RUN's text that sets or clears `CUDA_VISIBLE_DEVICES` (or a
sibling) anywhere, or empties the whole environment, is refused, and a launcher given its own GPU flags or settings, a
container runtime that picks GPUs, or a tool that starts the command without this launch's environment or elsewhere
(`tmux new`, `docker exec`, `sudo` without `-E`, `ssh`, `srun` …), is a WARNING on the card (§4).
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
— in the ledger, or only in the box's journal: the block's `info_prior` (receipts named `<run>` or `<run>--aNN`, e.g. a
`run-launch` rsk never saw); a block without it, or `unknown`, counts as one too (fail closed; the card's `prior` line
says which). A deny that names the run and lists `relaunch` or `resubmit` stops every launch of it, a first one too, on
any target in its scope (rsk cannot see every earlier attempt: procedure-slurm §4, Denies); a deny written with an
attempt's name (`<run>--a02`, or a glob over them such as `<run>--a*`) stands for the whole run. A relaunch grant covers it
only after a REBOOT ended the run's latest attempt that ran in the ledger, and only for a plan that repeats that attempt's
configuration — its bound fields, `launch_cfg` (below) included: an edited launcher config is `not the configuration of
aNN it resumes: launch_cfg …`, and an attempt recorded before rsk kept `launch_cfg` has none, so a relaunch whose plan
reads a config needs the user once; the user's approval of the card after any end. Exit as for Slurm (procedure-slurm §4: 0 launched, 1 failed — also a plan whose env would fail the gate —,
2 usage — also a RUN that picks GPUs, below —, 3 refused, 4 needs the user, 5 reply lost = SUBMIT_UNKNOWN, 6 stale plan /
drift / a live ledger run of that name / a busy `-d` GPU / `grants unreadable` / `needs: sync`, e.g. a box deployed
before `info_run_gpu=checked`, `info_launchers=checked` or `launch_cfg=`), plus 8: too few free GPUs now. rsk reads the box's journal before it decides: a launch
the target proves never started — verdict refused or failed with no receipt, launch.sh's exit 75 (the attempt name was
taken: this call claimed nothing), no attempt dir after launch.sh itself exited (1–127), or `run-launch` ending before
its launch ssh — is NOT_SUBMITTED: the use comes back and `plan <id> is free again`; a launch.sh killed after its gate
said go is launched (its receipt decides; the use is kept); anything else — ssh 255 whatever its stderr says, a signal,
a journal it cannot read — is SUBMIT_UNKNOWN (`rsk status` settles it). `run-launch` called directly while rsk is installed (on PATH, or in `uv tool dir --bin`)
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
2 usage (a RUN that picks GPUs too, before the claim), 6 same name alive / a busy `-d` GPU / not the approved plan, 75
that attempt already ran, 255 ssh.
**RUN never picks the GPUs** — `-d` / `-n` do (rsk: `-d` / `-g`), checked for other users' processes and bound in the
plan. RUN's TEXT, anywhere — its leading words, a later command, a pipeline element, `bash -c '…'`, a wrapper such as
`timeout` / `nice` before `env`, a container's `--env NAME=` / `-e NAME=` — must not assign or clear
`CUDA_VISIBLE_DEVICES`, `CUDA_DEVICE_ORDER`, `NVIDIA_VISIBLE_DEVICES`, `HIP_VISIBLE_DEVICES` or `ROCR_VISIBLE_DEVICES`:
`NAME=` and `NAME+=`; `-u NAME` and `--unset[= ]NAME`; `unset … NAME`; `export -n NAME`; `declare` / `typeset +x NAME`
— also quoted or backslashed (`'NAME'=0`, `N\AME=0`); `APPTAINERENV_NAME=` / `SINGULARITYENV_NAME=` count as
`NAME=` (apptainer sets NAME inside the container from it, `--cleanenv` or not). A mention as data counts too (`--note
"CUDA_VISIBLE_DEVICES=0"` is refused); reading them is fine (`$NAME`, `printenv NAME`). Nor may RUN's text empty the
whole environment, anywhere (the harness's `CUDA_VISIBLE_DEVICES` and `CUDA_DEVICE_ORDER` would go with it): `env -i`
(also `-vi`, `-0i`), `env -`, `env -- -`, `--ignore-environment` or any abbreviation of it from `--i` on — after a wrapper
(`timeout`, `nice`), after env's other options (`-v`, `-u NAME`, `-C DIR`) or inside `-S`'s string too (env's options end
at its command: `env A=1 cmd -i` and `cmd -i` are fine) — and bash's `exec -c` where a command starts (at the start;
after `;` `|` `&` `(` `{`, a backquote, a quote or a newline; after `then` / `do` / `else` / `time` / `!` / `builtin` /
`command` or `NAME=VALUE` words; `-l` and `-a NAME` may come first), never `exec -ac` (`-a` with the name `c`), `exec -a
-c`, `exec -- -c` or a subcommand's (`apptainer` / `singularity` / `kubectl exec -c`): `ERROR: RUN empties the whole
environment in its text ('env -i': the harness's CUDA_VISIBLE_DEVICES and CUDA_DEVICE_ORDER would go …)` (or `'exec
-c'`). The env facts are GNU env's and the `exec` ones this bash's (`tests/61` R6-6 and 'round-6 integration: bash's
`exec -c`'; on a box `tests/vgate/local.sh` `env_anywhere=`). Among the leading words an `env` option other than
`-v`/`--debug`, `-C DIR` or `-u OTHER` is refused too (it may set or clear them). When RUN's text shows it: exit 2 before
the claim (`ERROR: RUN … — the GPUs are launch.sh's choice`), nothing launched, no card, no attempt dir. When it shows
only after expansion (a conf variable) in the first command: the launch is reported, but the wrapper never starts the
payload (`ERROR: RUN … — not started` in the log, `<log>.rc` rc=2). The plan block's `info_run_gpu=checked` says the
deployed `launch.sh` checks RUN's words, and `info_launchers=checked` that it has the checks of this paragraph and the
next (the `APPTAINERENV_` and empty-environment refusals, the config and container WARNINGs); rsk refuses a deploy
without either (`needs: sync`); one from before the whole-text check also lacks `info_prior=` (its every plan is a
relaunch, its card says `rsk sync`). Honest limit: the payload is code — what it does once it starts is outside what
rsk can check: a value only an expansion inside a later command supplies (`x | env $PRE y`), a script it runs (one
that itself calls tmux or sudo), environment changes beyond the tools warned below (an `exec -c` the text does not show
at a command start, `su -`, `runuser -l`, `pkexec`, at / cron, a sudoers `env_delete`), launcher settings in files rsk
does not read (below); RUN is a command, not a GPU choice, and rsk constrains only what goes through it.
**Launchers that pick GPUs from their own flags** MAY ignore `CUDA_VISIBLE_DEVICES`: `deepspeed` (also `ds`,
`deepspeed.pt`, `python -m deepspeed.launcher.runner`) with `--include`/`-i`, `--exclude`/`-e`,
`--num_gpus`/`--num_accelerators`, `--num_nodes`, `-H`/`--hostfile` or `--master_addr` (argparse prefixes too, `--num_g`;
a short flag's value attached or not), and `accelerate launch` (also `accelerate-launch`, `python -m
accelerate.commands.launch`, `python -m accelerate.commands.accelerate_cli launch`) with `--gpu_ids`/`--gpu-ids` or
`--num_processes`/`--num-processes`. So may their configs.
`accelerate launch` without `--gpu_ids` takes `gpu_ids` from its config, which launch.sh reads, read-only: `--config_file
FILE` (relative to the project dir), else `$PROJ/.cache/huggingface/accelerate/default_config.yaml` (env.sh's `HF_HOME`;
`.json` when only that is a file); a `gpu_ids` other than `all` / `null` / `~` / empty (a YAML list under it is a value) warns, and so do a `--config_file`
it cannot read (missing, unreadable, named by an expansion or `~user`), a config over 64 KiB or an unreadable default one,
and a RUN that sets or unsets `HF_HOME` (any mention but a read, `$HF_HOME`: its default config is then not the one read
here). A relative `--config_file` after a `cd`, `pushd`, `--chdir` or `env -C` in RUN is not read from the project
dir: `with a config it cannot read here (--config_file X: relative, after a cd in RUN)` (an absolute one is read
wherever RUN goes). Without `--config_file` (and `--gpu_ids`) the config accelerate reads is unknown when the conf sets
`ENV_HOOK` (env.sh sources it after setting `HF_HOME`, and it may set anything), when `ENV_KIND=conda` (env.sh runs
`conda activate` after setting `HF_HOME`, and it applies the env's own variables — `conda env config vars`, its
`activate.d` scripts —, which may set `HF_HOME` / `ACCELERATE_…`: `tests/61` 'R8-4'), when the conf names `HF_HOME` or
`ACCELERATE_…` outside a comment line and not as an expansion (`$HF_HOME` is a read), when RUN names `ACCELERATE_…`,
when `.ws.conf` does not source or cannot be read here, or when the project's `.wandb_env` (your wandb key file, which
env.sh sources after setting `HF_HOME`) names `HF_HOME` or `ACCELERATE_…` the same way or cannot be read here — read-only
and never printed: the reason names only `HF_HOME` or `an ACCELERATE_… variable` (`tests/61` 'NF7'): `with no
--config_file: the config accelerate reads is unknown (ENV_HOOK '<hook>' may move it | ENV_KIND=conda: conda activate
'<env>' applies the env's own variables (HF_HOME / ACCELERATE_… among them), which may move it | .ws.conf names <NAME>,
which may move it | RUN names <NAME>, which may move it | .ws.conf did not source here | .ws.conf could not be read here
| .wandb_env names HF_HOME, which may move it | .wandb_env names an ACCELERATE_… variable, which may move it |
.wandb_env could not be read here) — … : give it --config_file FILE (read here,
bound in the plan) and drop any GPU flags and settings, or name the GPUs it will use to the user` (the project's own
default config is still read, and bound, beside it). `deepspeed` without `--hostfile`/`-H` warns when `/job/hostfile`
exists (its runner's default hostfile: read without the flag, it ignores `CUDA_VISIBLE_DEVICES`). A hostfile named by
deepspeed's `-H FILE` / `--hostfile FILE` (`-HFILE`, `-H=FILE`, `--hostfile=FILE`, an argparse prefix such as `--hostf`;
every one given) is read too, as `--config_file` is: an absolute path as given, `~/…` under `$HOME`, a relative one from
the project dir; `<file>:unreadable` after a cd in RUN, through an expansion or `~user`, over 64 KiB, missing, or for a
flag with no value (`'':unreadable`); its `-H`/`--hostfile` WARNING above is unchanged (`tests/61` 'R8-5'). Every config
and hostfile read here is bound in the plan (`launch_cfg`, below). A container does not get the landing at all: `docker`
/ `podman` / `nerdctl` / `nvidia-docker` with `--gpus` (any value, even `device=$CUDA_VISIBLE_DEVICES`), `--runtime`
(any value), `--device nvidia.com/…` or `/dev/nvidia…` (or a value from an expansion), `--privileged` or a bare
`-e`/`--env NVIDIA_VISIBLE_DEVICES`; `nvidia-docker run` always; `apptainer` / `singularity` with `--cleanenv`/`-e` or
`--containall`/`-C` (short clusters such as `-ce` too; without them they pass the landing in). launch.sh never refuses
any of these: it prints a counted WARNING, one per launcher in RUN's text (every word after it counts, the script's own
too) — `WARNING: RUN runs <launcher> with <flags> — such a launcher may ignore CUDA_VISIBLE_DEVICES and pick GPUs itself
…, not only this launch's GPU(s) [<landing ids>]: drop those flags (it then uses these), or name the GPUs it will use to
the user`; for a config, `with gpu_ids: … in <file>`, `with a config it cannot read here (…)` or `with /job/hostfile
(present: its default hostfile, read without --hostfile)` … `drop those flags and settings (it then uses these), or name
the GPUs it will use to the user`; for a container, `WARNING: RUN runs <rt> with … — a container started so does not get
this launch's CUDA_VISIBLE_DEVICES and may see GPUs its runtime picks (any on the box, another user's too), not only this
launch's GPU(s) [<ids>]: name the GPUs it will use to the user` (apptainer / singularity: `drop those flags (it then
keeps these), or …`). Only the user's approval of that card covers it — never a standing grant, whatever its
`--allow-warnings` (`any` too: such a run may use more GPUs than its `--max-gpus`, another user's too): the plan block
counts these WARNINGs apart as `warnings_gpu=N`, the card says `NO GRANT   N launcher / container / env-dropping
warning(s)`, and a block without `warnings_gpu` (an older `launch.sh`: `rsk sync`) counts as unknown — so no grant
covers a GPU container run (`docker run --gpus …`) either. Let the launcher use the landing (no GPU flags or
settings: it then uses the ids launch.sh picked), or name the GPUs it will use to the user. The spellings rest on
argparse (`tests/61` 'R5-2': unique prefixes and attached short values for deepspeed's runner, no abbreviations for
accelerate's); what the launchers do with the variable and where accelerate finds its config is their source, read back
from an installed copy by `tests/vgate/launchers.sh`, and the container facts are read on a box by
`tests/vgate/containers.sh` (both only with the user's OK).
**Tools that start the command elsewhere, or without this launch's environment**, take it off the landing too:
`docker` / `podman` / `nerdctl` / `nvidia-docker` `exec` or `start` (also `container exec|start`: the container's GPUs
were set when it was created); compose — `docker|podman|nerdctl compose`, `docker-compose`, `podman-compose` — `run` /
`up` / `exec` / `start` / `restart`; `kubectl exec|run|debug|apply|create` (a pod, on a node and GPUs the cluster picks);
`tmux` `new-session` / `new` / `new-window` / `neww` / `split-window` / `splitw` / `send-keys` / `send` / `respawn-*` /
`run-shell` / `if-shell` / `display-popup` / `pipe-pane`, under any name tmux runs them by — an alias (`splitp`,
`split-pane`, `respawnp`, `popup`, `pipep` …) or a unique prefix tmux accepts (`split`, `spl`, `sp`, `run-`, `ru`, `i`,
`if-`, `pi`; `new-` and `resp` too: a word at least as long as the shortest prefix only these commands share, while
`s`, `r`, `p`, `ne`, `res`, `display-p` or `send-`, which tmux finds ambiguous with a command not listed here and
refuses, do not warn) (a session made while a tmux server runs gets the server's environment, not the client's);
`screen` with a short-option cluster holding `d`, `D`, `m`, `R` or `X`
(`-dm`, `-d -m`, `-dmS`, `-S … -X`); `setpriv --reset-env` (or a prefix of it from `--res`); `sudo` unless `-E`,
`--preserve-env`, or `--preserve-env=` naming both `CUDA_VISIBLE_DEVICES` and `CUDA_DEVICE_ORDER` (sudoers' `env_reset`;
the harness's ids are `PCI_BUS_ID`-ordered, so both; `-i` / `--login` always warns, and an abbreviation such as
`--preserve-e` is not read); `doas`, `systemd-run`, `ssh` and `srun` / `salloc` / `sbatch` always. A tmux or screen
session also runs outside this run, which ends at once (`rsk cancel` cannot stop the session). Each is a counted
`WARNING: RUN starts its command through <tool …> — <reason> — so it may use GPUs other than this launch's GPU(s)
[<ids>] (any on the box, another user's too): run the command directly (launch.sh detaches it), or name the GPUs it will
use to the user`, counted in `warnings_gpu` like the ones above: only the user's approval of the card covers it. It
reads RUN's text, so it can fire on a word that is only an argument (`rsync -e ssh`, an `exec` inside `docker run … sh
-c`): fail closed, the card shows why. The spellings are `tests/61` 'R7-3'; the facts are read on a box by
`tests/vgate/envdrop.sh` (`ssh <alias> 'bash -s' < tests/vgate/envdrop.sh`, with `systemd-run` only when named: `'bash
-s tmux screen setpriv systemd-run'` starts one transient `--user` unit; it prints `tmux_server_env=`,
`tmux_first_env=`, `tmux_session=`, a second tmux line `tmux_split_prefix_env=` `tmux_prefix=` `tmux_alias=` (each word
asked of a running server with an invalid flag, `-~`, so tmux names the command it resolved and runs nothing; `tests/88`
checks launch.sh's prefix table against this machine's tmux), `screen_dm_env=`, `screen_session=`, `setpriv_reset_env=`,
`setpriv_reset_prefix=`, `systemd_run_env=`) and `containers.sh`'s `<rt>_exec_env=` — both only with the user's OK.
Honest limits — launch.sh sees none of these: a GPU value or launcher flags that only an expansion or a script supplies;
launcher settings in files it does not read (docker `--env-file`, compose files, deepspeed's `.deepspeed_env`); a docker
daemon whose default runtime is nvidia (an image's own `NVIDIA_VISIBLE_DEVICES` then hands the container GPUs with no
flag at all: `containers.sh` prints `docker_default_runtime=`); tools that replace the environment beyond the list above
(`su -`, `runuser -l`, `pkexec`, at / cron, a script that itself calls tmux) and a sudoers `env_delete` (not read);
tools not on the list at all (`byobu`, `lxc` / `incus exec`, `ray job submit`, `mpirun` / `mpiexec` `--host`, `su -l`,
`pixi run --clean-env`, `run0`); tmux commands it runs from a user `command-alias`, a `-f` config, `source-file` or
`set-hook`.
rsk's protocol (api=3: the line `# rs-api=3` inside the deployed `.ws/launch.sh`; with any `--rs-` word, run-launch's one
ssh checks that line first and, on an older `launch.sh`, exits 2 `does not speak rs-api=3`, nothing run — rsk: `needs:
sync`): every call, in every mode, reads the conf as env.sh resolves it (`profile.sh`, then `.ws.conf`, in a child
`bash --noprofile --norc` without the caller's channel or the launch lock, so a process it leaves behind never holds
the reply; what the conf prints goes to stderr) before the launcher checks, which need its `ENV_HOOK`; a plan or an
`--rs-expect` launch refuses a conf that does not source (exit 2), a plain launch goes on to env.sh's gate. `--rs-mode
plan` runs every step above and checks the env gate read-only — the venv's `python` must be
executable (resolved as env.sh resolves it: `VENV_DIR`, `T_ENV_ROOT`, `T_SUFFIX`), a conda env must activate in a
throwaway shell, the `ENV_HOOK` file must exist and `ENV_KIND` be valid — exiting 1 with no card when the launch's gate
would refuse; it creates nothing outside `.rs/` (env.sh itself mkdirs the project's caches: the real gate runs at the
launch). It then prints ONE `@@plan v1` … `@@end` block and starts nothing (bound: `name gpus_req exclude nice
launch_cfg busy_ok payload env_kind env_hook venv_dir uv_sync_args env_name` — `launch_cfg` = `<file>:<sha256>` of every
launcher config and hostfile the checks above read (accelerate's `--config_file` or default config; deepspeed's
`-H`/`--hostfile` file(s), else `/job/hostfile`), sorted and deduplicated, `<file>:unreadable` for one it could not
read (missing, over 64 KiB, named by an expansion or `~user`, relative after a cd), empty when none, `%q`-quoted only
when not plain; `busy_ok` = `<id>:<uuid>:<user>` of each busy GPU the landing accepts with `--gpu-busy-ok`
(sorted by id; empty, or `unknown`), `env_hook` = `<ENV_HOOK>:<sha256 of the file>`; `info_gpus=` `info_uuids=`
`info_busy=<id:user:pid,…>|unknown` `info_run_gpu=checked` (above) `info_prior=<n|unknown>` (the run's earlier attempts in
the box's journal: receipts named the run id — the name minus `--aNN` — or `<run id>--aNN`; `unknown` when one cannot be
read; envelope, not bound: rsk reads n > 0, or no number, as a relaunch) `info_launchers=checked` (above: this launch.sh
warns on launcher configs and container runtimes and refuses `env -i` / `exec -c` / `APPTAINERENV_` — a block without
it is exit 6 `needs: sync … lacks info_launchers`, a plan stored without it is refused at `--plan`: plan again); `warnings=N` (the distinct `WARNING:` lines) `warnings_avail=0` (a box has no
availability `-y` gate: too few free GPUs is exit 1) `warnings_gpu=N` (how many of them are the launcher / container /
env-dropping WARNINGs above: no standing grant covers a plan with one — only the user's approval of the card; rsk reads
a block without it as unknown, never grant-covered) `warnings_id=` (their sha256, digit runs masked) `bound_hash=`;
result `verdict=planned`). `--rs-expect <bound_hash> [--rs-warnings <warnings_id>]` launches only while the request
still hashes the same and the call's `WARNING:` lines give the same `warnings_id` (none given = no warning at all) —
else the current block, `changed: <keys>` (from the approved plan's own journal entry, when it is there) and `ERROR: the
resolved submission differs from the approved plan`, exit 6, before anything starts. The picked ids are envelope: a GPU
that got busy since the plan moves the pick, never the request. A plan is a card for the user, not an approval.
The card shows `launch_cfg` as `launch cfg <file> (sha256 <12 hex>) · …` (one it could not read: `<file> (UNREADABLE on
the box: what the launcher reads there is unknown)`). A config or hostfile edited after the card is exit 6 `changed:
launch_cfg`, even when its WARNING reads the same once digits are masked (`gpu_ids: 0` → `1`), and rsk says `not
submitted: <run> aNN — the resolved launch differs from the approved plan — launch_cfg: <file> (sha256 <old>) → <file>
(sha256 <new>): plan again — the new card goes to the user` (the use is given back). rsk requires the key: a block
without it is `needs: sync … lacks launch_cfg`, a nohup plan stored without it is refused at `--plan` (`lacks
launch_cfg`), and the ledger keeps it with each attempt, so a relaunch repeats it (above).

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
started, its launch was not confirmed). rc is always 0–255: after a TERM, a wait that cannot give the run's own status
(127, or a value outside 0–255 — bash 5.2.37 returned -1 under load) keeps the interrupted wait's 143 (`tests/61`
reproduces it only when asked: `RS_STRESS_TEST=1 bash selftest.sh` keeps every core busy for about a minute; a plain
selftest lists it among its SKIP lines). Once the pid is gone status.sh reads them: `proc=gone pid=… exit=N term=0|1 (<log>.rc)`
(else `(the log's EXIT footer)`, which must name that pid; `exit=unknown` when neither exists); a run
launched before launch.sh existed has neither: there `proc=gone` + the last lines + the final artifact ARE the evidence. Idle = ALL of the run's GPUs under ~5 % util
AND the log not advancing across two checks — never one sample. A nohup'd run survives ssh disconnect, not a reboot:
relaunch with the next `a<attempt>` (`rsk launch --relaunch <run>`, conventions §3) and confirm it resumed. `rsk status`
shows that end as `REBOOT` (pid gone, no `.rc`, the box's boot id is not the run's) — the one end a `relaunch` grant
resumes after.
**Stop a run only through `rsk cancel <run> [--job <pid>] [--approve "<the user's words>" [--asked "<your question>"]]`**:
the same ssh first checks
the pid against the run's receipt (pid, process start time, boot id, your user, the group leader); someone else's
process: never (exit 3). A ledgered run whose pid is gone, reused by another process (its start time differs) or whose
box rebooted (boot id differs) has ended: exit 0 `nothing to cancel … ended`, nothing signalled, its end recorded in the
ledger now (REBOOT for a changed boot id); exit 6 = its identity is not proven (the receipt's start or boot id is not the
ledger's, no receipt, not the group leader), nothing signalled. `rsk cancel --job <pid>` of a run the ledger shows ended
is checked against THAT run's own receipt (a pid reused since: `nothing to cancel … had ended already`, nothing
signalled) and needs the user's words (`cancel_own` never covers an ended attempt); a pid the ledger does not know is
checked against the one receipt whose start and boot id match that process now (several: exit 6 `ambiguous`). Then it sends TERM to the run's process group, waits
`--grace` (30 s) and KILLs what is left; `<log>.rc` is read back. It acts on the user's words naming that run — an
approval bound to its identity (target, pid, start, boot id), for 1 h, used up by its first cancel whatever came of it
— or, for your own judgment that it should stop, on a `cancel_own` grant (runs rsk launched only); else exit 4: ask.
The `--approve` words must name what is stopped, as a whole word: the pid (`--job <pid>`; a numeric range holding it
counts: `4101-4103`) or the run's id or name (`rsk cancel <run>`: the run, or its pid); a token inside a longer one does
not count (`sw1` is not named by `sw10`). When the words answer a question you asked ("sw1 has diverged — stop it?" →
"yes"), pass that question verbatim with `--asked`: it may name the run instead, and is recorded beside the words (the
approval's `source`, the audit) — never ask the user again. "stop it" with no question naming the run names nothing:
exit 4 `needs user: the words do not name <pid|run> — "<words>" names none of: pid P = run <run> (<name>) on <t>;
nothing recorded or cancelled`, no approval, no ssh — ask which run they mean. A check against a slip (a yes to "stop
sw1?" passed for sw2 is exit 4 too), not proof of consent: the question is your own text and rsk does not read whether
the answer was a yes — pass it only for the user's agreement; a `cancel_own` grant is unchanged.
A `cancel_own` grant's cancels count against its `max_launches`; a deny of plans (`rsk grant deny --run <hash>`, one that
covers cancels) matches every cancel of a run the ledger has no plan for. An answer cut off after the cancel started, or none at all (a timeout,
ssh's own 255, a signal), says `the cancel may have been sent: rsk status` (exit 5; a use is kept) — and so does ssh's
own 255 before `@@start`, whatever its stderr says (`… — ssh's own words are no proof that the body never ran; the use
is kept`: a fallback route or a login shell can print `Connection refused` on a session that ran). Exit 1 = processes
left in the run's group (`FAILED: … process(es) still in its group after TERM …`). Without
rsk, on the same terms: `ssh <host> "kill <pid>"` (the `<log>.pid` wrapper: it forwards TERM to the run once and records
`term=1`), and only if the run's group outlives that, `ssh <host> "kill -- -<pid>"` (the whole process group).

**Many runs or long waits: `run-watch`** (cwd = project root; `bin/run-watch` header = the contract). A table
`#@ run-watch v1` lists rows `name target done-path -` (the name = the log prefix `logs/<name>-<timestamp>.log`;
`rsk watch <table> …` runs it under the project's lease). Each
round: one read-only ssh per box, one dated event per change (ADOPT DONE STALL WARN ATTENTION). On workstations it
only detects: it never launches, relaunches or kills. Run it as this session's background task with a lease (`--for`,
default 2 h) and follow its output; every exit is a review point. Without that, run `--once` at each review. Never
detach it (no `nohup`, `setsid`, cron). One watcher per project: a second one exits 6 and names the holder (pid, host,
start); exit 7 = the `rsk watch` that started it is gone (`reason=parent-gone`): run `rsk watch` again. ATTENTION is a
finding — report it.

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
