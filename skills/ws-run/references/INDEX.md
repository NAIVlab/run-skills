root: ~/.agents/run-skills

| target | host | GPUs | default | max time | description | reference |
|---|---|---|---|---|---|---|

no workstation registered yet: register one with the user (~/.agents/run-skills/INSTALL.md, Steps 2-6: run-probe, then ~/.config/run-skills/targets/<name>/ from ~/.agents/run-skills/targets/_template-nohup/) or install a target pack

## Routing
- Pick the row whose name, host or description matches the user's words.
- **Placement of a new launch** (not status, logs or pulls). The user fixed it (a target plus its partition / GPU
  type, or GPU ids) → use it as given. They gave only a range ("an H200", "4 GPUs", "a free box") or nothing →
  first run `bash $ROOT/bin/run-avail [--type T] [--min N]` (free GPUs on every target, clusters and workstations,
  one read-only call). Place by what the job needs (GPU memory/type, GPUs on ONE node, walltime, preemption, cost)
  against what is free now, prefer `DEFAULT_STATION` (`.ws.conf`) when it can start the job now, and put the numbers
  in the plan. A cluster runs via hpc-run, a workstation via ws-run; a target whose `project:` column is not `set`
  needs `project-setup.md` first. Still ambiguous → ask.
- A Slurm cluster (sbatch, partitions, queues) belongs to the **hpc-run** skill, not this one.
- Never guess `WS_REMOTE_DIR`: a project without `.ws.conf` goes through `project-setup.md`.
