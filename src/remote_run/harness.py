"""The bash harness, driven from Python: one implementation of discovery and install (lib/common.sh, install.sh),
never a second one here."""

from __future__ import annotations

import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from remote_run import paths
from remote_run.errors import USAGE, RskError

_LIST_TARGETS = r'''
. "$RS_HOME/lib/common.sh"
for t in $(rs_targets); do
  if out=$( (rs_load_target "$t" >/dev/null 2>&1 && printf 'ok\t%s\t%s\t%s\t%s\t%s\n' "$t" "$T_KIND" "$T_HOST" "${T_XFER_HOST:-}" "$T_DIR") ); then
    printf '%s\n' "$out"
  else
    printf 'err\t%s\t%s\n' "$t" "$( (rs_load_target "$t") 2>&1 >/dev/null | tr '\t\n' '  ')"
  fi
done
'''


# ok: the target and where the project lives on it; err: its profile does not load (its kind, so its conf, is unknown);
# conf: the conf does not source. Silent only for a target with no conf of its kind or with no remote dir in it.
_PLACES = r'''
. "$RS_HOME/lib/common.sh"
for t in $(rs_targets); do
  e=$( (rs_load_target "$t") 2>&1 >/dev/null ) \
    || { printf 'err\t%s\t%s\n' "$t" "$(printf %s "$e" | tr '\t\n' '  ')"; continue; }
  ( rs_load_target "$t" >/dev/null 2>&1
    c=$(rs_conf_file); [ -f "./$c" ] || exit 0
    e=$( (rs_load_conf REMOTE_DIR WS_REMOTE_DIR REMOTE_HOST) 2>&1 >/dev/null ) \
      || { printf 'conf\t%s\t%s\n' "$c" "$(printf %s "$e" | tr '\t\n' '  ')"; exit 0; }
    rs_load_conf REMOTE_DIR WS_REMOTE_DIR REMOTE_HOST >/dev/null 2>&1
    d=$(rs_remote_dir 2>/dev/null) || exit 0
    printf 'ok\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$T_KIND" "$(rs_host)" "$d" "$(rs_deploy_dir)" "${REMOTE_HOST:-}" )
done
'''


@dataclass(frozen=True)
class Place:
    """Where a project lives on one target: resolved by lib/common.sh from the project's conf (never guessed)."""
    target: str
    kind: str = ""
    host: str = ""
    remote_dir: str = ""
    deploy: str = ""         # the deploy dir under remote_dir: .<target> (slurm) or .ws (nohup)
    remote_host: str = ""    # the conf's REMOTE_HOST: generic-only, it moves every Slurm target to one host
    error: str = ""          # the profile does not load: nothing else is known


@dataclass(frozen=True)
class Target:
    name: str
    kind: str = ""
    host: str = ""
    xfer_host: str = ""
    dir: str = ""
    error: str = ""


def env(src: Path) -> dict[str, str]:
    e = dict(os.environ)
    e["RS_HOME"] = str(src)
    e.setdefault("RS_USER_DIR", str(paths.user_dir()))
    e.setdefault("RS_PACKS_DIR", str(paths.packs_dir()))
    e.setdefault("RS_PYTHON", sys.executable)   # tests/90-py.sh: rsk's own interpreter (>= 3.11), packaged or not
    if paths.is_packaged(src):
        e["RS_PACKAGED"] = "1"     # tests/70-docs.sh: clone-only checks (symlinks, INDEX stubs) are skipped
    return e


def targets(src: Path) -> list[Target]:
    """Every registered target (overlay > packs > shipped), loaded by lib/common.sh's rs_load_target."""
    done = subprocess.run(["bash", "-c", _LIST_TARGETS], env=env(src), capture_output=True, text=True, timeout=60)
    found: list[Target] = []
    for line in done.stdout.splitlines():
        f = line.split("\t")
        if f[0] == "ok" and len(f) == 6:
            found.append(Target(f[1], f[2], f[3], f[4], f[5]))
        elif f[0] == "err" and len(f) >= 3:
            found.append(Target(f[1], error=f[2].strip()))
    return found


def run_install(src: Path) -> int:
    """install.sh from the shipped tree: harness copy, the skill + INDEX (old skills out), overlay, ssh check, selftest."""
    return subprocess.call(["bash", str(src / "install.sh")], env=env(src))


def reference(src: Path, target: str) -> str:
    """The target's reference file(s) as lib/common.sh's rs_ref names them ('' when the profile does not load)."""
    done = subprocess.run(["bash", "-c", '. "$RS_HOME/lib/common.sh"; rs_load_target "$1" >/dev/null 2>&1 && rs_ref', "rs",
                           target], env=env(src), capture_output=True, text=True, timeout=60)
    return done.stdout.strip() if done.returncode == 0 else ""


def places(src: Path, project: Path) -> list[Place]:
    """Every target whose conf (.hpc.conf for slurm, .ws.conf for nohup) in PROJECT resolves a remote dir, and every
    target whose profile does not load (Place.error). A conf that does not source fails the whole read: USAGE."""
    done = subprocess.run(["bash", "-c", _PLACES], env=env(src), cwd=project, capture_output=True, text=True, timeout=60)
    found = []
    for line in done.stdout.splitlines():
        f = line.split("\t")
        if f[0] == "ok" and len(f) == 7:
            found.append(Place(*f[1:]))
        elif f[0] == "err" and len(f) >= 3:
            found.append(Place(f[1], error=f[2].strip() or "rs_load_target failed"))
        elif f[0] == "conf" and len(f) >= 3:
            raise RskError(f"{project / f[1]} does not source: {f[2].strip()}", USAGE)
    return found
