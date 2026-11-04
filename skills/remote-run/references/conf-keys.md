# Conf keys — `.hpc.conf` (kind `slurm`) and `.ws.conf` (kind `nohup`)

The conf lives in the project root — `.hpc.conf` for Slurm targets, `.ws.conf` for workstations, both when the project
uses both kinds — and is **sourced as shell** (double-quote values with spaces; plain `export VAR=…` lines also reach
the job or run: env.sh sources the conf at its start). `submit.sh` reads `.hpc.conf` in a child shell and takes back only
the keys below: a function, alias or `PATH` change in the conf never affects the submit itself, and `T_*` lines never
override the target's profile. A Slurm job uses the conf as it was at submit time (a snapshot), also after a requeue. Precedence, highest first: CLI flag → `<TAG>_KEY` → `KEY` → default. `<TAG>` = target name uppercased
with non-alphanumerics dropped (`mycluster` → `MYCLUSTER_`, `my-hpc` → `MYHPC_`, `ws-box` → `WSBOX_`).
Only the keys marked **prefixable** honour `<TAG>_`; `run-sync` warns about any other `<TAG>_KEY` line
(`WARN: … is not honoured` — e.g. a `<TAG>_ENV_KIND` is never read). A target's profile may add its own prefixable keys
via `T_CONF_KEYS`.

## Keys of both confs

| key | prefixable | meaning / default |
|---|---|---|
| `ENV_KIND` | no | `uv` (default: a venv per target built by `run-bootstrap` from `pyproject.toml`), `conda` (a named env that must already exist) or `none` (no managed env: the payload brings its own runtime, e.g. `apptainer exec img.sif …`; containment env vars still apply, PATH is otherwise left as inherited, `BOOTSTRAP_HOOK` still runs) |
| `ENV_NAME` | yes | conda env name (`ENV_KIND=conda` only); exported to the job; the workstation launch (`launch.sh`) requires it to be the active env |
| `RUN` | yes | default run command; `python` is the target venv's python (`uv run` also works). Slurm: the agent pastes it after `--` (submit.sh has no fallback). Workstation: used when `run-launch` gets no `--`; keep it simple — quoting is not preserved across ssh + nohup |
| `JOB_NAME` | yes | default job/run name — Slurm `-n` (else the project dir basename), log `logs/<name>_<jobid>.out`; workstation `-N` (else the remote dir's basename), log `logs/<name>-<timestamp>.log` |
| `VENV_DIR` | yes | explicit uv venv path, single-quoted (`'$HOME/.venvs/proj'` expands on the remote); accepted by the containment guard and shared between projects on purpose |
| `ENV_HOOK` | no | repo-relative script sourced at the END of the deployed `env.sh` (job, launch, bootstrap, interactive) — may override managed vars; branch on `$RS_TARGET` / `$RS_CUDA_ARCH` (workstations also export `$WS_TAG`) inside, name your own per-target state with `$RS_SUFFIX` (the profile's `T_SUFFIX`, e.g. `.venv-train$RS_SUFFIX`); mkdir any dir you repoint; missing file = fail closed |
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
| `DEFAULT_TIME` | yes | default `-t` (`1-00:00:00`); rejected when it exceeds the partition MaxTime |
| `ACCOUNT` | yes | adds `--account=…` |
| `SBATCH_EXTRA` | yes | extra sbatch flags, space-separated, one option per word (`"--qos=high --exclude=n1"`; `--no-requeue` opts out of the default auto-requeue; no bundled short flags). May not contain `-p/--partition`, `-J/--job-name`, `-o/--output`, `-e/--error` (the harness owns name and log path), `--array`, `--wait`, a hetjob `:`, a forbidden QOS, or a trailing `-q/--qos` without a value. Accepted, e.g.: `--dependency=singleton` (segment chains, conventions §6), `--signal=B:USR1@600` (a longer save warning: the command line overrides `job.sbatch`'s `#SBATCH` 120 s), `--mail-type=END,FAIL`. The allowed set is `--qos/-q --account/-A --exclude/-x --dependency/-d --requeue --no-requeue --signal --mail-type --mail-user --constraint/-C --nice --reservation --comment` plus the profile's `T_SBATCH_EXTRA_ALLOW`; any other option, and one the harness sets itself (`--time --cpus-per-task --mem --gres --export --chdir`, `--account` next to `ACCOUNT`: sbatch keeps the LAST, which the warning names), prints `WARNING (lint): …` — refused in a later version. A `--comment` is kept, with ` rs=<NONCE>` (the submit's journal entry) appended |
| `REMOTE_HOST` | no | override the profile's ssh alias for sync/bootstrap (rare) |
| `DEFAULT_CLUSTER` | no | target to use when the user names none (skill routing only) |

## `.ws.conf` only (kind `nohup`)

| key | prefixable | meaning / default |
|---|---|---|
| `WS_REMOTE_DIR` | via `<TAG>_REMOTE_DIR` | project dir **relative to the box's `$HOME`** (`projects/<name>`). **Required; never guessed.** `<TAG>_REMOTE_DIR` overrides it per box; a generic `REMOTE_DIR=` line is not read here |
| `DEFAULT_NGPU` | yes | GPUs auto-picked when `-d`/`-n` are absent (1); must be a positive integer |
| `GPU_EXCLUDE` | yes | comma-separated ids never auto-picked (someone else's cards: `"0,1"`; spaces tolerated, ids validated); explicit `-d` bypasses it |
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
