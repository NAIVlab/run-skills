# Conf keys — `.hpc.conf` (kind `slurm`) and `.ws.conf` (kind `nohup`)

The conf lives in the project root — `.hpc.conf` for Slurm targets, `.ws.conf` for workstations, both when the project
uses both kinds — and is **sourced as shell** (double-quote values with spaces; plain `export VAR=…` lines also reach
the job or run: env.sh sources the conf at its start). `submit.sh` reads `.hpc.conf` in a child shell and takes back only
the keys below: a function, alias or `PATH` change in the conf never affects the submit itself, and `T_*` lines never
override the target's profile. A Slurm job uses the conf as it was at submit time (a snapshot), also after a requeue. The keys
that shape a submission or launch are bound into rsk's plan (`bound_hash`): a conf edited after the approval makes that
approved submit/launch exit 6 (`--rs-expect`), so re-plan after any conf change (a standing grant is checked against
each new plan's fields, so a re-plan inside its scope needs no new question; an approval names exact plans). Precedence, highest first: CLI flag → `<TAG>_KEY` → `KEY` → default. `<TAG>` = target name uppercased
with non-alphanumerics dropped (`mycluster` → `MYCLUSTER_`, `my-hpc` → `MYHPC_`, `ws-box` → `WSBOX_`).
Only the keys marked **prefixable** honour `<TAG>_`; `run-sync` warns about any other `<TAG>_KEY` line
(`WARN: … is not honoured` — e.g. a `<TAG>_ENV_KIND` is never read). A target's profile may add its own prefixable keys
via `T_CONF_KEYS`.

## Keys of both confs

| key | prefixable | meaning / default |
|---|---|---|
| `ENV_KIND` | no | `uv` (default: a venv per target built by `run-bootstrap` from `pyproject.toml`), `conda` (a named env that must already exist) or `none` (no managed env: the payload brings its own runtime, e.g. `apptainer exec img.sif …`; containment env vars still apply, PATH is otherwise left as inherited, `BOOTSTRAP_HOOK` still runs) |
| `ENV_NAME` | yes | conda env name (`ENV_KIND=conda` only); exported to the job; the workstation launch (`launch.sh`) requires it to be the active env |
| `RUN` | yes | default run command; `python` is the target venv's python (`uv run` also works). Slurm: the agent pastes it after `--` (submit.sh has no fallback). Workstation: used when `rsk launch` / `run-launch` gets no `--`; keep it simple — quoting is not preserved across ssh + nohup. It never picks the GPUs (`-d` / `-n` do): its text, anywhere (a later command, a pipeline element, `bash -c '…'`, a container's `--env NAME=`; quoted, backslashed or as data too), may not assign or clear `CUDA_VISIBLE_DEVICES`, `CUDA_DEVICE_ORDER`, `NVIDIA_VISIBLE_DEVICES`, `HIP_VISIBLE_DEVICES` or `ROCR_VISIBLE_DEVICES` (`NAME=`, `NAME+=`, `-u NAME`, `--unset[= ]NAME`, `unset … NAME`, `export -n NAME`, `declare`/`typeset +x NAME`; reading them is fine; `APPTAINERENV_NAME=` / `SINGULARITYENV_NAME=` count as `NAME=`: apptainer sets NAME inside the container from it), nor empty the whole environment anywhere (`env -i` / `-vi` / `-0i`, `env -`, `env -- -`, `--ignore-environment` or any abbreviation from `--i` — after a wrapper, after env's other options or inside `-S`'s string too —, and bash's `exec -c` where a command starts), nor may its leading words carry an `env` option other than `-v`/`--debug`, `-C DIR`, `-u OTHER`: exit 2 before the launch when RUN's text shows it, else (only after expansion, in its first command) the payload never starts (rc 2). A launcher given its own GPU flags (`deepspeed --num_gpus`…, `accelerate launch --gpu_ids`…) is a WARNING on the card, and so are a launcher's GPU settings (a `gpu_ids` in accelerate's `--config_file` or its default config under `$PROJ/.cache/huggingface`; `accelerate launch` with no `--config_file` while the config it reads is unknown — this conf sets `ENV_HOOK` or `ENV_KIND=conda`, or it, RUN or the project's `.wandb_env` names `HF_HOME` / `ACCELERATE_…` other than as an expansion; deepspeed without `--hostfile` while `/job/hostfile` exists; a hostfile `-H` / `--hostfile` names is read and bound), a container runtime that picks GPUs (`docker` / `podman` / `nerdctl` with `--gpus`, `--runtime`, `--device nvidia.com/…` or `/dev/nvidia…`, `--privileged`, a bare `-e NVIDIA_VISIBLE_DEVICES`; `nvidia-docker run`; `apptainer` / `singularity` with `--cleanenv` or `--containall`) and a tool that starts the command without this launch's environment or elsewhere (`docker` / `podman` `exec` / `start`, compose `run` / `up`, `kubectl exec`, `tmux new` / `send-keys` / `split` (any prefix tmux takes), `screen -dm`, `setpriv --reset-env`, `sudo` without `-E`, `doas`, `systemd-run`, `ssh`, `srun` / `sbatch`) — no standing grant covers such a card, only the user's approval of it: put the command itself in RUN. What the payload does once it runs is beyond any check (`procedure-nohup.md` §4) |
| `JOB_NAME` | yes | default job/run name — Slurm `-n` (else the project dir basename), log `logs/<name>_<jobid>.out`; workstation `-N` (else the remote dir's basename), log `logs/<name>-<timestamp>.log`. `rsk launch` refuses a NEW run whose name — this one included — is not `experiment-conventions.md` §2's shape: a dir's basename never is, so name each run |
| `VENV_DIR` | yes | explicit uv venv path, single-quoted (`'$HOME/.venvs/proj'` expands on the remote); accepted by the containment guard and shared between projects on purpose |
| `ENV_HOOK` | no | repo-relative script sourced at the END of the deployed `env.sh` (job, launch, bootstrap, interactive) — may override managed vars; branch on `$RS_TARGET` / `$RS_CUDA_ARCH` (workstations also export `$WS_TAG`) inside, name your own per-target state with `$RS_SUFFIX` (the profile's `T_SUFFIX`, e.g. `.venv-train$RS_SUFFIX`); mkdir any dir you repoint; missing file = fail closed. Bound into rsk's plan by path and the file's sha256 (with `VENV_DIR` and `UV_SYNC_ARGS`): editing the hook after an approval is a drift (exit 6) |
| `BOOTSTRAP_HOOK` | no | repo-relative script that `bootstrap.sh` runs **instead of** `uv sync` (env already exported, uv on PATH) |
| `UV_SYNC_ARGS` | no | extra words for `uv sync`, e.g. `--python-platform x86_64-manylinux_2_35` |
| `WANDB_MODE` | no | `online` (default) / `offline` / `disabled`; forced `offline` when no `WANDB_API_KEY` (an explicit `disabled` is kept) is available. Smoke runs always use `disabled` (`experiment-conventions.md`) |
| `EXTRA_EXCLUDES` | no | extra rsync exclude patterns, space-separated (also protects those paths from `-D`) |
| `SYNC_ALSO` | no | repo-relative paths force-pushed even though excluded (`rsync -R` semantics; no spaces in paths) on every sync; for a one-off (a new container image) use `run-sync --also <path>` instead |

## `.hpc.conf` only (kind `slurm`)

| key | prefixable | meaning / default |
|---|---|---|
| `REMOTE_DIR` | yes | absolute remote project dir. **Required; never guessed.** When the target's profile sets `T_REMOTE_DIR_REQUIRED=1`, its `<TAG>_REMOTE_DIR` is mandatory |
| `DEFAULT_PARTITION` | **prefixed only** | `<TAG>_DEFAULT_PARTITION` replaces the profile's `T_DEFAULT_PARTITION`; a generic `DEFAULT_PARTITION=` line is ignored (partition names are target-specific) |
| `DEFAULT_GPU_TYPE` | **prefixed only** | `<TAG>_DEFAULT_GPU_TYPE` replaces `T_DEFAULT_GPU_TYPE` (gres type name, or `any`) |
| `DEFAULT_GPUS` | yes | default `-g` (1) |
| `DEFAULT_CPUS` | yes | default `-c`; unset → partition heuristic (GPUs × per-GPU cpus) |
| `DEFAULT_MEM` | yes | default `-m`, e.g. `200G`; unset → partition heuristic (GPUs × per-GPU GB) |
| `DEFAULT_TIME` | yes | default `-t` (`1-00:00:00`); rejected (exit 2) when it exceeds the partition MaxTime, and when it is no limit — `0` in any spelling (`0:0`, `00:00:00`, `0-0`), `UNLIMITED`, `INFINITE`, `-1` (sbatch reads them as none: `give an explicit limit ≤ MaxTime`) — or not a time submit.sh can read (`MM`, `MM:SS`, `HH:MM:SS`, `D-HH[:MM[:SS]]`) |
| `ACCOUNT` | yes | adds `--account=…` |
| `SBATCH_EXTRA` | yes | extra sbatch flags, space-separated, one option per word (`"--qos=high --exclude=n1"`; `--no-requeue` opts out of the default auto-requeue; no bundled short flags). Every word must be an option or the value of the option before it, and a value goes as the next word only after an option that takes one (its exact name); otherwise write it attached (`--opt=VALUE`, `-oVALUE`). A word that is neither (`--`, `-`, a word after `--nice`, `--requeue` or `-v`, …) and a value option — or an abbreviation of one — left without its value at the end are refused (exit 2, in plan and submit): sbatch's getopt (a `+` optstring) runs the first such word as the batch script, with the harness's partition, GPUs, name, log and comment as its arguments, and a dangling value option takes the harness's next option as its value (`tests/vgate` `bare_word=`). May not contain `-p/--partition`, `-J/--job-name`, `-o/--output`, `-e/--error` (the harness owns name and log path), `--array`, `--wait`, a hetjob `:` or a forbidden QOS. Accepted, e.g.: `--dependency=singleton` (segment chains, conventions §6), `--signal=B:USR1@600` (a longer save warning: the command line overrides `job.sbatch`'s `#SBATCH` 120 s), `--mail-type=END,FAIL`. **Lint** (warnings only): the allowed set is `--qos/-q --account/-A --exclude/-x --dependency/-d --requeue --no-requeue --signal --mail-type --mail-user --constraint/-C --nice --reservation --comment` plus the profile's `T_SBATCH_EXTRA_ALLOW`; any other option, and one the harness sets itself (`--time --cpus-per-task --mem --gres --export --chdir`, `--account` next to `ACCOUNT`: sbatch keeps the LAST, which the warning names), prints `WARNING (lint): …` — refused in a later version. The lint parses the words as the scan does: an option's separate value is never linted as an option (in `--comment -t1` the `-t1` is a comment value, not a time — sbatch's getopt reads it so: `tests/vgate` `comment_value=`; the MaxTime check below still holds it as a possible time). **Grants**: a standing grant covers a plan only if every word here (the card's `conf extra`) is one of `--qos -q --account -A --exclude -x --constraint -C --reservation --signal --mail-type --mail-user --comment` (value as `--opt=V`, `-oV` or the next word), `--dependency=singleton` / `-d singleton`, `--requeue` / `--no-requeue`, `--nice` / `--nice=N`; anything else — a time, resource or node option in any spelling or abbreviation, an unknown option, a bare word — is named on the card's `NO GRANT` line and needs the user's approval of that card. `T_SBATCH_EXTRA_ALLOW` extends only the lint, never what a grant covers; the policy's own sbatch words never count either way. Every `--time`/`-t` here (any value form, also a word standing as another option's value, `--comment -t1`; sbatch takes the last one over `-t`) is held to the partition's MaxTime like `-t` and refused when it is no limit; a grant's `max_time` holds for each of them. A `--comment` is kept, with ` rs=<NONCE>` (the submit's journal entry) appended |
| `REMOTE_HOST` | no | override the profile's ssh alias for sync/bootstrap (rare) |
| `DEFAULT_CLUSTER` | no | target to use when the user names none (skill routing only) |

## `.ws.conf` only (kind `nohup`)

| key | prefixable | meaning / default |
|---|---|---|
| `WS_REMOTE_DIR` | via `<TAG>_REMOTE_DIR` | project dir **relative to the box's `$HOME`** (`projects/<name>`). **Required; never guessed.** `<TAG>_REMOTE_DIR` overrides it per box; a generic `REMOTE_DIR=` line is not read here |
| `DEFAULT_NGPU` | yes | GPUs auto-picked when `-d`/`-n` are absent (1): the idlest with no compute process; must be a positive integer |
| `GPU_EXCLUDE` | yes | comma-separated ids never auto-picked (someone else's cards: `"0,1"`; spaces tolerated, ids validated); explicit `-d` bypasses it (not the busy check: `-d` onto a GPU with a compute process is exit 6 without `--gpu-busy-ok`) |
| `NICE` | yes | `nice -n` level for the run, 0-19 (shared-box etiquette; negative values are rejected) |
| `DEFAULT_STATION` | no | target to use when the user names none (skill routing only) |

Not a conf key: the data-transfer node (`T_XFER_HOST`) is a site fact and lives only in the profile — every file
copy (`run-sync`, `run-pull`) goes there, the ssh commands stay on the host. Likewise, `T_*` values (host, conda init,
GPU facts, storage policy, Slurm defaults) come from the target's `profile.sh` (the user's
`~/.config/run-skills/targets/<t>/`, started from `$ROOT/targets/_template-<kind>/`, or an installed target pack's
`targets/<t>/`).

Minimal examples (`$ROOT/templates/hpc.conf.example` and `ws.conf.example` have the annotated versions):
```
# .hpc.conf
REMOTE_DIR=/project/<group>/<user>/<project>
ENV_KIND=uv
RUN="python -m train --config configs/base.yaml"
DEFAULT_GPUS=1
DEFAULT_TIME=1-00:00:00
DEFAULT_CLUSTER=mycluster
# MYCLUSTER_DEFAULT_PARTITION=gpu-long

# .ws.conf
ENV_KIND=uv
RUN="python train.py --config configs/base.yaml --device cuda:0"
WS_REMOTE_DIR=projects/<project>
DEFAULT_NGPU=1
GPU_EXCLUDE=
NICE=10
DEFAULT_STATION=mybox
```
