# <pack-name> — run-skills targets for <your group>

This pack adds <your group>'s machines to [run-skills](https://github.com/NAIVlab/run-skills), so that Claude Code,
Codex or pi can run your projects there with one sentence:

| target | kind | what it is | pick it for |
|---|---|---|---|
| `bigcluster` | Slurm | <site> — <partitions, GPUs> | <multi-GPU training, long runs> |
| `gpubox` | workstation | <room / owner> — <GPUs> | <quick experiments, debugging> |

## Install (one command)

```bash
git clone git@github.com:<org>/<pack-name>.git ~/.config/run-skills/packs/<pack-name> \
  && bash ~/.config/run-skills/packs/<pack-name>/install.sh
```

This installs (or updates) the run-skills engine in `~/.local/share/run-skills`, registers this pack, installs the
`hpc-run` / `ws-run` skills and runs the offline selftest. Then:

1. **ssh**: append [`ssh_config`](ssh_config) to `~/.ssh/config`, replace `<user>`, and `ssh-copy-id <alias>` for
   each target. The installer's "ssh aliases" step tells you which ones are still missing.
2. **wandb** (optional): put your own API key in `~/.config/run-skills/wandb_env`.

**Update:** `git -C ~/.config/run-skills/packs/<pack-name> pull && bash ~/.config/run-skills/packs/<pack-name>/install.sh`

## Use

In a project repo, ask your agent, e.g. *"run this on bigcluster, 2 GPUs, 1 day"*. The first time it scaffolds
`.hpc.conf` (see [`hpc.conf.example`](hpc.conf.example) for our directory layout) and asks for the remote dir.
It always shows a one-line plan and waits for your "go" before submitting.

## Group conventions

- Where project directories live on each target: <path pattern>.
- Accounts / QOS to use: <...>.
- Etiquette on shared boxes: <...>.

## Maintaining this pack

Edit `targets/<name>/` (profile, policy, reference, tests) and `routing/`. Check with
`bash ~/.local/share/run-skills/selftest.sh` — it runs every pack target's `tests.sh` — then push. Guide:
[run-skills docs/packs.md](https://github.com/NAIVlab/run-skills/blob/main/docs/packs.md).
