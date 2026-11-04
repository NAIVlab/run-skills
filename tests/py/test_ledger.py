"""ledger.py: the per-project state dir, the lock (two processes), atomic writes with .prev and their recovery, run
records and attempts, plans created O_EXCL, the audit log, the watch lease."""

import json
import os
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path

from helpers import ScratchHome

from remote_run import ledger as L
from remote_run import paths
from remote_run.errors import CONFLICT, RskError

SRC = str(Path(L.__file__).resolve().parent.parent)


def child(code: str, *args: str) -> subprocess.Popen:
    """A second process on the same ledger (the same RS_STATE_DIR)."""
    return subprocess.Popen([sys.executable, "-I", "-c", "import sys; sys.path.insert(0, sys.argv[1]); " + code, SRC,
                             *args], env=os.environ, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


class Basics(ScratchHome):
    def setUp(self) -> None:
        super().setUp()
        self.proj = self.home / "proj"
        self.proj.mkdir()
        self.led = L.Ledger(self.proj)

    def test_names(self):
        self.assertEqual(L.run_id("mytask-v3--train--lr-cosine--scratch--s0--a01"),
                         "mytask-v3--train--lr-cosine--scratch--s0")
        self.assertEqual(L.attempt_of("x--a12"), "a12")
        self.assertEqual(L.run_id("x--b01"), "x--b01")
        self.assertEqual(L.attempt_of("plain"), "")

    def test_dir_is_per_real_project_path(self):
        link = self.home / "link"
        link.symlink_to(self.proj)
        self.assertEqual(L.Ledger(link).dir, self.led.dir)
        self.assertTrue(str(self.led.dir).startswith(str(paths.state_dir() / "projects")))
        self.assertFalse(self.led.dir.exists())                 # nothing until the first write
        self.led.audit("x")
        self.assertEqual((self.led.dir / "project").read_text().strip(), str(self.proj.resolve()))
        (self.led.dir / "project").write_text("/somewhere/else\n")
        with self.assertRaises(RskError) as cm:
            self.led.audit("y")
        self.assertEqual(cm.exception.code, CONFLICT)

    def test_atomic_write_keeps_prev_and_recovers(self):
        p = self.led.dir / "f.json"
        L.write_json(p, {"v": 1})
        L.write_json(p, {"v": 2})
        self.assertEqual(json.loads((p.parent / "f.json.prev").read_text()), {"v": 1})
        self.assertEqual(L.read_json(p).data, {"v": 2})
        p.write_text('{"v": 3')                                   # torn
        got = L.read_json(p)
        self.assertEqual((got.data, got.source), ({"v": 1}, "prev"))
        self.assertTrue(got.recovered)
        L.write_json(p, {"v": 4})                                 # a corrupt file never replaces a good .prev
        self.assertEqual(json.loads((p.parent / "f.json.prev").read_text()), {"v": 1})
        p.write_text("[]")
        (p.parent / "f.json.prev").write_text("nope")
        self.assertEqual(L.read_json(p).source, "corrupt")
        self.assertEqual(L.read_json(self.led.dir / "absent.json").source, "missing")
        self.assertEqual([x.name for x in p.parent.iterdir() if x.name.endswith(".tmp")], [])

    def test_attempts(self):
        r, a = self.led.record_attempt(name="exp--a01", target="fx", kind="slurm", nonce="n1", submit="submitted",
                                       job="11", plan={"bound_hash": "h" * 64, "partition": "gpu", "warnings": "0"},
                                       plan_id="p-1", grant="g-1", quote="go")
        self.assertEqual((r, a), ("exp", "a01"))
        self.assertEqual(self.led.record_attempt(name="exp--a01", target="fx", kind="slurm", nonce="n1",
                                                 submit="submitted", job="11"), ("exp", "a01"))   # same nonce: no-op
        self.led.record_attempt(name="exp--a01", target="fx", kind="slurm", nonce="n2", submit="submitted", job="12")
        self.assertEqual(self.led.record_attempt(name="exp--a02", target="fx", kind="slurm", nonce="n3",
                                                 submit="unknown"), ("exp", "a02"))
        rec = self.led.read_run("exp").data
        self.assertEqual([s["job"] for s in rec["attempts"]["a01"]["submissions"]], ["11", "12"])
        self.assertEqual(rec["attempts"]["a01"]["request"]["bound"], {"partition": "gpu"})
        self.assertEqual(rec["attempts"]["a01"]["request"]["grant"], "g-1")
        self.assertEqual(L.attempt_state(rec["attempts"]["a02"]), "SUBMIT_UNKNOWN")
        self.assertTrue(L.is_live(rec["attempts"]["a02"]))         # unknown counts as live
        self.assertEqual(self.led.find_nonce("n3"), ("exp", "a02"))
        self.assertEqual(self.led.find_job("fx", "12"), ("exp", "a01"))
        self.assertIsNone(self.led.find_job("other", "12"))
        self.assertEqual(self.led.record_attempt(name="plain", target="fx", kind="slurm", nonce="n4",
                                                 submit="submitted")[1], "a01")
        self.assertEqual(self.led.record_attempt(name="plain", target="fx", kind="slurm", nonce="n5",
                                                 submit="submitted")[1], "a02")
        self.assertEqual(self.led.record_attempt(name="plain", target="fx", kind="slurm", nonce="n6",
                                                 submit="submitted", attempt="a02")[1], "a02")   # a chain segment
        for bad in ({"nonce": "-x"}, {"submit": "maybe"}, {"kind": "k8s"}):
            with self.assertRaises(RskError):
                self.led.record_attempt(**{"name": "e", "target": "fx", "kind": "slurm", "nonce": "n9",
                                           "submit": "submitted", **bad})
        events = [a["event"] for a in self.led.read_audit()[0]]
        self.assertEqual(events.count("attempt"), 6)   # the repeated nonce: none

    def test_observe_end_and_requeue(self):
        self.led.record_attempt(name="exp--a01", target="fx", kind="slurm", nonce="n1", submit="submitted", job="11")
        self.led.observe("exp", "a01", "11", "RUNNING", "squeue")
        att = self.led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual((L.attempt_state(att), L.is_live(att)), ("RUNNING", True))
        self.led.observe("exp", "a01", "11", "PREEMPTED", "sacct", end={"state": "PREEMPTED", "rc": "0:0",
                                                                         "evidence": "sacct"})
        att = self.led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual((L.attempt_state(att), L.is_live(att)), ("PREEMPTED", False))
        self.led.observe("exp", "a01", "11", "PENDING", "squeue")          # requeued: live again
        att = self.led.read_run("exp").data["attempts"]["a01"]
        self.assertEqual((L.attempt_state(att), L.is_live(att), att["result"]), ("PENDING", True, None))
        self.led.set_submission("exp", "a01", "n1", end={"state": "COMPLETED", "rc": "0:0", "at": L.now(),
                                                         "evidence": "sacct"})
        self.assertEqual(L.attempt_state(self.led.read_run("exp").data["attempts"]["a01"]), "COMPLETED")

    def test_a_corrupt_run_record_is_never_overwritten_blind(self):
        self.led.record_attempt(name="exp--a01", target="fx", kind="slurm", nonce="n1", submit="submitted", job="11")
        self.led.record_attempt(name="exp--a01", target="fx", kind="slurm", nonce="n2", submit="submitted", job="12")
        path = self.led.run_path("exp")
        path.write_text("{garbage")
        st = self.led.state()
        self.assertIn("run exp", st.budgets_unknown)               # recovered from .prev: counts unknown
        self.led.observe("exp", "a01", "11", "RUNNING", "squeue")  # the write marks the record recovered
        rec = self.led.read_run("exp").data
        self.assertTrue(rec["recovered"])
        self.assertEqual(len(rec["attempts"]["a01"]["submissions"]), 1)   # .prev predates n2
        self.assertIn("run exp", self.led.state().budgets_unknown)
        path.write_text("{garbage")
        path.with_name(path.name + ".prev").write_text("{garbage")
        with self.assertRaises(RskError) as cm:
            self.led.observe("exp", "a01", "11", "RUNNING", "squeue")
        self.assertEqual(cm.exception.code, CONFLICT)
        self.assertEqual(path.read_text(), "{garbage")

    def test_plans_are_created_exclusively_and_used_once(self):
        pid = self.led.create_plan({"target": "fx", "name": "exp--a01", "plan": {"bound_hash": "a" * 64}})
        self.assertRegex(pid, r"^p-\d{8}T\d{6}Z-[0-9a-f]{6}$")
        with self.assertRaises(RskError) as cm:
            self.led.create_plan({"id": pid, "target": "fx", "name": "other"})
        self.assertEqual(cm.exception.code, CONFLICT)
        self.assertEqual(self.led.read_plan(pid).data["name"], "exp--a01")     # not overwritten
        time.sleep(1.05)
        p2 = self.led.create_plan({"target": "fx", "name": "exp--a01"})
        self.assertEqual(self.led.latest_plan("fx", "exp--a01")["id"], p2)
        self.assertIsNone(self.led.plan_claim(pid))
        self.led.claim_plan(pid, nonce="n1")
        with self.assertRaises(RskError) as cm:
            self.led.claim_plan(pid, nonce="n2")
        self.assertEqual(cm.exception.code, CONFLICT)
        self.assertEqual(self.led.plan_claim(pid)["nonce"], "n1")
        (self.led.dir / "plans" / "p-bad.json").write_text("{")
        self.assertEqual(self.led.read_plan("p-bad").source, "corrupt")
        self.assertEqual(self.led.read_plan("../x").source, "missing")
        self.assertEqual([p["id"] for p in self.led.plans()], [pid, p2])

    def test_audit_survives_a_torn_line(self):
        self.led.audit("one", n=1)
        with open(self.led.dir / "audit.jsonl", "a") as f:
            f.write('{"at": "x", "event": "tor')               # a crash mid-append
        self.led.audit("two", n=2)
        recs, bad = self.led.read_audit()
        self.assertEqual([r["event"] for r in recs], ["one", "two"])
        self.assertEqual(bad, 1)

    def test_lock_is_reentrant_and_excludes_threads(self):
        with self.led.locked():
            with self.led.locked():
                self.assertTrue(self.led.holding())
            self.assertTrue(self.led.holding())
            got = []
            t = threading.Thread(target=lambda: got.append(self._try()))
            t.start()
            t.join()
            self.assertEqual(got, [CONFLICT])
        self.assertFalse(self.led.holding())

    def _try(self) -> int:
        try:
            with self.led.locked(timeout=0.2):
                return 0
        except RskError as exc:
            return exc.code

    def test_lease(self):
        self.assertEqual(L.lease_state(None), "none")
        rec = self.led.take_lease(time.time() + 600, ["t.tbl"])
        self.assertEqual(L.lease_state(rec), "live")
        self.assertEqual(L.lease_state(rec, time.time() + 601), "expired")
        self.assertEqual(L.lease_state({**rec, "host": "elsewhere"}), "foreign")
        self.assertEqual(L.lease_state({**rec, "pid_start": "1"}), "dead" if rec["pid_start"] else "live")
        self.assertTrue(self.led.release_lease())
        self.assertFalse(self.led.release_lease())
        self.assertEqual(self.led.lease().source, "missing")


class TwoProcesses(ScratchHome):
    def setUp(self) -> None:
        super().setUp()
        self.proj = self.home / "proj"
        self.proj.mkdir()

    def test_concurrent_read_modify_writes_lose_nothing(self):
        code = ("from remote_run import ledger as L\n"
                "led = L.Ledger(sys.argv[2])\n"
                "for i in range(40):\n"
                "    with led.locked():\n"
                "        led.update_run('ctr', lambda r: r.update(n=r.get('n', 0) + 1))\n"
                "        led.audit('inc', who=sys.argv[3])\n")
        ps = [child("exec(sys.argv[4])", str(self.proj), w, code) for w in ("a", "b")]
        for p in ps:
            _, err = p.communicate(timeout=120)
            self.assertEqual(p.returncode, 0, err)
        led = L.Ledger(self.proj)
        self.assertEqual(led.read_run("ctr").data["n"], 80)
        recs, bad = led.read_audit()
        self.assertEqual((len([r for r in recs if r["event"] == "inc"]), bad), (80, 0))

    def test_a_held_lock_names_its_holder(self):
        p = child("from remote_run import ledger as L\nimport time\n"
                  "with L.Ledger(sys.argv[2]).locked():\n    print('held', flush=True)\n    time.sleep(3)\n",
                  str(self.proj))
        self.assertEqual(p.stdout.readline().strip(), "held")
        with self.assertRaises(RskError) as cm:
            with L.Ledger(self.proj).locked(timeout=0.3):
                pass
        self.assertEqual(cm.exception.code, CONFLICT)
        self.assertIn(f"pid {p.pid}", str(cm.exception))
        p.wait(timeout=30)
        with L.Ledger(self.proj).locked(timeout=5):     # released when the holder ends
            pass

    def test_a_live_lease_of_another_process_refuses(self):
        p = child("from remote_run import ledger as L\nimport time\n"
                  "L.Ledger(sys.argv[2]).take_lease(time.time() + 60)\nprint('taken', flush=True)\ntime.sleep(3)\n",
                  str(self.proj))
        self.assertEqual(p.stdout.readline().strip(), "taken")
        led = L.Ledger(self.proj)
        with self.assertRaises(RskError) as cm:
            led.take_lease(time.time() + 60)
        self.assertEqual(cm.exception.code, CONFLICT)
        self.assertIn(f"pid {p.pid}", str(cm.exception))
        p.wait(timeout=30)
        self.assertEqual(L.lease_state(led.lease().data), "dead")
        rec = led.take_lease(time.time() + 60)                  # a dead holder's lease is taken over
        self.assertEqual(rec["pid"], os.getpid())
        self.assertIn("replaced", [k for a in led.read_audit()[0] if a["event"] == "lease_take" for k in a])


if __name__ == "__main__":
    unittest.main()
