"""Target packs under ~/.config/run-skills/packs/<name>: a git clone (updated by `rsk update`), or a symlink to a
working tree the user develops in (never pulled — its owner does that), or a plain directory (left alone)."""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlparse

from remote_run.errors import CONFLICT, OK, UNKNOWN, RskError


@dataclass(frozen=True)
class Pack:
    name: str
    path: Path
    kind: str            # clone | link | dir
    origin: str = ""     # a clone: its origin URL; a link: the resolved path (shown)
    branch: str = ""
    dirty: bool = False
    upstream: str = ""   # e.g. origin/main ("" = no upstream configured)
    remote: str = ""     # the git origin URL, also of the working tree a link points at (compared by add)


def _git(path: Path, *args: str, timeout: float = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True, timeout=timeout)


def inspect(path: Path) -> Pack:
    name = path.name
    if path.is_symlink():   # e.g. made by the pack's own install.sh: its git origin still identifies the pack
        return Pack(name, path, "link", origin=str(path.resolve()), remote=_origin(path.resolve()))
    if not (path / ".git").exists():
        return Pack(name, path, "dir")
    origin = _origin(path)
    branch = _git(path, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    dirty = bool(_git(path, "status", "--porcelain", "--untracked-files=no").stdout.strip())
    up = _git(path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    return Pack(name, path, "clone", origin, branch, dirty, up.stdout.strip() if up.returncode == 0 else "", origin)


def _origin(path: Path) -> str:
    done = _git(path, "remote", "get-url", "origin")
    return done.stdout.strip() if done.returncode == 0 else ""


def norm_url(url: str) -> str:
    """One spelling per repository, to spot a pack registered twice: `git@Host:org/x.git`, `ssh://git@host:22/org/x/`
    and `https://host/org/x` all give `host/org/x` (host lowercased; user, port, trailing / and .git dropped); a local
    path or file:// URL gives its resolved path."""
    url = url.strip()
    if not url:
        return ""
    if "://" in url:
        u = urlparse(url)
        if u.scheme == "file":
            return str(Path(unquote(u.path)).resolve())
        host, path = (u.hostname or "").lower(), u.path
    elif re.match(r"[^/]+:", url):   # scp-like [user@]host:path — git's rule: no slash before the first colon
        where, path = url.split(":", 1)
        host = where.rsplit("@", 1)[-1].lower()
    else:
        return str(Path(url).expanduser().resolve())
    return f"{host}/{re.sub(r'[.]git$', '', path.strip('/')).rstrip('/')}"


def all_packs(packs_dir: Path) -> list[Pack]:
    if not packs_dir.is_dir():
        return []
    return [inspect(p) for p in sorted(packs_dir.iterdir()) if p.is_dir() and (p / "targets").is_dir()]


def fast_forward(pack: Pack) -> tuple[bool, str, int]:
    """Update a clean clone that tracks an upstream: fetch + merge --ff-only. (changed, message, exit code): a pack
    that should have been updated and was not is UNKNOWN (the fetch failed) or CONFLICT (local changes or commits)."""
    if pack.kind == "link":
        return False, f"{pack.name}: a link to {pack.origin} (your working tree) — not pulled; update it yourself", OK
    if pack.kind == "dir":
        return False, f"{pack.name}: not a git clone — left alone", OK
    if pack.dirty:
        return False, f"{pack.name}: has uncommitted changes — skipped; commit or stash, then rsk update", CONFLICT
    if not pack.upstream:
        return False, f"{pack.name}: branch {pack.branch or '?'} tracks no upstream — skipped", OK
    before = _git(pack.path, "rev-parse", "HEAD").stdout.strip()
    fetch = _git(pack.path, "fetch", "--quiet")
    if fetch.returncode != 0:
        return False, f"{pack.name}: git fetch failed: {fetch.stderr.strip()[:200]}", UNKNOWN
    merge = _git(pack.path, "merge", "--ff-only", "--quiet", pack.upstream)
    if merge.returncode != 0:
        return False, f"{pack.name}: cannot fast-forward to {pack.upstream} (local commits?) — skipped", CONFLICT
    after = _git(pack.path, "rev-parse", "HEAD").stdout.strip()
    if before == after:
        return False, f"{pack.name}: up to date ({after[:12]})", OK
    return True, f"{pack.name}: {before[:12]} -> {after[:12]}", OK


def default_name(source: str) -> str:
    """`git@host:Org/run-skills-lab.git` -> `lab` (the run-skills- prefix is dropped); a path -> its basename."""
    base = re.sub(r"\.git$", "", source.rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1])
    return re.sub(r"^run-skills-", "", base) or base


def add(packs_dir: Path, source: str, name: str | None) -> tuple[Path, str]:
    """Register a pack: a local directory is linked, anything else is cloned. Refuses a second copy: the same
    directory, or the same repository by any URL spelling, whether registered as a clone or as a link."""
    local = Path(source).expanduser()
    name = name or default_name(source)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
        raise RskError(f"pack name {name!r}: letters, digits, . _ - only")
    wanted = {norm_url(source), norm_url(_origin(local)) if local.is_dir() else ""} - {""}
    for p in all_packs(packs_dir):   # the same pack under another name would list its routing twice
        same = (local.is_dir() and p.path.resolve() == local.resolve()) or wanted & {norm_url(p.origin), norm_url(p.remote)}
        if same:
            return p.path, f"already registered as {p.name} ({p.path})"
    dest = packs_dir / name
    if dest.exists() or dest.is_symlink():
        raise RskError(f"{dest} already exists and is not {source} — pick another --name or move it away")
    packs_dir.mkdir(parents=True, exist_ok=True)
    if local.is_dir():
        if not (local / "targets").is_dir():
            raise RskError(f"{local} has no targets/ directory — not a target pack")
        dest.symlink_to(local.resolve())
        return dest, f"linked {dest} -> {local.resolve()}"
    clone = subprocess.run(["git", "clone", "--quiet", source, str(dest)], capture_output=True, text=True, timeout=300)
    if clone.returncode != 0:
        raise RskError(f"git clone {source} failed (access to a private pack needs your git credentials): "
                       f"{clone.stderr.strip()[:300]}")
    if not (dest / "targets").is_dir():
        return dest, f"cloned to {dest}, but it has no targets/ — is this a target pack?"
    return dest, f"cloned {source} -> {dest}"
