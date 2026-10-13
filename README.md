# run-skills

**Let your coding agent run experiments on Slurm clusters and GPU workstations — contained, confirmed, and watched.**

run-skills is two agent skills (`hpc-run`, `ws-run`) plus a small bash harness. You say *"run this on mycluster
with 2 GPUs for a day"*; the agent syncs your project, builds its environment on the remote side, shows you a
one-line plan, and — after you say go — submits a correctly sized job and keeps an eye on it. Works with
**Claude Code**, **OpenAI Codex** and **pi** from one installed copy.

```text
you    › train configs/base.yaml on mycluster, 2 GPUs, 1 day
agent  › [mycluster] remote: mycluster:/project/lab/me/myproj  tag: MYCLUSTER  deploy: .mycluster
         bootstrap done (mycluster).
         Plan: mycluster / gpu / 2x A100 / 1-00:00:00 / python -m train --config configs/base.yaml
         name mytask-v1--train--base--scratch--s0--a01 · checkpoints + auto-resume ✓ — go?
you    › go
agent  › Submitted batch job 4815162 · log: logs/mytask-v1--train--base--scratch--s0--a01_4815162.out
         I'll review it with status.sh soon after it starts, then less often while it stays healthy.
```

## Why

Agents are good at writing training code and bad at the last mile of running it somewhere else. Left alone they
hand-write `sbatch` scripts with the wrong memory flags, fill a 50 GB `$HOME` with HuggingFace and pip caches,
`pip install` into a shared base env, launch onto a GPU a colleague is using, `tail -f` a 2 GB log into their
context, or "fix" a stuck job with `scancel`. run-skills turns all of that into a small set of commands with the
guard rails built in, and gives the agent a short, per-site reference instead of letting it guess.

## What you get

- **Containment.** Every cache and output — HF, torch, triton/inductor, pip, uv, wandb, tmp, logs, checkpoints — is
  pinned under the project directory (or wherever the target's storage policy says), never in `$HOME`. Targets that
  share a filesystem get suffixed venvs and compile caches so their binaries never clash.
- **Reproducible environments.** `uv` by default: one venv per target, built from your `pyproject.toml`. Or a named
  conda env, which the harness only *verifies* — it never creates or modifies conda envs.
- **Fail-closed.** A broken conf, a missing venv or a half-applied environment aborts the job instead of running it
  misconfigured. Walltimes above a partition's cap are rejected (they would pend forever); busy GPUs produce a warning
  that needs an explicit `-y`; site policies can refuse a submission outright.
- **A human in the loop.** The agent prints a one-line plan and waits for your explicit "go" before every submit or
  launch, and never cancels or kills a job without your OK.
- **Cheap, honest monitoring.** One deployed script, `status.sh`, returns a ~2 KB digest of a run: scheduler or PID
  state, restarts, exit footer, error/OOM/NaN hint counts, the wandb URL and the last lines — all from byte-bounded
  reads. The agent reviews often while a run is young or odd and backs off while it is healthy.
- **Experiment conventions.** Smoke / pilot / train / eval / ablate run classes, structured run names, a fixed
  wandb project/group/name mapping, and a checkpoint + auto-resume contract (Slurm jobs go out with `--requeue`;
  runs longer than the walltime cap become `--dependency=singleton` segment chains).
- **Sites are data, not code.** A cluster or workstation is one directory: `profile.sh` (facts), `policy.sh` (Slurm
  partitions and limits), `reference.md` (what the agent reads), `tests.sh`. Keep yours private, or share a whole
  lab's worth as a **target pack**.
- **Tested offline.** `bash selftest.sh` exercises the harness against stubbed `sbatch`/`sinfo`/`squeue`/`ssh`/`uv`/
  `rsync` — nothing leaves your machine.

## Requirements

| where | needs |
|---|---|
| your machine | Linux or macOS (bash 3.2 is fine), `git`, `rsync`, `ssh`; Claude Code, Codex (0.149+) or pi |
| every target | Linux with bash, key-based ssh through an alias in `~/.ssh/config`, NVIDIA GPUs |
| Slurm targets | `sbatch`/`squeue`/`sinfo`/`sacct` on the login node |
| your project | a Python repo with a `pyproject.toml` (uv), or an existing conda env on the target |

`uv` does not need to be installed remotely — if the target has none, the bootstrap installs a private copy from
astral.sh into the project's env root (so the target needs outbound internet for that one step).

## Quick start

**1. Install** (re-run the same command later to update):

```bash
git clone https://github.com/NAIVlab/run-skills.git ~/.local/share/run-skills
bash ~/.local/share/run-skills/install.sh
```

The installer copies the harness to `~/.agents/run-skills/`, installs one copy of each skill into
`~/.agents/skills/` (read directly by Codex and pi; `~/.claude/skills/` gets symlinks for Claude Code), scaffolds
`~/.config/run-skills/`, checks your ssh aliases and runs the offline selftest. It never edits `~/.ssh/config` and
never overwrites an existing wandb key.

> **In a lab that already has a target pack?** Install the pack instead — it installs the engine for you
> (see [Target packs](#target-packs)).

**2. Register a target.** Copy a template into your private overlay and fill it in:

```bash
cp -R ~/.local/share/run-skills/targets/_template-nohup ~/.config/run-skills/targets/mybox      # a GPU workstation
cp -R ~/.local/share/run-skills/targets/_template-slurm ~/.config/run-skills/targets/mycluster  # a Slurm cluster
```

The directory name is the target name. Edit `profile.sh` (ssh alias, GPUs, storage policy — every key is
commented), for Slurm also `policy.sh` (partitions, GPU ranges, per-GPU cpu/mem, walltime caps), and
`reference.md` — the one page the agent reads before using the target, so write down what a newcomer would need
(partitions, quotas, quirks). Add a matching `Host` block to `~/.ssh/config` (see
[`templates/ssh_config`](templates/ssh_config)), then re-run `install.sh` so the target shows up in the skills.

**3. Optional: your wandb key.** Put *your own* key ([wandb.ai/authorize](https://wandb.ai/authorize)) in
`~/.config/run-skills/wandb_env`. Every sync pushes it next to the project (mode 600). With no key, runs simply go
wandb-offline — the harness never falls back to credentials stored on the remote machine.

**4. Ask your agent**, from your project's root:

> run this on mybox with 1 GPU — `python train.py --config configs/base.yaml`

The first time, the agent scaffolds the project's `.ws.conf` (workstations) or `.hpc.conf` (clusters) and asks you
for the remote directory — it never guesses it. Annotated examples:
[`templates/ws.conf.example`](templates/ws.conf.example), [`templates/hpc.conf.example`](templates/hpc.conf.example).

## How a run happens

```text
 agent reads references/INDEX.md ──► picks the target ──► reads that target's reference.md
   │
   ├─ run-sync        rsync the code (caches, venvs, data, logs, checkpoints excluded and protected)
   │                  + deploy the harness into <remote dir>/.<target>/ (Slurm) or .ws/ (workstation)
   ├─ run-bootstrap   uv sync into the target's venv — or verify the conda env exists
   ├─ one-line plan   … waits for your explicit "go"
   ├─ submit          Slurm: submit.sh → site policy → partition limits → MaxTime → availability → sbatch
   │                  workstation: run-launch → nohup on the idlest GPUs (shown to you first)
   └─ monitor         status.sh digest; deep reads stay byte-bounded; stopping a run is your call
```

Each job sources the deployed `env.sh`, which pins every path, then exports a readiness sentinel; the job refuses to
start without it. Logs land in `logs/` with a header per (re)start and an `EXIT rc=…` footer, so "did it resume?"
and "how did it end?" have answers in the log itself.

## Targets, packs and your overlay

The harness finds targets in three places, highest precedence first:

| layer | location | for |
|---|---|---|
| your overlay | `~/.config/run-skills/targets/<name>/` | private machines; personal tweaks to a shared target |
| target packs | `~/.config/run-skills/packs/<pack>/targets/<name>/` | a lab's or site's shared targets |
| templates | `~/.agents/run-skills/targets/_template-*/` | starting points (never listed as targets) |

A directory **with** `profile.sh` defines a target. An overlay directory **without** one extends the target of the
same name from a pack: `policy.local.sh` can wrap the pack's `t_policy` (say, a personal queue you must never submit
to by accident), `reference.local.md` is shown next to the pack's reference, `tests.local.sh` joins the selftest.

### Target packs

A pack is a git repo — usually a private one, because cluster details are nobody else's business — holding
`targets/<name>/` directories, optional routing hints for the agent (`routing/hpc-run.md`) and an installer.
Lab members then need exactly one command:

```bash
git clone git@github.com:<your-org>/<your-pack>.git ~/.config/run-skills/packs/<your-pack> \
  && bash ~/.config/run-skills/packs/<your-pack>/install.sh
```

The pack's installer clones or updates this engine and runs its `install.sh`. Start from
[`templates/pack/`](templates/pack/); the full guide is [`docs/packs.md`](docs/packs.md).

## Configuration in one paragraph

The project conf (`.hpc.conf` / `.ws.conf`, in the repo root) is sourced as shell. Resolution is
CLI flag → `<TAG>_KEY` → `KEY` → default, where `<TAG>` is the target name uppercased without punctuation
(`my-hpc` → `MYHPC_`), so one conf can serve several targets: `REMOTE_DIR=/project/me/x` plus
`OTHERHPC_REMOTE_DIR=/scratch/me/x`. Every key, and which ones accept a tag:
[hpc-run conf keys](skills/hpc-run/references/conf-keys.md), [ws-run conf keys](skills/ws-run/references/conf-keys.md).
Hooks cover the unusual cases: `ENV_HOOK` (sourced at the end of the environment), `BOOTSTRAP_HOOK` (replaces
`uv sync`), `UV_SYNC_ARGS`, `SYNC_ALSO`, `EXTRA_EXCLUDES`.

## Safety rails

These are part of the skills' instructions and are enforced by the harness where code can enforce them:

- Confirm before every submit or launch; never `scancel`/`kill` anything without an explicit OK.
- Partition and QOS are `submit.sh`'s decision — no raw `sbatch`/`srun`, no `--partition` smuggled in via
  `SBATCH_EXTRA`. A policy refusal is final; `-y` only acknowledges availability warnings.
- Never create a conda env; never guess the remote directory; never use a machine's stored wandb credentials.
- Smoke tests run with `WANDB_MODE=disabled`; real runs checkpoint and resume.
- Monitoring is detect-only and byte-bounded; findings are reported, decisions stay with you.

## Repository layout

| path | what |
|---|---|
| `skills/` | the two skills: a thin `SKILL.md` each + `references/` (procedures, conf keys, experiment conventions) |
| `bin/` | local commands: `run-sync`, `run-bootstrap`, `run-launch` |
| `lib/common.sh` | local helpers: target discovery, conf precedence, conf linter, INDEX generation |
| `remote/` | deployed next to each project: `env.sh`, `bootstrap.sh`, `status.sh`, `submit.sh`, `job.sbatch` |
| `targets/` | `_template-slurm/`, `_template-nohup/` |
| `templates/` | conf examples, `ssh_config`, `wandb_env`, and `pack/` (a target-pack skeleton) |
| `codex/` | Codex UI metadata for the skills |
| `tests/`, `selftest.sh` | the offline test suite |
| `docs/` | [`DESIGN.md`](docs/DESIGN.md) (architecture and rationale), [`packs.md`](docs/packs.md) |

## Updating and uninstalling

Update: `git -C ~/.local/share/run-skills pull && bash ~/.local/share/run-skills/install.sh` (or re-run your
pack's `install.sh`). A change to `remote/` reaches a project at its next sync.

Uninstall: remove `~/.agents/run-skills`, `~/.agents/skills/{hpc-run,ws-run}`, the symlinks
`~/.claude/skills/{hpc-run,ws-run}` and `~/.claude/run-skills`, and the clone. `~/.config/run-skills` holds your
targets, packs and wandb key — delete it only if you mean to. Nothing is installed on the remote side outside your
project directories.

## Contributing

Issues and pull requests are welcome. The loop is: edit the clone → `bash selftest.sh` (prints
`RESULT: N pass, M fail`, exit code = failures) → `bash install.sh` → re-sync a project. Contributor and agent
guidance — constraints, portability rules, the test-helper contract — is in [`AGENTS.md`](AGENTS.md); design
rationale is in [`docs/DESIGN.md`](docs/DESIGN.md). Site-specific targets belong in packs, not in this repo.

## License

[MIT](LICENSE)
