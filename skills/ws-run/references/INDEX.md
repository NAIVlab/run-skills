root: ~/.agents/run-skills

| target | host | GPUs | default | max time | description | reference |
|---|---|---|---|---|---|---|

no workstation registered yet: register one with the user (~/.agents/run-skills/INSTALL.md, Steps 2-6: run-probe, then ~/.config/run-skills/targets/<name>/ from ~/.agents/run-skills/targets/_template-nohup/) or install a target pack

## Routing
- Pick the row whose name, host or description matches the user's words; if they name none, use `DEFAULT_STATION`
  from the project's `.ws.conf`; if still ambiguous, ask.
- A Slurm cluster (sbatch, partitions, queues) belongs to the **hpc-run** skill, not this one.
- Never guess `WS_REMOTE_DIR`: a project without `.ws.conf` goes through `project-setup.md`.
