---
name: ws-run
description: Run, launch, monitor, or stop training on the user's GPU workstations (no Slurm) listed in references/INDEX.md, for any local project with a .ws.conf. Rsyncs the project to the box, bootstraps a contained uv or conda env, and launches the run detached with nohup on the idlest GPUs (lowest memory.used — verify they are actually free in the printed table), with every cache and output kept inside the project dir. Use whenever the user wants to run, launch, nohup, train, or eval on a workstation, a GPU server, or the box (not a Slurm cluster), check a run's status, tail its log, or stop a run.
allowed-tools: Bash, Read, Write, Edit
---

# Run a project on a GPU workstation (nohup, no scheduler) — pick the target, read its reference, drive the harness

## 1. Pick the target
Read `references/INDEX.md` **now**. Its line 1 is `root: <dir>` — the installed harness dir, `$ROOT` below. The table
lists every registered workstation: name, ssh host, GPUs, description, and its reference file. Pick the target from
the user's words (its name or trigger words); if they name none, use `DEFAULT_STATION` from the project's `.ws.conf`;
if still ambiguous, ask. **Then read exactly that target's reference file** (the path in its table row).
If INDEX says no workstation is registered yet (or the user wants another one), register it with the user: Steps 2–6
of `$ROOT/INSTALL.md` (read-only discovery with `$ROOT/bin/run-probe`, then `~/.config/run-skills/targets/<alias>/`
from `$ROOT/targets/_template-nohup/`, then `install.sh`) — or install the user's lab target pack.
(For a Slurm cluster use the **hpc-run** skill instead.) A project runs on a workstation when its repo root has a
`.ws.conf`; if it is missing (or the user asks to set the project up), follow `references/project-setup.md` — it asks
for `WS_REMOTE_DIR`; never guess it.

## 2. Commands (cwd = the project root; `<t>` = target name, `<host>` = its host column)
```
TARGET=<t> bash $ROOT/bin/run-sync             # push code + deploy the harness to ~/<WS_REMOTE_DIR>/.ws/ (-n dry-run, -D prune)
TARGET=<t> bash $ROOT/bin/run-bootstrap        # first run / deps changed: uv sync the venv, or verify the conda env
ssh <host> "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader"   # who uses what
# >>> print a one-line plan (target / GPU ids / run command) and wait for an explicit go, then:
TARGET=<t> bash $ROOT/bin/run-launch -n 1 -N <name> -- <RUN>     # nohup on the idlest GPU(s); -d 0,1 picks ids explicitly
ssh <host> "bash ~/<WS_REMOTE_DIR>/.ws/status.sh logs/<name>-<timestamp>.log"   # start a review: bounded digest (PID, log, hints, last lines); -n 40 = deep read
```

## 3. Procedure
Follow `references/procedure-nohup.md` (sync → bootstrap → check GPUs → confirm → launch → monitor, the storage
model). Every conf key, and which accept a `<TAG>_` prefix, is in `references/conf-keys.md`. Run classes, naming,
the wandb project/group/name mapping and the checkpoint/resume contract: `references/experiment-conventions.md` —
read it before naming or launching any real experiment.

## Safety rails (always)
- **Confirm before every launch.** Workstations are often shared: never launch onto a GPU another job is using, and never
  `kill` a running process, without an explicit OK. Auto-pick takes the *idlest* GPUs, not necessarily free ones —
  read the printed table and use `-d` when the pick would land on a busy card.
- wandb uses the **user's own key** (the deployed `.wandb_env`), never the box's `~/.netrc`; no key → offline.
- `ENV_KIND=uv` is the default (a per-box venv built by `run-bootstrap` from `pyproject.toml`); scaffold new
  `.ws.conf` files as uv unless the user asks for conda. Never create a conda env — if `ENV_NAME` is missing on the
  box, stop and ask.
- Everything a run produces stays under the project dir (the harness pins caches, tmp, logs, ckpts there).
- Experiments checkpoint and resume: nothing restarts a nohup run after a crash or reboot, so the command must
  pick up from its latest checkpoint on relaunch; smoke tests always run `WANDB_MODE=disabled`.
- Monitoring (`experiment-conventions.md` §7): widen review intervals only with evidence; anomalies and milestones
  need closer attention. Choose low-cost waiting or notifications supported by the runtime; state the wake-up mechanism
  and coverage, or report a snapshot and the next check time. Start reviews with `status.sh`; keep log reads
  byte-bounded. Report every finding promptly, healthy status in one line. Detect-only — stopping a run is the user's call.
