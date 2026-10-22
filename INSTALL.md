# INSTALL.md — the agent's runbook for installing run-skills

You are a coding agent (Claude Code, Codex, pi, …) and the user asked you to install run-skills and connect it to
their GPU machines. Follow this file top to bottom. The [README](README.md) is the user's overview; this file is
yours. Speak the user's language; keep your messages short.

**The user's one-line request** (README, "Quick start") is: *Install run-skills for me: clone
https://github.com/NAIVlab/run-skills to `~/.local/share/run-skills` and follow its `INSTALL.md`.*

## Rules for the whole install

1. **Read-only on remote machines.** In Steps 0–7 you only run `run-probe` and `ssh <alias> true` on servers. Never
   submit a job, launch a run, create a conda env, install packages or create directories there. (Setting up a
   project afterwards does write — its sync and bootstrap — and `project-setup.md` asks for that OK separately.)
2. **Ask before the first connection.** One question covers every host you are about to probe. All your ssh calls use
   `-o BatchMode=yes` (`run-probe` does), so nothing ever waits at a password or 2FA prompt. Interactive steps —
   a first login through 2FA, accepting a host key, `ssh-copy-id`, `ssh-keygen` — are the user's, in their own
   terminal: give them the exact command and wait.
3. **Secrets never enter the conversation.** Never read private keys, never print an API key or token, never ask
   the user to paste one into the chat.
4. **`~/.ssh/config` changes need an explicit OK.** Show the exact change, back the file up first
   (`cp ~/.ssh/config ~/.ssh/config.bak-$(date +%Y%m%d)`; no file yet → `mkdir -p -m 700 ~/.ssh` and create it with
   mode 600), then append. The only edit to an existing block is replacing a `<user>`-style placeholder with the
   user's value. Never reorder or delete anything. Afterwards `ssh -G <alias>` must show the intended `hostname` and
   `user` — an earlier `Host *` block wins over later ones, so fix any conflict with the user. Never edit shell rc files.
5. **Site facts go to the user's overlay**, `~/.config/run-skills/` — never into the clone
   (`~/.local/share/run-skills`), a commit, or a public issue.
6. **Do not invent facts.** A value comes from a probe, from the user, or from site documentation the user points
   you to. Mark what the user told you as such in `reference.md`; write `TODO(ask)` rather than guess.
7. **Ask in small batches** — at most four questions per message, each with your suggested default, so "defaults"
   is a complete answer. Use your runtime's question UI when it has one.
8. **Sandboxed runtime?** Cloning, ssh and writing to `~/.agents`, `~/.claude`, `~/.config/run-skills` and
   `~/.local/share/run-skills` need network and home-directory access. Ask the user to grant it for this install, or
   hand them the command to run in their own terminal.

Commands here avoid globs that may match nothing (zsh aborts on those); keep it that way when you adapt them.
`$E` below is the engine clone, `~/.local/share/run-skills`; `$H` is the installed harness, `~/.agents/run-skills`.

## Step 0 — Look around

```bash
uname -s; command -v git rsync ssh; bash --version | head -1
ls -d ~/.local/share/run-skills ~/.agents/run-skills 2>/dev/null; ls ~/.config/run-skills/targets ~/.config/run-skills/packs 2>/dev/null
command -v claude codex pi
```

- `git`, `rsync` or `ssh` missing → tell the user how to install it (`brew install rsync`, `sudo apt install rsync`)
  and stop.
- `~/.agents/run-skills` exists → **update mode**: `git pull --ff-only` the engine and every installed pack
  (`git -C ~/.config/run-skills/packs/<entry> pull --ff-only`), then run Step 6. Offer Steps 2–5 only as "Do you
  want to add another server?" — never re-ask what is already registered, and skip the pack question below.
- One installed copy serves Claude Code, Codex and pi; nothing to choose.

Ask: **"Does your lab or group have a run-skills target pack (a git repo describing your shared clusters)? If so,
its git URL."** Default: no.

## Step 1 — Install the engine

Without a pack:

```bash
[ -d ~/.local/share/run-skills/.git ] || git clone https://github.com/NAIVlab/run-skills.git ~/.local/share/run-skills
git -C ~/.local/share/run-skills pull --ff-only
bash ~/.local/share/run-skills/install.sh
```

With a pack `<url>`: first check whether it is already installed — for each entry of
`~/.config/run-skills/packs`, `git -C ~/.config/run-skills/packs/<entry> remote get-url origin`; a match means
`<pack>` = that entry (reuse it; never clone a second copy — its routing would be listed twice). Otherwise
`<pack>` = the repo name (without `.git`):

```bash
[ -d ~/.config/run-skills/packs/<pack>/.git ] || git clone <url> ~/.config/run-skills/packs/<pack>
git -C ~/.config/run-skills/packs/<pack> pull --ff-only
bash ~/.config/run-skills/packs/<pack>/install.sh      # clones/updates the engine, then runs its install.sh
```

A private pack needs the user's git access (an ssh key on the git host); a clone failure is theirs to fix. Then
read the pack's README: it says how members set up ssh (its `ssh_config` and the placeholder to replace, such as
`<user>`) and the group's conventions.

Expect `Install OK` and `===== RESULT: N pass, 0 fail =====`. Any `FAIL`: show the failing lines and stop; do not
patch the engine. `ACTION: no ssh alias for: …` under `== ssh aliases ==` lists pack targets whose ssh alias is not
configured yet — Step 2 handles them.

## Step 2 — Find the user's servers

```bash
bash ~/.agents/run-skills/bin/run-probe hosts
```

Columns: alias, hostname, user, note (`skip: code host`, `placeholder user`, `registered: <target>`). It reads
`~/.ssh/config` and its `Include` files; it does not connect anywhere. Show the user the list without code hosts,
then ask:

- **"Which of these are GPU machines you want to run experiments on?"** (multi-select).
- **"Is any server missing from this list?"** For each: hostname, username, jump host if any. Draft a block from
  `$E/templates/ssh_config` (keep the `ControlMaster` lines: they let one interactive 2FA login serve all later
  calls; set `IdentityFile` to the user's actual key — see "Keys" below — or drop it) and apply rule 4.
- A pack target flagged by the installer: take the block from the pack's `ssh_config`; a `placeholder user` row:
  the block is already there. Either way ask for the user's username on that site and apply rule 4.

Keys: if `ls ~/.ssh | grep '\.pub$'` lists none, the user runs `ssh-keygen -t ed25519`. For each new alias the user runs
`ssh-copy-id <alias>` (sites without password logins have a key-upload page instead — ask the user).

## Step 3 — Probe (read-only)

Ask once: *"I'll connect to `<aliases>` and run read-only commands (OS, GPUs, Slurm partitions and your accounts,
disk usage). OK?"* Then, per alias:

```bash
bash ~/.agents/run-skills/bin/run-probe <alias>
```

- `UNREACHABLE` (exit 4): a password, 2FA or host-key prompt. Ask the user to run `ssh <alias>` once in their own
  terminal (and keep that session open on 2FA sites, so the ControlMaster connection stays up), then probe again.
  Still failing → skip the host and report it.
- `== slurm ==` lists partitions → kind **slurm**. `none: no sinfo` with GPUs under `== gpu (this node) ==` → kind
  **nohup** (a workstation). Neither → say what you saw. If the user says it *is* a Slurm cluster, Slurm is not on the
  PATH of a non-login ssh command — the harness needs it there (`submit.sh` runs that way), so this is a site issue
  to solve with its admins, not something to work around. Otherwise skip the host.
- On a Slurm login node `== gpu (this node) ==` is usually empty; the partitions' `gres` column is the GPU inventory.

## Step 4 — Register each server as a target

A pack already provides it → no `profile.sh` to write, but the pack ships placeholders (`<user>`, `<account>`, …),
never a member's identity, so **ask who the user is there** — the facts its README lists under "Personal facts"
(else: username, the account their runs bill to, where their projects live), suggesting the probe's `default
account:` / `associations` and `exists:` lines. Write the answers, marked "(user)", to
`~/.config/run-skills/targets/<name>/reference.local.md` — an overlay directory *without* `profile.sh`, which also
holds any personal rule (`$E/docs/packs.md`, "Precedence and personal tweaks"). Never put them into the pack.
Otherwise the target name is the alias, lowercase letters, digits and hyphens (it becomes the conf tag: `my-hpc` →
`MYHPC_`, and the deploy dir `.<name>/` in every project). Reserved, because the dir would collide: `ws`, `venv`, `cache`, `config`, `local`, `git`,
`claude`, `codex`, `agents`; names starting with `_` are ignored (templates).

```bash
cp -R ~/.local/share/run-skills/targets/_template-slurm ~/.config/run-skills/targets/<name>   # or _template-nohup
```

Fill `profile.sh` from the probe (every key is commented in the template):

| key | source |
|---|---|
| `T_HOST` | the alias |
| `T_DESC`, `T_GPUS` | gres column / `nvidia-smi` lines, e.g. `4x H100 80GB per node`; one line, no `<` or `>` |
| `T_TRIGGERS` | the name plus the nicknames the user says for this machine (ask) |
| `T_CUDA_ARCH` | `compute capability` (workstations); for Slurm, from the GPU model (A100 `8.0`, H100/H200 `9.0`) or empty |
| `T_CONDA_INIT` | the probe's `conda.sh:` line as `source <path>`; none found → `''` (only `ENV_KIND=conda` projects use it) |
| `T_DEFAULT_PARTITION`, `T_PARTITIONS`, `T_MAXTIME` | partition lines: `*` marks the site default; `timelimit` column; the user's choice wins |
| `T_DEFAULT_GPU_TYPE` | `any`, unless the user wants a specific gres type by default |
| `T_ENV_ROOT`, `T_TMPDIR`, `T_COMPILE_CACHE` | the storage questions below; keep the template values when nothing argues otherwise |
| `T_SUFFIX`, `T_REMOTE_DIR_REQUIRED` | another registered target mounts the same project filesystem → `T_SUFFIX='-<name>'` (separate venvs); this target shares none → `T_REMOTE_DIR_REQUIRED=1` |
| `T_XFER_HOST` (add the line) | only if the site requires a data-transfer node for rsync: its ssh alias |

For Slurm, write one `t_partition` case per partition the user will use: `P_GPUS=1-<GPUs per node>`,
`P_CPU_PER_GPU` = cpus per node ÷ GPUs per node, `P_MEM_PER_GPU` = MB per node ÷ 1024 ÷ GPUs per node, rounded down
(GB), `P_MAXTIME` = its timelimit, `P_PREEMPT=1` where jobs can be preempted. Partitions with mixed nodes: use the
node type the user will actually get, and say so in `P_NOTE`.

Then ask what probes cannot tell (one batch per server, or one batch for several):

- Slurm: **which partitions will you use, and the default?** (suggest a GPU partition the associations allow) — and
  **the account**, only when the probe shows several: record it in `reference.md`; projects set `<TAG>_ACCOUNT`.
- Slurm: **"Is there a partition or QOS you must never submit to by accident (say, a PI's priority queue)?"** A
  partition → a refusal in this target's `t_policy` (`exit 3`, see the template header); a QOS → `T_FORBIDDEN_QOS`.
  For a pack's target the refusal goes into the overlay's `policy.local.sh` instead.
- **"Where do your projects live on this server?"** Suggest a large filesystem from `== storage ==`, preferably an
  `exists: <dir>/<user>` line. Record the pattern in `reference.md` (absolute for Slurm; for a workstation, relative to
  `$HOME` when it can be); each project still confirms its own dir.
- **Storage policy**, when the probe shows a small `$HOME` or a network filesystem (`nfs`, `fuse`, `lustre`, …) for
  projects: "Many small files (venvs, caches) may be slow or quota-limited there — put envs under `<faster dir>`?"
  → `T_ENV_ROOT`. A per-job `$TMPDIR` the site documents → `T_TMPDIR=inherit`.
- Workstation: **"Is the box shared? Which GPUs belong to someone else?"** → `reference.md` (projects then set
  `GPU_EXCLUDE`).

Write `reference.md` from the template: one screen, self-contained, `$USER` / `<user>` instead of the user's id (so
the file can later move into a pack), every unprobed fact marked "(user)". Mention no other target.

## Step 5 — Defaults and wandb

- **"When a request names no server, which one should I use?"** → append a bullet to
  `~/.config/run-skills/routing/hpc-run.md` (Slurm) or `routing/ws-run.md` (workstations), e.g.
  `` - No target named and no DEFAULT_CLUSTER in the project's .hpc.conf → `<name>`. `` Choice rules the user states
  ("big jobs on A, debugging on B") go there too, as bullets.
- **"Do you log to Weights & Biases?"** Run `bash ~/.agents/run-skills/bin/run-probe wandb` (it never prints the key).
  - `~/.netrc: has an api.wandb.ai entry` → ask *"Use that key for run-skills?"*, then
    `run-probe wandb --import-netrc`.
  - Otherwise the user pastes their own key (wandb.ai/authorize) into `~/.config/run-skills/wandb_env`
    (`export WANDB_API_KEY=…`) with their own editor; re-run `run-probe wandb` to confirm `key: set`.
  - A team entity: you may write `export WANDB_ENTITY=<entity>` into that file yourself — it is not a secret.
  - No wandb: leave it empty; runs go offline and nothing else changes.

## Step 6 — Install and verify

```bash
bash ~/.local/share/run-skills/install.sh     # or: bash ~/.config/run-skills/packs/<pack>/install.sh
```

Check, and fix before reporting:

- the `targets:` line names every registered target; each skill line says `INDEX: N target row(s)`;
- `== ssh aliases ==` says `all target aliases found.`;
- `===== RESULT: N pass, 0 fail =====`;
- per target: `ssh -o BatchMode=yes -o ConnectTimeout=15 <alias> true` exits 0.

Skills are read when an agent session starts: the user needs a **new session** before they can use them.

## Step 7 — Report

One table: target · kind · ssh alias · GPUs · default partition · status (ready / needs: …). Then, briefly:

- what the user still has to do (`ssh-copy-id`, the wandb key, a new session);
- where their setup lives: `~/.config/run-skills/{targets,routing,wandb_env}`;
- updating: re-run the Step 1 commands;
- next: in a project, *"set up this project for `<target>`"*, or simply *"run train.py on `<target>`, 1 GPU"*.

Then ask: **"Do you want me to set up existing projects now? Give me their paths."**

## Existing projects

For each project the user names: work from its root directory and follow
`~/.agents/skills/hpc-run/references/project-setup.md` (one file serves both skills). It reads how the project
runs today (pyproject or requirements, conda, existing sbatch / nohup scripts, wandb, checkpoints), writes
`.hpc.conf` / `.ws.conf`, checks any copy already on the server, shows a dry-run sync, and — after the user's OK — syncs and
bootstraps. Those are the first writes on a server (a bootstrap may download uv and a Python into the project's env
root); nothing is launched without the user's go.
