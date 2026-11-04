"""Target packs: naming, registering (link or clone, never twice) and the fast-forward rules of rsk update."""

import subprocess
import unittest
from unittest import mock

from helpers import ScratchHome, git, make_repo

from remote_run import packs, paths
from remote_run.errors import CONFLICT, OK, UNKNOWN, RskError

PACK_FILES = {"targets/fx/profile.sh": "T_KIND=slurm; T_HOST=fx\n", "routing/hpc-run.md": "- rule\n"}


class Names(unittest.TestCase):
    def test_default_name(self):
        self.assertEqual(packs.default_name("git@github.com:Org/run-skills-lab.git"), "lab")
        self.assertEqual(packs.default_name("https://example.invalid/org/sites.git"), "sites")
        self.assertEqual(packs.default_name("/home/u/run-skills-lab/"), "lab")

    def test_norm_url_one_spelling_per_repository(self):
        for url in ("git@GitHub.com:Org/run-skills-lab.git", "ssh://git@github.com/Org/run-skills-lab",
                    "ssh://git@github.com:22/Org/run-skills-lab.git/", "https://GitHub.com/Org/run-skills-lab/",
                    "https://github.com/Org/run-skills-lab.git"):
            self.assertEqual(packs.norm_url(url), "github.com/Org/run-skills-lab", url)
        self.assertNotEqual(packs.norm_url("git@github.com:Org/run-skills-lab"), packs.norm_url("git@github.com:Org/lab"))
        self.assertEqual(packs.norm_url("file:///tmp/../tmp/x"), packs.norm_url("/tmp/x"))
        self.assertEqual(packs.norm_url(""), "")


def no_clone(real=subprocess.run):
    """packs.add must find the duplicate before it clones anything (the test URLs are not reachable)."""
    def run(cmd, *a, **kw):
        if "clone" in cmd:
            raise AssertionError(f"cloned: {cmd}")
        return real(cmd, *a, **kw)
    return mock.patch.object(packs.subprocess, "run", side_effect=run)


class Register(ScratchHome):
    def test_local_dir_is_linked_once(self):
        src = make_repo(self.home / "src" / "run-skills-lab", PACK_FILES)
        dest, msg = packs.add(paths.packs_dir(), str(src), None)
        self.assertTrue(dest.is_symlink())
        self.assertEqual(dest.name, "lab")
        again, msg = packs.add(paths.packs_dir(), str(src), "other")
        self.assertEqual(again, dest)
        self.assertIn("already registered", msg)
        self.assertEqual([p.kind for p in packs.all_packs(paths.packs_dir())], ["link"])

    def test_a_dir_without_targets_is_refused(self):
        (self.home / "notapack").mkdir()
        with self.assertRaises(RskError):
            packs.add(paths.packs_dir(), str(self.home / "notapack"), None)

    def test_clone_then_fast_forward(self):
        origin = make_repo(self.home / "origin" / "run-skills-lab", PACK_FILES)
        dest, _ = packs.add(paths.packs_dir(), f"file://{origin}", None)
        p = packs.inspect(dest)
        self.assertEqual((p.kind, p.branch, p.dirty, p.upstream), ("clone", "main", False, "origin/main"))
        changed, msg, code = packs.fast_forward(p)
        self.assertEqual((changed, code), (False, OK))
        self.assertIn("up to date", msg)
        (origin / "targets/fx/reference.md").write_text("new\n")
        git(origin, "add", "-A")
        git(origin, "commit", "-q", "-m", "more")
        changed, msg, code = packs.fast_forward(packs.inspect(dest))
        self.assertEqual((changed, code), (True, OK), msg)
        self.assertTrue((dest / "targets/fx/reference.md").is_file())

    def test_dirty_or_diverged_clone_is_skipped(self):
        origin = make_repo(self.home / "origin" / "lab", PACK_FILES)
        dest, _ = packs.add(paths.packs_dir(), f"file://{origin}", None)
        (dest / "targets/fx/profile.sh").write_text("T_KIND=slurm; T_HOST=changed\n")
        changed, msg, code = packs.fast_forward(packs.inspect(dest))
        self.assertEqual((changed, code), (False, CONFLICT))
        self.assertIn("uncommitted", msg)
        git(dest, "commit", "-qam", "local")
        (origin / "x").write_text("x")
        git(origin, "add", "-A")
        git(origin, "commit", "-q", "-m", "upstream")
        changed, msg, code = packs.fast_forward(packs.inspect(dest))
        self.assertEqual((changed, code), (False, CONFLICT))
        self.assertIn("cannot fast-forward", msg)

    def test_fetch_failure_is_unknown(self):
        origin = make_repo(self.home / "origin" / "lab", PACK_FILES)
        dest, _ = packs.add(paths.packs_dir(), f"file://{origin}", None)
        origin.rename(self.home / "gone")
        changed, msg, code = packs.fast_forward(packs.inspect(dest))
        self.assertEqual((changed, code), (False, UNKNOWN))
        self.assertIn("git fetch failed", msg)

    def test_link_and_plain_dir_are_left_alone(self):
        src = make_repo(self.home / "src" / "lab", PACK_FILES)
        dest, _ = packs.add(paths.packs_dir(), str(src), None)
        self.assertEqual(packs.fast_forward(packs.inspect(dest))[1:], (f"lab: a link to {src} (your working tree) — "
                                                                       "not pulled; update it yourself", OK))
        plain = paths.packs_dir() / "plain" / "targets"
        plain.mkdir(parents=True)
        self.assertEqual(packs.fast_forward(packs.inspect(plain.parent))[1:], ("plain: not a git clone — left alone", OK))

    def test_a_link_made_by_the_packs_install_sh_is_found_by_its_url(self):
        # the pack's own install.sh links packs/<clone dir name> -> the clone; a member then pastes the https URL
        src = make_repo(self.home / "src" / "run-skills-lab", PACK_FILES)
        git(src, "remote", "add", "origin", "git@Example.invalid:org/run-skills-lab.git")
        paths.packs_dir().mkdir(parents=True)
        (paths.packs_dir() / "run-skills-lab").symlink_to(src)
        self.assertEqual(packs.inspect(paths.packs_dir() / "run-skills-lab").remote, "git@Example.invalid:org/run-skills-lab.git")
        with no_clone():
            dest, msg = packs.add(paths.packs_dir(), "https://example.invalid/org/run-skills-lab/", None)
        self.assertEqual(dest, paths.packs_dir() / "run-skills-lab")
        self.assertIn("already registered as run-skills-lab", msg)
        self.assertFalse((paths.packs_dir() / "lab").exists())

    def test_a_clone_is_found_by_another_url_spelling_or_by_a_working_tree(self):
        clone = make_repo(paths.packs_dir() / "lab", PACK_FILES)
        git(clone, "remote", "add", "origin", "https://example.invalid/org/run-skills-lab.git")
        with no_clone():
            for url in ("git@example.invalid:org/run-skills-lab", "ssh://git@EXAMPLE.invalid:22/org/run-skills-lab.git/"):
                self.assertEqual(packs.add(paths.packs_dir(), url, "other"), (clone, f"already registered as lab ({clone})"))
        tree = make_repo(self.home / "src" / "run-skills-lab", PACK_FILES)   # the member's own working tree of it
        git(tree, "remote", "add", "origin", "git@example.invalid:org/run-skills-lab.git")
        self.assertIn("already registered as lab", packs.add(paths.packs_dir(), str(tree), None)[1])
        self.assertEqual([p.name for p in packs.all_packs(paths.packs_dir())], ["lab"])


if __name__ == "__main__":
    unittest.main()
