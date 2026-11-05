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
│   └── remote-run.md       # optional: bullets appended to the skill's routing rules (older packs: hpc-run.md, ws-run.md)
├── ssh_config              # optional: Host blocks with <user> placeholders
└── hpc.conf.example        # optional: a project conf with your group's directory layout
```

Start from the skeleton: `cp -R ~/.agents/run-skills/templates/pack my-lab-pack` (or from any clone), then copy
`targets/_template-slurm` or `targets/_template-nohup` for each target. The comments in the templates document
every key; [`../AGENTS.md`](../AGENTS.md) documents the `policy.sh` API (`t_partition`, `t_policy`).

## Writing a good target

- **`profile.sh`** is data, sourced locally and on the remote by bash *or* zsh: plain `KEY='value'` lines, paths
  single-quoted, only `$HOME` / `$USER` expand (on the remote). Choose the storage policy deliberately:
  `T_ENV_ROOT` (where venvs and uv caches live — move them off a filesystem that is slow on small files),
  `T_TMPDIR` (`project` or the job's `inherit`ed `$TMPDIR`), `T_COMPILE_CACHE`, and `T_SUFFIX` when two targets
  share a filesystem but not an OS or GPU architecture. `T_PARTITIONS` is a display list (error messages, `run-avail`'s
  `sinfo -p`; spaces or commas separate): `policy.sh`'s `t_partition` decides which partitions exist. `rsk grant
  add|deny|import --partition` never refuses one the list lacks — it records it as given with a NOTE, which `rsk grant
  list` / `rsk status` repeat — so list the partitions your users name, spelled as the policy takes them.
- **`T_DESC` and `T_TRIGGERS`** decide routing. `T_TRIGGERS` words are prepended to the installed skill
  description verbatim (some agents match skills lexically), so list the names people actually say: the target
  name, the site's nickname, notable partition or GPU names.
- **`policy.sh`** encodes what the scheduler will not tell you up front: per-partition GPU ranges, sensible cpu and
  memory per GPU, partition walltime caps (a request over the cap would pend forever), forced GPU types, preemption
  notes. `t_policy` can refuse a submission (exit 3) or require an acknowledgement flag — use it for queues that
  must never be hit by accident. Write every `-y` gate (in `t_policy` or `t_partition`) in one idiom, as the template
  does — print the WARNING, then test FORCE: `echo 'WARNING: … Re-run -y …' >&2; [ "$FORCE" = 1 ] || exit 1` — so a
  plan shows every gate, from the real call too, and a `-y` submit logs it. Never the P2 form
  `[ "$FORCE" = 1 ] || { echo 'WARNING: …' >&2; exit 1; }`: it is silent under `-y` and found only by the probe below
  (`tests/52` 'R5-10'). Such a gate shows on rsk's plan card: for a plan and an approved submit, `submit.sh` first runs
  `( FORCE=0; t_policy )` in a subshell, then the real one, and probes `t_partition` the same way right before its real
  call — so each may run twice and must have no side effects (no files written, nothing sent). In the probe every
  `exit 1` is a gate that is noted and passed (the function goes on: one gate never hides the next, and code after a gate
  must not assume it stopped the run); a gate that prints no `WARNING:` line gets a generic one, and everything the probe
  printed (digit runs masked) is bound into the card's `warnings_id`. Policy flags (`--<word>`, `T_FLAGS`) are bound into
  the plan (`flags=`): no standing grant covers a plan that has one, only the user's approval of its card.
- **`reference.md`** is what the agent knows about the site. Keep it to about one screen: a card with the key
  values, the filesystem story (quotas, which disk for what), partitions with their limits, interconnect, and the
  gotchas a newcomer learns the hard way. Write `<user>` / `$USER` instead of anyone's id, and never mention
  another target — cross-target choices go in `routing/`.
- **`tests.sh`** runs in the engine's selftest (phase B) with the helpers from `tests/lib.sh`
  (`mk_proj`, `sub`, `stub_sinfo`, `has`, `hasnt`, …). Test what your `policy.sh` adds: refusals, pinned nodes,
  forced GPU types, caps.

## Routing hints

The installed skill's `references/INDEX.md` lists every target of both kinds and ends with a **Routing** section. Each
pack's `routing/remote-run.md` is appended to it verbatim, so write Markdown bullets, for example:

```markdown
- "H100" alone is ambiguous: `bigcluster` partition `h100` (8 per node, NVLink, 2 d) vs `gpubox` (2 cards, no
  scheduler). Multi-GPU training → bigcluster; quick interactive checks → gpubox; else ask.
```

Packs written for the two earlier skills ship `routing/hpc-run.md` and `routing/ws-run.md`; nothing needs renaming.
A pack (or the member's `~/.config/run-skills/routing/`) without `remote-run.md` has both legacy files appended, each
once, every rule under a lead-in naming its kind (``- For `slurm` targets only …``), because it used to apply inside
that kind's skill only; a rule both files carry appears once, unscoped. With `remote-run.md`, only that file is read,
so move the legacy bullets into it when you add it, scoping each one to a kind or target where it needs that. Members
on an older engine read only the legacy names: keep those files too until everyone has run `rsk update`.

## Publishing and onboarding

1. Push the pack to a repo your members can read (keep it private if it describes non-public infrastructure).
2. In the pack's README, give members the one-liner:

   ```bash
   uv tool install git+https://github.com/NAIVlab/run-skills && rsk pack add git@github.com:<org>/<pack>.git && rsk setup
   ```

   `rsk pack add` clones into `~/.config/run-skills/packs/<pack>` (a local directory is linked instead). The pack's
   own `install.sh` still works too: it symlinks the pack and installs the engine from a clone. Members who prefer
   to let their agent do it can paste: *"Install run-skills for me with our target pack `<url>`: clone
   https://github.com/NAIVlab/run-skills to `~/.local/share/run-skills` and follow its `INSTALL.md`."* The runbook
   installs the pack, fills in the pack's `ssh_config` placeholders with the member's username, and probes the
   targets read-only.
3. Updates: `rsk update` fast-forwards every clean pack clone, upgrades rsk and re-runs `rsk setup` (a pack linked
   to a working tree is the owner's to pull; then `rsk setup`). Profile and policy edits apply at the next sync;
   changes to names, descriptions or routing need the setup to reach the skill's INDEX.

The pack's `install.sh` knobs (environment variables): `RS_ENGINE_URL` (engine repo, e.g. your fork), `RS_ENGINE_DIR`
(its clone, default `~/.local/share/run-skills`), `RS_PACKS_DIR` (default `~/.config/run-skills/packs`, which rsk reads too).

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
- No user ids, account names or personal queues in a shared pack: use placeholders (`<user>`, `<account>`) and put
  personal rules in each member's overlay. List the placeholders under "Personal facts" in the pack's README:
  INSTALL.md (Step 4) asks each member for them and writes the answers to their `reference.local.md`.
- Maintainers of a public fork can list forbidden words — one `grep -E` pattern per line, matched
  case-insensitively — in `~/.config/run-skills/forbidden-words`; the selftest then fails if any of them appears in
  the engine repo. The list lives outside the repo, so it never leaks itself.
