# AGENTS.md

Guidance for Codex and other coding agents — and, via the `CLAUDE.md` symlink, Claude Code — working in this repo.

## What this repo is

One agent skill, `remote-run` (Slurm clusters + GPU workstations; it replaced the `hpc-run` / `ws-run` pair), plus the bash
harness it drives, shipped as the uv tool `remote-run` whose command `rsk` (`src/remote_run/`, standard library only, Python
>= 3.11) installs and updates it and is the agent's path for every read, launch and cancel; the README has the user-facing story, `INSTALL.md` the runbook an agent follows to install
it for a user (shipped to the harness dir; tested by `70-docs`). MIT, public. Edit the clone only — the tool env, `~/.agents/run-skills`
and `~/.agents/skills/remote-run` are generated (`uv tool install` + `rsk setup`, which runs `install.sh` from the wheel's copy of the
harness). The reasons behind the constraints below: `docs/DESIGN.md`; target packs: `docs/packs.md`.

## Commands

```bash
bash selftest.sh           # the only test suite, offline (stubbed sbatch/sinfo/scontrol/squeue/ssh/uv/rsync): phase A =
                           # tests/NN-*.sh on fixture targets in a temp RS_USER_DIR; phase B = targets/*/tests.sh (+ the
                           # packs' and the overlay's tests{,.local}.sh). Prints "===== RESULT: N pass, M fail =====", exit M. Run after ANY edit.
bash install.sh            # copy to ~/.agents/run-skills, ONE skill copy in ~/.agents/skills (+ ~/.claude/skills symlink), INDEX, hpc-run/ws-run uninstalled, forwarders, selftest
uv tool install --editable . && rsk setup   # the same through rsk, from this clone (edits are live; re-run setup after them)
bash tests/pkg-wheel.sh    # NOT in selftest (uv + network once): wheel contents, uv tool install from git, setup, update, rollback
```

`rsk` (`src/remote_run/`): `cli.py`; `install.py` (how it was installed: PEP 610 `direct_url.json` + `uv-receipt.toml`
→ update commands); `packs.py`; `harness.py` calls `lib/common.sh` / `install.sh` (targets, conf → remote dir) — never a
second implementation in Python; `observe.py` + `status.py` (`rsk status` / `rsk logs`: read-only, one ssh per target,
discovery by WorkDir / `logs/*.pid`; a failed read is UNOBSERVABLE, never "no jobs"; also the ledger's runs, unledgered jobs,
SUBMIT_UNKNOWN reconciled from the remote journal); `ledger.py` + `grants.py` (the per-project ledger and the one authorisation
record type, below); `launch.py` (`rsk launch`), `cancel.py` (`rsk cancel`), `watch.py` (`rsk watch` = the lease around
`bin/run-watch`), `adopt.py` (`rsk adopt`), `wrappers.py` (`rsk sync|bootstrap|pull|avail` exec `bin/run-*`, no logic), `legacy.py`
(`rsk doctor --legacy-refs`); `errors.py` = the exit codes (0 ok 1 failed 2 usage 3 refused 4 needs user 5 unknown 6 conflict 7 lease
ended 8 placement). The wheel force-includes the harness under `remote_run/_harness/` (`pyproject.toml`): a new top-level dir the
harness needs at run time goes there too, and `tests/pkg-wheel.sh` lists what must be in it (`install.sh` copies every dir the docs name under `~/.agents/run-skills`: 70-docs). Unit tests: `tests/py/`
(run by `tests/90-py.sh` with an isolated interpreter, scratch HOME and RS_* dirs; python < 3.11 = SKIP in a clone, FAIL only packaged);
`tests/62-rsk-launch.sh` runs the real CLI end to end (plan → card → approve / grant / deny, drift, sweep, lost reply, cancel identity,
busy GPUs, the lease) against the fixture targets through an *executing* ssh stub, so the deployed submit.sh / launch.sh do the work.

Hard rules: never commit generated files (they exist only in installed copies); this repo is public and ships **no
site at all** — no cluster/host/site name, user id, account, group path or personal policy gate, not even in a
test's word list or a comment (sites live in target packs or the user's overlay; tests use fixtures). The selftest
greps the repo for the overlay's private `forbidden-words` patterns (the list itself stays out too); never
hardcode the check count.

## Architecture

### Three layers

1. **`skills/remote-run/SKILL.md`** (thin, both kinds; everything through `rsk`: reads first, `rsk launch` / `rsk cancel` check the
   user's authorisation; a brief bash fallback for installs without rsk) + `references/`: `INDEX.md` (line 1
   `root:` = harness dir, one row per target with a `kind` column, Routing rules; a stub that `install.sh` regenerates with
   `rs_gen_index`), `procedure-slurm.md` / `procedure-nohup.md`, `conf-keys.md` (both confs), `experiment-conventions.md` (run classes,
   naming, wandb mapping, checkpoint/resume), `project-setup.md` (onboarding) — ONE copy each. The agent reads INDEX, then exactly one `targets/<t>/reference.md`.
2. **Local:** `bin/run-sync`, `bin/run-pull`, `bin/run-bootstrap`, `bin/run-launch` + `lib/common.sh` (sourced; never deployed);
   `bin/run-avail` (free GPUs on every target before an open placement: one parallel read-only ssh each, one deadline);
   `bin/run-probe` (INSTALL.md's discovery: ssh hosts, one read-only BatchMode probe, wandb key state; `tests/85-probe.sh`);
   `bin/run-watch` (batch watch of a run table: one read-only ssh per target per round, events, state in `logs/run-watch/`
   — each line names its target: status/jobs carry over only on the same target, unknown submits and (every round)
   every fail-stop from any state file naming the row (a table keeps all of them; `--release` clears only its trigger's);
   row targets: exact `rs_targets` names, else exit 2; acts only with `--act` on `#@ ok`-approved rows within `#@ allow`; one per
   project, lock → exit 6; `--act` / `--approve` without `RS_VIA_RSK` while rsk is installed → `use: rsk watch …`, exit 2;
   exit 7 in every mode once `RS_WATCH_PARENT` (rsk watch's pid) is gone or no longer its parent; `tests/47-watch.sh`).
   Prologue: `RS_HOME=$(cd "$(dirname "$0")/.." && pwd)`; `TARGET` (aliases `CLUSTER`/`STATION`) → `rs_load_target`.
3. **Remote:** `remote/env.sh`, `remote/bootstrap.sh`, `remote/status.sh` (both kinds; status.sh = the agent's one bounded
   monitoring read), `remote/submit.sh`, `remote/job.sbatch` (slurm),
   `remote/launch.sh` (nohup), deployed by `run-sync` with the target's `profile.sh` (+ `T_NAME='<t>'` and `T_REF` = `rs_ref`,
   the local reference path(s) that submit.sh/status.sh re-print, appended), `policy.sh`, the user's `policy.local.sh` and,
   written last, `MANIFEST` (`<sha256>  <file>` per deployed file). Remote scripts never source `lib/`; `env.sh` and `bootstrap.sh`
   carry the same resolver (`TARGET` → `$PROJ/.<t>` if it exists else `$PROJ/.ws` → `profile.sh` → conf → `profile.sh` again: the site's `T_*` win).

### Where each script runs

| | local (cwd = project root) | on the target |
|---|---|---|
| slurm | `run-sync`, `run-pull`, `run-bootstrap` (ssh wrapper) | `<REMOTE_DIR>/.<t>/{API,env.sh,bootstrap.sh,status.sh,submit.sh,job.sbatch,profile.sh,MANIFEST[,policy.sh,policy.local.sh]}`; submit = `ssh host 'bash …/.<t>/submit.sh …'` |
| nohup | `run-sync`, `run-pull`, `run-bootstrap`, `run-launch` (one ssh) | `~/<WS_REMOTE_DIR>/.ws/{API,env.sh,bootstrap.sh,status.sh,launch.sh,profile.sh,MANIFEST}` |

Every file copy goes to `rs_xfer_host` (the profile's `T_XFER_HOST`, a site fact with no conf key, else the ssh
host), every ssh to `rs_host`: a transfer node's restricted shell takes rsync only, so `run-pull` never sshes.
An edit to `remote/*` reaches a project only after `install.sh` **and** a re-sync. Logs: slurm `logs/<name>_<jobid>.out` (line 1 `rs-attempt=`
before env.sh, header `target= job= restart=N node=… attempt=`, footer `EXIT rc=N`; submit.sh prints the path), nohup `logs/<name>-<timestamp>.log` + `.pid`.
`status.sh <jobid|log> [ckpt-dir]` (squeue/sacct or the PID, last 256 KiB → hints + last lines, last 64 MiB → harness start/exit markers,
~2 KB output) is the monitoring read. `ckpt_entry` is directory activity, never proof of resume; log reads are byte-bounded.

### Targets: discovery, packs and overlay (`lib/common.sh`)

`rs_roots` (highest first) = `$RS_USER_DIR/targets/` (default `~/.config/run-skills/targets`) → each
`$RS_PACKS_DIR/<pack>/targets/` (default `$RS_USER_DIR/packs`, glob order) → `$RS_HOME/targets/` (templates only).
`rs_targets` = dirs with a `profile.sh` under any root, `_*` skipped, sorted unique; `rs_target_dir` = the first root
that has one. A pack (and `$RS_USER_DIR`) may add `routing/remote-run.md`, appended verbatim to the INDEX Routing section — else its
legacy `routing/hpc-run.md` + `ws-run.md` (never required to rename), each rule under a kind lead-in (`rs_legacy_routing`). A user dir **with** `profile.sh` replaces a pack's target; one
**without** extends it (`policy.local.sh` sourced by submit.sh after `policy.sh`, `reference.local.md` appended to
the INDEX row, `tests.local.sh` in phase B). `rs_load_target` unsets every `T_*`, sources the profile, sets
`T_NAME T_TAG T_DIR T_LOCAL_DIR`, validates `T_KIND`/`T_HOST`, refuses the name `rs` (`.rs/` is the journal). Tag = `rs_tag NAME` (alnum only, uppercased:
`ws-box` → `WSBOX`) — no knob. `profile.sh` is POSIX data: single-quoted paths, only `$HOME`/`$USER` expand, on the
remote (`rs_path`). Consumers: sync excludes (`.<name>/` + literal `.ws/`), INDEX, the linter, install, phase B.

### Config precedence

`.hpc.conf` / `.ws.conf` are **sourced as shell**. Resolution, highest first: CLI flag → `<TAG>_KEY` → `KEY` →
default (`ovr KEY [DEFAULT]`, eval-based). Prefixable: `RS_PREFIXABLE_SLURM` / `RS_PREFIXABLE_NOHUP` (+ the
profile's `T_CONF_KEYS`); `DEFAULT_PARTITION`/`DEFAULT_GPU_TYPE` are prefixed-only (generic ignored, profile
`T_DEFAULT_*` is the fallback); `ENV_KIND ENV_HOOK BOOTSTRAP_HOOK UV_SYNC_ARGS WANDB_MODE EXTRA_EXCLUDES SYNC_ALSO
REMOTE_HOST DEFAULT_CLUSTER DEFAULT_STATION WS_REMOTE_DIR` are generic-only; `rs_lint_conf` warns (`not honoured`)
on any other `<TAG>_KEY` line. Remote dir: slurm `ovr REMOTE_DIR` (tagged form mandatory when `T_REMOTE_DIR_REQUIRED=1`);
nohup `<TAG>_REMOTE_DIR` else `WS_REMOTE_DIR` — never guessed. Jobs go out with `--export=ALL`, so every local /
login-node reader `unset`s the keys it reads (generic + `<TAG>_`) before sourcing the conf (`rs_load_conf KEY...` in
bin/*, submit.sh's list); env.sh trusts that cleared environment. Extend those lists when adding a key. submit.sh sources the
conf (after profile.sh) in a child `bash --noprofile --norc` and imports only that list as NUL-separated data, never eval'd: a conf's function/alias/PATH never reaches the policy.

### The fail-closed sentinel — preserve this shape

`remote/env.sh` is *sourced* (bash or zsh, never `set -e`); its body is one function whose every failure is
`_rs_fail MSG; return 1` (`env.sh: … — refusing to continue`) and whose last lines export `RUN_ENV_READY=$PROJ` plus
the kind's legacy sentinel (`HPC_ENV_READY` | `WS_ENV_READY`). Every consumer does `unset RUN_ENV_READY HPC_ENV_READY
WS_ENV_READY CONDA_DEFAULT_ENV` → source → require `RUN_ENV_READY == $PROJ`, then verifies the env materialised:
`job.sbatch` needs `$UV_PROJECT_ENVIRONMENT/bin/python` (`uv venv missing`; waived only for the payload `bash $PROJ/.<t>/bootstrap.sh`
= `run-bootstrap --job`) or `CONDA_DEFAULT_ENV == ENV_NAME` (`ENV_KIND=none`: nothing); `launch.sh`'s env subshell needs `python -ef $RS_VENV/bin/python` (`uv venv not active`) or the conda env active;
`bootstrap.sh` (uv and none source env.sh, conda never does; uv additionally) needs `UV_PROJECT_ENVIRONMENT` under a root snapshotted
**before** sourcing (`$PROJ`, `T_ENV_ROOT`, `VENV_DIR`), so an `ENV_HOOK` (sourced last, may override anything) cannot
move the guard; a derived venv's owner file `.run-skills-proj` must match unless `VENV_DIR` is explicit. `job.sbatch` sources
the attempt's `env.sh` snapshot if present; env.sh/bootstrap.sh in a job with a valid `RS_ATTEMPT` and its dir read profile/conf/hook
from it (a missing snapshot or another job's `receipt` fails closed, never the live file; else `RS_ATTEMPT` is unset, NOTE). New early
exits in env.sh and new consumers keep this pattern and get a test.

### The attempt journal (`<PROJ>/.rs/attempts/<NONCE>/`; submit.sh, launch.sh)

Each call `mkdir`s its dir (the claim: `--rs-attempt NONCE`, a separate word an old parser rejects with exit 2, else generated;
NONCE = `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, the set spelled out; taken = exit 75), keeps the caller's fds as 3/4, `exec >>out
2>>err </dev/null` (submit.sh then runs the rest, policy included, in a subshell with 3/4 closed), writes `stage`, the `receipt` (once the job exists, before a byte about it is printed) and, in the EXIT trap,
`result` (`stage= rc= verdict=submitted|launched|refused|failed|unknown`), THEN replays out/err (`trap '' PIPE`): a dead ssh
(SIGPIPE on the first write) loses nothing, the exit status is unchanged. Slurm adds the snapshots `conf hook profile.sh env.sh`;
`/.rs/` is an anchored sync exclude, refused by run-pull; nothing deletes attempts. 6 = a live same-name job of the project.
**api=3** = the line `# rs-api=3` inside the deployed `submit.sh` / `launch.sh`: rsk's plan ssh reads it in the script it is
about to run, run-launch checks `.ws/launch.sh` before passing any `--rs-` word (else exit 2 `does not speak rs-api=3`);
`remote/API` (`api=3`, in MANIFEST) is still deployed but proves nothing (an older run-sync leaves it while rewriting the
script). Both pre-scan `--rs-mode plan`, `--rs-expect <64 hex>` and `--rs-warnings <warnings_id: 64 hex>` (with `--rs-expect`
only; submit.sh also `--rs-chain`) as separate words before `--` — an older parser exits 2 (tested against `git show
8560838:` / `650d7d6:` / `e612ef6:` submit.sh and launch.sh; rsk maps its `unknown arg` to `needs: sync`, exit 6); an unknown
`--rs-*`, and an `--rs-` word as an option's value, is exit 2 (submit.sh, launch.sh, run-launch, rsk launch). Plan mode runs
every check (`FORCE=1`: a -y gate prints its `WARNING:` and goes on; submit.sh probes the policy first, below; launch.sh
checks the env gate read-only — the venv's python executable, a conda env that activates in a throwaway shell, the `ENV_HOOK`
file, a valid `ENV_KIND`: else exit 1, no card — and creates nothing outside `.rs/`) and prints ONE `@@plan v1` … `@@end`
block: `api= kind= target=`, the bound fields (`rs_bound`, one function; also `env_hook=<path>:<sha256>`, `venv_dir`,
`uv_sync_args`; slurm `conf_extra` = the conf's own SBATCH_EXTRA words, then `flags` = `T_FLAGS` (the policy flags, a `%q`
list), right before `chain`, the last; nohup `busy_ok=<id>:<uuid>:<user>,…` sorted by id, or `unknown`), `info_*` (envelope;
nohup `info_run_gpu=checked`, which rsk requires — a block without it, or a slurm one without `flags=`, is `needs: sync`;
`info_prior=<n|unknown>`, slurm after `info_source_dirty`, nohup after `info_run_gpu`: `rs_prior`, the run's earlier attempts
= journal receipts named the run id or `<run id>--aNN`, slurm + this WorkDir's squeue rows no receipt names, `unknown` when
squeue failed or a receipt is unreadable — rsk derives `relaunch` from n > 0 or no number, never `needs: sync`),
`warnings=` (the distinct `WARNING:` lines in out+err, not `WARNING (lint)`), `warnings_avail=` (the availability gate's
share), `warnings_id=` (sha256 of those lines, sorted, digit runs → `#`, + a silent policy gate's probe output, below),
`bound_hash=` (sha256 of the lines `kind=` … the last bound field, each + newline); it stops before the snapshots / the
wrapper (`stage=plan rc=0 verdict=planned`). `--rs-expect H` recomputes that hash and the
warnings_id right before the snapshots and sbatch (nohup: before the env gate's subshell): another hash, or a warnings_id
other than `--rs-warnings` (none given: no warning at all), prints the block, `changed: <keys>` (against the approved plan's
block in its own journal entry) and `ERROR: … differs from the approved plan`, exit 6 (`stage=expect`, refused) — -y never
passes a new warning, nor one swapped for another; under it a failed squeue is exit 1. `--rs-chain` adds
`--dependency=singleton` (another dependency: exit 2) and passes the duplicate guard. Every time limit sbatch could read
(`-t`, `DEFAULT_TIME`, each `--time`/`-t` of the policy's or SBATCH_EXTRA's words, a value word included) must be explicit (0
/ UNLIMITED / INFINITE / -1 / unreadable: exit 2) and within MaxTime; an SBATCH_EXTRA word that is no option and no option's
value, or a trailing value option, is exit 2 (sbatch's `+` getopt runs it as the script: `tests/vgate` `bare_word=`); the
lint reads the words as that scan does (`--comment -t1`: `-t1` is a value, `tests/vgate` `comment_value=`). launch.sh: a GPU
with a compute process (`--query-compute-apps`, parsed without a temp file; unreadable = unknown) is never auto-picked (too
few free: exit 1), `-d` onto one is exit 6, an unknown state exit 1 — unless `--gpu-busy-ok`. RUN never picks the GPUs:
leading words (`rs_gpuenv`) — before its command, also after a leading `env` — that set or clear `CUDA_VISIBLE_DEVICES
CUDA_DEVICE_ORDER NVIDIA_/HIP_/ROCR_VISIBLE_DEVICES`, or an `env` option but `-v --debug -C DIR -u OTHER` (GNU env's rules:
`tests/61`, `tests/vgate/local.sh` `env_facts=`), and RUN's TEXT anywhere (`rs_gputext`: `NAME=`/`NAME+=` after a blank,
`; | & ( ' " =` or a backquote, `-u NAME`/`--unset[= ]NAME`, `unset … NAME`, `export -n`, `declare`/`typeset +x`; also with
quotes and backslashes removed — a mention as data counts) are exit 2 before the claim; seen only once expanded (first
command), the wrapper refuses to start the payload (rc 2). `rs_launchers`: deepspeed / accelerate launch (and their
aliases) with their own GPU flags → a counted `WARNING:` naming launcher, flags and landing (grant kind `any` only;
spellings: `tests/61` 'R5-2'; facts: `tests/vgate/launchers.sh`, plumbing `tests/88`). What the payload's own code does is beyond any check. P7: run-launch without `RS_VIA_RSK`
while rsk is installed (on PATH or `$(uv tool dir --bin)/rsk`) prints `use: rsk launch …` and exits 2 (else it launches,
with a NOTE; a Slurm target points at `rsk launch`) — a nudge, not a guard; `tests/lib.sh` exports `RS_VIA_RSK`.

### Authorisation (`grants.py`, `ledger.py`; used by `launch.py`, `cancel.py`; docs/DESIGN.md "Authorization")

The user's policy: never ask again for what they already allowed, but check every action against it. Every launch, relaunch,
chain and cancel calls `grants.check()` first — a deny → 3 (its quote), a covering record → act and record the use, else
`needs user:` → 4. One record type in the ledger's `grants.json` (`<state>/projects/<sha256(realpath)[:16]>/`, flock, atomic
writes with `.prev`, single-use `plans/`, append-only `audit.jsonl`): `approval` (the plan ids + bound hashes of the cards
the user approved, claimed and recorded in one lock hold, expiring with the plans (24 h) — a sweep is one record — or named
jobs to cancel, each bound to its identity in `scope.idents` (Slurm target, job id, run name, WorkDir; nohup target, pid,
start, boot_id), for 1 h, used up by its first cancel that passed authorisation, never refunded; one without `idents` covers
nothing), `grant` (a standing predicate: scope + actions + `max_live` / `max_launches` / `expires`, all three stated, `none`
= the user set none; `resubmit` is refused in a new one; `allow_warnings` = `availability` (warnings == warnings_avail) |
`any`, a stored `true` = `any`; `cancel_own` cancels count against `max_launches`, refunded only when the answer proves
nothing was signalled), `deny` (always wins; one of `launch` stops relaunch/chain too; its name globs also match the run id;
a fact it scopes that is unknown matches: a cancel of a job without a plan, an `rsk watch` row — no bound hash, its GPU type
and partition never certain —, a run with an attempt recorded without a class; targets compared as `grants.target_key`
names — `fx/`, `./fx`, `FX` are fx, a spelling that is not one plain name matches every target deny; `scope.jobs` only
with cancel actions, else invalid; `rsk grant add|deny|import` refuse a target `rs_targets` does not list, exit 2
`unknown target`). A deny `validate()` rejects, an id `d-…` or
a missing / damaged `kind` is a deny matching everything until fixed or revoked (a non-object: until removed by hand); any
other invalid record covers nothing; an unreadable `grants.json` (no good `.prev`) is exit 6 `grants unreadable` for launch,
cancel and watch `--act`/`--approve`, and while it is recovered or missing every deny in `audit.jsonl` still counts
(`rsk grant recount` restores those denies and the revocations; a lost grant or approval needs the user's words again). The action
is derived (`launch.plan_actions`): a run with attempts that may have run (not only NOT_SUBMITTED, not the plan's own) in
the ledger, or `info_prior` > 0, or no readable `info_prior` (`launch.info_prior`) → relaunch, `chain=1` → chain; every one applies (a deny of any matches, a record must allow all). The class is the name's,
set only at the run's first attempt (none there: a later one is exit 2). Never grant-covered: warnings the grant's
`allow_warnings` kind does not cover (`-y` is sent only for a card that showed warnings, under a record that covers them), a
policy flag (`flags=`), `--same-name-ok`, a `conf_extra` word outside `grants.EXTRA_ALLOW` (the card's `NO GRANT`; policy
words never count), a time over `max_time_s` in any limit sbatch could read (0 / UNLIMITED = unlimited), a relaunch whose
latest attempt that ran did not end in `INFRA_END` (PREEMPTED NODE_FAIL BOOT_FAIL REBOOT) or that does not repeat that
attempt's configuration (a plan named after an older attempt is the next aNN), a workstation plan on a busy GPU;
`rsk sync -D` (run-sync's grammar: `--also -n` is a path) / `rsk bootstrap --job` (any `--job` word) need `--approve`
(audited); never at all: someone else's job or process. A provably unsent submit (refused / failed with no receipt, no attempt dir, run-launch
before its ssh; nohup: the journal decides first — a receipt with gate `go` is launched whatever the exit; slurm: ssh's own
255, no answer, its never-opened words: `cancel.not_reached`, exit 5 `not reached — nothing sent`) is NOT_SUBMITTED:
the use is refunded and the plan's claim released (`rsk launch --plan P` retries it under the same record). `cancel_own`
covers only live ledger attempts rsk launched; no `@@start` from an ssh that did not end with the remote's own status is exit
5, use kept — but `not_reached` gives a `cancel_own` use back (exit 5); a non-zero scancel is exit 5 `CANCELLING?`, use
kept, unless scancel's own line for that id says `Invalid job id` / `already completing or completed` (`scancel_moot`:
exit 0, `COMPLETING`, use back; the words: `tests/vgate/slurm-remote.sh` `scancel_ended=` / `scancel_invalid=`). run-watch keeps its own approvals (`#@ ok`, bash) — `rsk watch` adds the lease, checks every row against the
denies for every action run-watch could take (`--act` / `--approve`; and at each lease refresh: TERM, exit 3), sets
`RS_VIA_RSK=1 RS_WATCH_PARENT=<its pid>`, and refuses (6) beside an orphaned run-watch lock. A record is bookkeeping, not
proof of consent: an agent can write any quote; rsk constrains only what goes through it.

### Storage policy (env.sh, driven by `T_*`)

Always in `$PROJ`: HF/torch caches, wandb dirs, `logs/`, `ckpts/`. `ENV_ROOT` = `T_ENV_ROOT` or `$PROJ` holds the
venv (`$PROJ/.venv$SUF` | `$ENV_ROOT/envs/<proj>$SUF` | conf `VENV_DIR`), `.cache/uv*$SUF`, `bin/` (uv binary) and,
when `ENV_ROOT != $PROJ`, small-file state under `state/<proj>$SUF`. `T_TMPDIR`: `project` → `$PROJ/tmp`; `inherit`
→ the preset `$TMPDIR` if writable else `/tmp/$USER/run-skills$SUF`. `T_COMPILE_CACHE`: `project` | `tmp` | path;
compile dirs are `$SUF`-suffixed except `nv`, not mkdir'd when in `$TMPDIR`. `RAY_TMPDIR` stays under `/tmp`.
`PATH="$VENV/bin:$ENV_ROOT/bin:$PATH"` for both kinds, `UV_NO_SYNC=1`. Exports `TARGET RS_TARGET RS_KIND RS_CUDA_ARCH
RS_SUFFIX RS_SOURCE_COMMIT RS_ENV_ROOT RS_VENV` (`RS_SOURCE_COMMIT` from the `.run-source` stamp each run-sync writes, which
also makes run-sync refuse a second local checkout of the same remote dir without `--take-over`) and `CLUSTER` (slurm) **xor** `WS_TAG` (nohup, lowercase). `T_SUFFIX` is empty or hyphen-prefixed
(sync protects the literal glob `/.venv-*`). The protected-exclude list (`rs_sync_excludes`; run-pull's push-back
check reuses it) is static on purpose (hand-built `.venv-foo` dirs must survive `-D`); any dir env.sh creates under
`$PROJ` must be an anchored entry there.

### policy.sh API (slurm; bash; sourced only by submit.sh)

`t_partition NAME` sets `P_GPUS=min-max P_CPU_PER_GPU P_MEM_PER_GPU P_GTYPE P_GTYPE_DEFAULT P_PREEMPT P_MAXTIME P_CPU_ONLY
P_MEM_PER_CPU P_NOTE` (submit.sh resets all to '' first), may `SB_ARGS+=(…)`, returns 1 for unknown. `t_policy` (optional;
every target should define it so an overlay can wrap it as `t_policy_shipped`) runs right after arg parsing with `PART
PART_FROM_CLI NGPU GTYPE GTYPE_FROM_CLI TIME FORCE ACK T_FLAGS SB_ARGS SB_EXTRA NAME PROJ CLUSTER TAG PLAN` visible
(`PLAN=1`: plan mode, with `FORCE=1`); its exit code propagates verbatim (3 = refusal; `-y` never unlocks it). In plan mode
and under `--rs-expect` submit.sh probes `( FORCE=0; t_policy )` (`rs_probe`: a subshell, output journaled and counted), then
runs the real one, and probes `t_partition` in its own `FORCE=0` subshell right before its real call, with the `PART` that
is submitted (`return 1` = an unknown partition, not a gate) — so both may run twice and must have no side effects. In the
probe every `exit 1` is a passed -y gate and the function goes on, as in plan mode: a function's first gate hides none after
it, and code after a gate must not assume it stopped the run; any other exit is the verdict. A gate with no `WARNING:` line
gets the generic one, and then the probe's whole output, digit-masked, joins `warnings_id`. Gate idiom (the template,
docs/packs.md): `echo 'WARNING: …' >&2; [ "$FORCE" = 1 ] || exit 1` — print, then test FORCE, so a plan's real call and a
`-y` submit show it too; never the P2 form `[ "$FORCE" = 1 ] || { echo …; exit 1; }`, silent under -y (`tests/52` 'R5-10'). A bash fact (70-docs, and
`tests/vgate/slurm-remote.sh` `bash_exit_fn=`): a function named `exit` outranks the builtin outside POSIX mode; under
`set -o posix` bash refuses it and the probe fails closed, exit 2. Unknown `--word` flags land in `T_FLAGS` (bound
`flags=`: never grant-covered), `--*-user-asked` sets `ACK=1`. Then: (probe) partition → `-g` range → cpu/mem heuristics →
MaxTime (`P_MAXTIME` else `T_MAXTIME`; explicit limits only) → payload guard → `SBATCH_EXTRA` scan (`-p`, `T_FORBIDDEN_QOS`,
every word an option or its option's value, no trailing value option) → every `--time`/`-t` in `SB_ARGS` vs MaxTime → sinfo
availability (`WARNING: only … Re-run -y`) → duplicate guard (`--same-name-ok`, singleton chains and `--rs-chain` skip it) →
`SBATCH_EXTRA` lint on the scan's words (WARN: not in the allowlist + `T_SBATCH_EXTRA_ALLOW`, or a harness option) → plan
block / `--rs-expect` check → snapshots → `sbatch` (env `RS_ATTEMPT`, last `--comment` + ` rs=<NONCE>`). Nothing
cluster-named lives in shared code; a policy's own EXIT trap, `exit` or fds stay in submit.sh's subshell, away from the journal.

### Tests contract (`tests/lib.sh`)

Caller sets `RS_HOME`; `$T` is a scratch dir; helpers `ok bad has hasnt nosub mk_proj sub with_path stub_sinfo
stub_fail stub_rsync last_attempt fulltmp fulltmp_ok` (the sbatch stub prints `ARG:<arg>` lines and `ENV:RS_ATTEMPT=`;
`fulltmp CMD…` runs CMD with `TMPDIR` on a full tmpfs and `BASH_COMPAT=42` in an `unshare -rm` namespace, `fulltmp_ok`
says whether this machine reproduces that — SKIP when not). Stubs live in `$T/bin`, on `PATH` **only** via `sub`/`with_path`/an explicit
`PATH="$T/bin:$PATH"`, and dispatch on literal strings (`ssh` answers `nvidia-smi --query-gpu=…`, logs anything
else as a launch; `sinfo` returns lines registered with `stub_sinfo PATTERN LINE`) — a reworded remote command or
a new partition needs a stub case. `mk_proj TARGET CONF` fakes a deploy from `rs_deploy_files` (absolute paths);
`sub` drops stderr: assert rejections by exit status. Phase A = fixture targets only; per-target checks go in `tests.sh`.

### One skill copy for Claude Code, Codex and pi

`install.sh` installs the one skill into `$RS_SKILLS_ROOT` (default `~/.agents/skills/remote-run/`, scanned natively by Codex 0.149+
and pi), symlinks `~/.claude/skills/remote-run` to it, and moves a copy under `~/.codex/skills` / `~/.pi/agent/skills` to `<root>.pre-v2/`
(listed twice otherwise). The replaced `hpc-run` / `ws-run` leave all four roots: a link into the shared root, a dangling link or a
copy install.sh generated in the shared root (`references/INDEX.md` line 1 `root:`) is removed, anything else moved to `<root>.pre-v2/` (`tests/75-install.sh`); `rsk doctor` FAILs while one is discoverable. One SKILL.md: `allowed-tools:` (Claude; accepted-and-ignored elsewhere) + `codex/remote-run.openai.yaml`
as `agents/openai.yaml` (Codex UI metadata). No sed over scripts. The skill reaches the harness through INDEX's `root:` line; its description is < 1024 chars with every target's `T_TRIGGERS` prepended (install prepends missing ones; ship it < 870), no `<>`.

### Portability

Sourced files (`remote/env.sh`, every `profile.sh`) are zsh-safe: no arrays, `[[ ]]`, `${var^^}`, `${!var}`, `BASH_SOURCE`.
Local scripts run on macOS bash 3.2 / BSD sed: no `${var^^}` (use `tr`), `declare -A`, `readarray`, `sed -i`. Remote scripts
run under a bare non-login `ssh host cmd`: no conda/uv on PATH, `$USER` possibly unset (`RS_USER=${USER:-$(id -un)}`).
`job.sbatch` runs in tests without Slurm: `${SLURM_*:-}` reads, `"$@" & … wait` shape. Remote parsing uses no here-string or
heredoc (up to bash 5.0 they are temp files in `$TMPDIR`, and a full one fails silently): split by parameter expansion, fail
closed — `status.sh`, `submit.sh`, `launch.sh` (its run wrapper is a single-quoted literal written with `printf`: never a
single quote inside it) and run-watch's remote bodies; `fulltmp` tests it. Local parsing (run-watch's, run-probe) may still
use them.

## Adding a target

Never in this repo. Personal: `~/.config/run-skills/targets/<name>/{profile.sh,policy.sh,reference.md,tests.sh}`
(start from `targets/_template-*`). Shared by a group: the same files under a target pack's `targets/<name>/`
(skeleton: `templates/pack/`, installer tested by `tests/80-pack.sh`). The name is the tag, the deploy dir, the
sync exclude and the INDEX row — nothing else needs editing. Extending a pack's target: `policy.local.sh` /
`reference.local.md` / `tests.local.sh` in an overlay dir without `profile.sh`. References are self-contained, `<user>`-neutral, never
mention another target (cross-target routing lives only in INDEX's Routing section).

## Editing the docs
The rails in `SKILL.md` / `procedure-*.md` / `experiment-conventions.md` (check the existing authorisation before every
submit/launch/cancel and ask only outside it — the user's table in docs/DESIGN.md; cancel only after the identity check, never
someone else's job or process; a grant records the user's words, never invented or widened, and is no proof of consent; never
create a conda env, never guess the remote dir, own wandb key only, smokes run `WANDB_MODE=disabled`, formal runs checkpoint +
auto-resume, monitoring = bounded reviews, adaptive cadence, explicit wake-up capability, detect-only — its exceptions are
`run-watch --act` on user-approved rows within their budget and rsk actions a user's grant covers) are the product — do not trim
them (70-docs pins them). Facts live
once: values in `profile.sh`, limits in `policy.sh`, prose in `reference.md`, keys in `conf-keys.md`. The INDEX stub
must equal `rs_gen_index OUT ROOT` output with no targets (test `70-docs`): regenerate under bash into a temp file
(`RS_USER_DIR=/nonexistent RS_PACKS_DIR=/nonexistent`, root `~/.agents/run-skills`; the generator copies Routing
from the stub) and move it over.
Every Slurm / wandb / bash fact written into a doc or script comes with a reproduction or a test — never from memory.
