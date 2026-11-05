"""rsk doctor --legacy-refs: project docs still steering agents the old way, one line each, read-only."""

import contextlib
import io
import os
import unittest

from helpers import ScratchHome

from remote_run import cli, legacy


class Refs(ScratchHome):
    def setUp(self) -> None:
        super().setUp()
        r = self.root = self.home / "projects"

        def put(rel: str, text: str) -> None:
            p = r / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        put("a/CLAUDE.md", "# a\nUse the hpc-run skill.\nssh fx 'bash ~/p/.fx/submit.sh -p gpu -- c'\n"
                           "TARGET=ws bash ~/.agents/run-skills/bin/run-launch -N x\nfine: rsk launch, run-skills, "
                           "remote-run\n")
        (r / "a" / "AGENTS.md").symlink_to("CLAUDE.md")                  # one file, read once
        put("b/.claude/CLAUDE.md", "see ws-run\n")
        put("c/.venv/CLAUDE.md", "hpc-run\n")
        put("c/node_modules/x/AGENTS.md", "hpc-run\n")
        put("d/AGENTS.md", "rsk launch -T t -- c\nthe run-skills engine; remote-run\n")
        put("engine/src/remote_run/__init__.py", "")
        put("engine/remote/submit.sh", "")
        put("engine/AGENTS.md", "replaces hpc-run and ws-run\n")
        (r / "link").symlink_to(r / "a")                                  # a symlinked dir is not followed

    def test_one_line_per_hit_and_what_is_skipped(self):
        text = "\n".join(legacy.report([str(self.root)]))
        a = str(self.root / "a" / "CLAUDE.md")
        self.assertIn(f"{a}:2: names the replaced skill hpc-run", text)
        self.assertIn(f"{a}:3: a raw `ssh … submit.sh` recipe", text)
        self.assertIn(f"{a}:4: a raw run-launch recipe", text)
        self.assertIn(f"{self.root / 'b' / '.claude' / 'CLAUDE.md'}:1: names the replaced skill ws-run", text)
        self.assertNotIn(":5:", text)
        for gone in ("AGENTS.md:2", ".venv", "node_modules", "link/", "d/AGENTS.md", "engine/AGENTS.md"):
            self.assertNotIn(gone, text)
        self.assertIn(f"skipped {self.root / 'engine'} (the run-skills engine itself", text)
        self.assertIn("== 4 legacy reference(s) in 2 of 3 file(s) ==", text)

    def test_doctor_flag_defaults_to_projects_and_exits_0(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cli.main(["doctor", "--legacy-refs"])
        self.assertEqual(rc, 0)
        self.assertIn(f"== {self.home / 'projects'} — 3 CLAUDE.md / AGENTS.md file(s)", buf.getvalue())
        with contextlib.redirect_stdout(io.StringIO()) as b2:
            self.assertEqual(cli.main(["doctor", "--legacy-refs", str(self.home / "nope")]), 0)
        self.assertIn("not a directory", b2.getvalue())


if __name__ == "__main__":
    unittest.main()
