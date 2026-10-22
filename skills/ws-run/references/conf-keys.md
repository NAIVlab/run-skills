# `.ws.conf` keys (kind `nohup`)

The conf lives in the project root and is **sourced as shell** (double-quote values with spaces; plain
`export VAR=…` lines also reach the run). Precedence, highest first: CLI flag → `<TAG>_KEY` → `KEY` → default.
`<TAG>` = target name uppercased with non-alphanumerics dropped (`ws-box` → `WSBOX_`, `mybox` → `MYBOX_`).
Only the keys marked **prefixable** honour `<TAG>_`; `run-sync` warns about any other `<TAG>_KEY` line
(`WARN: … is not honoured` — e.g. a `<TAG>_ENV_KIND` is never read). A profile may add keys via `T_CONF_KEYS`.

| key | prefixable | meaning / default |
|---|---|---|
| `WS_REMOTE_DIR` | via `<TAG>_REMOTE_DIR` | project dir **relative to the box's `$HOME`** (`projects/<name>`). **Required; never guessed.** `<TAG>_REMOTE_DIR` overrides it per box; a generic `REMOTE_DIR=` line is not read here |
| `ENV_KIND` | no | `uv` (default: a per-box `.venv` built by `run-bootstrap` from `pyproject.toml`) or `conda` (a named env that must already exist) |
| `ENV_NAME` | yes | conda env name (`ENV_KIND=conda` only); the launch chain requires it to be the active env |
| `RUN` | yes | default run command (used when `run-launch` gets no `--`); `python` is the venv's python; keep it simple — quoting is not preserved across ssh + nohup |
| `DEFAULT_NGPU` | yes | GPUs auto-picked when `-d`/`-n` are absent (1); must be a positive integer |
| `GPU_EXCLUDE` | yes | comma-separated ids never auto-picked (someone else's cards: `"0,1"`; spaces tolerated, ids validated); explicit `-d` bypasses it |
| `NICE` | yes | `nice -n` level for the run, 0-19 (shared-box etiquette; negative values are rejected) |
| `JOB_NAME` | yes | default `-N` name (else the remote dir's basename); log = `logs/<name>-<timestamp>.log` |
| `VENV_DIR` | yes | explicit uv venv path, single-quoted (`'$HOME/.venvs/proj'` expands on the box); accepted by the containment guard and shared between projects on purpose |
| `ENV_HOOK` | no | repo-relative script sourced at the END of `.ws/env.sh` — may override managed vars; branch on `$WS_TAG` / `$RS_TARGET` inside; mkdir any dir you repoint; missing file = fail closed |
| `BOOTSTRAP_HOOK` | no | repo-relative script that `bootstrap.sh` runs **instead of** `uv sync` (env already exported, uv on PATH) |
| `UV_SYNC_ARGS` | no | extra words for `uv sync` |
| `WANDB_MODE` | no | `online` (default) / `offline` / `disabled`; forced `offline` when no `WANDB_API_KEY` (an explicit `disabled` is kept) is available. Smoke runs always use `disabled` (`experiment-conventions.md`) |
| `EXTRA_EXCLUDES` | no | extra rsync exclude patterns, space-separated (also protects those paths from `-D`) |
| `SYNC_ALSO` | no | repo-relative paths force-pushed even though excluded (`rsync -R` semantics; no spaces in paths) |
| `DEFAULT_STATION` | no | target to use when the user names none (skill routing only) |

Not a conf key: the data-transfer node (`T_XFER_HOST`) is a site fact and lives only in the profile — every file
copy (`run-sync`, `run-pull`) goes there, the ssh commands stay on the host. Likewise, `T_*` values (host, conda
init, GPU facts, storage policy) come from the box's `profile.sh` in
`~/.config/run-skills/targets/<t>/` (start from `$ROOT/targets/_template-nohup/`) or an installed target pack.

Minimal example (`templates/ws.conf.example` in the clone has the annotated version):
```
ENV_KIND=uv
RUN="python train.py --config configs/base.yaml --device cuda:0"
WS_REMOTE_DIR=projects/<project>
DEFAULT_NGPU=1
GPU_EXCLUDE=
NICE=10
DEFAULT_STATION=mybox
```
