# Target packs — share your lab's clusters and workstations

A **target pack** is a git repository that bundles the run-skills targets a group shares: the clusters and GPU
boxes everyone uses, their limits and quirks, and the hints the agent needs to choose between them. Members install
the pack with one command; the pack installs and updates the engine. Your site details stay in your own (usually
private) repo, and the public engine never needs to know about them.

## Layout

```text
my-lab-pack/
├── install.sh              # copied from templates/pack/install.sh — set ENGINE_URL if you use a fork
├── README.md               # member-facing: install, ssh setup, which target for what
├── targets/
│   ├── bigcluster/         # one directory per target; the directory name is the target name
│   │   ├── profile.sh      # facts: ssh alias, GPUs, storage policy, Slurm defaults (POSIX data)
│   │   ├── policy.sh       # Slurm only: partitions, GPU ranges, cpu/mem per GPU, walltime caps, gates
│   │   ├── reference.md    # the one page the agent reads before using this target
│   │   └── tests.sh        # optional: checks against the stubbed submit path
│   └── gpubox/
│       ├── profile.sh
│       └── reference.md
├── routing/
│   ├── hpc-run.md          # optional: bullets appended to the Slurm skill's routing rules
│   └── ws-run.md           # optional: same for workstations
├── ssh_config              # optional: Host blocks with <user> placeholders
└── hpc.conf.example        # optional: a project conf with your group's directory layout
```

Start from the skeleton: `cp -R ~/.local/share/run-skills/templates/pack my-lab-pack`, then copy
`targets/_template-slurm` or `targets/_template-nohup` for each target. The comments in the templates document
every key; [`../AGENTS.md`](../AGENTS.md) documents the `policy.sh` API (`t_partition`, `t_policy`).

## Writing a good target

- **`profile.sh`** is data, sourced locally and on the remote by bash *or* zsh: plain `KEY='value'` lines, paths
  single-quoted, only `$HOME` / `$USER` expand (on the remote). Choose the storage policy deliberately:
  `T_ENV_ROOT` (where venvs and uv caches live — move them off a filesystem that is slow on small files),
  `T_TMPDIR` (`project` or the job's `inherit`ed `$TMPDIR`), `T_COMPILE_CACHE`, and `T_SUFFIX` when two targets
  share a filesystem but not an OS or GPU architecture.
- **`T_DESC` and `T_TRIGGERS`** decide routing. `T_TRIGGERS` words are prepended to the installed skill
  description verbatim (some agents match skills lexically), so list the names people actually say: the target
  name, the site's nickname, notable partition or GPU names.
- **`policy.sh`** encodes what the scheduler will not tell you up front: per-partition GPU ranges, sensible cpu and
  memory per GPU, partition walltime caps (a request over the cap would pend forever), forced GPU types, preemption
  notes. `t_policy` can refuse a submission (exit 3) or require an acknowledgement flag — use it for queues that
  must never be hit by accident.
- **`reference.md`** is what the agent knows about the site. Keep it to about one screen: a card with the key
  values, the filesystem story (quotas, which disk for what), partitions with their limits, interconnect, and the
  gotchas a newcomer learns the hard way. Write `<user>` / `$USER` instead of anyone's id, and never mention
  another target — cross-target choices go in `routing/`.
- **`tests.sh`** runs in the engine's selftest (phase B) with the helpers from `tests/lib.sh`
  (`mk_proj`, `sub`, `stub_sinfo`, `has`, `hasnt`, …). Test what your `policy.sh` adds: refusals, pinned nodes,
  forced GPU types, caps.

## Routing hints

The installed `references/INDEX.md` of each skill lists every target and ends with a **Routing** section. Each
pack's `routing/<skill>.md` is appended to it verbatim, so write Markdown bullets, for example:

```markdown
- "H100" alone is ambiguous: `bigcluster` partition `h100` (8 per node, NVLink, 2 d) vs `gpubox` (2 cards, no
  scheduler). Multi-GPU training → bigcluster; quick interactive checks → gpubox; else ask.
```

## Publishing and onboarding

1. Push the pack to a repo your members can read (keep it private if it describes non-public infrastructure).
2. In the pack's README, give members the one-liner:

   ```bash
   git clone git@github.com:<org>/<pack>.git ~/.config/run-skills/packs/<pack> \
     && bash ~/.config/run-skills/packs/<pack>/install.sh
   ```

   A clone elsewhere works too — `install.sh` symlinks it into `~/.config/run-skills/packs/`.
3. Updates: `git -C ~/.config/run-skills/packs/<pack> pull && bash ~/.config/run-skills/packs/<pack>/install.sh`
   pulls the pack, then pulls the engine and reinstalls. Profile and policy edits apply at the next sync; changes to
   names, descriptions or routing need the reinstall to reach the skills' INDEX.

Installer knobs (environment variables): `RS_ENGINE_URL` (engine repo, e.g. your fork), `RS_ENGINE_DIR` (its
clone, default `~/.local/share/run-skills`), `RS_PACKS_DIR` (default `~/.config/run-skills/packs`).

## Precedence and personal tweaks

Targets resolve as: the member's overlay `~/.config/run-skills/targets/<name>/` → packs, in directory order →
the engine's own `targets/` (which ships only the `_template-*` starting points, never listed as targets). A member who needs a personal rule on a shared target creates an overlay directory with the
same name but **without** `profile.sh`; it then extends the pack's target:

- `policy.local.sh` — sourced after the pack's `policy.sh`; may wrap `t_policy` (`t_policy_shipped` is the original):
  ```bash
  eval "$(declare -f t_policy | sed '1s/^t_policy/t_policy_shipped/')"
  t_policy() { [ "$PART" = vip ] && { echo "REFUSED: vip is policy-gated" >&2; exit 3; }; t_policy_shipped; }
  ```
- `reference.local.md` — linked from INDEX next to the pack's reference.
- `tests.local.sh` — runs in the selftest after the pack's tests.

An overlay directory **with** `profile.sh` replaces the pack's target entirely.

## Keeping private things private

- Put the pack in its own repo; the engine repo never needs your site names.
- No user ids, account names or personal queues in a shared pack: use placeholders (`<user>`) and put personal
  rules in each member's overlay.
- Maintainers of a public fork can list forbidden words — one `grep -E` pattern per line, matched
  case-insensitively — in `~/.config/run-skills/forbidden-words`; the selftest then fails if any of them appears in
  the engine repo. The list lives outside the repo, so it never leaks itself.
