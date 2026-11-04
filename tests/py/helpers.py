"""Shared fixtures for the rsk unit tests: a scratch HOME with every RS_* dir inside it, and a throwaway git identity
for fixture repos (never the user's)."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

GIT_ENV = {"GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
           "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}


class ScratchHome(unittest.TestCase):
    """Each test runs with HOME and RS_USER_DIR / RS_PACKS_DIR / RS_STATE_DIR / RS_HARNESS_ROOT / RS_SKILLS_ROOT in a
    temp dir, so nothing reads or writes the real ~/.config/run-skills or ~/.agents."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        env = {"HOME": str(self.home), "RS_USER_DIR": str(self.home / "cfg"), "RS_PACKS_DIR": str(self.home / "cfg/packs"),
               "RS_STATE_DIR": str(self.home / "state"), "RS_HARNESS_ROOT": str(self.home / "harness"),
               "RS_SKILLS_ROOT": str(self.home / "skills"), **GIT_ENV}
        self._env = mock.patch.dict(os.environ, env)
        self._env.start()
        for k in ("XDG_STATE_HOME", "PYTHONPATH"):
            os.environ.pop(k, None)

    def tearDown(self) -> None:
        self._env.stop()
        self._tmp.cleanup()


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True,
                          env={**os.environ, **GIT_ENV}).stdout.strip()


def make_repo(path: Path, files: dict[str, str]) -> Path:
    path.mkdir(parents=True)
    git(path, "init", "-q", "-b", "main")
    for name, text in files.items():
        (path / name).parent.mkdir(parents=True, exist_ok=True)
        (path / name).write_text(text)
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "init")
    return path
