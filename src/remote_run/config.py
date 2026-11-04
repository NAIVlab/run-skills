"""~/.config/run-skills/config.toml: rsk's own settings. Site facts never go here (they live in packs and the
overlay's profile.sh / policy.sh / reference.md); the file may be absent, and every key has a default."""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from remote_run.errors import RskError

# section -> key -> (type, default, help)
SCHEMA: dict[str, dict[str, tuple[type, object, str]]] = {
    "update": {
        "packs": (bool, True, "rsk update also fast-forwards clean git clones under packs/"),
    },
}


@dataclass(frozen=True)
class Config:
    values: dict[str, dict[str, object]]
    path: Path
    exists: bool
    unknown: tuple[str, ...] = field(default=())

    def get(self, section: str, key: str) -> object:
        return self.values[section][key]


def defaults() -> dict[str, dict[str, object]]:
    return {s: {k: spec[1] for k, spec in keys.items()} for s, keys in SCHEMA.items()}


def load(path: Path) -> Config:
    """Read PATH (absent = all defaults). Wrong types are errors; unknown keys are reported, not fatal."""
    values = defaults()
    if not path.is_file():
        return Config(values, path, False)
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise RskError(f"{path}: cannot read: {exc}") from exc
    unknown: list[str] = []
    for section, table in data.items():
        if section not in SCHEMA or not isinstance(table, dict):
            unknown.append(section)
            continue
        for key, value in table.items():
            spec = SCHEMA[section].get(key)
            if spec is None:
                unknown.append(f"{section}.{key}")
                continue
            if not isinstance(value, spec[0]):
                raise RskError(f"{path}: {section}.{key} must be {spec[0].__name__}, got {value!r}")
            values[section][key] = value
    return Config(values, path, True, tuple(unknown))


def describe() -> str:
    """The documented keys, as a commented config.toml."""
    lines = ["# ~/.config/run-skills/config.toml — rsk settings only; sites live in packs/ and targets/."]
    for section, keys in SCHEMA.items():
        lines.append(f"[{section}]")
        for key, (_typ, default, help_text) in keys.items():
            shown = str(default).lower() if isinstance(default, bool) else repr(default)
            lines.append(f"{key} = {shown}    # {help_text}")
    return "\n".join(lines)
