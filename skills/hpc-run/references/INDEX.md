root: ~/.agents/run-skills

| target | host | GPUs | default | max time | description | reference |
|---|---|---|---|---|---|---|

no cluster registered yet: add ~/.config/run-skills/targets/<name>/profile.sh from ~/.agents/run-skills/targets/_template-slurm/ (or a target pack) and re-run install.sh

## Routing
- Pick the row whose name, host, description or trigger words match the user's words; if they name none, use
  `DEFAULT_CLUSTER` from the project's `.hpc.conf`; if still ambiguous, ask.
- A GPU model alone ("H100") can match several clusters or partitions: decide by what the job needs (interconnect,
  walltime, per-user limits, preemption) from each candidate's reference; else ask.
- A workstation without a scheduler belongs to the **ws-run** skill, not this one.
- Never guess `REMOTE_DIR`: local and remote names differ — scaffold `.hpc.conf` and ask for it.
