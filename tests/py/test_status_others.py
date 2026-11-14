"""I5: rsk status counts this user's live jobs of OTHER dirs on a Slurm target it read (other projects, other tabs of the
same user) — by state and pending reason, from the rows the same squeue already returns,
never as this project's jobs, never "none" when the read failed. I6: --check-after shows a pending job's squeue reason.
Against test_status's stub ssh (the remote script runs locally, stub squeue / sacct on PATH)."""

import contextlib
import io
import json
import os
import unittest
from unittest import mock

import test_status as TS
from helpers import no_sleep

from remote_run import harness, observe, paths
from remote_run import launch as X
from remote_run import ledger as L
from remote_run import status as S
from remote_run.errors import OK, UNKNOWN

LINE = "  this user's other jobs on fx-slurm (other dirs: this user's other projects or sessions): "


class Others(TS.Base):
    def setUp(self) -> None:
        super().setUp()
        TS.Slurm.slurm_fixture(self)   # this dir: 101 RUNNING, 102 PENDING (squeue), 90 / 91 (sacct); /elsewhere: 999

    def rows(self, *rows: str) -> None:
        with open(self.stub / "squeue.out", "a") as f:
            f.writelines(r + "\n" for r in rows)

    def status(self, *argv: str) -> tuple[int, str]:
        return TS.run("status", "-C", str(self.proj), *argv)

    def test_this_projects_jobs_are_unchanged(self):   # the existing fixture: the same jobs, the other dir's counted
        rc, text = self.status("--json")
        self.assertEqual(rc, OK, text)
        t = json.loads(text)["targets"][0]
        self.assertEqual(sorted((j["id"], j["state"], j["source"]) for j in t["jobs"]),
                         [("101", "RUNNING", "squeue"), ("102", "PENDING", "squeue"), ("90", "FAILED", "sacct"),
                          ("91", "COMPLETED", "sacct")])
        self.assertEqual(t["other_dirs"], {"states": {"RUNNING": 1}, "pending_reasons": {}})
        rc, text = self.status()
        self.assertEqual(rc, OK, text)
        self.assertIn(LINE + "RUNNING 1\n", text)
        self.assertNotIn("not-mine", text)                     # counted, never listed
        self.assertNotIn("999", text)

    def test_counts_by_state_and_pending_reason(self):
        o1, o2 = "/elsewhere/proj", "/elsewhere/tab-b"
        self.rows(f"201|b1|PENDING|Priority|0|0|{o1}|", f"202|b2|PENDING|Priority|0|0|{o2}|",
                  f"203|b3|PENDING|Priority|0|0|{o2}|", f"204|b4|PENDING|QOSMaxJobsPerUserLimit|0|0|{o2}|",
                  f"205|b5|RUNNING|None|0|1700000000|{o2}|", f"206|b6|COMPLETING|None|0|1700000000|{o2}|",
                  f"207|b7|COMPLETED|None|0|1700000000|{o2}|",     # ended (squeue keeps it a while): holds no limit
                  f"208|b8|CANCELLED|None|0|0|{o1}|")
        rc, text = self.status()
        self.assertEqual(rc, OK, text)
        self.assertIn(LINE + "RUNNING 2, PENDING 4 (Priority 3, QOSMaxJobsPerUserLimit 1), COMPLETING 1\n", text)
        self.assertNotRegex(text, r"job 20[0-9]")              # none of them is this project's
        t = json.loads(self.status("--json")[1])["targets"][0]
        self.assertEqual(t["other_dirs"], {"states": {"RUNNING": 2, "PENDING": 4, "COMPLETING": 1},
                                           "pending_reasons": {"Priority": 3, "QOSMaxJobsPerUserLimit": 1}})
        self.assertEqual(sorted(j["id"] for j in t["jobs"]), ["101", "102", "90", "91"])

    def test_omitted_when_there_are_none(self):
        (self.stub / "squeue.out").write_text(f"101|exp--a01|RUNNING|None|1|1700000000|{self.remote}|\n"
                                              f"300|done|COMPLETED|None|0|1700000000|/elsewhere/proj|\n")
        rc, text = self.status()
        self.assertEqual(rc, OK, text)
        self.assertNotIn("other jobs", text)
        t = json.loads(self.status("--json")[1])["targets"][0]
        self.assertEqual(t["other_dirs"], {"states": {}, "pending_reasons": {}})

    def test_never_none_when_the_read_failed(self):
        for env in ("SSH_FAIL", "SQ_FAIL"):
            with self.subTest(fail=env):
                os.environ[env] = "1"
                try:
                    rc, text = self.status()
                    self.assertEqual(rc, UNKNOWN, text)
                    self.assertIn("UNOBSERVABLE", text)
                    self.assertNotIn("other jobs", text)
                    rc, text = self.status("--json")
                    self.assertIsNone(json.loads(text)["targets"][0]["other_dirs"])
                finally:
                    os.environ.pop(env)

    def test_the_counts_are_bounded(self):
        long = "ReqNodeNotAvail,_UnavailableNodes:" + ",".join(f"node-{i:03d}" for i in range(40))
        self.rows(*(f"{400 + i}|r{i}|PENDING|Reason{i:02d}|0|0|/elsewhere/proj|" for i in range(40)),
                  f"499|rl|PENDING|{long}|0|0|/elsewhere/proj|")
        rc, text = self.status("--json")
        self.assertEqual(rc, OK, text)
        why = json.loads(text)["targets"][0]["other_dirs"]["pending_reasons"]
        self.assertLessEqual(len(why), observe.OTHERS_KEYS + 1)
        self.assertEqual(sum(why.values()), 41)
        self.assertIn("(other)", why)
        line = next(ln for ln in self.status()[1].splitlines() if ln.startswith(LINE))
        self.assertIn("PENDING 41 (", line)
        self.assertLess(len(line), 2000)
        o = observe.parse(harness.Place("fx-slurm", "slurm", "fxhost", "/p", ".fx-slurm"),
                          f"@@start\n@@pwd /p|/p\n@@squeue\n1|n|PENDING|{long}|0|0|/q|\n@@sacct\n@@attempts\n@@end\n",
                          0, "")
        (k, n), = o.others_reasons.items()
        self.assertEqual((len(k), k.endswith("..."), n), (60, True, 1))

    def test_a_box_has_none(self):
        box = harness.Place("fx-box", "nohup", "fxbox", "/p", ".ws")
        o = observe.parse(box, "@@start\n@@now 1700000100\n@@pwd /p|/p\n@@ws\n@@attempts\n@@end\n", 0, "")
        self.assertTrue(o.ok)
        self.assertEqual((o.others, S.others_line(o)), ({}, []))


class CheckAfterReason(TS.Base):
    """I6: --check-after's milestone line carries squeue's reason for a pending job: `PENDING (Priority)`."""

    def setUp(self) -> None:
        super().setUp()
        TS.Slurm.slurm_fixture(self)
        self.led = L.Ledger(self.proj)

    def test_pending_shows_its_reason(self):
        b = self.led.record_attempt(name="exp--b01", target="fx-slurm", kind="slurm", nonce="n-b", submit="submitted",
                                    job="102")
        a = self.led.record_attempt(name="exp--a01", target="fx-slurm", kind="slurm", nonce="n-a", submit="submitted",
                                    job="101")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), no_sleep(X) as sl:
            code = X.check_after(self.led, paths.harness_src(), self.proj,
                                 [(*b, "fx-slurm", "n-b"), (*a, "fx-slurm", "n-a")], 5, 60.0, OK)
        text = buf.getvalue()
        self.assertEqual(code, OK, text)
        sl.assert_called_once_with(5)
        self.assertIn("exp--b01 a01 on fx-slurm (job 102): PENDING (Priority) 5 s after the launch", text)
        self.assertIn("exp a01 on fx-slurm (job 101): RUNNING 5 s after the launch", text)   # no reason shown

    def test_a_pending_job_without_a_reason_shows_none(self):
        (self.stub / "squeue.out").write_text(f"102|exp--b01|PENDING||0|0|{self.remote}|\n")
        b = self.led.record_attempt(name="exp--b01", target="fx-slurm", kind="slurm", nonce="n-b", submit="submitted",
                                    job="102")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), mock.patch.object(X.time, "sleep"):
            X.check_after(self.led, paths.harness_src(), self.proj, [(*b, "fx-slurm", "n-b")], 5, 60.0, OK)
        self.assertIn("(job 102): PENDING 5 s after the launch", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
