# Set up an existing project (both kinds)

Use this when a project has no `.hpc.conf` (Slurm) / `.ws.conf` (workstation) yet, or the user asks to set up,
onboard or migrate one. Goal: a conf that reproduces how the project runs today, a checked first sync, a
bootstrapped env, and a short list of gaps — without rewriting the project's code and without launching anything.
cwd = the project root; `$ROOT` = line 1 of `INDEX.md`; ONE copy of this file serves both skills (ws-run links to it).

## 1. Inspect how it runs today (local, read-only)
```
git status --short | head -20; git remote -v | head -2
find . -maxdepth 1 \( -name pyproject.toml -o -name uv.lock -o -name 'requirements*.txt' -o -name 'environment*.y*ml' -o -name setup.py -o -name .hpc.conf -o -name .ws.conf \)
grep -rlE '^#SBATCH|sbatch |srun |nohup |CUDA_VISIBLE_DEVICES' --include='*.sh' --include='*.slurm' --include='*.sbatch' --include=Makefile . 2>/dev/null | head
grep -rnE 'wandb\.init|WANDB_(PROJECT|ENTITY)' --include='*.py' . 2>/dev/null | head -5
grep -rnE 'resume|load_state_dict|save_checkpoint' --include='*.py' . 2>/dev/null | head -5
grep -rnE 'HF_HOME|TRANSFORMERS_CACHE|TORCH_HOME|/home/|/scratch/' --include='*.py' --include='*.sh' --include='*.yaml' . 2>/dev/null | head
find . \( -name .git -o -name '.venv*' -o -name node_modules \) -prune -o -type f -size +50M -print 2>/dev/null | head
```
A conf already present → the project is set up: `TARGET=<t> bash $ROOT/bin/run-sync -n` lints it (`WARN: … not honoured`); fix
only what it reports. Read every launch script you found (bounded: `head -60`) — it is the spec for steps 2–3.

## 2. Map what you found onto the conf (keys: `conf-keys.md`)
| found | conf |
|---|---|
| `pyproject.toml` with `[project] dependencies` | `ENV_KIND=uv` (default): `run-bootstrap` runs `uv sync` into the target's own venv. Deps only under `[tool.poetry]` or in requirements files → treat as the next row |
| only `requirements*.txt` | ask: convert (`uv init --bare` + `uv add -r requirements.txt` — this edits the repo), or keep it and add `BOOTSTRAP_HOOK=scripts/rs_bootstrap.sh` (below) |
| `conda activate X` in scripts / `environment.yml` | `ENV_KIND=conda`, `ENV_NAME=X` — only verified on the target; missing there → stop and ask (never create it) |
| every run goes through a container (`apptainer exec` / `singularity exec` / `docker run`) and no host python is needed | `ENV_KIND=none`: no venv is built or required; the image is a large file → `EXTRA_EXCLUDES="/img.sif"` and ship it once with `run-sync --also img.sif` |
| a second checkout (git worktree) of the same project | its own `REMOTE_DIR` when both run jobs; sharing one makes `run-sync` refuse the other checkout (`--take-over` moves it, with the user's OK) |
| `#SBATCH -p/--partition` | `<TAG>_DEFAULT_PARTITION` (a generic `DEFAULT_PARTITION` is ignored) |
| `-N` > 1, `--ntasks` > 1, `srun torchrun` across nodes | not supported (one node per job): report it as a gap; single-node `torchrun` in `RUN` is fine |
| `--gres=gpu:N` / `--gres=gpu:<type>:N` / `--gpus=N` | `DEFAULT_GPUS=N` (+ `<TAG>_DEFAULT_GPU_TYPE=<type>`) |
| `-t/--time`, `--mem`, `-c/--cpus-per-task` | `DEFAULT_TIME` (≤ the partition cap), `DEFAULT_MEM`, `DEFAULT_CPUS` — or omit mem/cpus to use the partition heuristic |
| `-A/--account` | `ACCOUNT` (`<TAG>_ACCOUNT` when per cluster) |
| `--qos`, `--constraint`, `--exclude`, `--mail-*` | `SBATCH_EXTRA` (never a partition, job name or log path) |
| `module load …`, project `export VAR=…` lines | `ENV_HOOK=scripts/rs_env.sh` (sourced at the end of env.sh; branch on `$RS_TARGET`). Under a bare ssh command or a job `module` is often undefined: start the hook with `type module >/dev/null 2>&1 \|\| . /etc/profile.d/<the probe's modules: file>`. Drop exports of cache paths — the harness pins those |
| `CUDA_VISIBLE_DEVICES=0,1`, `nohup … &`, tmux | workstation: drop them — `DEFAULT_NGPU=2` (the id count), `run-launch` picks GPUs (`-d` for ids) and detaches; someone else's GPUs → `GPU_EXCLUDE` |
| the python command line | `RUN="…"` (double-quoted) |
| `wandb.init(project=…, entity=…)` | keep it; the key comes from the user's `wandb_env`; names per `experiment-conventions.md` |
| hardcoded cache dirs / `/home/…` paths in code | report them: they bypass containment or break on another machine. Change code only with the user's OK |
| large files outside the excluded dirs | `EXTRA_EXCLUDES` (otherwise every sync uploads them) |
| small inputs the code reads from `data/`, `outputs/`, … (excluded at the repo root) | `SYNC_ALSO="data/prompts"`; big datasets stay on the server, not in the sync |

Keep the old scripts untouched; the conf replaces them only for runs made through the harness.

`BOOTSTRAP_HOOK` for a requirements-only project — a new file in the repo, so ask whether to commit it or list it in
`.git/info/exclude` like the conf (it runs instead of `uv sync`; env.sh already exported
`UV_PROJECT_ENVIRONMENT`, uv is on PATH; `uv venv` fails if the venv exists, hence the guard):
```
#!/usr/bin/env bash
set -euo pipefail
[ -x "$UV_PROJECT_ENVIRONMENT/bin/python" ] || uv venv "$UV_PROJECT_ENVIRONMENT"
uv pip install --python "$UV_PROJECT_ENVIRONMENT/bin/python" -r requirements.txt
```

## 3. Ask the user (one batch, defaults filled in)
- **Target(s)** for this project (default: the INDEX routing default).
- **Remote dir**: "Does this project already exist on `<target>`? Where?" — never guess. New: propose
  `<project root from the target's reference>/<repo name>` and wait for a yes. Several targets that do not share a
  filesystem → one `<TAG>_REMOTE_DIR` each (mandatory where the profile sets `T_REMOTE_DIR_REQUIRED=1`).
- **Env**: the mapping you chose in step 2; **run command and resources** taken from the old script.
- **Commit the conf?** A shared or public repo → keep it local: append `.hpc.conf` / `.ws.conf` to
  `.git/info/exclude` (local-only; no tracked file changes). A personal repo → committing it is fine.

## 4. A copy already on the target — check before the first sync
Write the conf (step 5's first line), then, with the user's OK to connect (read-only):
```
TARGET=<t> bash $ROOT/bin/run-sync -n                                  # writes nothing on the server
ssh <host> "cd <REMOTE_DIR> && ls -a | head -40; git status --short 2>/dev/null | head -20"
```
- **Remote-only edits**: in the dry run, `<f` lines other than `<f+++++++++` (new) are existing remote files a sync would
  overwrite with the local version (rsync compares size and time); `git status` there shows uncommitted work. Show
  both; let the user bring changes back first (`run-pull <path>`) or accept the loss.
- **A venv the harness would adopt** — `.venv` (or `.venv<T_SUFFIX>`, or `T_ENV_ROOT/envs/<proj>`) without a
  `.run-skills-proj` file inside: `run-bootstrap` would `uv sync` into it and change it. Ask: let the harness manage
  it, or set `VENV_DIR` to a fresh path.
- **Data and results there are safe**: `data/ ckpts/ checkpoints/ logs/ outputs/ runs/ wandb/` and the other
  generated dirs are excluded and never deleted, not even with `-D`. Other output dirs the project writes → add them
  to `EXTRA_EXCLUDES` before anyone uses `-D`.

## 5. Write the conf, dry-run, sync, bootstrap
Scaffold the conf (`conf-keys.md`'s minimal example plus step 2's keys), then:
```
TARGET=<t> bash $ROOT/bin/run-sync -n       # first line: remote / tag / deploy; then the itemized upload list
```
Check the remote dir, and that the list holds no data, checkpoints or secrets (`.env`, tokens) → `EXTRA_EXCLUDES`;
no `WARN … not honoured`. Show the user the summary (file count, anything notable) and ask for the OK to write: then
`run-sync`, then `run-bootstrap` (ends `bootstrap done (<t>).`; uv builds only this project's venv, downloading uv
and a Python into the env root when the server has none; conda is only checked).

## 6. Hand over
Report the conf, what each old-script setting became, and the gaps from step 1 — above all whether the trainer
checkpoints and auto-resumes (`experiment-conventions.md` §6; formal runs need it). Offer one smoke run following
the procedure: plan → explicit go → `WANDB_MODE=disabled`, smallest resources. Never launch it unasked.
