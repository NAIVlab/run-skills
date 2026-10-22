# <name> — <institution / cluster> (Slurm)  ·  `TARGET=<name>`

Template: copy next to your `profile.sh` in `~/.config/run-skills/targets/<name>/` and fill every section. The skill
reads this file and nothing else about the target, so keep it self-contained (no references to other targets), one
screen long, and free of personal ids (write `<user>`, `$USER`). Re-run `install.sh` to list it in `INDEX.md`.

## Card
| host | deploy dir | tag | default partition / GPU type | walltime cap | suffix |
|---|---|---|---|---|---|
| `<ssh alias>` (`<fqdn>`) | `.<name>/` | `<TAG>_` | `<T_DEFAULT_PARTITION>` / `<T_DEFAULT_GPU_TYPE>` | `<T_MAXTIME>` | `<T_SUFFIX or none>` |

## Cluster
- Login node, OS, Slurm version, accounting (`ACCOUNT` needed? how to list associations), QOS names.
- Data transfer: does the site require copies to go through a transfer node (`T_XFER_HOST`)? What its shell accepts.
- How conda is initialised (`T_CONDA_INIT`), `CUDA_HOME` (`T_CUDA_HOME`), module loads a job needs.

## Filesystem
- `$HOME` size and rules; the project filesystem (where `REMOTE_DIR` lives) and its quirks (small-file performance,
  quotas); scratch / node-local `/tmp`. Say which of these the profile's `T_ENV_ROOT` / `T_TMPDIR` /
  `T_COMPILE_CACHE` point at and why.

## Partitions (exactly the names `policy.sh` accepts)
| partition | nodes | GPUs | `-g` | cpus / mem per GPU | preemption / QOS | notes |
|---|---|---|---|---|---|---|
| `<p1>` | | | `<P_GPUS>` | `<P_CPU_PER_GPU>` / `<P_MEM_PER_GPU>`G | | |

- Per-partition MaxTime exceptions (`P_MAXTIME`), GPU types for `-G`, interconnect (NVLink? topology), preemption
  semantics (what `--requeue` means here), paid vs free partitions and what `-y` acknowledges.

## Containment / storage on this target
What `env.sh` pins where under this profile's policy (venv path, caches, `TMPDIR`, compile caches, Ray), and any
sanctioned exceptions.

## Gotchas
- Known failure modes, drained nodes, allocator flags, single-node limits, default cpu/mem heuristics.
