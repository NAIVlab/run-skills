# <pack-name> — run-skills targets for <your group>

This pack adds <your group>'s machines to [run-skills](https://github.com/NAIVlab/run-skills), so that Claude Code,
Codex or pi can run your projects there with one sentence:

| target | kind | what it is | pick it for |
|---|---|---|---|
| `bigcluster` | Slurm | <site> — <partitions, GPUs> | <multi-GPU training, long runs> |
| `gpubox` | workstation | <room / owner> — <GPUs> | <quick experiments, debugging> |

## Install (one command)

```bash
uv tool install git+https://github.com/NAIVlab/run-skills && rsk pack add git@github.com:<org>/<pack-name>.git && rsk setup
```

(Needs [uv](https://docs.astral.sh/uv/). Without it: clone this pack and run its `install.sh`.)

Or let your agent do it — paste into Claude Code, Codex or pi: *"Install run-skills for me with our target pack
`git@github.com:<org>/<pack-name>.git`: clone https://github.com/NAIVlab/run-skills to `~/.local/share/run-skills`
and follow its `INSTALL.md`."* It also sets up your ssh aliases (asking first) and the wandb key.

Either way, this installs the run-skills engine (the `rsk` command), registers this pack, installs the
`remote-run` skill and runs the offline selftest. Then:

1. **ssh**: append [`ssh_config`](ssh_config) to `~/.ssh/config`, replace `<user>`, and `ssh-copy-id <alias>` for
   each target. The installer's "ssh aliases" step tells you which ones are still missing.
2. **wandb** (optional): put your own API key in `~/.config/run-skills/wandb_env`.

**Update:** `rsk update` (the engine and this pack's clone; installed with `install.sh`: re-run it after a `git pull`)

## Use

In a project repo, ask your agent, e.g. *"run this on bigcluster, 2 GPUs, 1 day"*. The first time it scaffolds
`.hpc.conf` (see [`hpc.conf.example`](hpc.conf.example) for our directory layout) and asks for the remote dir.
Before every submit it checks whether your words already cover it (`rsk launch` reads the project's grants): if
they do, it submits and says so; if not, it shows you the plan card and waits for your "go". Charged partitions,
more resources or a wider scope than you allowed always come back to you.

## Personal facts (the install asks each member)

The pack holds placeholders only; the agent installing it asks every member for these and writes the answers to
their own overlay, `~/.config/run-skills/targets/<name>/reference.local.md`:

- `<user>`: your username on each target (also the `User` line of [`ssh_config`](ssh_config)).
- `<account>`: the Slurm account your runs should bill to, if not your default association.
- Your project directory on each target: <path pattern with `<user>`>.

## Group conventions

- QOS to use: <...>.
- Etiquette on shared boxes: <...>.

## Maintaining this pack

Edit `targets/<name>/` (profile, policy, reference, tests) and `routing/`. Check with
`rsk setup` (its selftest runs every pack target's `tests.sh`) — then push. Guide:
[run-skills docs/packs.md](https://github.com/NAIVlab/run-skills/blob/main/docs/packs.md).
