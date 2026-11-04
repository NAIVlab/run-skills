"""install.detect: how an rsk was installed decides the update commands."""

import unittest
from pathlib import Path
from unittest import mock

from helpers import ScratchHome, git, make_repo

from remote_run import install

RECEIPT = {"tool": {"requirements": [{"name": "remote-run", "git": "https://example.invalid/run-skills"}],
                    "entrypoints": [{"name": "rsk", "install-path": "/x/bin/rsk", "from": "remote-run"}]}}
UV = "/x/bin/uv"


def git_url(ref: str = "") -> dict:
    vcs = {"vcs": "git", "commit_id": "a" * 40}
    if ref:
        vcs["requested_revision"] = ref
    return {"url": "https://example.invalid/run-skills", "vcs_info": vcs}


class Detect(unittest.TestCase):
    def test_git_unpinned_upgrades_in_place(self):
        i = install.detect(git_url(), RECEIPT, UV, None)
        self.assertEqual((i.kind, i.uv_tool, i.ref), ("git", True, ""))
        self.assertEqual(i.steps, ((UV, "tool", "upgrade", "--reinstall", "remote-run"),))

    def test_git_ref_reinstalls_the_same_ref(self):
        # uv tool upgrade keeps a requested ref; reinstalling at that ref moves a branch and keeps a tag
        i = install.detect(git_url("v3.1"), RECEIPT, UV, None)
        self.assertEqual(i.steps, ((UV, "tool", "install", "--force", "--reinstall",
                                    "git+https://example.invalid/run-skills@v3.1"),))

    def test_without_uv_only_a_manual_line(self):
        i = install.detect(git_url(), RECEIPT, None, None)
        self.assertEqual(i.steps, ())
        self.assertIn("uv tool upgrade", i.manual)

    def test_editable_is_never_updated_by_rsk(self):
        i = install.detect({"url": "file:///src/run-skills", "dir_info": {"editable": True}}, RECEIPT, UV, None)
        self.assertEqual((i.kind, i.steps), ("editable", ()))
        self.assertIn("git -C /src/run-skills pull", i.manual)

    def test_directory_install_needs_reinstall(self):
        i = install.detect({"url": "file:///src/run%20skills", "dir_info": {}}, RECEIPT, UV, None)
        self.assertEqual(i.steps, ((UV, "tool", "install", "--force", "--reinstall", "/src/run skills"),))

    def test_pip_install_gets_a_manual_line(self):
        i = install.detect(git_url(), None, UV, None)
        self.assertEqual((i.kind, i.uv_tool, i.steps), ("git", False, ()))
        self.assertIn("pip install --upgrade git+https://example.invalid/run-skills", i.manual)

    def test_source_checkout(self):
        i = install.detect(None, None, UV, Path("/src/run-skills"))
        self.assertEqual((i.kind, i.steps), ("source", ()))

    def test_to_ref_only_for_git_uv_tools(self):
        g = install.detect(git_url(), RECEIPT, UV, None)
        self.assertEqual(install.steps_to(g, "abc123", UV),
                         ((UV, "tool", "install", "--force", "--reinstall", "git+https://example.invalid/run-skills@abc123"),))
        e = install.detect({"url": "file:///s", "dir_info": {"editable": True}}, RECEIPT, UV, None)
        self.assertEqual(install.steps_to(e, "abc123", UV), ())

    def test_entry_path_from_receipt(self):
        self.assertEqual(install.entry_path(RECEIPT), "/x/bin/rsk")


class RemoteRef(ScratchHome):
    """What a requested ref is upstream (scratch file:// remote): the commit a tag or branch names, not a tag object."""

    def setUp(self):
        super().setUp()
        self.repo = make_repo(self.home / "r", {"a": "a\n"})
        self.first = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "tag", "-a", "v3.1", "-m", "release")
        git(self.repo, "branch", "dev/main")
        (self.repo / "b").write_text("b\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "b")
        self.head = git(self.repo, "rev-parse", "HEAD")
        self.url = f"file://{self.repo}"

    def test_annotated_tag_is_its_commit_not_the_tag_object(self):
        self.assertNotEqual(git(self.repo, "rev-parse", "v3.1"), self.first)
        self.assertEqual(install.remote_ref(self.url, "v3.1"), ("tag", self.first, ""))

    def test_branch_and_head(self):
        self.assertEqual(install.remote_ref(self.url, "main"), ("branch", self.head, ""))
        self.assertEqual(install.remote_ref(self.url, "dev/main"), ("branch", self.first, ""))
        self.assertEqual(install.remote_ref(self.url, ""), ("head", self.head, ""))

    def test_commits(self):
        with mock.patch("subprocess.run", side_effect=AssertionError("queried a full SHA")):
            self.assertEqual(install.remote_ref(self.url, self.first), ("commit", self.first, ""))
        self.assertEqual(install.remote_ref(self.url, self.first[:10]), ("commit", self.first[:10], ""))

    def test_unknown_ref_and_unreachable_remote(self):
        self.assertEqual(install.remote_ref(self.url, "nope")[:2], ("", ""))
        kind, head, err = install.remote_ref(f"file://{self.home}/missing", "main")
        self.assertEqual((kind, head), ("", ""))
        self.assertIn("missing", err)


if __name__ == "__main__":
    unittest.main()
