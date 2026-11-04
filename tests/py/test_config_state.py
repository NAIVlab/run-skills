"""config.toml parsing and the state-dir file helpers."""

import json
import unittest

from helpers import ScratchHome

from remote_run import config, paths, state
from remote_run.errors import CONFLICT, RskError


class Config(ScratchHome):
    def test_absent_file_gives_defaults(self):
        c = config.load(paths.config_file())
        self.assertFalse(c.exists)
        self.assertIs(c.get("update", "packs"), True)

    def test_values_types_and_unknown_keys(self):
        f = paths.config_file()
        f.parent.mkdir(parents=True)
        f.write_text("[update]\npacks = false\nspeed = 3\n[sites]\nx = 1\n")
        c = config.load(f)
        self.assertIs(c.get("update", "packs"), False)
        self.assertEqual(set(c.unknown), {"update.speed", "sites"})

    def test_wrong_type_and_bad_toml_are_errors(self):
        f = paths.config_file()
        f.parent.mkdir(parents=True)
        f.write_text('[update]\npacks = "yes"\n')
        with self.assertRaises(RskError):
            config.load(f)
        f.write_text("[update\n")
        with self.assertRaises(RskError):
            config.load(f)

    def test_template_documents_every_key(self):
        self.assertIn("packs = true", config.describe())


class State(ScratchHome):
    def test_write_json_is_atomic_and_readable(self):
        p = paths.state_dir() / "a" / "x.json"
        state.write_json(p, {"k": 1})
        self.assertEqual(state.read_json(p), {"k": 1})
        self.assertEqual([q.name for q in p.parent.iterdir()], ["x.json"])   # no temp file left behind

    def test_read_json_tolerates_garbage(self):
        p = paths.state_dir() / "bad.json"
        p.parent.mkdir(parents=True)
        p.write_text("{not json")
        self.assertIsNone(state.read_json(p))

    def test_jsonl_appends(self):
        p = paths.state_dir() / "h.jsonl"
        state.append_jsonl(p, {"a": 1})
        state.append_jsonl(p, {"a": 2})
        self.assertEqual([json.loads(x)["a"] for x in p.read_text().splitlines()], [1, 2])

    def test_lock_refuses_a_second_holder(self):
        p = paths.state_dir() / "t.lock"
        with state.locked(p, "test"):
            with self.assertRaises(RskError) as cm:
                with state.locked(p, "test"):
                    pass
            self.assertEqual(cm.exception.code, CONFLICT)
        with state.locked(p, "test"):   # released
            pass


if __name__ == "__main__":
    unittest.main()
