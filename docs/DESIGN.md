# run-skills — design

This document explains *why* run-skills is shaped the way it is. The user-facing story is in the
[README](../README.md); the precise contracts an editor must keep (portability rules, test helpers, the
`policy.sh` API) are in [AGENTS.md](../AGENTS.md).

## Goals

1. **A new cluster or workstation is a drop-in directory** — including ones that never enter this repo.
2. **One code path, two launch backends**: Slurm (`sbatch`) and scheduler-less workstations (`nohup`).
3. **Storage policy is declared per target**, because sites differ: a fast project filesystem here, a quota on
   small files there, a per-job `$TMPDIR` somewhere else.
4. **The agent reads little and guesses nothing**: an index of targets plus one self-contained page per target.
5. **Unsafe actions need a human**: submissions, launches, cancellations, new conda envs, remote directories.

Non-goals: multi-node jobs, non-NVIDIA hardware, a new configuration language, a daemon or a database.

## Three layers

```text
skills/<s>/SKILL.md + references/     what the agent reads (thin entry, index, procedure, conf keys, conventions)
bin/ + lib/common.sh                   local commands run from the project root (sync, bootstrap, launch)
remote/                                deployed next to each project and executed there (env, bootstrap, status,
                                       submit, job wrapper)
```

The skills reach the harness through the first line of the installed `references/INDEX.md` (`root: <dir>`), so
the skill text never hardcodes an install location. Remote scripts never source local code: everything they need
is deployed into `<REMOTE_DIR>/.<target>/` (Slurm) or `.ws/` (workstations) by `run-sync`, together with the
target's `profile.sh`, its `policy.sh` and any personal `policy.local.sh`.

## A target is a directory

| file | language | read by | holds |
|---|---|---|---|
| `profile.sh` | POSIX data | local tools *and* the remote `env.sh` (bash or zsh) | ssh alias, GPUs, storage policy, Slurm defaults |
| `policy.sh` | bash | only `submit.sh` on the login node | partitions, GPU ranges, cpu/mem per GPU, caps, gates |
| `reference.md` | Markdown | the agent | what a newcomer needs to know about the site |
| `tests.sh` | bash | the selftest | checks of what `policy.sh` adds |

Keeping profiles as plain data means they can be sourced by a zsh login shell and by the local tools without
executing site logic; keeping Slurm logic in `policy.sh` means workstation targets carry none.

**Discovery** (`lib/common.sh`): targets come from the user's overlay, then installed packs, then the engine's own
`targets/` (templates only, skipped). The first directory with a `profile.sh` wins. An overlay directory without
one *extends* the target of the same name (`policy.local.sh`, `reference.local.md`, `tests.local.sh`). The target
name is everything: it derives the conf tag (`my-hpc` → `MYHPC_`), the deploy directory, the sync exclude and the
INDEX row — there is no other registry to keep in sync.

**Packs** exist because the natural unit of sharing is a group: the same few clusters, the same filesystem
conventions, the same "which H100 do I want" question. A pack is just another root in the discovery list plus
optional routing bullets for the INDEX, so supporting it cost a few lines and no new concepts.

## Configuration

The project conf (`.hpc.conf` / `.ws.conf`) stays **sourced shell** — existing confs compute values and export
variables, and a new format would break them for no gain. Resolution is CLI flag → `<TAG>_KEY` → `KEY` → default,
so one conf serves several targets. Only listed keys accept a tag; a linter warns about tagged keys nothing reads.
Because jobs are submitted with `--export=ALL`, every reader unsets the keys it is about to read before sourcing the
conf, so a stale exported value can never masquerade as configuration.

## Containment (`remote/env.sh`)

One `env.sh` serves both kinds. It is *sourced* — by the Slurm job wrapper, the bootstrap, the nohup launch chain,
project scripts and interactive shells — so it never uses `set -e` and must be zsh-safe. It:

- pins blob caches (HuggingFace, torch, wandb), logs and checkpoints under the project;
- puts the venv, uv caches and small-file state under `T_ENV_ROOT` (default: the project), because some project
  filesystems are fast for large files and slow or quota-limited for many small ones;
- chooses `TMPDIR` (`project` or the job's own `inherit`ed one) and compile caches (`project`, `tmp`, or a path);
- suffixes architecture-specific state with `T_SUFFIX` when targets share a filesystem but not an OS or GPU arch;
- keeps `RAY_TMPDIR` node-local (AF_UNIX socket paths are limited to ~107 bytes);
- exports `RUN_ENV_READY=$PROJ` only if every step succeeded.

**Fail closed.** Every consumer unsets the sentinel, sources `env.sh`, requires `RUN_ENV_READY == $PROJ`, and then
checks that the environment actually materialised: the venv's python exists (and, for workstation launches, is the
python on `PATH`), or the named conda env is active. The bootstrap snapshots the allowed venv roots *before*
sourcing, so a project hook that runs last cannot move the guard. A misconfigured job therefore stops with a
one-line reason instead of training for a day in the wrong environment.

## Submission (`remote/submit.sh` + `policy.sh`)

`submit.sh` is generic; everything site-specific is behind two hooks:

- `t_partition NAME` sets limits for a partition (GPU range, cpu/mem per GPU, GPU type, walltime cap, preemption
  note) and may add sbatch flags; it rejects unknown partitions.
- `t_policy` runs right after argument parsing and may rewrite the request or refuse it. Its exit code propagates
  verbatim, and a refusal cannot be overridden with `-y`.

Then, in order: GPU range, cpu/mem heuristics, walltime cap (a request above `MaxTime` would pend forever), a payload
guard (no nested `sbatch`/`srun`), a scan of `SBATCH_EXTRA` (no partition or forbidden QOS smuggled in), an
availability check with `sinfo` (busy → warning, `-y` to queue anyway), and finally `sbatch --requeue`.
The job wrapper writes a header per start (`restart=N`) and an `EXIT rc=N` footer, and forwards Slurm's warning and
termination signals to the trainer, so the log itself records how each attempt ended.

## Monitoring (`remote/status.sh`)

Agents are expensive readers. `status.sh` is the single monitoring read: scheduler state (or PID liveness on a
workstation), harness markers, error/OOM/NaN hint counts and the last lines, all from byte-bounded windows
(last 256 KiB for hints, last 64 MiB for markers), in about 2 KB. Hints are counts, not diagnoses; "0" over a
partial window is reported as such. A checkpoint directory's newest entry is reported as *activity*, never as proof
that a run resumed. The skills describe cadence as a policy — review closely when a run is young, restarting or
anomalous; widen the interval only on evidence — rather than as a timetable, and require the agent to say how it
will wake up next instead of promising unattended monitoring.

## Installation

`install.sh` copies the harness to `~/.agents/run-skills/` and installs **one** copy of each skill into
`~/.agents/skills/` — read natively by Codex and pi — with symlinks from `~/.claude/skills/` for Claude Code. A
second copy would be listed twice by agents that scan several roots. It generates each skill's INDEX from the
discovered targets and prepends the targets' trigger words to the skill description (some agents select skills
lexically; descriptions stay under 1024 characters and free of `<>`). The clone never receives generated files.

## Onboarding is a conversation

Installing is easy; *describing a site* is the hard part, and it is the agent that will later depend on that
description. So setup is a runbook for the agent, `INSTALL.md`, rather than an interactive script: the agent lists the
user's ssh hosts, probes the chosen ones, and asks only what a probe cannot know — which partitions the user may use,
where projects live, which queues must never be hit by accident. Facts that can be measured are measured by
`bin/run-probe`: one `BatchMode` ssh running read-only commands with bounded output, so every agent sees the same
evidence, a password prompt can never hang it, and the selftest can run it against stubs. What cannot be measured is
asked and marked as the user's word in `reference.md`. The rails mirror the skills': nothing is submitted, secrets
never pass through the conversation (`run-probe wandb` reports whether a key is set and can import one from `~/.netrc`
without printing it), and `~/.ssh/config` changes are shown before they are made. Existing projects get the same
treatment from `project-setup.md`: their current launch scripts are the specification for the conf, and a copy
already on the server is checked for remote-only edits and a hand-built venv before the first sync.

## Testing

`selftest.sh` runs entirely offline. Phase A runs the generic suite against fixture targets in a scratch overlay,
with stubs for `sbatch`, `sinfo`, `squeue`, `scontrol`, `ssh`, `uv` and `rsync` that dispatch on literal command
strings. Phase B runs every real target's `tests.sh` (engine, packs, overlay) with the same helpers. Documentation
is tested too: the committed INDEX stubs must equal the generator's output, the skills must keep their rails, and
an optional list of forbidden words keeps private names out of the repo.
