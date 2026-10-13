# <alias> — <lab / room> GPU workstation (no scheduler)  ·  `TARGET=<alias>`

Template: copy next to your `profile.sh` in `~/.config/run-skills/targets/<alias>/` and fill every section. The
skill reads this file and nothing else about the box, so keep it self-contained, short, and free of personal ids
(write `<user>`, `$USER`). Re-run `install.sh` to list it in `INDEX.md`.

## Card
| host | deploy dir | tag | GPUs | RAM / CPUs | suffix |
|---|---|---|---|---|---|
| `<ssh alias>` (`<hostname>`) | `.ws/` | `<TAG>_` | `<T_GPUS>` | | `<T_SUFFIX or none>` |

## Box
- OS, driver / CUDA version, how to reach it (ProxyJump? VPN?) — the alias in `~/.ssh/config` owns all of that.
- conda location (`T_CONDA_INIT`), whether `uv` is preinstalled (`run-bootstrap` installs a private copy otherwise).

## Filesystem
- `$HOME` type and free space (`WS_REMOTE_DIR` is relative to it), other disks, and the size of `/tmp`
  (the profile keeps `TMPDIR` in-project when it is small).

## GPUs and sharing
- Who else uses the box, which GPU ids are reserved (`GPU_EXCLUDE` in the conf), how to check before launching
  (`nvidia-smi`, `ps -eo pid,etime,cmd`), usual `NICE` etiquette.

## Containment / storage on this target
What `.ws/env.sh` pins where under this profile's policy (venv, caches, `TMPDIR`, Ray) and any exceptions.

## Gotchas
- Known quirks (driver mismatches, per-arch wheels, ports in use, reboot schedule).
