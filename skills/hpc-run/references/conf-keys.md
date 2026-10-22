# `.hpc.conf` keys (kind `slurm`)

The conf lives in the project root and is **sourced as shell** (double-quote values with spaces; plain
`export VAR=…` lines also reach the job). Precedence, highest first: CLI flag → `<TAG>_KEY` → `KEY` → default.
`<TAG>` = target name uppercased with non-alphanumerics dropped (`mycluster` → `MYCLUSTER_`, `my-hpc` → `MYHPC_`).
Only the keys marked **prefixable** honour `<TAG>_`; `run-sync` warns about any other `<TAG>_KEY` line
(`WARN: … is not honoured`). A target's profile may add its own prefixable keys via `T_CONF_KEYS`.

| key | prefixable | meaning / default |
|---|---|---|
| `REMOTE_DIR` | yes | absolute remote project dir. **Required; never guessed.** When the target's profile sets `T_REMOTE_DIR_REQUIRED=1`, its `<TAG>_REMOTE_DIR` is mandatory |
| `ENV_KIND` | no | `uv` (default: a venv built by `run-bootstrap` from `pyproject.toml`) or `conda` (a named env that must already exist) |
| `ENV_NAME` | yes | conda env name (`ENV_KIND=conda` only); exported to the job |
| `RUN` | yes | default run command (the agent pastes it after `--`; submit.sh has no fallback); `python` is the target venv's python (`uv run` also works) |
| `DEFAULT_PARTITION` | **prefixed only** | `<TAG>_DEFAULT_PARTITION` replaces the profile's `T_DEFAULT_PARTITION`; a generic `DEFAULT_PARTITION=` line is ignored (partition names are target-specific) |
| `DEFAULT_GPU_TYPE` | **prefixed only** | `<TAG>_DEFAULT_GPU_TYPE` replaces `T_DEFAULT_GPU_TYPE` (gres type name, or `any`) |
| `DEFAULT_GPUS` | yes | default `-g` (1) |
| `DEFAULT_CPUS` | yes | default `-c`; unset → partition heuristic (GPUs × per-GPU cpus) |
| `DEFAULT_MEM` | yes | default `-m`, e.g. `200G`; unset → partition heuristic (GPUs × per-GPU GB) |
| `DEFAULT_TIME` | yes | default `-t` (`1-00:00:00`); rejected when it exceeds the partition MaxTime |
| `ACCOUNT` | yes | adds `--account=…` |
| `SBATCH_EXTRA` | yes | extra sbatch flags, space-separated, one option per word (`"--qos=high --exclude=n1"`; `--no-requeue` opts out of the default auto-requeue; no bundled short flags). May not contain `-p/--partition`, `-J/--job-name`, `-o/--output`, `-e/--error` (the harness owns name and log path), `--array`, `--wait`, a hetjob `:`, a forbidden QOS, or a trailing `-q/--qos` without a value. Accepted, e.g.: `--dependency=singleton` (segment chains, conventions §6), `--signal=B:USR1@600` (a longer save warning: the command line overrides `job.sbatch`'s `#SBATCH` 120 s), `--mail-type=END,FAIL` |
| `JOB_NAME` | yes | default job/log name (else the project dir basename); log = `logs/<name>_<jobid>.out` |
| `VENV_DIR` | yes | explicit uv venv path, single-quoted (`'$HOME/.venvs/proj'` expands on the remote); accepted by the containment guard and shared between projects on purpose |
| `ENV_HOOK` | no | repo-relative script sourced at the END of `env.sh` (job, bootstrap, interactive) — may override managed vars; branch on `$RS_TARGET` / `$RS_CUDA_ARCH` inside; mkdir any dir you repoint; missing file = fail closed |
| `BOOTSTRAP_HOOK` | no | repo-relative script that `bootstrap.sh` runs **instead of** `uv sync` (env already exported, uv on PATH) |
| `UV_SYNC_ARGS` | no | extra words for `uv sync`, e.g. `--python-platform x86_64-manylinux_2_35` |
| `WANDB_MODE` | no | `online` (default) / `offline` / `disabled`; forced `offline` when no `WANDB_API_KEY` (an explicit `disabled` is kept) is available. Smoke runs always use `disabled` (`experiment-conventions.md`) |
| `EXTRA_EXCLUDES` | no | extra rsync exclude patterns, space-separated (also protects those paths from `-D`) |
| `SYNC_ALSO` | no | repo-relative paths force-pushed even though excluded (`rsync -R` semantics; no spaces in paths) |
| `REMOTE_HOST` | no | override the profile's ssh alias for sync/bootstrap (rare) |
| `DEFAULT_CLUSTER` | no | target to use when the user names none (skill routing only) |

Not a conf key: the data-transfer node (`T_XFER_HOST`) is a site fact and lives only in the profile — every file
copy (`run-sync`, `run-pull`) goes there, the ssh commands stay on the host. Likewise, `T_*` values come from the target's `profile.sh` (the user's `~/.config/run-skills/targets/<t>/`,
or an installed target pack's `targets/<t>/`).

Minimal example (`templates/hpc.conf.example` in the clone has the annotated version):
```
REMOTE_DIR=/project/<group>/<user>/<project>
ENV_KIND=uv
RUN="python -m train --config configs/base.yaml"
DEFAULT_GPUS=1
DEFAULT_TIME=1-00:00:00
DEFAULT_CLUSTER=mycluster
# MYCLUSTER_DEFAULT_PARTITION=gpu-long
```
