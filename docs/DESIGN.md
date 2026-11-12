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
5. **Unsafe actions need the user's authorisation — checked first, asked for only when it is missing**: submissions,
   launches and cancellations are checked against what the user already allowed (below); new conda envs, remote
   directories and someone else's jobs are never the agent's to decide.

Non-goals: multi-node jobs, non-NVIDIA hardware, a new configuration language or task file, a daemon, a database server
or a control plane (rsk runs only when called; its ledger is a few JSON files per project on the user's machine;
`run-watch` is a foreground command the session owns, with a lease; its state file is a receipt, not a database).

## Three layers

```text
skills/remote-run/SKILL.md + refs/     what the agent reads (thin entry, index, a procedure per kind, conf keys, conventions)
src/remote_run/ (rsk)                  the agent's commands: reads, plan → the user's authorisation → act, the ledger
bin/ + lib/common.sh                   local commands run from the project root (sync, bootstrap, launch, watch)
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
  verbatim, and a refusal cannot be overridden with `-y`. For a plan and for an approved submit (`--rs-expect`) it is
  first probed as a submit without `-y` sees it — `( FORCE=0; t_policy )` in a subshell — because a policy gate written
  as `[ "$FORCE" -ne 1 ] && { echo "WARNING: …"; exit 1; }` is silent under the plan's `FORCE=1` and would never reach
  the card; `t_partition` can hold such a gate too, so it is probed the same way, in its own subshell right before its
  real call, with the partition that is submitted (a `t_policy` gate cannot hide it; its `return 1` is an unknown
  partition, not a gate). Inside the probe every `exit 1` is a gate that is noted and passed — the function goes on, as
  plan mode goes on past each gate — so a function's first gate hides none after it; a gate without a `WARNING:` line of
  its own gets a generic one, and then everything the probe printed, digits masked, enters `warnings_id` (two silent gates
  never pass for each other); any other non-zero exit ends the call. Passing a gate relies on a bash fact reproduced in
  `tests/vgate` (`bash_exit_fn=`) and in the selftest: a function named `exit` outranks the builtin, except in POSIX mode,
  where bash refuses to define it and the probe fails closed (exit 2). So both functions may run twice and must have no
  side effects, and code after a gate must not assume the gate stopped the run. The probe is the safety net, not the
  idiom: a gate prints its WARNING, then tests FORCE (`echo 'WARNING: …' >&2; [ "$FORCE" = 1 ] || exit 1`, the
  template's and `docs/packs.md`'s rule), so the plan's real call and a `-y` submit show it too; the P2 form
  `[ "$FORCE" = 1 ] || { echo 'WARNING: …' >&2; exit 1; }` is silent under `-y`, and only the probe finds it.

Then, in order: GPU range, cpu/mem heuristics, walltime cap (a request above `MaxTime` would pend forever; a limit of
`0` in any spelling, `UNLIMITED`, `INFINITE` or `-1` is no limit at all to sbatch and is refused, as is one the script
cannot read — and that holds for every `--time` / `-t` sbatch could read, the policy's and `SBATCH_EXTRA`'s included,
because sbatch keeps the last one), a payload guard (no nested `sbatch`/`srun`), a scan of `SBATCH_EXTRA` (no partition
or forbidden QOS smuggled in; every word an option or the value of the option before it — sbatch's getopt string starts
with `+`, so the first other word would become the batch script and the harness's own options after it that script's
arguments, and a value option at the end would swallow the harness's next option), an availability check with `sinfo`
(busy → warning, `-y` to queue anyway; a node the job's own last `--exclude` / `-x` names is listed `[excluded]` and never
counted — a count of GPUs the job may not use once said "6 free" where none was usable — but only a plain comma-separated
host list is read: a hostlist range or a path is not expanded here, never guessed, so a NOTE says the count includes it;
and free is all the gate measures — priority, QOS / per-user caps and the account's other jobs decide when a job
starts, which squeue's pending reason names and the docs teach to read), a lint of `SBATCH_EXTRA` that reads its words
as that scan does (an option's separate value, `--comment -t1`, is never linted as an option), and finally
`sbatch --requeue`.
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
option wins, comment storage, what a requeue re-reads, sbatch's reading of a time limit of 0, of an option's value
word `-t1` and of a bare word — which it runs as the batch script) was reproduced on the targets with `tests/vgate/`
(`slurm-remote.sh` submits 8 tiny jobs, five of them held and cancelled unrun). It also prints scancel's exit and words
for its own ended job (`scancel_ended=`) and for an id no job can have (`scancel_invalid=`, 4000000000, sent only after
`squeue -j` lists none) — the words `rsk cancel` reads as "nothing to cancel" (below; not yet run on a cluster, so any
other wording stays unknown: fail closed); `launchers.sh` reads the
launcher facts behind the workstation's launcher WARNING back from an installed deepspeed / accelerate, launching
nothing (`ds_abbrev ds_short ds_alias ds_ignores_cvd ds_hostfile`, `ds_hostfile_flag` — want `h1,h2,h3,h4,h5,h7`: the
file of `-H h1`, `-Hh2`, `-H=h3`, `--hostf h4`, `--hostfile=h5` and the last of `-H h6 -H h7`, the spellings launch.sh
binds —, `ds_pool_cvd` — yes: the runner turns
`CUDA_VISIBLE_DEVICES` into `--include` only when no hostfile gave it a resource pool —, `acc_hyphen acc_abbrev
acc_sets_cvd`, `acc_all`, `acc_cfg_gpu_ids` — the config's `gpu_ids` is taken when `--gpu_ids` is absent —,
`acc_cfg_hyphen`, `acc_cfg_default` — want `$HF_HOME/accelerate/default_config.yaml` — and `acc_cfg_json_only` — want
`default_config.json`); and `containers.sh` starts throwaway containers that only `printenv` (no GPU is asked for:
`ssh <alias> 'bash -s <docker-image|-> <apptainer-image|->' < tests/vgate/containers.sh`) and prints `<rt>_version`,
`<rt>_gpus_flag`, `<rt>_env` (docker / podman: want `unset`, no host environment goes in), `<rt>_env_e` (a bare `-e`:
want 5), `docker_default_runtime`, and for apptainer / singularity `<rt>_env` (want 5: it does go in),
`<rt>_cleanenv` / `<rt>_containall` (want `unset`) and `<rt>_prefix` (`APPTAINERENV_CUDA_VISIBLE_DEVICES=7` with
`--cleanenv`: want 7), and for docker / podman `<rt>_exec_env` (`exec` into a throwaway detached container, removed
after: want `unset`, exec passes no host environment in either). `envdrop.sh` reads the facts behind the warning on
tools that start the command elsewhere from a box's own tmux / screen / setpriv / systemd-run (`ssh <alias> 'bash -s' <
tests/vgate/envdrop.sh`; `systemd-run` only when named, `'bash -s tmux screen setpriv systemd-run'`, which starts one
transient `--user` unit): `tmux_server_env=` (a session made while a server runs: want `unset`, it gets the server's
environment), `tmux_first_env=` (the session that starts the server: want 5), `tmux_session=` and `screen_session=`
(want `other`: outside the caller's session), `screen_dm_env=`, `setpriv_reset_env=` and `setpriv_reset_prefix=` (`--res`:
want `unset`), `systemd_run_env=` (want `unset`), and a second tmux line: `tmux_split_prefix_env=` (`tmux split -d`, a
command named by a prefix, into the server's session: want `unset`), `tmux_prefix=` and `tmux_alias=` (each word asked
of the running server with an invalid flag, `-~`, so tmux names the command it resolved and runs nothing — the want
list is in the script's header: `sp` is split-window, `ru` run-shell, `i` if-shell, `pi` pipe-pane, while `s`, `r`, `p`,
`ne`, `res`, `display-p`, `send-` are ambiguous and `split-p` unknown); `tests/88` also runs it on this machine's own
tmux and setpriv when they are installed, and checks launch.sh's tmux prefix table and alias list against that tmux.
`local.sh` adds `env_anywhere=` (GNU env after a wrapper and its other options: want `rc=1` four
times, then 125 — `--i` is ambiguous — or 1 on an older env). All of them run only with the user's OK, e.g. `ssh <alias>
'bash -s <dir>/.venv/bin/python' < tests/vgate/launchers.sh`; `tests/88-vgate.sh` checks their plumbing on stubs and
fake modules.

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

No remote parsing goes through a here-string or a heredoc: up to bash 5.0 both are temp files in `$TMPDIR`, and on a
full one the read fails silently — an empty busy-GPU list reads as "none busy", a time limit loses its hours. `status.sh`
(its squeue / sacct rows), `submit.sh`, `launch.sh` (its run wrapper is a single-quoted literal written with `printf`,
so its text never holds a single quote) and run-watch's remote bodies split by parameter expansion, and anything they
cannot parse fails closed. `tests/lib.sh`'s `fulltmp` runs a command with `TMPDIR` on a full tmpfs and `BASH_COMPAT=42`
in a private mount namespace to prove it (skipped where user namespaces are unavailable).

### Plan mode and `--rs-expect`

An approval is given to what the user was shown, but a submit is resolved on the target: conf defaults, the policy's
added flags, `SBATCH_EXTRA`. Between "here is the plan" and "go" any of that can change (a re-sync, an edited conf, a
policy update), and an agent re-typing the command can drift too. So the remote scripts resolve the request twice with
the same code: `--rs-mode plan` runs the whole submit or launch path — policy, limits, availability, duplicate guard,
lint, the GPU pick; on a workstation the env gate read-only (the venv's python must be executable, a conda env must
activate in a throwaway shell, the `ENV_HOOK` file must exist, `ENV_KIND` must be valid — a plan whose launch the gate
would refuse ends with exit 1 and no card, so the user is never asked to approve a launch that cannot start; `env.sh`
itself creates the project's cache dirs, and a plan creates nothing outside `.rs/`, so the real gate still runs at the
launch) — and, instead of `sbatch` / `setsid`, prints one `@@plan v1` block
of *bound* fields (what an approval is for: partition, gres, cpus, mem, time, account, name, the extra sbatch words —
`extra`, the policy's and `SBATCH_EXTRA`'s together, and `conf_extra`, the conf's own words alone —, the policy flags
handed to the site's policy (`flags=`: the policy may turn them into any sbatch option, so no standing grant covers a
plan with one), the payload argv, the env — kind, name, the `ENV_HOOK` file by its sha256, `VENV_DIR`, `UV_SYNC_ARGS`;
for a workstation the GPU request rather than the ids picked, every launcher config and hostfile its launcher check read,
`launch_cfg=<path>:<sha256>,…` (below), and the occupants of the busy GPUs its landing accepts,
`busy_ok=<id>:<uuid>:<user>,…`) with `bound_hash`, the sha256 of those lines. The envelope (free GPUs now, which ids a
pick chose, file hashes, the source commit, the warnings; on a workstation `info_run_gpu=checked` and, after
`info_prior`, `info_launchers=checked`, below; and
`info_prior=<n|unknown>` — after `info_source_dirty` on Slurm, after `info_run_gpu` on a workstation —, the run's earlier
attempts the target can see: journal receipts named the run id or `<run id>--aNN`, on Slurm also squeue's rows of such a
name with this WorkDir, live or ended and still listed, that no receipt names; `unknown` when squeue failed or a receipt
cannot be read) is printed as `info_*` and the `warnings*` lines and not bound: it legitimately changes between plan and run. `--rs-expect <hash>` then recomputes the hash with the same function right before the snapshots
and `sbatch` (before the env gate on a workstation) and refuses (exit 6) on any difference, printing `changed: <keys>`
when the approved plan's own block is still in the journal (rsk also diffs it against the card it stored), so the refusal
says what moved — `time: … → …`, `busy_ok: 1:GPU-…:me → 1:GPU-…:root` — rather than just "it differs".
Plan mode treats every `-y` gate as acknowledged — it prints the WARNING and goes on — so one card shows every
warning. A plan with warnings needs the `-y` again at submit time, which is not bound; counting warnings is not enough
(one gate can clear while another appears), so the plan prints `warnings_id`, the sha256 of its distinct `WARNING:`
lines sorted with every digit run masked (a count of free GPUs may move; the gate may not; a policy gate with no
`WARNING:` line adds what its probe printed, above), plus `warnings` (how many)
and `warnings_avail` (how many are the harness's own availability gate's). The submit carries `--rs-warnings
<warnings_id>` and the script recomputes it: a warning that appeared or went away is exit 6, so a `-y` sent for the
card's warnings never passes another one (under `--rs-expect` a failed squeue, the duplicate check, is exit 1, not a
`-y` gate). An `SBATCH_EXTRA` `--time` (sbatch takes the last one) is held to MaxTime like `-t`, and the card shows it
and the conf's own `SBATCH_EXTRA` words. The flags are separate words, so an older `submit.sh` / `launch.sh` exits 2 on
the bare value word instead of submitting without the check, and an `--rs-` word is never taken as an option's value.
What a deploy speaks is the line `# rs-api=3` inside the deployed `submit.sh` / `launch.sh` — not a separate file,
which an older `run-sync` would leave in place while it rewrote the script: rsk's plan ssh reads that line in the
script it is about to run (run-launch does the same for `launch.sh`) and reports `needs: sync` when it is missing, as
it does when an older parser answers rsk's words with `unknown arg` (exit 2). The hash proves the submission is the planned one, not
that the user agreed to it: that stays the user's words, recorded by rsk. A busy GPU is part of the same decision: the
workstation launch reads `nvidia-smi --query-compute-apps` once and never picks, or launches `-d` onto, a GPU with a
compute process unless `--gpu-busy-ok` — the user's OK naming the GPUs (`-d`), not a default; rsk sends it only when the
approved card's own landing was busy, pinned to that landing, and the occupants are bound: a different owner on an
approved GPU, a newly busy GPU in the landing or another physical GPU behind the same id is exit 6. An unreadable
busy state is `unknown`, never "none busy". All of that would be moot if the run command could pick its own GPUs:
the run starts as `env <RUN>`, so a `CUDA_VISIBLE_DEVICES=…` (or `CUDA_DEVICE_ORDER`, `NVIDIA_` / `HIP_` /
`ROCR_VISIBLE_DEVICES`) among RUN's leading words — also after a leading `env`, or cleared with `env -u` / `-i` —
would replace the checked landing, and so would one further on: a later command, a pipeline element, `bash -c '…'`, a
wrapper such as `timeout` before `env`, a container's `--env NAME=`. `launch.sh` refuses (exit 2 before its claim,
nothing created) a RUN whose leading words do so (or carry any `env` option but `-v`/`--debug`, `-C DIR`, `-u` of
another name), and a RUN whose TEXT, anywhere, assigns or clears one of them — `NAME=` / `NAME+=`, `-u NAME`,
`--unset[= ]NAME`, `unset … NAME`, `export -n NAME`, `declare` / `typeset +x NAME`, read as written and again with quotes
and backslashes removed; `APPTAINERENV_NAME=` / `SINGULARITYENV_NAME=` count as `NAME=`, since apptainer sets NAME inside
the container from them, `--cleanenv` or not (`containers.sh` `<rt>_prefix=`). Emptying the whole environment anywhere
takes the harness's `CUDA_VISIBLE_DEVICES` and `CUDA_DEVICE_ORDER` with it, so it is refused the same way: `env -i`
(`-vi`, `-0i`), `env -`, `env -- -`, `--ignore-environment` or any abbreviation of it from `--i` on — after a wrapper,
after env's other options (`-v`, `-u NAME`, `-C DIR`), inside `-S`'s string —, read with GNU env's own rule that its
options end at its command (`env A=1 cmd -i` is fine), and bash's `exec -c` where a command starts (`-l` / `-a NAME`
may come first; never `exec -ac`, `exec -a -c`, `exec -- -c` or a subcommand's `exec -c`, such as apptainer's): `ERROR:
RUN empties the whole environment in its text ('env -i': …)`. The env facts are `tests/61` R6-6 (and `tests/vgate/local.sh`
`env_anywhere=` on a box), the `exec -c` ones `tests/61` 'round-6 integration', with the local bash. A rule on the text
cannot tell code from data, so a mention as data (`--note
"CUDA_VISIBLE_DEVICES=0"`) is refused too; reading them (`$NAME`, `printenv NAME`) is fine. When the first command shows
it only after expansion, the wrapper checks the expanded words and never starts the payload. The plan says so with
`info_run_gpu=checked`, and rsk requires that line (an older deploy: `needs: sync`). Launchers that pick GPUs from their
own flags are the other way past the landing: deepspeed's runner, given `--include`, `--exclude`, `--num_gpus`,
`--num_nodes` (or a hostfile), drops `CUDA_VISIBLE_DEVICES` and numbers the GPUs itself, and `accelerate launch` sets it
from `--gpu_ids` (their source; `tests/vgate/launchers.sh` reads it back from an installed copy). They are ordinary
commands, so `launch.sh` does not refuse them: their GPU flags (deepspeed's also as argparse prefixes, `-H`,
`--master_addr`, `--num_accelerators`; accelerate's `--num_processes` too, both spellings) print a counted WARNING naming
the launcher, the flags and the landing — on the card, so only the user's approval of it covers it: launch.sh counts
these WARNINGs apart as well (`warnings_gpu=N` in the block's envelope), and rsk lets no standing grant cover a plan
with `warnings_gpu` > 0, whatever its `allow_warnings` kind — `any` included (NF8: a "≤ 1 GPU" grant of kind `any` had
covered `deepspeed --num_gpus 4`, `docker run --gpus all` and `ssh otherbox …`; such a run may use more GPUs than its
scope, another user's too, which the user's policy leaves to them) — nor a block without the key (an older launch.sh:
unknown, so uncovered; `rsk sync`); the card shows `NO GRANT   N launcher / container / env-dropping warning(s)`
(`grants.gpu_warn_miss`, `tests/62` and `test_grants.Round9`). Their configs, and container runtimes, are the same way
past the landing. accelerate takes `gpu_ids` from its config
when `--gpu_ids` is absent (`acc_cfg_gpu_ids=`), so launch.sh reads that config, read-only — `--config_file` (relative to
the project dir), else `$PROJ/.cache/huggingface/accelerate/default_config.yaml`, where env.sh's `HF_HOME` puts it
(`.json` when only that is a file: `acc_cfg_default=`, `acc_cfg_json_only=`) — and warns on a `gpu_ids` other than `all` /
`null` / `~` / empty, on a config it cannot read (missing, unreadable, named by an expansion or `~user`, over 64 KiB, or
relative after a `cd` / `pushd` / `--chdir` / `env -C` in RUN: `(--config_file X: relative, after a cd in RUN)` — the
project's file of that name is not the one read) and on a RUN that sets or unsets `HF_HOME`. Without `--config_file`
the default config is only where env.sh put `HF_HOME` if nothing moved it: env.sh sources the `ENV_HOOK` last, after
exporting `HF_HOME`, and a hook may set anything (`tests/61` 'R7-4': a hook points `HF_HOME` at a shared cache, and a
stub accelerate reading its config lands on another user's GPU). So `accelerate launch` with neither `--config_file` nor
`--gpu_ids` warns `the config accelerate reads is unknown (…)` when the conf sets `ENV_HOOK`, when `ENV_KIND=conda`
(env.sh runs `conda activate` after exporting `HF_HOME`, and conda applies the env's own variables — `conda env config
vars`, its `activate.d` scripts —, which may set `HF_HOME` or `ACCELERATE_…`: `tests/61` 'R8-4', the reason
`ENV_KIND=conda: conda activate '<env>' applies the env's own variables (HF_HOME / ACCELERATE_… among them), which may
move it`), when the conf names `HF_HOME` or `ACCELERATE_…` outside a comment line and not as an expansion, when RUN
names `ACCELERATE_…`, when the conf did not source or could not be read, or when the project's `.wandb_env` — the
user's wandb key file, which env.sh sources after exporting `HF_HOME` — names `HF_HOME` or `ACCELERATE_…` the same way
or cannot be read here (read-only, never printed: the reason names only `HF_HOME` or `an ACCELERATE_… variable`;
`tests/61` 'NF7': a `.wandb_env` pointing `HF_HOME` at a shared cache lands a stub accelerate on another user's GPU) —
fail closed; the project's own default
config is still read and bound beside it. To know the hook, launch.sh now reads the conf (profile, then `.ws.conf`, in a
child bash without rc files, the caller's channel and the launch lock closed) in every mode, before this check; a plain
launch whose conf does not source goes on to env.sh's gate. deepspeed's runner reads `/job/hostfile` when no
`--hostfile` is given and then ignores `CUDA_VISIBLE_DEVICES` (it turns that into `--include` only without a hostfile's
resource pool: `ds_hostfile=`, `ds_pool_cvd=`), so that file's presence warns; a hostfile `-H FILE` / `--hostfile FILE`
names (`-HFILE`, `-H=FILE`, `--hostfile=FILE`, argparse prefixes; every one given: `ds_hostfile_flag=`) is read as
`--config_file` is — relative = the project's; after a cd in RUN, through an expansion or `~user`, or a flag with no
value, `<file>:unreadable` — beside its `-H` / `--hostfile` WARNING (`tests/61` 'R8-5'). A warning's digits are masked
in `warnings_id`, so `gpu_ids: 0` edited to `1` after the card would pass `--rs-expect` with the same warning: every
config and hostfile the check read is therefore bound, `launch_cfg=<path>:<sha256>[,…]` (sorted and deduplicated;
`<path>:unreadable` for one it could not read; empty when none; right before `busy_ok`), and an edit after the card is
exit 6 `changed: launch_cfg` — rsk names the old and new digests and gives the use back; the ledger keeps the field with
each attempt, so a relaunch grant repeats it (an edited config is `not the configuration of aNN it resumes`; an attempt
recorded before the field has none, so its relaunch with a config is the user's call once). A container does not inherit
the landing at all: docker, podman and nerdctl pass no host environment in (only `-e`), and `--gpus` (any value),
`--runtime`, `--device nvidia.com/…` or `/dev/nvidia…`, `--privileged` or a bare `-e NVIDIA_VISIBLE_DEVICES` hand it
GPUs its runtime picks — `nvidia-docker run` always —, while apptainer / singularity pass the environment in unless
`--cleanenv` / `--containall` (`containers.sh`). Each is a counted WARNING (`… a container started so does not get this
launch's CUDA_VISIBLE_DEVICES and may see GPUs its runtime picks …`), so a GPU container run is covered only by the
user's approval of its card (`warnings_gpu`: never a grant). A tool that starts the command elsewhere, or without this
launch's environment, is the last way past the landing, and gets the same counted WARNING (`RUN starts its command
through
<tool …> — <reason> — so it may use GPUs other than this launch's GPU(s) […]: run the command directly (launch.sh
detaches it), or name the GPUs it will use to the user`): a container's `exec` / `start` (its GPUs were set when it was
created; `containers.sh` `<rt>_exec_env=`), compose `run` / `up` / `exec` / `start` / `restart`, `kubectl
exec|run|debug|apply|create`, tmux's session-making and key-sending commands (a session made while a server runs gets
the server's environment, not the client's: `envdrop.sh` `tmux_server_env=`) under any name tmux runs them by — an
alias, a default command-alias (`splitp`, `split-pane`) or any unique prefix tmux accepts (`split`, `spl`, `sp`, `run-`,
`ru`, `i`, `if-`, `pi`): a word warns when it is a prefix of a warned command at least as long as the shortest prefix
only warned commands share in tmux's table (`new-` and `resp` too, ambiguous only among them), never one tmux finds
ambiguous with a command not warned (`s`, `r`, `p`, `ne`, `res`, `display-p`, `send-`: tmux refuses those; `tmux_prefix=`,
`tmux_alias=`, `tmux_split_prefix_env=`), `screen` detached or remote-controlled
(`-dm`, `-X`: outside this run, which ends at once), `setpriv --reset-env` (and its prefix from `--res`), `sudo` unless it
keeps both `CUDA_VISIBLE_DEVICES` and `CUDA_DEVICE_ORDER` (`-E`, `--preserve-env`, or `--preserve-env=` naming both;
`-i` / `--login` always: sudoers' `env_reset`), and always `doas`, `systemd-run`, `ssh` and `srun` / `salloc` /
`sbatch` (the spellings: `tests/61` 'R7-3'). It reads RUN's text, so it can fire on a word that is only an argument
(`rsync -e ssh`, an `exec` inside `docker run … sh -c`): fail closed, the card says why. A plan says it has these checks
with `info_launchers=checked` (and binds `launch_cfg`), which rsk requires: an older deploy's card would lack those
WARNINGs and a grant would cover, say, `docker run --gpus all`, so a block without either is `needs: sync`, and a
nohup plan stored without them is refused at `--plan`. This is a check of RUN's words, not of the payload: the payload
is code, and what it does once it starts — set its own environment from a script it runs, take a value only an
expansion inside a later command supplies (`x | env $PRE y`), read a config rsk does not read — is outside what rsk can
check (the honest limits, below).

## Authorization: check first, ask only outside scope

The first rails were "confirm before every submit, confirm before every cancel". For long experiments that is tedious
and it wastes intent the user has already expressed: a user who said "run these five ablations on this cluster"
should not be asked five times, and a preempted job should not wait overnight for a "yes, resume it". The user's
policy: no need to ask again every time, but every action must check whether an authorisation exists.

| situation | ask again? |
|---|---|
| the user said "run this set of experiments on this target" | parameters within that scope: act directly |
| the user approved a sweep | the whole set shares one approval, no per-member question |
| a preempted run resumes with its original configuration, and the user authorised auto-resume | within the budget: act directly |
| a charged partition, more resources, or a wider experiment scope | confirm |
| the user said "cancel job 123" | cancel once the job's identity is verified |
| the user authorised "on a failure, stop the rest of the group" | act when the condition holds |
| the agent decides on its own that a run is not worth continuing | confirm — unless the user authorised that kind of judgment |

How rsk maps it. `rsk launch` plans on the target first (plan mode, above), stores the plan and its card, and calls
`grants.check()` before anything is submitted; `rsk cancel` does the same before it signals anything. There is one
record type, in the project's ledger under rsk's state dir: an **approval** (the plan ids and bound hashes of the cards
the user approved, expiring with those plans — one record covers a whole sweep, a chain of N segments is one approval
used N times; a later plan of the same configuration is a new card — or the jobs a user named for cancelling), a
**grant** (a standing predicate: targets, partitions, GPU types, classes, name globs, caps on GPUs / CPUs / memory /
time, which warnings it accepts, the actions allowed, and `max_live` / `max_launches` / `expires` — all three always
stated, `none` meaning the user's words set none, so a limit is never the agent's invention), and a **deny** (it always
wins). Covered → act and record the use; not covered → `needs user:` with the card, exit 4; the user's words then go to
`--approve`. When the target proves nothing was submitted (a refusal or failure before `sbatch` / `setsid` with no
receipt, no attempt dir at all, `run-launch` failing before its launch ssh) the attempt is `NOT_SUBMITTED`, not
unknown: the use is given back and the plan's claim released, so once the cause is fixed (a venv built, a policy
satisfied) `rsk launch --plan <id>` submits the same card under the same record with no new question — `--rs-expect`
still refuses drift. ssh's own words are never that proof: a Slurm submit whose ssh exits 255 with no receipt — before
the remote's first line (`@@api`) too — is `SUBMIT_UNKNOWN` whatever its stderr says (`… — ssh exit 255 (<its last line>)
— ssh's own words are no proof that nothing was sent`), because a ProxyCommand's fallback route or a login shell prints
`Connection refused` / `Permission denied` on a session that did open and ran `submit.sh` (round 5 took those words as
proof and released the plan, and the retry submitted the job again). The use is kept, the plan stays used (`rsk launch
--plan <id>` again: exit 6), and `rsk status` reconciles the attempt from the journal — or, when the journal holds no
attempt dir of that nonce, `rsk adopt --not-submitted` with the user's words (the reproductions: `tests/py/test_launch.py`
Round5 `test_r6_4_…`, `tests/62` with `$T/ssh.fallback`, whose first route refuses and whose second runs the body).
On a workstation rsk reads the journal before deciding, whatever the exit: a receipt whose gate
said go is a launch (a `launch.sh` killed after that point still started the run, and the use is kept); only the
journal's refusal or failure with no receipt, `launch.sh`'s own exit with no attempt dir (it claims one first) or a
taken attempt name (75), or `run-launch` ending before its launch ssh proves nothing started; anything else (ssh 255, a
signal, a journal that cannot be read) stays `SUBMIT_UNKNOWN` for `rsk status` to settle.

The rows "charged partition / more resources / wider scope" fall out of the predicate, and when in doubt a grant does
not cover. A plan with warnings (a `-y` gate) is covered only by a grant whose `allow_warnings` kind covers them:
`availability` covers a plan whose only warnings are the harness's own availability gate (`warnings == warnings_avail`:
the cluster is busy, queue anyway), `any` covers every `-y` gate, a policy's charged-partition warning included — and is
recorded only when the user's words say so (`rsk grant add --allow-warnings availability|any`, a bare flag is a usage
error; an older record's `true` reads as `any`). No kind covers a workstation plan's launcher / container / env-dropping
WARNINGs (`warnings_gpu` > 0, or no `warnings_gpu=` at all): only the user's approval of that card does. rsk sends `-y`
only when the approved card showed warnings or the covering grant's kind covers the plan's warnings, and the target
checks they are
the same warnings (`warnings_id`). A request above a cap is not covered; `max_time` holds for every time limit sbatch
could read — the bound time and each `--time` / `-t` among the extra words, a site policy's included (it comes after
the harness's and wins) — and a limit of 0 or `UNLIMITED` is unlimited, so it never fits. A Slurm plan is coverable only
if every word of the conf's `SBATCH_EXTRA` (bound as `conf_extra`) is in a short allowlist — `--qos -q --account -A
--exclude -x --constraint -C --reservation --signal --mail-type --mail-user --comment`, `--dependency=singleton` / `-d
singleton`, `--requeue` / `--no-requeue`, `--nice[=N]` — because a time, resource or node option has more spellings and
abbreviations than any cap could follow; anything else is named on the card's `NO GRANT` line and is the user's call.
The policy's own `SB_ARGS` words are site policy and never affect coverage; `T_SBATCH_EXTRA_ALLOW` widens only the lint.
Policy flags (`--<word>` handed to the site's `t_policy`, bound as `flags=`) are the same kind of unknown — the policy
may turn one into any sbatch option — so no standing grant covers a plan with policy flags: the card lists them, and
only the user's approval of that card does.
The action is derived, never taken from a flag: a run that already has attempts that may have run (any target; only
`NOT_SUBMITTED` ones and the plan's own do not count) is a `relaunch` — attempts in the ledger, OR `info_prior` > 0 in the
plan's block (the target's journal and squeue know the run: run-watch's submits, a direct `run-launch`, another
checkout's never enter this ledger), OR no readable `info_prior` (an older deploy, a failed squeue, an unreadable
receipt: fail closed) —, a plan with `chain=1` (also an `SBATCH_EXTRA`
singleton) a `chain`, and every action that applies is checked — a deny of any of them matches, a record must allow
all of them. A `relaunch` grant covers a relaunch only after the run's latest attempt that ran ended with positive
evidence of an infrastructure end — Slurm `PREEMPTED` / `NODE_FAIL` / `BOOT_FAIL`, a workstation `REBOOT` (pid gone, no
`.rc`, a new boot id) — never `CANCELLED` (someone may have pressed cancel), `COMPLETED`, `FAILED`, `TIMEOUT`,
`OUT_OF_MEMORY` or an unknown end, and only when the plan repeats THAT attempt's bound fields (the attempt whose end it
relies on, never an older one the plan happens to be named after: such a plan is recorded as the next attempt); the
user's approval of the card covers any — so it never resumes a run only the target's journal shows: the ledger holds no
end of it to rely on (`the ledger has no earlier attempt of the run that ran`), and that is the user's call. That
default is auto-recovery; a user who hands the agent re-runs ("you decide, don't ask again", "fix the code and just
run it") says more, and a grant recorded with `scope.relaunch_after: "any"` (`rsk grant add --relaunch-after any`)
carries it (in a grant that allows `launch` too): a relaunch is then judged as a launch — scope, budgets, warnings,
flags, denies — whatever the end and the configuration (a fixed command, another target), but never while an earlier
attempt may still be live: a ledger attempt live or SUBMIT_UNKNOWN on any target, or one only the target's journal
shows (its `info_prior_here` — submit.sh's count of receipts whose `target=` is this target or absent, else
`info_prior` — counts more submissions of the run than the ledger holds there, or cannot say; the plan at most 10 min
old). Without it the
agent asked after every fixed bug, or wrote the standing grant's words down again as a card's approval (seen: one
project, ten relaunch approvals quoting two old sentences); so `--approve` words that repeat a standing grant's quote
(the same words, a part of them or them inside longer words — compared without punctuation, case or spaces, weighing
24 or more, a CJK character 2 — of a grant older than an hour: `grants.recycled`) are exit 4 for every `--approve`
(launch, cancel, `rsk watch`, `adopt --not-submitted`, `sync -D`, `bootstrap --job`), and `rsk grant add|import` FLAG a
new grant that repeats an older one's words: an approval is the answer to what is on screen. A nudge against copying, not proof: other
words still pass. Before deciding, `rsk launch` re-reads every target where the ledger counts an attempt of the run as
live (`launch.refresh`: the read `rsk status` makes), since the ledger learns of an end only from such a read — a job
that just failed was refused as a live duplicate and gave a relaunch grant no end to rely on. Run names and the tracker
follow `experiment-conventions.md`, and reading it was not enough (seen: `…--eval--<method>-final`, an origin field
holding a dataset, wandb runs with no group or job type), so `rsk launch` says it where the agent looks — as hints,
refusing only what is certain (conventions are hints, not gates). A NEW run — no ledger attempt that may have run
(a NOT_SUBMITTED one never did), no receipt in the target's journal (`info_prior` not above 0; unknown counts as new) —
whose name, as rsk resolved it and as the block prints it, is not `<task>--<stage>--<variant>--<origin>--s<seed>[--aNN]`,
or holds an opaque word (new, final, best, r2: whether `r16` is a revision or a LoRA rank is a meaning no pattern
sees), gets a NOTE and a card line and is launched as named; an existing run is not checked (its grants, lineage and
resume stay whole); `--free-name` marks a name as the user's own: unchecked, said on the card, covered as any plan. A
smoke is refused (exit 2) only when rsk can see its run reach wandb — its command's env words set another
`WANDB_MODE` or unset it, or the Slurm conf binds one that is not `disabled`, the command leaves it and nothing
applied after the conf can change it — and whatever
rsk cannot tell is a WARNING on the card, the plan going on. The command's env words are read as GNU env reads them (`launch.env_scan`, the rules of
launch.sh's `rs_gpuenv`: options first — `-v`, `-C DIR` pass, `-u WANDB_MODE` unsets it, any other is unclear —, then
every word holding `=`, then the command, `env` again read alike): a Slurm payload is an argv, so only after a first
word `env` (a bare `NAME=VALUE` there is a program name); a box line is `env`'s words from its first (launch.sh runs
`eval "_rw_go $RUN"`, `_rw_go` = `env "$@"`); unclear, so a WARNING: a box line of several commands (shell operators
or a newline split it before env runs; `$(…)` too; scanned as bash reads it, so `;<` or `|>` count and a quoted `'|'`
does not), an expansion in env's words (`$` `` ` `` `{` a glob: the eval expands it first), an env option, a box's conf
(not on its card), and a Slurm conf value that something env.sh applies after it may change, either way — an ENV_HOOK, a conda
env, or a `$PROJ/.wandb_env` naming WANDB_MODE (the block's `info_wandb_env`, submit.sh's read-only look; an older
deploy without it cannot say). A wrapper before `env` or the
payload's own code can still change it: rsk reads words, not runs. What a formal run logs is the trainer's business,
never visible to rsk: once it went out (or may have) rsk sums §4's fields up (for a run with earlier attempts:
resume the same wandb run) as a NOTE — a reminder, not a check; the fields are set before the launch. A run's class is the one its name carries (`--class` only labels a name
without one) and is set only at its first attempt: another one later is exit 2, and so is any class for a run whose
first attempt had none (a grant scoped by class never covers that run); a deny of `launch` stops relaunches and chains
too, and its name globs also match the run id. A run's attempts carry the job name `<run>--aNN`, which is what squeue,
sacct and the log show, so a user's "do not relaunch exp--a02" is naturally recorded with that name — and since an
attempt is launched once, a launch-type deny of one attempt has no other meaning than the run: a deny's names glob that
ends in an attempt's suffix (two or more digits), or in a glob that can match one (`x--a*`, `x--a0?`,
`x--a[0-9][0-9]`), also matches with that suffix removed against the plan's run id (`grants.run_glob`), so it stands for
every attempt of the run — launch, relaunch, chain, cancel, and `rsk watch` rows (a row is its run id); `x--a?`,
`x--a[0-9]`, `x--a[!0-9]*` or `--a*` cannot match an attempt's suffix and keep their plain meaning. The record keeps the
name as given; `rsk grant deny` / import say what it stands for (`NOTE: name <run>--a02 is an attempt's name (--aNN): the
deny stands for run <run> — every attempt of it, the next one included (an attempt is launched once)`), and `rsk grant
list` shows `names <run>--a02 (= run <run>: every attempt of it)`. A deny that names a run (a names glob matching the
plan's name or run id, an attempt's name standing for its run) and lists `relaunch` or `resubmit` matches EVERY
launch-type action of that run — launch and chain included — on any
target in its scope: the derived action rests on the history rsk can see, and a run's earlier attempts may be where it
cannot look (another target's journal, run-watch's state, a harness from before the journal, another checkout), so "do
not relaunch a" must also stop a plain launch of a on a target whose journal never saw it. The refusal says so (`… — a
deny of relaunching a run stops every launch of it, on any target in its scope: rsk cannot see every earlier attempt
(…)`), `rsk grant list` shows `DENY relaunch (it names a run: every launch of it too — …)`, a launch grant recorded
right after such a deny is FLAGged, and `rsk watch` meets it on a row at `(launch)`. A deny naming no run keeps the
derived action. A conditional wish ("if a fails, don't relaunch it") therefore becomes a deny only once a has run: a deny
always wins. A deny fails closed on facts it cannot see: a deny of plans (bound
hashes), names, classes, partitions or GPU types matches whenever that fact is unknown — a cancel of a job the ledger
has no plan for, an `rsk watch` row (no bound hash; its partition and GPU type are not certain, since the policy may
rewrite or force them), a run with an attempt recorded without a class. Targets are compared as normalised names
(`grants.target_key`): `fx/`, `fx/.`, `./fx` and `FX` all compare as `fx` — spellings a filesystem may resolve to the
same profile directory —; a spelling that is not one plain name may be any target and matches every target deny. A deny names what it can be
compared with: `scope.jobs` (a job id or pid) exists only at a cancel, so a deny by job id is for cancels only — `rsk
grant deny --job` with a launch action is exit 2 (a run's launches are denied by `--name '<run>'`), and such a record
already stored is invalid. `rsk grant add|deny|import` refuse a target the harness does not list (exit 2 `unknown
target`): a misspelt one would make a deny match nothing. A partition is checked against `T_PARTITIONS`, the profile's
display list (the shipped template says so; split on commas and whitespace, as `run-avail` hands it to `sinfo -p`), but
that list is not the authority: `policy.sh`'s `t_partition` decides which partitions exist and may accept one the list
omits. Round 6 refused every unlisted partition and so lost a user's deny of a real one; round 7 recorded any partition
with a NOTE, so a typo (`dbug` for `debug`) left the user's "never" unenforced with only a NOTE to show for it. The rule
now (R8-3): a partition no scoped Slurm target's list names (every target the harness knows, without `-T`) is exit 2,
nothing recorded — `partition P is not in the profile's display list (T_PARTITIONS of <t>: a, b) — nothing recorded:
check the spelling with the user …; if it is a real partition the display list omits (policy.sh decides which exist),
record it again with --unlisted-partition` —, and the caller who confirmed with the user that it is real gives
`--unlisted-partition` (an import record `"unlisted_ok": true`, never stored): then it is recorded as given, with `NOTE:
partition P is not in the profile's display list (T_PARTITIONS of <t>: a, b; <u>: none) — recorded as given: policy.sh,
not the profile, decides which partitions exist; the record matches only a plan whose partition is spelled exactly so`
(`tests/62` 'round 7 R7-2' records and enforces such a deny; 'round 8 R8-3' refuses the typo). No check, the NOTE only,
when a scoped Slurm target's profile has no `T_PARTITIONS` or only workstations are in scope (a workstation has no
partitions, so no launch there names one). A GPU type has no list anywhere: it is echoed in a NOTE, never checked.
Every list argument of `rsk grant add|deny` (targets, partitions, GPU types, classes, names, jobs, runs, actions) is
split on commas and each item stripped (`'b1, b2'` is b1 and b2: a deny keyed on ` b2` would never match `b2`); an
empty item or one with whitespace inside is exit 2, naming it — a space-separated list is not split on a guess — and
`--job` takes only job ids or pids. `validate()` rejects a stored list item with leading, trailing or inner whitespace
(`whitespace in a scope item`), so such a deny, imported or edited in by hand, is invalid and matches everything (R8-1;
cancel identities, which hold a WorkDir, are exempt). A record stored before these checks, or whose target
was removed since, would still be inert, so `rsk grant list` and `rsk status` (whose grants block is the same) flag
every active record naming a target the harness does not know — `WARNING: <id> (<kind>): target X is not one the
harness knows (…) — never matches[ there] (the user's deny is not enforced there | it covers nothing there) — fix or
revoke: …` (`--json`: `scope_problems`) — and repeat the partition NOTE for a stored record (`scope_notes`; a partition
the list lacks may be real, so it is never "never matches"), and `rsk doctor` flags the unknown targets of every ledger
under the state dir (`== grants ==`; its exit code is unaffected). A record `validate()` rejects is never described:
`rsk grant list` and `rsk status` show it as `<id>  INVALID — <what>: <why>`, and the `--json` of both as
`{record, invalid, fail_closed}` (R8-7: a hand-damaged entry — `targets: 5`, a scope that is a string, an entry that is
not an object — once crashed `rsk status --json`; `test_status`
`test_r8_7_status_never_crashes_on_a_damaged_grants_record`). A record that may be a deny but cannot be
read as one — a deny `validate()` rejects (a stored jobs + launch deny included), an id starting `d-`, a missing or damaged `kind` — is taken as a deny
matching everything until it is fixed by hand or revoked (`rsk grant list` then shows `revoked: matches nothing`); an
entry that is not an object at all, until it is removed by hand: fail closed. The same holds for the file: a `grants.json` that cannot be read at all (corrupt, no good `.prev`) may hold a
deny, so `rsk launch`, `rsk cancel` and `rsk watch --act/--approve` refuse (exit 6, `grants unreadable — rsk grant
recount / restore`); while it is recovered from `.prev` or missing, every deny `audit.jsonl` shows still counts, and
`rsk grant recount` writes those denies and the recorded revocations back; a lost grant or approval is not rebuilt
(fail closed): it needs the user's words again.
Preemption: Slurm's own requeue, a run-watch table's `#@ allow preempt=N` (its `#@ ok` line carries the user's words),
or a `relaunch` grant (after an infrastructure end, above). "Cancel job 123": the words given to `--approve` must name
what is cancelled, as a whole word (R8-2, `cancel.named` / `cancel.unnamed`): for `--job J` the job id J (the pid on a
workstation) or the run's id or job name; for `rsk cancel RUN` the run id or name, or every job id it cancels — a token
inside a longer one does not count (`101` in `1101` or `101_2`, `sw1` in `sw10`, `exp--sw1` or `sw1-b`), trailing
punctuation does (`job 101.`); a numeric range names every id in it (`102-104`, `102 to 104`, `102…104`, `102..104`,
`102~104`; both ends whole tokens, low end first: `cancel.ranges`, NF8 — "cancel jobs 102-104" had refused 102 and 104
too). Words that answer the agent's own question name what the question names: `--asked "<the question, verbatim>"`
(NF8: "sw1 (job 101) diverged — cancel it?" answered "yes" was exit 4, and the agent asked again — the second
confirmation the user's policy rules out: an authorisation already given stays valid); the approval keeps both — its
quote the words, its `source` `asked: "<question>"` — and so do the audit's `cancel` lines (`asked`). Otherwise exit 4
`needs user: the words do not name <J|RUN> — "…" names none of: …; nothing recorded or cancelled` (`"…" (answering "…")
names none of` with a question), with no approval and no ssh: "cancel job 101, it diverged" once approved and cancelled
job 102, since the identity check only proves a job is this user's and this project's, and a yes to "cancel sw1?" passed
for sw2 is refused the same way. This is a token check against good-faith slips, not proof of consent — an agent can
still write words naming any job, and the asked text is its own (it can write any question; rsk does not read whether
the answer was a yes): the honest limit of every record. Group words ("the whole sw sweep") name no run; a `cancel_own`
grant is unchanged. `--approve` then records a cancel approval naming that job and bound to the
identity it was given for (Slurm: target, job id, run name, WorkDir; workstation:
target, pid, start, boot id); it expires after an hour and is used up by the first cancel that passed authorisation,
whatever came of it (an approval is never refunded — "cancel 123" said yesterday does not cancel a new job 123), and
the identity check (name, WorkDir and user on Slurm; the receipt's pid, process start time and boot id on a workstation)
runs in the same ssh that cancels; on a workstation the receipt's start and boot id must also be the ledger's, and a
pid the ledger shows ended is checked against that run's own receipt, so a pid the box has since given to another
process is never taken for it. A ledgered run that already ended — Slurm: ended in squeue; workstation: pid gone,
reused by another process, or the box rebooted — is exit 0 "nothing to cancel … ended", its end recorded now. A
non-zero `scancel` proves nothing by itself (a request that timed out may still be applied): it is exit 5 `UNKNOWN: job
J (<run> aNN): scancel exit N (…)` — quoting scancel's line naming job id J, else its last line naming no job id, never
another job's (`cancel.scancel_line`) —, the use kept, the ledger `CANCELLING?` until `rsk status` sees the end — unless
scancel's own line for that id says `Invalid job id` or `already completing or completed`: then there was nothing to
cancel (exit 0, the ledger `COMPLETING`, a `cancel_own` use given back). `tests/vgate/slurm-remote.sh` is the
reproduction of those words (`scancel_ended=`, `scancel_invalid=`); other words stay unknown.
"Stop the rest of the group": run-watch's `#@ allow fail-stop`. The agent's own judgment: a grant with `cancel_own`,
which covers only live runs rsk launched for this project (never adopted ones, never one the ledger shows ended), its
cancels counted against `max_launches` (given back only when the answer proves nothing was signalled — never after a
timeout, an ssh failure or a signal with no answer at all, since the cancel may have run there, and that holds for ssh's
own 255 before the body's `@@start` whatever its stderr says: exit 5 `… ssh's own words are no proof that the body never
ran; the use is kept` — `tests/py/test_cancel.py` `test_r6_4_…`, whose `SSH_FALLBACK` stub runs the body behind a
refused first route). Some decisions are never a
grant's, only the user's words at the time: a GPU another job is using, a policy flag the user must ask for
(`--*-user-asked`), a second live copy of a run (`--same-name-ok`), a remote delete (`rsk sync -D`, read with
run-sync's own grammar: `--also -n` is a path, not a dry run) and a job no card showed (`rsk bootstrap --job`) — those
two run only with `--approve`; and nothing ever covers someone else's job or process, a policy refusal
or a new conda env. Sweeps and chains cost one question; a plan that drifted between card and submit (`--rs-expect`)
costs a new card, never a silent submit.

**P7: one path.** With rsk installed, `bin/run-launch` called directly prints `use: rsk launch -T <t> …` and exits 2
(rsk sets `RS_VIA_RSK=1`; installed = on PATH or in `uv tool dir --bin`; a Slurm target is pointed at `rsk launch` too),
and `bin/run-watch … --act` or `--approve` prints `use: rsk watch …` and exits 2 the same way (watching without them
stays direct); installed without rsk both keep working, with a NOTE, and the skill's
bash fallback checks the user's words in the conversation, with no ledger to keep them. `rsk doctor --legacy-refs`
lists project docs that still teach the old skills or raw `ssh … submit.sh` / `run-launch` recipes. Both steer;
neither is a guard.

**The honest limits.** A grant or approval record is bookkeeping, not proof of consent: its quote is whatever the agent
wrote as the user's words, and an agent can write anything — the rails (show the card, wait for the user's words,
record only what they said, never widen a grant) are what make it the user's decision. rsk constrains only the actions
that go through it: an agent with ssh can still type `sbatch`, `scancel` or `kill`, and `submit.sh` cannot tell who
called it (its policy refusals and guards still hold). `rsk sync -D` and `rsk bootstrap --job` take only the user's
words (`--approve`, recorded in the audit log with the command line); the other `rsk sync|bootstrap|pull|avail` calls are
thin wrappers with no check: rails only. A run-watch table's `#@ ok` is a second store of approvals, kept by bash; `rsk
watch` adds the lease and binds run-watch to the user's denies: with `--act` (or `--approve`) every row — target,
GPU count, time, name / run id, class; its partition and GPU type are never certain (the policy may rewrite `-p` or
force a type), so a deny scoped by them matches every row of its target, and a deny of plans every row in its scope (a
row has no bound hash) — is checked against them for every action run-watch could take on it (launch, relaunch,
resubmit, chain, cancel), whatever the table's `#@ allow` says (`--release` and an `SBATCH_EXTRA` singleton act outside
it) — only a deny scoped by job ids, which is for cancels, counts just for a table whose `#@ allow` has `fail-stop` (the
one cancel run-watch makes), and there it matches every row, the row's job not being known —, before anything starts and
again at every lease refresh (a new matching deny stops run-watch with TERM, exit 3).
That row check is static: it reads the row's words, never what the target's policy makes of them, so a policy that
rewrites `-p` (or forces a GPU type) is not seen by `rsk watch`'s row check — which is why such denies match every row of
the target, and what a job really got is squeue's. A row's target is compared as a normalised name too, and run-watch
itself refuses (exit 2) a target that is not a name `rs_targets` lists, spelled exactly.
run-watch also stops itself (exit 7) once the `rsk watch` that started it is gone (`RS_WATCH_PARENT`, checked every
round, after each read and before each submit or cancel ssh), so an orphan whose `rsk watch` was killed outright acts no
further — its lease and its deny checks went with it; until it notices, its lock makes `rsk watch` exit 6. A bare
`run-watch` (installs without rsk) reads no ledger, and run-watch's runs never enter it: `rsk status` lists them as
run-watch's, and `rsk launch` sees them only through a plan's `info_prior` (which makes a plan of the same run a
`relaunch`, so a deny of relaunches holds) — a relaunch grant still never resumes one.

What rsk cannot check, in one place (each is also said where it applies; anything that only contrived input or
arbitrary payload code reaches is listed here rather than chased further):
- **the payload is code — what it does once it starts is outside what rsk can check**: the workstation check of RUN is
  a check of its words, not of the payload — scripts it calls (one that itself calls tmux or sudo), an `exec -c` the
  text does not show at a command start, a value only an expansion supplies at run time (`x | env $PRE y`);
- tools that replace the environment beyond the warned list (`su -`, `runuser -l`, `pkexec`, at / cron, a script that
  itself calls tmux) and tools not on that list that start the command elsewhere or anew (`byobu`, `lxc` / `incus exec`,
  `ray job submit`, `mpirun` / `mpiexec` `--host` / `--hostfile`, `su -l`, `pixi run --clean-env`, `run0`); tmux
  commands run from a user `command-alias`, a `-f` config, `source-file` or `set-hook` (launch.sh reads RUN's text, not
  tmux's config); a sudoers `env_delete` (not read: `sudo -E` is taken to keep the GPU variables); a docker daemon
  whose default runtime is nvidia (an image's own `NVIDIA_VISIBLE_DEVICES` then hands the container GPUs with no flag at
  all: `tests/vgate/containers.sh` prints `docker_default_runtime=`);
- a GPU value or launcher flags that only an expansion or a script supplies (the wrapper re-checks only the first
  command's expanded leading words, for the GPU variables), and launcher settings in files rsk does not read: docker
  `--env-file`, compose files, deepspeed's `.deepspeed_env`;
- the launcher, config, container and tool checks read RUN's text, so they can fire on a word that is only an argument
  (`rsync -e ssh`, an `exec` inside `docker run … sh -c`) — fail closed, the card shows why — and they are warnings: the
  user's approval of the card lets such a run through (never a grant: `warnings_gpu`);
- a standing launch grant still covers the first launch, on another target, of a run whose earlier attempts rsk cannot
  see (run-watch's on another target, a history from before the journal or only in sacct) unless a deny names that run:
  the cross-target rule is the deny's, not the grant's;
- `rsk watch`'s row check is static (above), and a table's `#@ ok` is checked by run-watch (bash), never by the ledger;
  rsk and run-watch read a table's bytes the same way (lines end at LF, words split at space / tab, and both refuse a
  NUL or another control character but tab), so what still differs between their readings errs toward checking more:
  rsk may check rows or `#@ allow` words run-watch never acts on, or accept a line run-watch then refuses (exit 2,
  nothing run);
- two detect-only run-watch processes started within the same instant over a stale `logs/run-watch/.lock` (its holder
  dead) can both take it; acting ones go through `rsk watch`, whose lease serialises them — run one watcher per project,
  through `rsk watch`;
- an older installed run-watch is transitional: it reads only the last `#failstop` of a state file (and drops
  `#failstop-released`), refuses `#@ ok … conf=` lines and, run on its own, accepts a table both current tools refuse
  (it strips one CR per line and bash `read` drops NUL bytes) — one harness version per project (`rsk update`, then `rsk
  setup`);
- anything that does not go through rsk: a raw `sbatch`, `scancel` or `kill`, a `run-watch` installed without rsk — rsk
  constrains only what goes through it.

Nothing here guarantees that an agent complies. What it does guarantee is
narrower and checkable: an action that goes through rsk is checked against the recorded decisions before it happens,
every use is counted against its limits under a lock, denies win, a lost reply is never resubmitted blind, and the
ledger shows what was done under which words.

## Monitoring (`remote/status.sh`)

Agents are expensive readers. `status.sh` is the single monitoring read: scheduler state (or PID liveness on a
workstation), harness markers, error/OOM/NaN hint counts and the last lines, all from byte-bounded windows
(last 256 KiB for hints, last 64 MiB for markers), in about 2 KB. Hints are counts, not diagnoses; "0" over a
partial window is reported as such. A checkpoint directory's newest entry is reported as *activity*, never as proof
that a run resumed. The skill describes cadence as a policy — review closely when a run is young, restarting or
anomalous; widen the interval only on evidence — rather than as a timetable, and require the agent to say how it
will wake up next instead of promising unattended monitoring. A workstation run's wrapper writes its end as
`<log>.rc` (`rc= term= at=`), which `status.sh` reads once the pid is gone; rc is always 0–255. After a TERM, bash's
`wait` returns 143 when the trap interrupts it, and once the run is gone a second `wait` should give the run's own
status — but under load bash 5.2.37 returned -1 there (3 of 60 group TERMs), which no reader can parse, so a second wait
that gives 127 or a value outside 0–255 keeps the 143 (`tests/61`, opt-in: `RS_STRESS_TEST=1 bash selftest.sh` keeps
every core busy for about a minute and checks 40 such TERMs; a plain selftest lists it among its SKIP lines).

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
observation path and, through `rsk launch` / `rsk cancel`, its checked path for acting. Since an agent lists every
installed skill by its description, a leftover `hpc-run` next to `remote-run` would compete with it on stale text:
`install.sh` removes the old copies it generated in the shared root
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
an optional list of forbidden words keeps private names out of the repo. `rsk` itself has unit tests (`tests/py/`) and
an end-to-end section (`tests/62-rsk-launch.sh`) in which an executing ssh stub runs the deployed scripts locally.

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
  The terminal sacct row must also name the row (JobName) and this project's WorkDir (`pwd` or `pwd -P`; any other
  spelling of it is a mismatch, which fails closed): a job id that now belongs to another job, or to another project's
  job of the same name, is held (`job-identity-mismatch`), never settled or resubmitted on; the submit ssh checks that
  job's name and WorkDir again (`prev-identity`).
- **Act only on an approval that can go stale.** The table's `#@ allow` line is the budget (no defaults); `#@ ok`
  carries a checksum of that line plus its block of rows, written by `--approve` with the user's words. The checksum
  only stops edited or appended rows (and raised budgets) from inheriting an old approval — it cannot prove that the
  user agreed; the skill rail (show the rows and budget, wait for the OK) does that.
- **Never guess a submit outcome.** One row per submit ssh; no `+ sbatch` line from `submit.sh` = refused before
  sbatch (budget refunded); a receipt = submitted; anything else is a sticky `submit-unknown` that only `--adopt` or
  a user-approved `--release` clears (the attempt journal's `refused`/`failed`/`planned` = nothing queued). CANCELLED is
  never resubmitted (someone may have pressed cancel). An unknown submit is sticky across tables too: one held by ANY
  other state file of the project (its attempt nonce) makes the row submit-unknown even when the row has its own state,
  unless that state already settled the attempt (the same nonce, or a newer submit of its own); the next read settles
  it from the attempt journal (a receipt: `ADOPT`; nothing queued: the row's own status back), and until then further
  submits wait (`submit-unknown-elsewhere`).
- **A row is one run by its name, on its target.** A table renamed or copied takes the row's state from the other
  `logs/run-watch/*.state` files — spent budgets never fewer than any of them holds, so a new file name never resets a
  budget — but status and job ids only from a state line of the row's own target: every state line records its target
  (an older line without one follows its jobs only when its file watched exactly one target, that one, and the row was
  not removed; else its target is unknown and its live job is found again by name and WorkDir), and a job on another
  target is never followed (only its spent budgets and an unknown submit carry over; a row whose target is edited drops
  its jobs and becomes pending). A row's words never carry `--rs-*`. Its target is a plain name `rs_targets` lists,
  spelled exactly (anything else is exit 2, nothing written or run): a spelling the filesystem still resolves
  (`fx-slurm/` finds the same profile and deploy dir) would evade an `rsk -T fx-slurm` deny that compared raw strings.
- **Fail-stop goes with the rows, and cancels only under `--act`.** Every round, every fail-stop in any state file whose
  lines name one of a table's rows (renamed, copied, or sharing rows; a removed row's line too) stops that table too and
  hands over that row's pending cancel — renaming a stopped table must not resume the group, nor may a row's own newer
  state hide the stop; a state file that cannot be read for its stop holds every submit that round. A table keeps every
  stop that holds it as a set (its own and each inherited one, `also-held-by=`), each with its own pending cancels, and
  still forms its own stop when one of its rows fails while another group's holds it. `--release <trigger>` clears only
  the stops that name triggered, with their pending cancels, in every table of the watch that holds one, even where the
  trigger is not one of its rows, and records `#failstop-released` so the same stop is not taken again from another file
  (an older run-watch drops that line and may take it again: fail closed); while another stop remains every row stays
  held, the trigger's own too (`held-by=`, `reason=release-held`), so one release never resumes rows another stop holds.
  A `--release` is the user's OK for one submit past the holds that exist when the watch starts: a fail-stop that holds
  the row's table later in the same watch, before the release was used — formed by a row failing, or taken from another
  state file (a row of a stopped group added and approved mid-watch) — withdraws it (`ATTENTION …
  reason=release-withdrawn fail-stop=<trigger>`), and nothing is submitted past that stop: `--release` again, with the
  user's OK. A release can wait a round (one submit per target per round), so a stop can come first.
  A run-watch from before stop sets reads only the last `#failstop` of a file (each stop is written with its own
  `#failstop-pending`, so the pair it reads is one stop's own) and writes the file back with that one: one harness
  version per project. A row whose submit was unknown at the stop is cancelled once it is tracked, but only by an `--act` run and only
  while the table's approved `#@ allow` still has `fail-stop` (a detect-only run reports `why=no-act`; approving the
  table without it drops those pending cancels, the stop itself still holding the group until `--release`).
- **One watcher per project.** A second run-watch exits 6 naming the lock's holder (pid, host, start, act); a lock
  on another host is never broken. A run-watch that `rsk watch` started stops (exit 7) once that rsk is gone, so a
  killed `rsk watch` never leaves an orphan acting without its lease and deny checks. Numbers in flags, `#@ allow`, `after=` and `--adopt` are base 10 (`0060` is 60:
  shell arithmetic would read it as octal). A table header or `#@ ok` line this copy cannot read is refused, naming a
  newer run-watch as the likely writer; an installed copy from before `conf=` binding refuses those ok lines as
  malformed (and an older one reads the newer state files as lost), so the installed harness is updated (`rsk update`, `rsk setup`), never the line.
- **One table, one reading.** rsk's deny check and run-watch must see the same rows: bash `read` drops a NUL byte that
  Python keeps, and Python's `splitlines()` ends a line at characters bash does not, so a NUL inside `fail-stop` hid the
  stop from rsk's row check (a deny by job id, which counts only under `fail-stop`, was skipped) while run-watch acted
  on it. Both now refuse (exit 2, the same words: `<table>: line N holds 0xHH, a NUL
  byte or a control character other than tab — a run-watch table is plain text (LF line ends); rsk and run-watch both
  refuse it`) a table holding a NUL or any control character but tab — a CR too, so a CRLF table, which run-watch used to
  accept by stripping the CR, is refused now —, `rsk watch` in every mode before the lease, run-watch at every read (a
  byte written in during a watch ends it, exit 2); and rsk reads lines at LF and words at space / tab only, as bash
  does. The `--approve` words are held to the same bytes (no double quote, newline or control character but tab; UTF-8
  is fine).
- **Report, never interfere**: requeue storms, stalls (log mtime) and a missing resume line are events only.

