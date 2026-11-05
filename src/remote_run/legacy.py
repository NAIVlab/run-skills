"""`rsk doctor --legacy-refs [DIR…]`: a read-only report of project docs that still steer agents the old way.

Looks at CLAUDE.md / AGENTS.md (also .claude/CLAUDE.md) under each DIR (default ~/projects; dot dirs other than
.claude, environments, caches, logs and checkpoints are skipped; symlinked dirs are not followed; a file reached
twice, e.g. CLAUDE.md -> AGENTS.md, is read once) and prints one line per hit:
  - the replaced skills by name: hpc-run, ws-run (now the one skill remote-run);
  - a raw `ssh … submit.sh` recipe, or a raw `run-launch` recipe (now rsk launch: plan → the user's words → submit).
The engine's own clone (src/remote_run + remote/submit.sh) is skipped: its docs describe the replacement. Nothing is
written anywhere; exit 0 whatever it finds (the lines are the report).
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from remote_run import paths

DOCS = ("CLAUDE.md", "AGENTS.md")
SKIP = {"node_modules", "__pycache__", "site-packages", "logs", "ckpts", "checkpoints", "wandb", "wandb-artifacts",
        "outputs", "runs", "run_logs", "videos", "data", "tmp", "venv", "env", "envs"}
MAX_DEPTH = 6
MAX_BYTES = 1 << 20
RULES = (
    (re.compile(r"(?<![\w-])hpc-run(?![\w-])"), "names the replaced skill hpc-run (now remote-run)"),
    (re.compile(r"(?<![\w-])ws-run(?![\w-])"), "names the replaced skill ws-run (now remote-run)"),
    (re.compile(r"\bssh\b.*submit\.sh"), "a raw `ssh … submit.sh` recipe (now: rsk launch)"),
    (re.compile(r"(?<![\w-])run-launch(?![\w-])"), "a raw run-launch recipe (now: rsk launch)"),
)


def _engine(d: Path) -> bool:
    return (d / "src" / "remote_run" / "__init__.py").is_file() and (d / "remote" / "submit.sh").is_file()


def doc_files(root: Path) -> tuple[list[Path], list[Path]]:
    """(the docs under ROOT, the engine clones skipped)."""
    found, skipped, seen = [], [], set()
    root = root.expanduser()
    if not root.is_dir():
        return [], []
    base = len(root.parts)
    for d, dirs, files in os.walk(root, followlinks=False):
        here = Path(d)
        if _engine(here):
            skipped.append(here)
            dirs[:] = []
            continue
        depth = len(here.parts) - base
        dirs[:] = sorted(x for x in dirs if depth < MAX_DEPTH and x not in SKIP and (x == ".claude" or not x.startswith("."))
                         and not x.startswith(".venv") and not (here / x).is_symlink())
        for f in sorted(files, key=lambda f: ((here / f).is_symlink(), f)):   # the real file over its alias
            if f in DOCS:
                p = here / f
                try:
                    real = p.resolve()
                except OSError:
                    continue
                if real not in seen and real.is_file():
                    seen.add(real)
                    found.append(p)
    return found, skipped


def scan(path: Path) -> list[tuple[int, str, str]]:
    try:
        raw = path.read_bytes()[:MAX_BYTES]
    except OSError:
        return []
    hits = []
    for n, line in enumerate(raw.decode("utf-8", "replace").splitlines(), 1):
        for rx, what in RULES:
            if rx.search(line):
                hits.append((n, what, " ".join(line.split())[:140]))
    return hits


def report(dirs: list[str]) -> list[str]:
    roots = [Path(x) for x in dirs] or [paths.home() / "projects"]
    lines, nfiles, nhit, files_hit = [], 0, 0, 0
    for r in roots:
        docs, skipped = doc_files(r)
        lines.append(f"== {r} — {len(docs)} CLAUDE.md / AGENTS.md file(s) (read-only) ==" if r.expanduser().is_dir()
                     else f"== {r} — not a directory ==")
        lines += [f"  skipped {s} (the run-skills engine itself: its docs describe the replacement)" for s in skipped]
        for p in docs:
            nfiles += 1
            hits = scan(p)
            files_hit += bool(hits)
            for n, what, text in hits:
                nhit += 1
                lines.append(f"  {p}:{n}: {what}: {text}")
    lines.append(f"== {nhit} legacy reference(s) in {files_hit} of {nfiles} file(s) =="
                 + ("" if not nhit else " — point them at the remote-run skill / rsk launch (the user decides the edit)"))
    return lines


def cmd_legacy_refs(dirs: list[str]) -> int:
    print("\n".join(report(dirs)), flush=True)
    return 0
