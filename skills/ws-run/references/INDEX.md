root: ~/.agents/run-skills

| target | host | GPUs | default | max time | description | reference |
|---|---|---|---|---|---|---|

no workstation registered yet: add ~/.config/run-skills/targets/<name>/profile.sh from ~/.agents/run-skills/targets/_template-nohup/ (or a target pack) and re-run install.sh

## Routing
- Pick the row whose name, host or description matches the user's words; if they name none, use `DEFAULT_STATION`
  from the project's `.ws.conf`; if still ambiguous, ask.
- A Slurm cluster (sbatch, partitions, queues) belongs to the **hpc-run** skill, not this one.
- Never guess `WS_REMOTE_DIR`: scaffold `.ws.conf` and ask for it.
