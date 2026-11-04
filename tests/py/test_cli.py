"""The rsk commands that need no remote and no install: config, pack, update planning, doctor, target listing."""

import contextlib
import dataclasses
import io
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

from helpers import ScratchHome, git, make_repo

from remote_run import __version__, cli, harness, install, packs, paths, state
from remote_run.errors import CONFLICT, OK, UNKNOWN, USAGE


def run(*argv: str) -> tuple[int, str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        try:
            rc = cli.main(list(argv))
        except SystemExit as exc:   # argparse: --version / usage errors
            rc = exc.code
    return rc, buf.getvalue()


GIT_INSTALL = install.Install("git", "https://example.invalid/run-skills", "a" * 40, "", True,
                              (("/x/uv", "tool", "upgrade", "--reinstall", "remote-run"),), "uv tool upgrade")
EDITABLE = install.Install("editable", "/src", manual="git -C /src pull")


def record_setup(commit: str, rc: int = 0) -> None:
    """What cmd_setup leaves behind: a harness copy and install.json."""
    root = paths.harness_root()
    (root / "bin").mkdir(parents=True, exist_ok=True)
    (root / "bin" / "run-sync").write_text("")
    state.write_json(paths.state_dir() / "install.json", {
        "version": __version__, "commit": commit, "harness_src": str(paths.harness_src()), "harness_root": str(root),
        "install_rc": rc})


@contextlib.contextmanager
def tool_update(inst: install.Install, now_commit: str):
    """rsk update with uv mocked (succeeds) and the commit uv left; yields the os.execv mock (the hand-over to setup)."""
    after = {"url": inst.source, "vcs_info": {"vcs": "git", "commit_id": now_commit}}
    with mock.patch.object(install, "current", return_value=inst), mock.patch("subprocess.call", return_value=0), \
         mock.patch.object(install, "read_direct_url", return_value=after), \
         mock.patch.object(install, "entry_path", return_value="/x/bin/rsk"), mock.patch("os.execv") as execv:
        yield execv


class Commands(ScratchHome):
    def test_version(self):
        rc, text = run("--version")
        self.assertEqual(rc, 0)
        self.assertRegex(text, r"^rsk \d")

    def test_config_template_and_values(self):
        self.assertIn("[update]", run("config", "--template")[1])
        rc, text = run("config")
        self.assertEqual(rc, OK)
        self.assertIn("update.packs = True", text)

    def test_pack_list_empty_and_add(self):
        self.assertIn("no packs", run("pack", "list")[1])
        src = make_repo(self.home / "run-skills-lab", {"targets/fx/profile.sh": "T_KIND=slurm; T_HOST=fx\n"})
        rc, text = run("pack", "add", str(src))
        self.assertEqual(rc, OK)
        self.assertIn("rsk setup", text)
        self.assertIn("lab\tlink", run("pack", "list")[1])

    def test_update_dry_run_runs_nothing(self):
        with mock.patch.object(install, "current", return_value=GIT_INSTALL), \
             mock.patch("subprocess.call", side_effect=AssertionError("ran a command")):
            rc, text = run("update", "--dry-run")
        self.assertEqual(rc, OK)
        self.assertIn("$ /x/uv tool upgrade --reinstall remote-run", text)
        self.assertIn("rsk setup --after-update", text)

    def test_update_failure_of_uv_is_unknown_and_records_nothing(self):
        with mock.patch.object(install, "current", return_value=GIT_INSTALL), mock.patch("subprocess.call", return_value=1):
            rc, text = run("update", "--tool-only")
        self.assertEqual(rc, 5)
        self.assertFalse((paths.state_dir() / "update-history.jsonl").exists())

    def test_update_with_nothing_new_skips_setup(self):
        record_setup(GIT_INSTALL.commit)
        with tool_update(GIT_INSTALL, GIT_INSTALL.commit) as execv:
            rc, text = run("update", "--tool-only")
        self.assertEqual(rc, OK)
        self.assertIn("already the newest", text)
        execv.assert_not_called()

    def test_update_reruns_setup_unless_install_json_proves_this_commit(self):
        # e.g. `uv tool upgrade --all` moved rsk to this commit without running setup, or the last setup failed
        for case in ("no record", "b" * 40, "failed"):
            with self.subTest(case):
                (paths.state_dir() / "install.json").unlink(missing_ok=True)
                if case != "no record":
                    record_setup(GIT_INSTALL.commit if case == "failed" else case, rc=2 if case == "failed" else 0)
                with tool_update(GIT_INSTALL, GIT_INSTALL.commit) as execv:
                    rc, text = run("update", "--tool-only")
                self.assertEqual(rc, OK)
                self.assertNotIn("already the newest", text)
                self.assertEqual(execv.call_args.args[1][1:3], ["setup", "--after-update"])

    def test_update_of_a_pinned_install_says_pinned(self):
        sha = "c" * 40
        pinned = dataclasses.replace(GIT_INSTALL, commit=sha, ref=sha)
        record_setup(sha)
        with tool_update(pinned, sha) as execv:
            rc, text = run("update", "--tool-only")
        self.assertEqual(rc, OK)
        self.assertIn(f"pinned to {sha}", text)
        self.assertIn("rsk update --to main follows the branch again", text)
        self.assertNotIn("already the newest", text)
        execv.assert_not_called()
        tagged = dataclasses.replace(GIT_INSTALL, ref="v3.0")
        record_setup(tagged.commit)
        for kind, says in (("tag", "pinned to v3.0"), ("branch", "already the newest")):
            with tool_update(tagged, tagged.commit), \
                 mock.patch.object(install, "remote_ref", return_value=(kind, tagged.commit, "")):
                self.assertIn(says, run("update", "--tool-only")[1])

    def test_check_reads_a_tag_as_its_commit(self):
        repo = make_repo(self.home / "upstream", {"a": "a\n"})
        git(repo, "tag", "-a", "v3.1", "-m", "release")
        commit = git(repo, "rev-parse", "v3.1^{commit}")
        tagged = install.Install("git", f"file://{repo}", commit, "v3.1", True, GIT_INSTALL.steps, "")
        with mock.patch.object(install, "current", return_value=tagged):
            rc, text = run("update", "--check")
        self.assertEqual(rc, OK)
        self.assertIn("up to date", text)
        self.assertIn("pinned to tag v3.1", text)
        self.assertNotIn("available", text)
        with mock.patch.object(install, "current", return_value=dataclasses.replace(tagged, ref=commit)), \
             mock.patch("subprocess.run", side_effect=AssertionError("queried a commit")):
            self.assertIn(f"pinned to {commit}", run("update", "--check")[1])
        with mock.patch.object(install, "current", return_value=dataclasses.replace(tagged, source=f"file://{self.home}/gone")):
            rc, text = run("update", "--check")
        self.assertEqual(rc, UNKNOWN)
        self.assertIn("cannot read", text)

    def test_doctor_warns_when_the_harness_copy_is_from_another_commit(self):
        record_setup("b" * 40)
        with mock.patch.object(install, "current", return_value=GIT_INSTALL):
            text = run("doctor")[1]
        self.assertRegex(text, r"WARN .* is from commit bbbbbbbbbbbb, this rsk is aaaaaaaaaaaa — run: rsk setup")
        record_setup(GIT_INSTALL.commit)
        with mock.patch.object(install, "current", return_value=GIT_INSTALL):
            self.assertIn("installed by rsk setup", run("doctor")[1])

    def test_update_to_needs_a_git_install(self):
        ed = install.Install("editable", "/src", manual="git -C /src pull")
        with mock.patch.object(install, "current", return_value=ed):
            rc, _ = run("update", "--to", "v1")
        self.assertEqual(rc, USAGE)

    def test_setup_ends_with_the_pack_verdict_it_was_handed(self):
        with mock.patch.object(harness, "run_install", return_value=0):
            rc, text = run("setup", "--after-update", "--pack-rc", "6", "--packs-failed", "lab")
        self.assertEqual(rc, CONFLICT)
        self.assertIn("pack(s) not updated: lab", text)
        self.assertEqual(state.read_json(paths.state_dir() / "install.json")["install_rc"], 0)
        with mock.patch.object(harness, "run_install", return_value=0):
            self.assertEqual(run("setup")[0], OK)

    def test_doctor_reports_a_missing_install(self):
        rc, text = run("doctor")
        self.assertEqual(rc, USAGE)
        self.assertIn("run: rsk setup", text)

    def test_doctor_fails_while_a_replaced_skill_is_still_discoverable(self):
        record_setup("")
        copy = paths.skills_root() / "remote-run"
        copy.mkdir(parents=True)
        (copy / "SKILL.md").write_text("---\nname: remote-run\n---\n")
        (self.home / ".claude" / "skills").mkdir(parents=True)
        (self.home / ".claude" / "skills" / "remote-run").symlink_to(copy)
        clean = run("doctor")[1]
        self.assertIn(f"ok   skill remote-run: {copy}", clean)
        self.assertNotIn("replaced by remote-run", clean)
        left = [self.home / ".codex" / "skills" / "hpc-run", self.home / ".pi/agent" / "skills" / "ws-run",
                paths.skills_root() / "ws-run"]
        for d in left:
            d.mkdir(parents=True)
            (d / "SKILL.md").write_text("---\nname: old\n---\n")
        (self.home / ".claude" / "skills" / "ws-run").symlink_to(paths.skills_root() / "ws-run")
        (self.home / ".claude" / "skills" / "hpc-run").symlink_to(self.home / "gone")   # dangling: nothing to list
        rc, text = run("doctor")
        self.assertEqual(rc, USAGE)
        for d in [*left, self.home / ".claude" / "skills" / "ws-run"]:
            self.assertRegex(text, rf"FAIL skill (hpc|ws)-run \(replaced by remote-run\) is still installed: {d} — run: rsk setup")
        self.assertNotIn(f"{self.home / '.claude' / 'skills' / 'hpc-run'}", text)
        with mock.patch.dict(os.environ, {"RS_SKILLS_ROOT": str(self.home / ".claude" / "skills")}):
            self.assertEqual(run("doctor")[1].count(f"{self.home / '.claude' / 'skills' / 'ws-run'} —"), 1)


class PackUpdates(ScratchHome):
    """rsk update's exit reflects the packs it could not fast-forward, before and after the hand-over to setup."""

    def setUp(self):
        super().setUp()
        self.origin = make_repo(self.home / "origin" / "run-skills-lab", {"targets/fx/profile.sh": "T_KIND=slurm\n"})
        self.dest = packs.add(paths.packs_dir(), f"file://{self.origin}", None)[0]

    def test_a_dirty_pack_is_a_conflict(self):
        (self.dest / "targets/fx/profile.sh").write_text("changed\n")
        record_setup(GIT_INSTALL.commit)
        with tool_update(GIT_INSTALL, GIT_INSTALL.commit) as execv:
            rc, text = run("update")
        self.assertEqual(rc, CONFLICT)
        self.assertIn("rsk: pack(s) not updated: lab", text)
        execv.assert_not_called()

    def test_the_verdict_survives_the_hand_over_to_setup(self):
        self.origin.rename(self.home / "gone")
        with tool_update(GIT_INSTALL, "b" * 40) as execv:
            rc, text = run("update")
        self.assertIn("lab: git fetch failed", text)
        self.assertIn("pack(s) not updated: lab — setup runs now, then rsk update exits 5", text)
        self.assertEqual(execv.call_args.args[1][-4:], ["--pack-rc", str(UNKNOWN), "--packs-failed", "lab"])
        rc, text = run("update", "--packs-only")
        self.assertEqual(rc, UNKNOWN)

    def test_check_says_cannot_fetch_instead_of_up_to_date(self):
        self.origin.rename(self.home / "gone")
        with mock.patch.object(install, "current", return_value=EDITABLE):
            rc, text = run("update", "--check")
        self.assertEqual(rc, UNKNOWN)
        self.assertIn("pack lab: cannot fetch", text)
        self.assertNotIn("up to date", text)

    def test_packs_only_with_packs_disabled_says_so(self):
        paths.config_file().write_text("[update]\npacks = false\n")
        rc, text = run("update", "--packs-only")
        self.assertEqual(rc, USAGE)
        self.assertIn("packs are disabled", text)

    def test_pack_list_shows_a_links_origin(self):
        tree = make_repo(self.home / "src" / "run-skills-x", {"targets/fy/profile.sh": "T_KIND=slurm\n"})
        git(tree, "remote", "add", "origin", "git@example.invalid:org/run-skills-x.git")
        packs.add(paths.packs_dir(), str(tree), None)
        self.assertIn(f"x\tlink\t-> {tree} (your working tree, origin git@example.invalid:org/run-skills-x.git)",
                      run("pack", "list")[1])


class Pipe(ScratchHome):
    def test_a_reader_that_leaves_is_141_not_a_traceback(self):   # `rsk … | head`: stdout's pipe closes early
        child = ("import os, sys; sys.path[:0] = sys.argv[1:2]; from remote_run import cli\n"
                 "r, w = os.pipe(); os.close(r); os.dup2(w, 1)\n"
                 "sys.exit(cli.main(['config', '--template']))")
        done = subprocess.run([sys.executable, "-I", "-c", child, str(Path(cli.__file__).parent.parent)],
                              capture_output=True, text=True, env=os.environ)
        self.assertEqual(done.returncode, 141, done.stderr)
        self.assertNotIn("Traceback", done.stderr)


class Targets(ScratchHome):
    def test_targets_are_listed_and_a_broken_one_is_reported(self):
        good = paths.user_dir() / "targets" / "fx-ok"
        broken = paths.user_dir() / "targets" / "fx-bad"
        good.mkdir(parents=True)
        broken.mkdir(parents=True)
        (good / "profile.sh").write_text("T_KIND=slurm; T_HOST=fxhost; T_XFER_HOST=fxdata\n")
        (broken / "profile.sh").write_text("T_KIND=cloud; T_HOST=x\n")
        found = {t.name: t for t in harness.targets(paths.harness_src())}
        self.assertEqual((found["fx-ok"].kind, found["fx-ok"].host, found["fx-ok"].xfer_host), ("slurm", "fxhost", "fxdata"))
        self.assertIn("T_KIND must be", found["fx-bad"].error)


if __name__ == "__main__":
    unittest.main()
