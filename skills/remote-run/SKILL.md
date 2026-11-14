---
name: remote-run
description: Run, submit, launch, monitor, stop or cancel code on the user's Slurm clusters (project .hpc.conf) and GPU workstations without a scheduler (project .ws.conf) listed in references/INDEX.md. Rsyncs the project to its remote dir, bootstraps a contained uv or conda env, checks free GPUs on every target when the user leaves the placement open, then submits an availability-checked sbatch job or launches a detached nohup run on the idlest free GPUs, with every cache and output kept inside the project dir. Use whenever the user wants to run, launch, sbatch, nohup, train or eval on a cluster, HPC, Slurm, a named partition, a workstation, a GPU server or the box, or wants job status, logs, results copied back, or to cancel a job or stop a run. Replaces the hpc-run and ws-run skills, which project docs and older notes may still name.
allowed-tools: Bash, Read, Write, Edit
---

# Run a project on a Slurm cluster or a GPU workstation — pick the target, read its reference, drive it with rsk

## 1. Pick the target
Read `references/INDEX.md` **now**. Its line 1 is `root: <dir>` — the installed harness dir, `$ROOT` below. The table
lists every registered target with its kind — `slurm` (a cluster) or `nohup` (a GPU workstation, no scheduler) — ssh
host, GPUs, default partition / GPU type, walltime cap, description and its reference file. Pick the target from the
user's words (its name or trigger words). For a new launch whose placement they did not fix (only a range like "an
H200" / "4 GPUs" / "a free box", or nothing), run `rsk avail` (= `$ROOT/bin/run-avail`) first and place by what is free
now (INDEX Routing: Placement) — a cluster may fit better than a box, or the reverse; `DEFAULT_CLUSTER` in `.hpc.conf` /
`DEFAULT_STATION` in `.ws.conf` is preferred when it can start the job. **Then read exactly that target's reference
file** (the path in its table row): partitions or GPUs, caps, storage model, gotchas, and a card of its values. A
summary of a file is not the file: once your context was summarized, re-read the reference (every path in the row; the
harness re-prints them as `reference:` / `ref=`) before each plan unless its text is verbatim in context; a plan you
show cites it (`ref: <path>`; rsk's card has it as `reference`).
If INDEX says no target is registered yet (or the user wants another one), register it with the user: Steps 2–6 of
`$ROOT/INSTALL.md` (read-only discovery with `$ROOT/bin/run-probe`, then `~/.config/run-skills/targets/<name>/` from
`$ROOT/targets/_template-slurm/` or `$ROOT/targets/_template-nohup/`, then `rsk setup`; installed without rsk: re-run
`bash ~/.local/share/run-skills/install.sh` or the pack's `install.sh`) — or `rsk pack add` the user's lab target pack.
A project runs on a target when its repo root has that kind's conf, `.hpc.conf` (Slurm) or `.ws.conf` (workstation);
if it is missing (or the user asks to set the project up), follow `references/project-setup.md` — it asks for
`REMOTE_DIR` / `WS_REMOTE_DIR`; never guess them.

## 2. Commands (cwd = the project root; `<t>` = target name) and the flow
`rsk` is uv's tool command (off PATH: `$(uv tool dir --bin)/rsk`); reads are one BatchMode ssh per target. Exit: 0 ok ·
1 failed on the target · 2 usage / setup gap · 3 refused (policy or the user's deny: final) · 4 needs the user · 5 no
answer (state unknown) · 6 conflict (plan again, sync, or follow the live run) · 8 too few free GPUs. The flow: `rsk status`
→ `rsk avail` (placement open) → `rsk sync` / `rsk bootstrap` → `rsk launch` → monitor (`rsk status`, `rsk logs`, `rsk watch`) → `rsk cancel` → `rsk pull`.
```
rsk status [-T <t>]... [--days N]                 # FIRST (new session, after a summary): ledger runs, jobs on each target, grants, `needs user:`; UNOBSERVABLE = unknown, never "none"
rsk avail [--type T] [--min N]                    # placement left open: free GPUs on EVERY target (clusters + workstations), read-only
rsk sync -T <t> [-n] [--also <path>]              # push code + deploy the harness (run-sync; -n dry run first on a new project; -D prune: only with --approve)
rsk bootstrap -T <t> [--job -p <partition>]       # first run / deps changed: uv sync the target venv, or verify the conda env (run-bootstrap; --job: only with --approve)
rsk launch -T <t> [Slurm: -p P -g N -G TYPE -t TIME -n NAME --chain N | box: -g N or -d IDS [--gpu-busy-ok], -N NAME] [--class C] -- <RUN>
rsk launch --plan <id> [--plan <id>]... --approve   # submit the card(s) the user approved (+ --check-after 30: start milestone)
rsk launch --relaunch <run>                       # the run's next attempt (aNN) with its recorded configuration
rsk logs -T <t> <jobid|log> [<ckpt-dir>] [-n 40]  # start a review: the status.sh digest, byte-bounded (-n 40 = deep read; or <jobid|relative log> --grep PAT: matching lines)
rsk exec -T <t> -- <cmd> [args]                   # ONE bounded read in the remote project dir instead of a raw ssh: squeue sacct sinfo nvidia-smi
                                                  #   ps df ls stat quota mfsgetquota, head/tail -c N <relative path>, …; no pipes, no $VAR
rsk watch <table> [--act] [--once] [--for S]      # many jobs or long waits: run-watch under the project's lease (procedure §5); --act: every row checked against the denies
rsk watch <table> --approve                      # the user OKed the shown rows + `#@ allow` (Slurm); --act / --approve go through rsk watch only
rsk cancel <run> [--job <id|pid>] [--approve] [--wait S]   # identity check, then scancel / TERM → KILL (--approve: not this ledger's run, the user OKed it)
rsk pull -T <t> [-n] [--root] <path>...           # copy results back (run-pull; -n = count + size first; --root: under OUTPUT_ROOT)
rsk grant add|deny|list|revoke …                  # what the user allows / forbids standing (§3); rsk adopt: ledger a run rsk did not start
rsk doctor                                        # offline check of this install (skill, packs, targets, grants, ssh aliases); rsk update: when the user asks
```
Read each call's whole output and exit code; `rsk launch` / `rsk cancel` end with the verdict line `rsk launch: exit N
(<meaning>)[ — <why>]`. Scripting rsk: log every call's full output, branch on the exit code (never on grepped words), pass
options literally or as an array — zsh, maybe your shell, never splits an unquoted `$VAR` (a name with a space: exit 2).
`rsk launch -T` plans on the target (every check a submit runs; nothing submitted), stores the plan and its card, then
checks the user's recorded authorisations (§3). Exit 0 `covered by <id> (…)` = submitted under what they allowed
earlier: say so in your report, with the record. Exit 4 `needs user: approval — plan <id>` = **show the card verbatim,
wait for the user's words**, then, once they approve it, `--plan <id> --approve`. A sweep: plan each member, show every
card, one `--approve` with several `--plan`. Exit 6 = the card went stale (used, superseded, expired, drifted:
it says what changed; `needs: sync`) or that run is live: sync or plan again, show the new card. Exit 5 after a submit = SUBMIT_UNKNOWN, never resubmitted (it blocks that run until `rsk status` settles it),
whatever ssh's own words were (a fallback route of a session that ran can print `Connection refused`): the plan stays used;
`plan <id> is free again` = the target proved nothing went out: fix the cause, `rsk launch --plan <id>` retries it under the same record.
Moving a run: `rsk cancel <run> --wait 120`, then plan it on the new target; `not ended yet` or a refusal saying a
cancel's end is not seen yet (often: the old target was unreadable) → `rsk status` again, never `--same-name-ok`; no
checkpoint moves by itself (procedures §6). Slurm: free is not schedulable (priority, caps, your other jobs): a long wait → compare targets (`rsk avail`) rather than stacking submits.
Slurm: `references/procedure-slurm.md` (sync → bootstrap → plan → submit → monitor, the storage model, what `submit.sh`
checks). Workstation: `references/procedure-nohup.md` (sync → bootstrap → GPUs → plan → launch → monitor). Conf keys:
`references/conf-keys.md`. Naming, run classes, wandb, checkpoint/resume: `references/experiment-conventions.md` — read
it before naming, submitting or launching any real experiment. `rsk launch` NOTEs a NEW run named outside its §2
(rename it; a name the user chose: `--free-name`), refuses a smoke it can see reaching wandb (exit 2) and WARNs on the
card where it cannot tell: start a smoke's command with `env WANDB_MODE=disabled` (one command; several: `bash -c`).
Set §4's wandb fields before a formal launch; the NOTE after it: check they landed. Installed without rsk (no uv): `TARGET=<t> bash
$ROOT/bin/run-{avail,sync,bootstrap,pull,watch}`, Slurm `ssh <host> 'bash <REMOTE_DIR>/.<t>/submit.sh … -- <RUN>'`, box
`TARGET=<t> bash $ROOT/bin/run-launch … -- <RUN>` (procedures §4–§5); no ledger: check the user's words the same way,
and for anything they do not cover print a one-line plan and wait for their go.

## 3. Authorisation — check first, ask only outside what the user allowed
Do not ask again for what the user already allowed; check every action against it. Before every launch, relaunch,
resubmit or cancel, check for an existing authorisation first (`rsk launch` / `rsk cancel` check the project's ledger:
approvals, grants, denies); act when it covers the action, ask only when it does not. `--approve` is a flag that says
the user approved what is on screen (the card, the rows, this cancel); rsk records that it was approved, never their words.
- "Run this set on this target", "you decide", "auto-resume preemptions within N": record it once, `rsk grant add
  --action launch|relaunch|chain -T <t> [--partition P] [--name '<glob>'] [--max-gpus N] [--max-time T]
  [--allow-warnings availability|any] --max-live N|none --max-launches N|none --expires <date>|none` — exactly the
  scope and limits they stated (`none` where they set none; unclear → ask). Never invent a grant, never widen one.
  "Never X" → `rsk grant deny …`: a deny always wins (`rsk watch --act` too) and matches what it cannot rule out (a job
  without a plan, a watch row, a run of unknown class). `--job` is for cancels only: a run's launches are denied with
  `--name '<run>'` (exit 2 otherwise) — an attempt's name (`<run>--a02`, `<run>--a*`) stands for the run; `-T` must
  name a target the harness knows (exit 2 `unknown target`); a `--partition` the target's `T_PARTITIONS` display list
  lacks is exit 2 too: check the spelling with the user — one they confirm is real (policy.sh decides) takes
  `--unlisted-partition` and is recorded with a NOTE (GPU types are never checked). List flags split on commas (`--name
  'b1, b2'` is two); an empty item or one holding a space is exit 2. A deny naming a run with `relaunch`/`resubmit`
  stops every launch of it on any target in its scope (rsk cannot see every earlier attempt): record "if a fails, don't
  relaunch it" only once a has run. `rsk grant list`, `rsk status` and `rsk doctor` flag a record naming a target the
  harness does not know (`never matches`). A sweep they approved shares one approval, never one question each. The
  action is the plan's, never a flag's: a run that ran before = `relaunch`, a singleton chain = `chain` (each one that
  applies is checked; a run ran before also when only the target's journal shows it — run-watch's runs never enter the
  ledger: the plan's `info_prior` —, and a deploy that cannot say counts as one: fail closed); a run's class is set only
  at its first attempt.
- A `launch` grant also covers relaunches of runs in its scope, judged as a launch (scope, caps, budgets, warnings,
  denies) after any end and whatever the configuration (a bug fixed, a run moved) — never while an earlier attempt rsk
  can see may be live; rsk re-reads a run the ledger counts as live first. Preemption recovery they authorised runs
  within its budget: a requeueing partition restarts the job itself; else `rsk watch <table> --act` resubmits approved
  rows within `#@ allow preempt=N`, or `rsk launch --relaunch <run>` under a `relaunch`-only grant (the configuration of
  the run's latest attempt that ran, and only after an infrastructure end — Slurm PREEMPTED / NODE_FAIL / BOOT_FAIL,
  box REBOOT; never CANCELLED, COMPLETED, FAILED, TIMEOUT, OUT_OF_MEMORY or unknown). "Stop the rest of the group if one
  fails" = `#@ allow … fail-stop`.
- Ask first: a charged partition, more resources or a wider scope than authorised. A plan with warnings is never
  grant-covered unless their words allowed it (`--allow-warnings availability` = only the harness's availability gate,
  `any` = every -y gate, a charged partition's too — only when their words say so); a box's launcher / container
  WARNING is never grant-covered, whatever the kind (it may use more GPUs, another user's). A covering grant also
  covers policy flags, `SBATCH_EXTRA` words outside the grant allowlist and `--same-name-ok` (the card NOTEs them).
  `--max-time` caps every time limit.
- Cancel: a run of this project's ledger (rsk launched or adopted it — your own) → `rsk cancel <run>`, no question; it
  is cancelled once its identity checks out (Slurm: name, WorkDir, user; box: pid, start time, boot id). Anything else
  — another job of yours in this WorkDir, a process the ledger does not hold — only with the user's OK for this
  command: `rsk cancel --job 123 -T <t> --approve` (without it: exit 4, ask); nothing is stored for a later cancel. A
  deny of cancel still refuses (exit 3). Say in your report what you stopped and why.
- Never someone else's job or process, whatever was approved. Only the user's OK at the time, never a grant: a GPU
  another job uses (they name it: `-d <ids> --gpu-busy-ok`), `rsk sync -D`, `rsk bootstrap --job` and `rsk adopt
  --not-submitted` (each only with `--approve`).
A grant records the scope and limits the user allowed; it is bookkeeping, not proof of consent — an agent can record
anything there. rsk keeps decisions from being asked twice or stretched and constrains only what goes through it.
Record only what the user allowed.
The payload is code: what it runs once it starts (scripts, tools replacing its environment beyond the warned ones, values
only an expansion supplies, launcher settings in files rsk does not read) is outside rsk's checks, as is an older run-watch.
Exit 6 `grants unreadable`: no deny can be ruled out, so rsk launches, cancels and acts on nothing — tell the user (they
restore `grants.json`, or move it and its `.prev` aside and `rsk grant recount`: denies return; lost grants need the user again).

## Safety rails (always)
- **Check the existing authorisation before every submit, launch or cancel; ask only outside it** (§3). Workstations are
  often shared: never launch onto a GPU another job is using without the user's words naming it — auto-pick takes the
  idlest GPUs with no compute process; read the card's busy line. On a box the run command never picks GPUs (`-d`/`-g`
  do): RUN's text that sets or clears `CUDA_VISIBLE_DEVICES` or a sibling, anywhere, is refused (exit 2), as
  `APPTAINERENV_<name>=` too, and so is one emptying the environment (`env -i`, `exec -c`); a launcher given its own GPU
  flags (deepspeed `--num_gpus`…, `accelerate launch --gpu_ids`…) is a card WARNING, as are its GPU settings (accelerate's
  `gpu_ids`, `/job/hostfile`; no `--config_file` while `ENV_HOOK`, `ENV_KIND=conda`, `HF_HOME` or `ACCELERATE_…` may
  move it), a container runtime picking GPUs (`docker run --gpus`…, `apptainer --cleanenv`…) and a tool starting the
  command without this launch's environment or elsewhere (`docker exec`, `tmux new`, `sudo` without `-E`, `ssh`,
  `srun`…) — let it use the landing (run the command directly), or name its GPUs to the user (only their approval of
  that card covers it, never a grant). Cancel only after the identity check (`rsk cancel`).
- Slurm: partition and QOS are `submit.sh`'s decision — no raw `sbatch`/`srun`/`salloc`, no `scontrol update`, no
  `--partition` inside `SBATCH_EXTRA`. A policy refusal (exit 3) is final; `-y` also confirms policy warnings
  (availability, occupancy, SU cost): rsk sends it only when the approved card showed warnings or the covering grant's
  kind covers the plan's warnings, and the target then checks they are the same warnings (a new one: exit 6).
- wandb uses the **user's own key** (the deployed `.wandb_env`), never a cluster's or the box's `~/.netrc`; no key →
  offline. Never `wandb login` on a cluster.
- Never create a conda env: if `ENV_NAME` is missing on the target, stop and ask. uv venvs are different —
  `run-bootstrap` builds them from the project's own `pyproject.toml`, so running it is safe. `ENV_KIND=uv` is the
  default; scaffold new `.ws.conf` files as uv unless the user asks for conda.
- Everything a run produces stays under the project's remote dir (the harness pins caches, tmp, logs, ckpts there) —
  or under the root outside it that its conf declares (`OUTPUT_ROOT`, `conf-keys.md`), reached only with `--root`.
- A submit or launch whose ssh died or printed nothing is never retried blind: `rsk status` settles it from the remote
  `.rs/attempts/<NONCE>/result` + `receipt` (procedure §4).
- Files cross the wire only through `run-sync` (up) and `run-pull` (back) (`rsk sync` / `rsk pull`), via the target's
  transfer host where the site requires one. Never hand-roll `rsync`/`scp`/`sftp` to `<host>`; ssh is for commands and bounded reads.
  No checkpoint moves by itself: carry it before resuming on another target (`--root` under `OUTPUT_ROOT`; procedure §6).
- Experiments checkpoint and resume: Slurm jobs go out with `--requeue`, so the run command must pick up from its
  latest checkpoint when re-run (check it before a long submit); nothing restarts a nohup run after a crash or reboot,
  so the command must pick up from its latest checkpoint on relaunch. Smoke tests always run `WANDB_MODE=disabled`.
- Monitoring (`experiment-conventions.md` §7): widen review intervals only with evidence; anomalies and milestones
  need closer attention. Choose low-cost waiting or notifications supported by the runtime; state the wake-up mechanism
  and coverage, or report a snapshot and the next check time. Start reviews with the `status.sh` digest (`rsk logs`);
  keep log reads byte-bounded. Report every finding promptly, healthy status in one line. Detect-only — stopping,
  killing or resubmitting a run is the user's call, except what they authorised and a tool checks: `run-watch --act`
  (Slurm) first-submits or resubmits only table rows the user approved (rows + budget shown, their OK recorded with
  `rsk watch <table> --approve`), within the table's `#@ allow` budget, `fail-stop` cancels included (`rsk watch --act`
  first refuses rows a deny of theirs matches); `rsk launch --relaunch` under a grant that covers it and `rsk cancel` of
  this project's own ledger runs (§3; report why); on workstations `run-watch` only detects.
- Under a standing grant: a CANCELLED end was someone's decision — never relaunched unprompted; several runs failing at
  once point at the target or a shared input — read one log before relaunching any; bound the relaunches you start.
