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
(busy → warning, `-y` to queue anyway), a lint of `SBATCH_EXTRA` that reads its words as that scan does (an option's
separate value, `--comment -t1`, is never linted as an option), and finally `sbatch --requeue`.
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
other wording stays unknown: fail closed); and `launchers.sh` reads the
launcher facts behind the workstation's launcher WARNING back from an installed deepspeed / accelerate, launching
nothing (`ds_abbrev ds_short ds_alias ds_ignores_cvd ds_hostfile`, `acc_hyphen acc_abbrev acc_sets_cvd`). Both run only
with the user's OK, e.g. `ssh <alias> 'bash -s <dir>/.venv/bin/python' < tests/vgate/launchers.sh`; `tests/88-vgate.sh`
checks their plumbing on stubs and fake modules.

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
for a workstation the GPU request rather than the ids picked, and the occupants of the busy GPUs its landing accepts,
`busy_ok=<id>:<uuid>:<user>,…`) with `bound_hash`, the sha256 of those lines. The envelope (free GPUs now, which ids a
pick chose, file hashes, the source commit, the warnings; on a workstation `info_run_gpu=checked`, below; and
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
and backslashes removed. A rule on the text cannot tell code from data, so a mention as data (`--note
"CUDA_VISIBLE_DEVICES=0"`) is refused too; reading them (`$NAME`, `printenv NAME`) is fine. When the first command shows
it only after expansion, the wrapper checks the expanded words and never starts the payload. The plan says so with
`info_run_gpu=checked`, and rsk requires that line (an older deploy: `needs: sync`). Launchers that pick GPUs from their
own flags are the other way past the landing: deepspeed's runner, given `--include`, `--exclude`, `--num_gpus`,
`--num_nodes` (or a hostfile), drops `CUDA_VISIBLE_DEVICES` and numbers the GPUs itself, and `accelerate launch` sets it
from `--gpu_ids` (their source; `tests/vgate/launchers.sh` reads it back from an installed copy). They are ordinary
commands, so `launch.sh` does not refuse them: their GPU flags (deepspeed's also as argparse prefixes, `-H`,
`--master_addr`, `--num_accelerators`; accelerate's `--num_processes` too, both spellings) print a counted WARNING naming
the launcher, the flags and the landing — on the card, so only the user's approval of it, or a grant of kind `any`, covers
it. This is a check of RUN's words, not of the payload: the payload is code, and what it does once it starts — set its
own environment from a script it runs, take a value only an expansion inside a later command supplies (`x | env $PRE
y`), read accelerate's config file or deepspeed's `/job/hostfile` and `.deepspeed_env` — is outside what rsk can check.

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
still refuses drift. A Slurm submit whose ssh never opened the session is the same proof from the other side: ssh's own
exit 255, no answer at all, and ssh's own words for it (`Connection refused` / `timed out`, `No route to host`, `Could not
resolve hostname`, `Permission denied (…)`, `Host key verification failed`) — exit 5 `<t> not reached — nothing sent`,
`NOT_SUBMITTED`, the use back and the plan free again; any other 255 may have run there and stays unknown (the words:
`tests/py/test_cancel.py` `SshWords`, from the local ssh client; the submit: `test_launch.py` Round5
`test_r5_6_a_submit…`, `tests/62` 'R5-6 for rsk launch'). On a workstation rsk reads the journal before deciding, whatever the exit: a receipt whose gate
said go is a launch (a `launch.sh` killed after that point still started the run, and the use is kept); only the
journal's refusal or failure with no receipt, `launch.sh`'s own exit with no attempt dir (it claims one first) or a
taken attempt name (75), or `run-launch` ending before its launch ssh proves nothing started; anything else (ssh 255, a
signal, a journal that cannot be read) stays `SUBMIT_UNKNOWN` for `rsk status` to settle.

The rows "charged partition / more resources / wider scope" fall out of the predicate, and when in doubt a grant does
not cover. A plan with warnings (a `-y` gate) is covered only by a grant whose `allow_warnings` kind covers them:
`availability` covers a plan whose only warnings are the harness's own availability gate (`warnings == warnings_avail`:
the cluster is busy, queue anyway), `any` covers every `-y` gate, a policy's charged-partition warning included — and is
recorded only when the user's words say so (`rsk grant add --allow-warnings availability|any`, a bare flag is a usage
error; an older record's `true` reads as `any`). rsk sends `-y` only when the
approved card showed warnings or the covering grant's kind covers the plan's warnings, and the target checks they are
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
end of it to rely on (`the ledger has no earlier attempt of the run that ran`), and that is the user's call. A run's class is the one its name carries (`--class` only labels a name
without one) and is set only at its first attempt: another one later is exit 2, and so is any class for a run whose
first attempt had none (a grant scoped by class never covers that run); a deny of `launch` stops relaunches and chains
too, and its name globs also match the run id. A deny fails closed on facts it cannot see: a deny of plans (bound
hashes), names, classes, partitions or GPU types matches whenever that fact is unknown — a cancel of a job the ledger
has no plan for, an `rsk watch` row (no bound hash; its partition and GPU type are not certain, since the policy may
rewrite or force them), a run with an attempt recorded without a class. Targets are compared as normalised names
(`grants.target_key`): `fx/`, `fx/.`, `./fx` and `FX` all compare as `fx` — spellings a filesystem may resolve to the
same profile directory —; a spelling that is not one plain name may be any target and matches every target deny. A deny names what it can be
compared with: `scope.jobs` (a job id or pid) exists only at a cancel, so a deny by job id is for cancels only — `rsk
grant deny --job` with a launch action is exit 2 (a run's launches are denied by `--name '<run>'`), and such a record
already stored is invalid. `rsk grant add|deny|import` refuse a target the harness does not list (exit 2 `unknown
target`): a misspelt one would make a deny match nothing. A record that may be a deny but cannot be
read as one — a deny `validate()` rejects (a stored jobs + launch deny included), an id starting `d-`, a missing or damaged `kind` — is taken as a deny
matching everything until it is fixed by hand or revoked (`rsk grant list` then shows `revoked: matches nothing`); an
entry that is not an object at all, until it is removed by hand: fail closed. The same holds for the file: a `grants.json` that cannot be read at all (corrupt, no good `.prev`) may hold a
deny, so `rsk launch`, `rsk cancel` and `rsk watch --act/--approve` refuse (exit 6, `grants unreadable — rsk grant
recount / restore`); while it is recovered from `.prev` or missing, every deny `audit.jsonl` shows still counts, and
`rsk grant recount` writes those denies and the recorded revocations back; a lost grant or approval is not rebuilt
(fail closed): it needs the user's words again.
Preemption: Slurm's own requeue, a run-watch table's `#@ allow preempt=N` (its `#@ ok` line carries the user's words),
or a `relaunch` grant (after an infrastructure end, above). "Cancel job 123": `--approve` records a cancel approval
naming that job and bound to the identity it was given for (Slurm: target, job id, run name, WorkDir; workstation:
target, pid, start, boot id); it expires after an hour and is used up by the first cancel that passed authorisation,
whatever came of it (an approval is never refunded — "cancel 123" said yesterday does not cancel a new job 123), and
the identity check (name, WorkDir and user on Slurm; the receipt's pid, process start time and boot id on a workstation)
runs in the same ssh that cancels; on a workstation the receipt's start and boot id must also be the ledger's, and a
pid the ledger shows ended is checked against that run's own receipt, so a pid the box has since given to another
process is never taken for it. A ledgered run that already ended — Slurm: ended in squeue; workstation: pid gone,
reused by another process, or the box rebooted — is exit 0 "nothing to cancel … ended", its end recorded now. A
non-zero `scancel` proves nothing by itself (a request that timed out may still be applied): it is exit 5 `UNKNOWN: job
J (<run> aNN): scancel exit N (…)`, the use kept, the ledger `CANCELLING?` until `rsk status` sees the end — unless
scancel's own line for that id says `Invalid job id` or `already completing or completed`: then there was nothing to
cancel (exit 0, the ledger `COMPLETING`, a `cancel_own` use given back). `tests/vgate/slurm-remote.sh` is the
reproduction of those words (`scancel_ended=`, `scancel_invalid=`); other words stay unknown.
"Stop the rest of the group": run-watch's `#@ allow fail-stop`. The agent's own judgment: a grant with `cancel_own`,
which covers only live runs rsk launched for this project (never adopted ones, never one the ledger shows ended), its
cancels counted against `max_launches` (given back only when the answer proves nothing was signalled — never after a
timeout, an ssh failure or a signal with no answer at all, since the cancel may have run there; ssh's own 255 with no
answer and its words that the session never opened — `Connection refused` / `timed out`, `No route to host`, `Could
not resolve hostname`, `Permission denied (…)`, `Host key verification failed` — is that proof: `not reached — nothing
sent`, exit 5, the use back; a cancel approval stays used even then, the user's words were for that one cancel). Some decisions are never a
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
it), before anything starts and again at every lease refresh (a new matching deny stops run-watch with TERM, exit 3).
That row check is static: it reads the row's words, never what the target's policy makes of them, so a policy that
rewrites `-p` (or forces a GPU type) is not seen by `rsk watch`'s row check — which is why such denies match every row of
the target, and what a job really got is squeue's. A row's target is compared as a normalised name too, and run-watch
itself refuses (exit 2) a target that is not a name `rs_targets` lists, spelled exactly.
run-watch also stops itself (exit 7) once the `rsk watch` that started it is gone (`RS_WATCH_PARENT`, checked every
round, after each read and before each submit or cancel ssh), so an orphan whose `rsk watch` was killed outright acts no
further — its lease and its deny checks went with it; until it notices, its lock makes `rsk watch` exit 6. A bare
`run-watch` (installs without rsk) reads no ledger, and run-watch's runs never enter it: `rsk status` lists them as
run-watch's, and `rsk launch` sees them only through a plan's `info_prior` (which makes a plan of the same run a
`relaunch`, so a deny of relaunches holds) — a relaunch grant still never resumes one. The workstation check of RUN is a
check of its words, not of the payload: the payload is code — what it does once it starts is outside what rsk can check
(a script it runs, a value an expansion supplies to a later command, a launcher's config file or hostfile), and a
launcher's GPU flags are only a warning. Nothing here guarantees that an agent complies. What it does guarantee is
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
- **Report, never interfere**: requeue storms, stalls (log mtime) and a missing resume line are events only.

