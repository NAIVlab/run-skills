"""How this rsk was installed, and the commands that update it.

Read from the files installers leave behind: the package's PEP 610 ``direct_url.json`` (git URL and commit,
local directory, editable) and uv's ``uv-receipt.toml`` next to the tool interpreter (installed with
``uv tool install``). Two uv details decide the commands:
- a tool installed from a git ref (``@v3.1`` or ``@main``) keeps that ref on ``uv tool upgrade``, so a pinned
  install is refreshed with ``uv tool install --force --reinstall git+URL@REF`` (a branch moves, a tag stays);
- uv caches the build of a local directory by version, so a directory install needs ``--reinstall``.
An editable install or a source checkout is updated with git by its owner; rsk only says how.
What a requested ref is on the remote (tag, branch or commit) is asked with ``git ls-remote`` (``remote_ref``).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from importlib import metadata
from pathlib import Path
from urllib.parse import unquote, urlparse

DIST = "remote-run"
ENTRY = "rsk"
UPSTREAM = "https://github.com/NAIVlab/run-skills"
SHA = re.compile(r"[0-9a-f]{7,40}")


@dataclass(frozen=True)
class Install:
    kind: str                              # git | dir | editable | source | other
    source: str                            # git URL, directory, checkout or interpreter prefix
    commit: str = ""                       # installed git commit (git installs)
    ref: str = ""                          # requested git ref, if the install named one
    uv_tool: bool = False                  # installed with `uv tool install`
    steps: tuple[tuple[str, ...], ...] = field(default=())   # commands that update it, in order
    manual: str = ""                       # the same as one line to run by hand

    def describe(self) -> str:
        how = "uv tool" if self.uv_tool else {"source": "a source checkout", "editable": "an editable install"}.get(
            self.kind, "pip or another installer")
        where = f"{self.source}" + (f"@{self.ref}" if self.ref else "") + (f" ({self.commit[:12]})" if self.commit else "")
        return f"installed with {how} from {where}"


def find_uv() -> str | None:
    """uv on PATH, else where its installer puts it (a non-login shell may lack ~/.local/bin)."""
    found = shutil.which("uv")
    if found:
        return found
    for d in (os.environ.get("UV_INSTALL_DIR"), os.environ.get("XDG_BIN_HOME"),
              str(Path.home() / ".local" / "bin"), str(Path.home() / ".cargo" / "bin")):
        if d and (Path(d) / "uv").is_file() and os.access(Path(d) / "uv", os.X_OK):
            return str(Path(d) / "uv")
    return None


def read_direct_url() -> dict | None:
    try:
        text = metadata.distribution(DIST).read_text("direct_url.json")
    except metadata.PackageNotFoundError:
        return None
    return json.loads(text) if text else None


def read_receipt(prefix: Path) -> dict | None:
    path = prefix / "uv-receipt.toml"
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return None


def entry_path(receipt: dict | None) -> str | None:
    """Where uv put the `rsk` executable (the receipt's entrypoints), else PATH's `rsk`."""
    for e in ((receipt or {}).get("tool", {}).get("entrypoints", []) or []):
        if isinstance(e, dict) and e.get("name") == ENTRY and e.get("install-path"):
            return str(e["install-path"])
    return shutil.which(ENTRY)


def _file_path(url: str) -> str:
    p = urlparse(url)
    return unquote(p.path) if p.scheme == "file" else url


def detect(direct_url: dict | None, receipt: dict | None, uv: str | None, checkout: Path | None) -> Install:
    """Classify an install from its files (pure: tests pass fakes)."""
    uv_tool = receipt is not None
    if direct_url is None:
        src = str(checkout) if checkout else sys.prefix
        return Install("source", src, manual=f"git -C {src} pull --ff-only   (running from a source checkout)")
    url = str(direct_url.get("url", ""))
    vcs = direct_url.get("vcs_info")
    dir_info = direct_url.get("dir_info")
    if isinstance(dir_info, dict) and dir_info.get("editable"):
        path = _file_path(url)
        return Install("editable", path, uv_tool=uv_tool,
                       manual=f"git -C {path} pull --ff-only   (editable install: the checkout is the install)")
    if isinstance(vcs, dict) and vcs.get("vcs") == "git":
        commit, ref = str(vcs.get("commit_id", "")), str(vcs.get("requested_revision", "") or "")
        target = f"git+{url}" + (f"@{ref}" if ref else "")
        cmd = ("tool", "install", "--force", "--reinstall", target) if ref else ("tool", "upgrade", "--reinstall", DIST)
        manual = "uv " + " ".join(cmd)
        if not uv_tool:
            return Install("git", url, commit, ref, manual=f"{sys.executable} -m pip install --upgrade {target}")
        return Install("git", url, commit, ref, True, ((uv, *cmd),) if uv else (), manual)
    if isinstance(dir_info, dict):
        path = _file_path(url)
        cmd = ("tool", "install", "--force", "--reinstall", path)
        if not uv_tool:
            return Install("dir", path, manual=f"{sys.executable} -m pip install --upgrade {path}")
        return Install("dir", path, uv_tool=True, steps=((uv, *cmd),) if uv else (), manual="uv " + " ".join(cmd))
    return Install("other", url or sys.prefix, uv_tool=uv_tool,
                   manual=f"uv tool install --force --reinstall git+{UPSTREAM}")


def current() -> Install:
    from remote_run import paths   # late: tests import this module without a harness
    checkout = paths.PKG.parent.parent if (paths.PKG.parent.parent / "install.sh").is_file() else None
    return detect(read_direct_url(), read_receipt(Path(sys.prefix)), find_uv(), checkout)


def steps_to(inst: Install, ref: str, uv: str | None) -> tuple[tuple[str, ...], ...]:
    """`rsk update --to REF`: reinstall from the same git URL at REF (git installs only)."""
    if inst.kind != "git" or not inst.uv_tool or not uv:
        return ()
    return ((uv, "tool", "install", "--force", "--reinstall", f"git+{inst.source}@{ref}"),)


def remote_ref(url: str, ref: str) -> tuple[str, str, str]:
    """What REF names at URL: (kind, commit, error), kind = tag | branch | commit | head, or "" with the error.
    A full SHA is not queried; an annotated tag lists its tag object first, so its peeled ``^{}`` line wins over it,
    and a branch must be refs/heads/REF exactly (``ls-remote URL main`` also lists refs/heads/dev/main)."""
    if len(ref) == 40 and SHA.fullmatch(ref):
        return "commit", ref, ""
    names = (f"refs/tags/{ref}^{{}}", f"refs/tags/{ref}", f"refs/heads/{ref}") if ref else ("HEAD",)
    try:
        done = subprocess.run(["git", "ls-remote", url, *names], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return "", "", str(exc)[:120]
    if done.returncode != 0:
        return "", "", " ".join(done.stderr.split())[:120] or f"git ls-remote exited {done.returncode}"
    seen = {name: sha for sha, _, name in (line.partition("\t") for line in done.stdout.splitlines())}
    for name, kind in zip(names, ("tag", "tag", "branch") if ref else ("head",)):
        if seen.get(name):
            return kind, seen[name], ""
    if SHA.fullmatch(ref):   # an abbreviated commit: no tag or branch has that name
        return "commit", ref, ""
    return "", "", f"no tag or branch {ref!r} there"
