"""Where things live. Same defaults and RS_* overrides as lib/common.sh and install.sh.

- the harness tree (bin lib remote targets skills ...): inside the wheel under remote_run/_harness, else the
  source checkout this package sits in (editable installs, `python -m remote_run` from a clone);
- the user's dir ~/.config/run-skills (overlay targets, packs/, wandb_env, config.toml) — never touched by updates;
- the state dir ~/.local/state/run-skills (install record, update history, later the run ledger);
- the installed harness copy ~/.agents/run-skills and the skills root ~/.agents/skills (written by install.sh);
- the other roots agents scan for skills: ~/.claude/skills, $CODEX_HOME/skills, $PI_HOME/skills (install.sh's defaults).
"""

from __future__ import annotations

import os
from pathlib import Path

from remote_run.errors import RskError

PKG = Path(__file__).resolve().parent
PACKAGED = PKG / "_harness"


def _env_path(name: str, default: Path) -> Path:
    value = os.environ.get(name, "")
    return Path(value).expanduser() if value else default


def harness_src() -> Path:
    """The harness tree this rsk ships: the packaged copy, else the checkout around src/remote_run."""
    if (PACKAGED / "lib" / "common.sh").is_file():
        return PACKAGED
    checkout = PKG.parent.parent
    if (checkout / "lib" / "common.sh").is_file() and (checkout / "install.sh").is_file():
        return checkout
    raise RskError(f"the harness files are missing next to {PKG} (a broken install?) — reinstall: "
                   "uv tool install --force --reinstall git+https://github.com/NAIVlab/run-skills")


def is_packaged(src: Path) -> bool:
    return src == PACKAGED


def home() -> Path:
    return Path.home()


def user_dir() -> Path:
    return _env_path("RS_USER_DIR", home() / ".config" / "run-skills")


def packs_dir() -> Path:
    return _env_path("RS_PACKS_DIR", user_dir() / "packs")


def config_file() -> Path:
    return user_dir() / "config.toml"


def state_dir() -> Path:
    xdg = os.environ.get("XDG_STATE_HOME", "")
    base = Path(xdg) if xdg else home() / ".local" / "state"
    return _env_path("RS_STATE_DIR", base / "run-skills")


def harness_root() -> Path:
    return _env_path("RS_HARNESS_ROOT", home() / ".agents" / "run-skills")


def skills_root() -> Path:
    return _env_path("RS_SKILLS_ROOT", home() / ".agents" / "skills")


def skill_roots() -> list[Path]:
    """Every directory an agent scans for skills, as install.sh names them: Claude Code, Codex, pi, the shared root."""
    return [home() / ".claude" / "skills", _env_path("CODEX_HOME", home() / ".codex") / "skills",
            _env_path("PI_HOME", home() / ".pi" / "agent") / "skills", skills_root()]
