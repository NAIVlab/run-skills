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
   A long session's context gets summarized, and a summary of that page is not the page: `run-sync`, `run-launch`,
   `submit.sh` and `status.sh` re-print its path (`rs_ref`, deployed as `T_REF`) so it can be re-read; one line each.
5. **Unsafe actions need a human**: submissions, launches, cancellations, new conda envs, remote directories. One
   narrow, pre-approved exception: `run-watch --act` (below).

Non-goals: multi-node jobs, non-NVIDIA hardware, a new configuration language, a daemon or a database
(`run-watch` is a foreground command the session owns, with a lease; its state file is a receipt, not a database).

## Three layers

```text
skills/remote-run/SKILL.md + refs/     what the agent reads (thin entry, index, a procedure per kind, conf keys, conventions)
bin/ + lib/common.sh                   local commands run from the project root (sync, bootstrap, launch)
remote/                                deployed next to each project and executed there (env, bootstrap, status,
                                       submit, job wrapper)
```

The skill reaches the harness through the first line of the installed `references/INDEX.md` (`root: <dir>`), so
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

One `env.sh` serves both kinds. It is *sourced* — by the Slurm job wrapper, the bootstrap, the workstation `launch.sh`,
project scripts and interactive shells — so it never uses `set -e` and must be zsh-safe. It:

- pins blob caches (HuggingFace, torch, wandb), logs and checkpoints under the project;
- puts the venv, uv caches and small-file state under `T_ENV_ROOT` (default: the project), because some project
  filesystems are fast for large files and slow or quota-limited for many small ones;
- chooses `TMPDIR` (`project` or the job's own `inherit`ed one) and compile caches (`project`, `tmp`, or a path);
- suffixes architecture-specific state with `T_SUFFIX` when targets share a filesystem but not an OS or GPU arch
  (exported as `RS_SUFFIX`, so a project naming its own extra venv can follow the same rule);
- keeps `RAY_TMPDIR` node-local (AF_UNIX socket paths are limited to ~107 bytes);
- exports `RUN_ENV_READY=$PROJ` only if every step succeeded.

**Fail closed.** Every consumer unsets the sentinel, sources `env.sh`, requires `RUN_ENV_READY == $PROJ`, and then
checks that the environment actually materialised: the venv's python exists (and, for workstation launches, is the
python on `PATH`), or the named conda env is active. The bootstrap snapshots the allowed venv roots *before*
sourcing, so a project hook that runs last cannot move the guard. `ENV_KIND=none` has nothing to materialise (the
payload brings its own runtime, typically a container); the containment variables still apply. The one payload
`job.sbatch` starts without a venv is the deployed bootstrap itself (`run-bootstrap --job`): login nodes with a
virtual-memory cap cannot run a torch-sized `uv sync`, so the env is built where the jobs run. A misconfigured job therefore stops with a
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

## Submission records (the attempt journal)

A submit is one ssh, and an ssh can die between "sbatch created the job" and "the caller read the job id". The remote
side then keeps running (a non-pty session's command is not hung up) until its first write to the dead channel, which
kills it with SIGPIPE — so a submit that printed as it went could create a job and die before recording it, and the
caller could not tell "never submitted" from "submitted, id lost" (a retry then makes a duplicate). Hence the rule
*decide and record first, print last*. Every `submit.sh` (and the workstation `launch.sh`) call claims
`<PROJ>/.rs/attempts/<NONCE>/` with `mkdir` — atomic on the project filesystems, across login nodes too — writes all of
its output to `out` / `err` there, writes a `receipt` (job id, name, partition, argv) as soon as the job exists and a
`result` (stage, rc, verdict) on exit, and only then replays out/err to the caller. A dead caller costs nothing but the
replay. `submit.sh` runs everything after the claim, the site's policy code included, in a subshell: a policy that sets
its own EXIT trap, exits, or opens and closes descriptors cannot take the journal's trap or the caller's channels. The NONCE can come from the caller (`--rs-attempt`, a separate word so that an older `submit.sh` rejects it with
exit 2 instead of submitting without a journal), which makes a retry idempotent: the same NONCE again is exit 75. Without
it a NONCE is generated, so every existing caller gets a journal. The verdict is honest about what it cannot know:
`unknown` when sbatch ran but no receipt could be written (sbatch may create a job and still return non-zero);
`refused` only for an explicit rejection (a reply that timed out after the controller accepted the job is not one —
the same rule `run-watch` follows). The job also carries `rs=<NONCE>` in its comment (squeue keeps comments everywhere;
sacct does not, on some sites), so even an `unknown` attempt can be matched to a job later. The Slurm and ssh behaviour
this relies on (mkdir as a claim across login nodes, the silent-vs-writing non-pty command, which repeated sbatch
option wins, comment storage, what a requeue re-reads) was reproduced on the targets with `tests/vgate/`.

A requeued job re-runs its stored batch script with the submit-time environment, but it re-reads `env.sh`, the profile
and the conf from disk at each start — so a re-sync or an upgrade between submit and restart would silently change a
running experiment. `submit.sh` therefore snapshots `conf`, the `ENV_HOOK`, `profile.sh` and `env.sh` into the attempt
dir; `job.sbatch` sources that `env.sh`, and inside the job `env.sh` reads the other three from there, failing closed if
one is missing or the attempt's receipt names another job (an inherited `RS_ATTEMPT` must never lend one job's
snapshots to another). A submission from inside a job never inherits the parent's attempt (`submit.sh` unsets the
`RS_*` it owns before anything else).

Two more guards came with it. The conf is shell, and `submit.sh` used to source it in the shell that then ran the
policy and `sbatch`: a conf defining `sbatch()` or changing `PATH` changed what was submitted. It is now sourced (after the
profile, as `env.sh` sources it) in a child shell that hands back only the keys `submit.sh` reads, as NUL-separated
data that is never evaluated. On a workstation the run starts in a fresh shell, so `launch.sh` hands it the conf's and
the hook's plain variables that `RUN` names, in a mode-600 file the run deletes once read, captured after the harness's
own exports (a plain `CUDA_VISIBLE_DEVICES` in the conf cannot move the run off its GPUs). And a second live job of the same name from the same
project (a retry after a lost reply, an agent that forgot the first submit) would write the same logs and checkpoints:
`submit.sh` refuses it (exit 6) unless the caller says `--same-name-ok` or the job is a singleton chain, which waits
for its predecessor by design. `SBATCH_EXTRA` is linted (warnings only for now) against an allowlist, since options
the harness sets itself (`--time`, `--mem`, …) are silently overridden by whichever comes last on the command line.
`run-sync` writes a `MANIFEST` (sha256 of every deployed file) last, so a half-finished deploy is detectable.

## Monitoring (`remote/status.sh`)

Agents are expensive readers. `status.sh` is the single monitoring read: scheduler state (or PID liveness on a
workstation), harness markers, error/OOM/NaN hint counts and the last lines, all from byte-bounded windows
(last 256 KiB for hints, last 64 MiB for markers), in about 2 KB. Hints are counts, not diagnoses; "0" over a
partial window is reported as such. A checkpoint directory's newest entry is reported as *activity*, never as proof
that a run resumed. The skill describes cadence as a policy — review closely when a run is young, restarting or
anomalous; widen the interval only on evidence — rather than as a timetable, and require the agent to say how it
will wake up next instead of promising unattended monitoring.

## Installation

`install.sh` copies the harness to `~/.agents/run-skills/` and installs **one** copy of the skill into
`~/.agents/skills/` — read natively by Codex and pi — with a symlink from `~/.claude/skills/` for Claude Code. A
second copy would be listed twice by agents that scan several roots. It generates the skill's INDEX from the
discovered targets and prepends the targets' trigger words to the skill description (some agents select skills
lexically; the description stays under 1024 characters and free of `<>`). The clone never receives generated files.

**One skill, both kinds.** There used to be two skills, `hpc-run` (Slurm) and `ws-run` (workstations). They shared
their rails, conventions and project setup almost word for word, and a placement left open spans both kinds anyway
(`run-avail` reads every target), so an agent needed both and had to route between them. `remote-run` keeps one INDEX
with a `kind` column, one rail list (kind-specific rails labelled) and a procedure per kind; `rsk` is its read-only
observation path. Since an agent lists every installed skill by its description, a leftover `hpc-run` next to
`remote-run` would compete with it on stale text: `install.sh` removes the old copies it generated in the shared root
(and links to them), moves everything else out of every root Claude Code, Codex and pi scan instead of deleting it
(a copy elsewhere may carry the user's edits), and `rsk doctor` fails while one is still discoverable. Packs keep
their `routing/hpc-run.md` / `ws-run.md` (members on older engines read only those names); the INDEX uses them when a
pack has no `remote-run.md`, each rule under a lead-in naming its kind, since it applied inside that kind's skill only
(a rule both files carry is cross-kind and appears once, unscoped).

The engine ships as a uv tool (`remote-run`, command `rsk`): `uv tool install git+…` gives it an isolated env that no
project venv, `VIRTUAL_ENV` or `PYTHONPATH` can shadow, and `rsk update` is one command for everything a member has
— it upgrades the tool through uv, fast-forwards clean pack clones, and has the *new* rsk re-run `rsk setup` (which
runs the same `install.sh`, from the wheel's copy of the harness, and its selftest against the member's packs). uv is
used at install and update time only; `rsk` never calls it to run. The user's dir `~/.config/run-skills/` (overlay,
packs, wandb key, `config.toml` for rsk's own settings — never a site fact) lives outside the tool env, so an update
never touches it. A remote deploy changes only at the project's next sync. `rsk status` finds a project's jobs by
place (Slurm WorkDir, `logs/*.pid`), not from memory: a context summary or a new session cannot lose them, and a
target that does not answer is reported as unobservable, never as idle.

## Onboarding is a conversation

Installing is easy; *describing a site* is the hard part, and it is the agent that will later depend on that
description. So setup is a runbook for the agent, `INSTALL.md`, rather than an interactive script: the agent lists the
user's ssh hosts, probes the chosen ones, and asks only what a probe cannot know — which partitions the user may use,
where projects live, which queues must never be hit by accident. Facts that can be measured are measured by
`bin/run-probe`: one `BatchMode` ssh running read-only commands with bounded output, so every agent sees the same
evidence, a password prompt can never hang it, and the selftest can run it against stubs. What cannot be measured is
asked and marked as the user's word in `reference.md`. The rails mirror the skill's: nothing is submitted, secrets
never pass through the conversation (`run-probe wandb` reports whether a key is set and can import one from `~/.netrc`
without printing it), and `~/.ssh/config` changes are shown before they are made. Existing projects get the same
treatment from `project-setup.md`: their current launch scripts are the specification for the conf, and a copy
already on the server is checked for remote-only edits and a hand-built venv before the first sync.

## Testing

`selftest.sh` runs entirely offline. Phase A runs the generic suite against fixture targets in a scratch overlay,
with stubs for `sbatch`, `sinfo`, `squeue`, `scontrol`, `ssh`, `uv` and `rsync` that dispatch on literal command
strings. Phase B runs every real target's `tests.sh` (engine, packs, overlay) with the same helpers. Documentation
is tested too: the committed INDEX stub must equal the generator's output, the skill must keep every rail, and
an optional list of forbidden words keeps private names out of the repo.

## Batch watching (`run-watch`)

Agents watching many jobs one `squeue` at a time either poll too often or miss preemptions; hand-rolled watchers
in projects drifted (retrying states nobody approved, counting a budget before the submit succeeded). `run-watch`
is the one shared watcher:

- **Observe cheaply.** One read-only BatchMode ssh per target per round, the script on stdin (inside a function, so a
  cut-off script runs nothing); no deploy. A failed or incomplete observation decides nothing; a queue that empties
  between two rounds is believed only on the second (a truncated reply must not read as "every job is gone").
- **Settled = purged + terminal.** A requeued job keeps its id and stays in the controller, so "gone from
  `squeue --states=all` and sacct shows a final state" is the same rule on a cluster that requeues and one that
  cancels on preemption — no per-partition mode table. The submit ssh checks both again right before submitting.
- **Act only on an approval that can go stale.** The table's `#@ allow` line is the budget (no defaults); `#@ ok`
  carries a checksum of that line plus its block of rows, written by `--approve` with the user's words. The checksum
  only stops edited or appended rows (and raised budgets) from inheriting an old approval — it cannot prove that the
  user agreed; the skill rail (show the rows and budget, wait for the OK) does that.
- **Never guess a submit outcome.** One row per submit ssh; no `+ sbatch` line from `submit.sh` = refused before
  sbatch (budget refunded); a receipt = submitted; anything else is a sticky `submit-unknown` that only `--adopt` or
  a user-approved `--release` clears. CANCELLED is never resubmitted (someone may have pressed cancel).
- **Report, never interfere**: requeue storms, stalls (log mtime) and a missing resume line are events only.

