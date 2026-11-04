root: ~/.agents/run-skills

| target | kind | host | GPUs | default | max time | description | reference |
|---|---|---|---|---|---|---|---|

no target registered yet: register one with the user (~/.agents/run-skills/INSTALL.md, Steps 2-6: run-probe, then ~/.config/run-skills/targets/<name>/ from ~/.agents/run-skills/targets/_template-slurm/ (cluster) or _template-nohup/ (workstation)) or install a target pack

## Routing
- Pick the row whose name, host, description or trigger words match the user's words. Its `kind` decides the rest:
  `slurm` (a cluster: sbatch, partitions, queues) → `procedure-slurm.md` and the project's `.hpc.conf`; `nohup` (a
  workstation, no scheduler) → `procedure-nohup.md` and the project's `.ws.conf`.
- **Placement of a new launch** (not status, logs or pulls). The user fixed it (a target plus its partition / GPU
  type, or GPU ids) → use it as given. They gave only a range ("an H200", "4 GPUs", "a free box") or nothing →
  first run `bash $ROOT/bin/run-avail [--type T] [--min N]` (free GPUs on every target, clusters and workstations,
  one read-only call). Place by what the job needs (GPU memory/type, GPUs on ONE node, walltime, preemption, cost)
  against what is free now, prefer `DEFAULT_CLUSTER` (`.hpc.conf`) or `DEFAULT_STATION` (`.ws.conf`) when it can
  start the job now, and put the numbers in the plan. A target whose `project:` column is not `set` needs
  `project-setup.md` first. Still ambiguous → ask.
- A GPU model alone ("H100") can match several clusters or partitions: decide by what the job needs (interconnect,
  walltime, per-user limits, preemption) from each candidate's reference; else ask.
- Never guess `REMOTE_DIR` (`.hpc.conf`) or `WS_REMOTE_DIR` (`.ws.conf`): local and remote names differ — a project
  without the conf of the target's kind goes through `project-setup.md`.
