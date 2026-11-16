"""The order of observations in the ledger: every update carries its read's window [ssh start, answer] and an older one
never overwrites a newer one (two readers racing: rsk status / launch's refresh / cancel --wait / wait); overlapping
reads that disagree (live vs ended) leave the submission uncertain; a terminal re-read moves the watermark; a read that
shows an ended job live again (a Slurm requeue, the same nohup process: boot, pid AND /proc start) reopens its recorded
end; an identity that cannot be checked leaves it uncertain."""

import unittest

from helpers import ScratchHome

from remote_run import harness, observe
from remote_run import ledger as L
from remote_run import status as S

SLURM = harness.Place("fx-slurm", kind="slurm", host="h", remote_dir="/r", deploy=".fx-slurm")
BOX = harness.Place("fx-box", kind="nohup", host="b", remote_dir="/r", deploy=".ws")
LOG = "logs/exp--a01-20261103-120000.log"


def slurm_obs(state: str, t: float, source: str = "squeue", rc: str = "", took: float = 1.0) -> observe.Observation:
    o = observe.Observation(SLURM, ok=True, now=int(t), observed_at=t + took, started_at=t)
    o.jobs.append(observe.Job("101", "exp--a01", state, exit_code=rc, source=source))
    return o


def box_obs(alive: bool, t: float, boot: str = "boot-1", pid: str = "4242", pstart: str = "77") -> observe.Observation:
    o = observe.Observation(BOX, ok=True, now=int(t), observed_at=t + 1, started_at=t, boot_id=boot)
    if alive:
        o.jobs.append(observe.Job(pid, "exp", "ALIVE", source="pid", log=LOG, pid=pid, pstart=pstart))
    else:
        o.jobs.append(observe.Job("", "exp", "ENDED", source="pid", log=LOG, reason="gone"))
    return o


class Base(ScratchHome):
    def setUp(self) -> None:
        super().setUp()
        self.proj = self.home / "proj"
        self.proj.mkdir()
        self.led = L.Ledger(self.proj)

    def slurm_run(self) -> None:
        self.led.record_attempt(name="exp--a01", target="fx-slurm", kind="slurm", nonce="n1", submit="submitted",
                                job="101")

    def box_run(self, boot: str = "boot-1") -> None:
        self.led.record_attempt(name="exp--a01", target="fx-box", kind="nohup", nonce="n1", submit="submitted",
                                proc={"pid": "4242", "pgid": "4242", "start": "77", "boot_id": boot, "log": LOG,
                                      "gpu_ids": "0"})

    def att(self) -> dict:
        return self.led.read_run("exp").data["attempts"]["a01"]

    def reopens(self) -> list[dict]:
        return [r for r in self.led.read_audit()[0] if r.get("event") == "reopened"]


class Races(Base):
    """Two reads computed from the same snapshot, applied in either order: the newer read's state stands."""

    def test_terminal_read_older_than_a_requeue_read_is_dropped(self):
        self.slurm_run()
        st = self.led.state()
        old = slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")      # taken first: the job had ended (it is requeued since)
        new = slurm_obs("PENDING", 1010.0)                       # taken later: requeued, pending again
        S.record(self.led, st, [new])                            # the newer read lands first
        S.record(self.led, st, [old])                            # the older one, computed before it, lands second
        att = self.att()
        self.assertTrue(L.is_live(att), att)
        self.assertIsNone(att["result"])
        sub = att["submissions"][0]
        self.assertEqual((sub["seen"]["state"], sub["end"], sub["obs_w"]), ("PENDING", None, [1010.0, 1011.0]))
        self.assertEqual(att["observed"]["state"], "PENDING")

    def test_terminal_read_newer_than_a_live_read_stands(self):
        self.slurm_run()
        st = self.led.state()
        old = slurm_obs("RUNNING", 1000.0)
        new = slurm_obs("COMPLETED", 1010.0, "sacct", "0:0")
        S.record(self.led, st, [new])
        S.record(self.led, st, [old])                            # an older live read never reopens a newer end
        att = self.att()
        self.assertFalse(L.is_live(att), att)
        self.assertEqual(att["result"]["state"], "COMPLETED")
        self.assertEqual(att["submissions"][0]["seen"]["state"], "COMPLETED")
        self.assertEqual(self.reopens(), [])

    def test_in_order_both_apply(self):
        self.slurm_run()
        st = self.led.state()
        S.record(self.led, st, [slurm_obs("RUNNING", 1000.0)])
        S.record(self.led, st, [slurm_obs("COMPLETED", 1010.0, "sacct", "0:0")])
        self.assertEqual(self.att()["result"]["state"], "COMPLETED")

    def test_nohup_end_read_before_a_newer_alive_read_is_dropped(self):
        self.box_run()
        st = self.led.state()
        S.record(self.led, st, [box_obs(True, 1010.0)])
        S.record(self.led, st, [box_obs(False, 1000.0)])
        att = self.att()
        self.assertTrue(L.is_live(att), att)
        self.assertEqual(att["submissions"][0]["seen"]["state"], "ALIVE")

    def test_apply_observation_returns_stale_and_changes_nothing(self):
        att = {"submissions": [{"nonce": "n", "job": "7", "submit": "submitted", "seen": {"state": "RUNNING"},
                                "end": None, "obs_w": [50.0, 51.0]}], "observed": None, "result": None}
        self.assertEqual(L.apply_observation(att, "7", "COMPLETED", "sacct", "t", end={"state": "COMPLETED"},
                                             win=(40.0, 45.0)), "stale")
        self.assertIsNone(att["submissions"][0]["end"])
        self.assertIsNone(att["result"])
        self.assertEqual(L.apply_observation(att, "7", "RUNNING", "squeue", "t", win=(60.0, 61.0)), "applied")
        self.assertEqual(att["submissions"][0]["obs_w"], [60.0, 61.0])

    def test_an_older_ledger_without_a_window_loads_and_takes_any_read(self):
        self.slurm_run()
        att = self.att()
        self.assertNotIn("obs_w", att["submissions"][0])
        self.assertIsNone(L.obs_window(att["submissions"][0]))
        self.assertEqual(L.obs_window({"obs_t": 7.0}), (7.0, 7.0))     # the format before windows: an instant
        S.record(self.led, self.led.state(), [slurm_obs("RUNNING", 5.0)])
        self.assertEqual(self.att()["submissions"][0]["seen"]["state"], "RUNNING")

    def test_a_caller_without_a_window_is_now(self):   # rsk cancel's own markers: newer than any read begun before them
        import time
        self.slurm_run()
        st = self.led.state()
        self.led.observe("exp", "a01", "101", "CANCELLING", "rsk cancel (scancel rc=0)")
        S.record(self.led, st, [slurm_obs("RUNNING", time.time() - 30.0)])  # a read started before it: dropped
        self.assertEqual(self.att()["submissions"][0]["seen"]["state"], "CANCELLING")

    def test_a_submit_unknown_resolved_meanwhile_is_left_alone(self):
        self.led.record_attempt(name="exp--a01", target="fx-slurm", kind="slurm", nonce="n1", submit="unknown")
        st = self.led.state()
        self.led.set_submission("exp", "a01", "n1", submit="not_submitted", evidence="another reader")
        o = slurm_obs("RUNNING", 1000.0)
        o.attempts_ok = True
        o.attempts["n1"] = {"receipt": {"job": "101"}, "result": {}, "gate": ""}
        S.record(self.led, st, [o])
        self.assertEqual(self.att()["submissions"][0]["submit"], "not_submitted")


class Reopen(Base):
    def test_a_requeued_slurm_job_reopens_its_recorded_end(self):
        self.slurm_run()
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")])
        self.assertEqual(self.att()["result"]["state"], "COMPLETED")
        notes = S.record(self.led, self.led.state(), [slurm_obs("PENDING", 1100.0)])
        att = self.att()
        self.assertTrue(L.is_live(att), att)
        self.assertIsNone(att["result"])
        self.assertIsNone(att["submissions"][0]["end"])
        self.assertEqual(L.attempt_state(att), "PENDING")
        self.assertTrue(any("reopened" in n for n in notes), notes)
        r = self.reopens()
        self.assertEqual(len(r), 1, r)
        self.assertEqual((r[0]["run"], r[0]["attempt"], r[0]["key"], r[0]["state"], r[0]["ended"]["state"]),
                         ("exp", "a01", "101", "PENDING", "COMPLETED"))
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1200.0, "sacct", "0:0")])
        self.assertEqual(self.att()["result"]["state"], "COMPLETED")   # and ends again

    def test_requeued_state_reopens(self):
        self.slurm_run()
        S.record(self.led, self.led.state(), [slurm_obs("FAILED", 1000.0, "sacct", "1:0")])
        S.record(self.led, self.led.state(), [slurm_obs("REQUEUED", 1100.0, "sacct")])
        self.assertTrue(L.is_live(self.att()))

    def test_a_terminal_read_of_an_ended_job_keeps_the_end_and_moves_the_watermark(self):
        self.slurm_run()
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")])
        end = self.att()["submissions"][0]["end"]
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1100.0, "sacct", "0:0")])   # the same end: kept
        sub = self.att()["submissions"][0]
        self.assertEqual((sub["end"], sub["obs_w"]), (end, [1100.0, 1101.0]))
        self.assertEqual(self.att()["result"]["state"], "COMPLETED")

    def test_another_job_id_reopens_nothing(self):
        self.slurm_run()
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")])
        o = observe.Observation(SLURM, ok=True, observed_at=1101.0, started_at=1100.0)
        o.jobs.append(observe.Job("102", "exp--a01", "RUNNING", source="squeue"))
        S.record(self.led, self.led.state(), [o])
        self.assertFalse(L.is_live(self.att()))

    def test_the_same_nohup_process_alive_again_reopens(self):
        self.box_run()
        S.record(self.led, self.led.state(), [box_obs(False, 1000.0)])
        self.assertEqual(self.att()["result"]["state"], "ENDED")
        S.record(self.led, self.led.state(), [box_obs(True, 1100.0)])
        self.assertTrue(L.is_live(self.att()))
        self.assertEqual(len(self.reopens()), 1)

    def test_another_boot_or_a_reused_pid_reopens_nothing(self):
        self.box_run()
        S.record(self.led, self.led.state(), [box_obs(False, 1000.0)])
        S.record(self.led, self.led.state(), [box_obs(True, 1100.0, boot="boot-2")])   # another boot: over
        S.record(self.led, self.led.state(), [box_obs(True, 1200.0, pstart="99")])     # same pid, another start
        self.assertFalse(L.is_live(self.att()))
        self.assertEqual(self.reopens(), [])
        self.assertNotIn("uncertain", self.att()["submissions"][0])

    def test_a_provably_other_process_confirms_the_end_and_moves_the_watermark(self):   # round 3: wait can end on it
        self.box_run()
        S.record(self.led, self.led.state(), [box_obs(False, 1000.0)])
        end = self.att()["submissions"][0]["end"]
        for o in (box_obs(True, 1100.0, boot="boot-2"), box_obs(True, 1200.0, pstart="99")):
            S.record(self.led, self.led.state(), [o])
            sub = self.att()["submissions"][0]
            self.assertEqual((sub["end"], sub["obs_w"]), (end, [o.started_at, o.observed_at]))
            self.assertEqual(sub["seen"]["state"], "ENDED")
        self.assertFalse(L.is_live(self.att()))

    def test_an_older_live_read_never_reopens(self):
        self.slurm_run()
        st = self.led.state()
        S.record(self.led, st, [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")])
        S.record(self.led, self.led.state(), [slurm_obs("PENDING", 900.0)])
        self.assertFalse(L.is_live(self.att()))
        self.assertEqual(self.reopens(), [])


class Windows(Base):
    """Finding 4: ordering by windows [ssh start, answer], not by ssh start alone."""

    def test_a_conflict_on_an_uncertain_submission_keeps_its_reason_and_widens(self):   # round 3
        att = {"submissions": [{"nonce": "n", "job": "7", "submit": "submitted", "seen": {"state": "COMPLETED"},
                                "end": {"state": "COMPLETED", "rc": "0:0"}, "obs_w": [100.0, 101.0]}],
               "observed": None, "result": None}
        self.assertEqual(L.apply_observation(att, "7", "RUNNING", "squeue", "t", win=(100.5, 102.0)), "uncertain")
        why = att["submissions"][0]["uncertain"]["why"]
        self.assertEqual(L.apply_observation(att, "7", "RUNNING", "squeue", "t", win=(101.5, 103.0)), "stale")
        sub = att["submissions"][0]
        self.assertEqual((sub["uncertain"]["why"], sub["obs_w"]), (why, [100.0, 103.0]))
        self.assertTrue(L.is_live(att))

    def test_overlapping_reads_that_disagree_leave_it_uncertain_until_a_newer_read(self):
        self.slurm_run()
        st = self.led.state()
        S.record(self.led, st, [slurm_obs("RUNNING", 1000.0, took=10.0)])               # [1000, 1010]
        notes = S.record(self.led, st, [slurm_obs("COMPLETED", 1005.0, "sacct", "0:0")])   # [1005, 1006]: overlaps
        att = self.att()
        sub = att["submissions"][0]
        self.assertTrue(L.is_live(att), att)                       # neither read is known to be the newer one
        self.assertEqual(L.attempt_state(att), "UNCERTAIN")
        self.assertIsNone(att["result"])
        self.assertIn("conflicting reads", sub["uncertain"]["why"])
        self.assertEqual((sub["seen"]["state"], sub["end"], sub["obs_w"]), ("RUNNING", None, [1000.0, 1010.0]))
        self.assertTrue(any("uncertain" in n for n in notes), notes)
        self.assertEqual([r["event"] for r in self.led.read_audit()[0] if r.get("event") == "uncertain"], ["uncertain"])
        S.record(self.led, self.led.state(), [slurm_obs("RUNNING", 1008.0)])           # still inside: no decision
        self.assertTrue(L.is_live(self.att()))
        self.assertIn("uncertain", self.att()["submissions"][0])
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1020.0, "sacct", "0:0")])   # strictly newer
        att = self.att()
        self.assertFalse(L.is_live(att), att)
        self.assertNotIn("uncertain", att["submissions"][0])
        self.assertEqual(att["result"]["state"], "COMPLETED")

    def test_an_overlapping_live_read_beside_a_recorded_end_is_uncertain_not_ended(self):
        self.slurm_run()
        st = self.led.state()
        S.record(self.led, st, [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0", took=10.0)])
        S.record(self.led, st, [slurm_obs("PENDING", 1002.0)])
        att = self.att()
        self.assertTrue(L.is_live(att), att)                       # the end is kept, but no longer counted
        self.assertEqual(att["submissions"][0]["end"]["state"], "COMPLETED")
        self.assertIsNone(att["result"])
        S.record(self.led, self.led.state(), [slurm_obs("PENDING", 1100.0)])           # strictly newer: a requeue
        att = self.att()
        self.assertTrue(L.is_live(att))
        self.assertIsNone(att["submissions"][0]["end"])
        self.assertNotIn("uncertain", att["submissions"][0])

    def test_overlapping_agreeing_reads_the_later_started_stands(self):
        self.slurm_run()
        st = self.led.state()
        S.record(self.led, st, [slurm_obs("RUNNING", 1000.0, took=10.0)])
        S.record(self.led, st, [slurm_obs("PENDING", 995.0, took=10.0)])               # agrees (live), began earlier
        self.assertEqual(self.att()["submissions"][0]["seen"]["state"], "RUNNING")
        S.record(self.led, st, [slurm_obs("PENDING", 1004.0)])                          # agrees, began later
        sub = self.att()["submissions"][0]
        self.assertEqual((sub["seen"]["state"], "uncertain" in sub), ("PENDING", False))

    def test_a_clock_step_back_is_uncertain_never_silently_dropped(self):
        self.slurm_run()
        S.record(self.led, self.led.state(), [slurm_obs("RUNNING", 100000.0)])
        S.record(self.led, self.led.state(), [slurm_obs("RUNNING", 1000.0)])            # agrees: dropped, harmless
        self.assertEqual(self.att()["submissions"][0]["obs_w"], [100000.0, 100001.0])
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")])   # disagrees, 27 h back
        att = self.att()
        self.assertTrue(L.is_live(att), att)
        self.assertIn("clock went back", att["submissions"][0]["uncertain"]["why"])
        self.assertEqual(att["submissions"][0]["obs_w"], [1000.0, 100001.0])           # widened, never moved back
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1010.0, "sacct", "0:0")])   # still in question
        self.assertTrue(L.is_live(self.att()))          # uncertain (never a false end) until a read past both decides
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 100100.0, "sacct", "0:0")])
        self.assertEqual(self.att()["result"]["state"], "COMPLETED")
        self.assertFalse(L.is_live(self.att()))

    def test_a_small_step_back_is_plain_stale(self):
        self.slurm_run()
        S.record(self.led, self.led.state(), [slurm_obs("RUNNING", 5000.0)])
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 2000.0, "sacct", "0:0")])   # < 1 h: older
        att = self.att()
        self.assertEqual((att["submissions"][0]["seen"]["state"], "uncertain" in att["submissions"][0]),
                         ("RUNNING", False))

    def test_an_end_of_unknown_age_is_reopened_by_live_evidence_and_a_confirmation_records_a_window(self):
        self.slurm_run()
        self.led.update_run("exp", lambda rec: rec["attempts"]["a01"]["submissions"][0].update(
            end={"state": "COMPLETED", "rc": "0:0", "at": "2026-01-01T00:00:00Z", "evidence": "old"},
            seen={"state": "COMPLETED", "at": "2026-01-01T00:00:00Z", "source": "sacct"}))
        self.led.update_run("exp", lambda rec: L._settle(rec["attempts"]["a01"]))
        self.assertFalse(L.is_live(self.att()))
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 900.0, "sacct", "0:0")])   # confirmation
        sub = self.att()["submissions"][0]
        self.assertEqual((sub["end"]["evidence"], sub["obs_w"]), ("old", [900.0, 901.0]))
        self.led.update_run("exp", lambda rec: rec["attempts"]["a01"]["submissions"][0].pop("obs_w") and None)
        S.record(self.led, self.led.state(), [slurm_obs("RUNNING", 500.0)])            # live beats an end of no age
        self.assertTrue(L.is_live(self.att()))
        self.assertEqual(len(self.reopens()), 1)

    def test_a_delayed_live_read_older_than_a_confirmation_never_reopens(self):   # finding 3
        self.slurm_run()
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")])
        st = self.led.state()                                      # a reader computes from this, slowly
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1100.0, "sacct", "0:0")])   # a confirmation
        S.record(self.led, st, [slurm_obs("RUNNING", 1050.0)])     # began after the first end, before the confirmation
        att = self.att()
        self.assertFalse(L.is_live(att), att)
        self.assertEqual(self.reopens(), [])
        self.assertEqual(att["submissions"][0]["obs_w"], [1100.0, 1101.0])

    def test_a_newer_read_of_another_end_replaces_the_recorded_one(self):   # round 3 P2: requeued, ended again
        self.slurm_run()
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")])
        self.assertEqual(self.att()["result"]["state"], "COMPLETED")
        st = self.led.state()
        S.record(self.led, st, [slurm_obs("COMPLETED", 1100.0, "squeue", "")])     # equivalent (no rc): watermark only
        att = self.att()
        self.assertEqual((att["submissions"][0]["end"]["rc"], att["submissions"][0]["obs_w"]), ("0:0", [1100.0, 1101.0]))
        notes = S.record(self.led, self.led.state(), [slurm_obs("FAILED", 1200.0, "sacct", "1:0")])   # strictly newer
        att = self.att()
        self.assertEqual((att["submissions"][0]["end"]["state"], att["submissions"][0]["end"]["rc"]), ("FAILED", "1:0"))
        self.assertEqual((att["result"]["state"], att["result"]["rc"]), ("FAILED", "1:0"))
        self.assertFalse(L.is_live(att))
        ev = [r for r in self.led.read_audit()[0] if r.get("event") == "end_replaced"]
        self.assertEqual(len(ev), 1, ev)
        self.assertEqual((ev[0]["ended"]["state"], ev[0]["end"]["state"]), ("COMPLETED", "FAILED"))
        self.assertTrue(any("replaces its recorded end" in n for n in notes), notes)
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1150.0, "sacct", "0:0")])   # older: dropped
        self.assertEqual(self.att()["result"]["state"], "FAILED")

    def test_an_overlapping_read_of_another_end_keeps_the_recorded_one(self):
        self.slurm_run()
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0", took=10.0)])
        S.record(self.led, self.led.state(), [slurm_obs("FAILED", 1005.0, "sacct", "1:0")])   # overlaps: not newer
        att = self.att()
        self.assertTrue(L.is_live(att), att)        # neither end taken: uncertain until a strictly newer read decides
        self.assertIn("different ends", att["submissions"][0]["uncertain"]["why"])
        self.assertEqual(att["submissions"][0]["end"]["state"], "COMPLETED")   # kept as data, not as the verdict
        self.assertEqual([r for r in self.led.read_audit()[0] if r.get("event") == "end_replaced"], [])
        S.record(self.led, self.led.state(), [slurm_obs("FAILED", 1100.0, "sacct", "1:0")])   # strictly newer decides
        att = self.att()
        self.assertFalse(L.is_live(att), att)
        self.assertEqual(att["result"]["state"], "FAILED")

    def test_an_overlapping_same_end_still_confirms(self):
        self.slurm_run()
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0", took=10.0)])
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1005.0, "sacct", "")])   # squeue-like, no rc
        att = self.att()
        self.assertFalse(L.is_live(att), att)
        self.assertNotIn("uncertain", att["submissions"][0])

    def test_skew_never_moves_the_watermark_back(self):
        """Codex: FAILED at [10000,10001]; delayed COMPLETED reads at [100,101] then [102,103] never turn it into success."""
        a = {"submissions": [{"job": "5", "submit": "submitted", "obs_w": [10000.0, 10001.0], "seen": {"state": "FAILED"},
                              "end": {"state": "FAILED", "rc": "1:0", "at": "x", "evidence": "sacct"}}],
             "result": {"state": "FAILED", "rc": "1:0", "at": "x", "evidence": "sacct"}}
        for w in ((100.0, 101.0), (102.0, 103.0)):
            L.apply_observation(a, "5", "COMPLETED", "sacct", "t", end={"state": "COMPLETED", "rc": "0:0", "evidence": "sacct"},
                                win=w)
        sub = a["submissions"][0]
        self.assertEqual(sub["end"]["state"], "FAILED")
        self.assertGreaterEqual(sub["obs_w"][1], 10001.0)
        self.assertTrue(L.is_live(a))           # uncertain: never a success
        L.apply_observation(a, "5", "FAILED", "sacct", "t", end={"state": "FAILED", "rc": "1:0", "evidence": "sacct"},
                            win=(10100.0, 10101.0))   # a read that began after every read in question decides
        self.assertFalse(L.is_live(a))
        self.assertEqual(a["result"]["state"], "FAILED")

    def test_apply_observation_replaces_only_on_a_strictly_newer_different_end(self):
        def att(rc="0:0"):
            return {"submissions": [{"job": "5", "submit": "submitted", "obs_w": [100.0, 101.0],
                                     "seen": {"state": "COMPLETED"},
                                     "end": {"state": "COMPLETED", "rc": rc, "at": "x", "evidence": "sacct"}}],
                    "result": {"state": "COMPLETED", "rc": rc, "at": "x", "evidence": "sacct"}}
        for state, rc, win, how, want in (("FAILED", "1:0", (102, 103), "replaced", "FAILED"),
                                          ("COMPLETED", "2:0", (102, 103), "replaced", "COMPLETED"),
                                          ("COMPLETED", "0:0", (102, 103), "applied", "COMPLETED"),
                                          ("COMPLETED", "", (102, 103), "applied", "COMPLETED"),
                                          ("FAILED", "1:0", (100.5, 103), "uncertain", None),   # overlapping, another end
                                          ("COMPLETED", "", (100.5, 103), "applied", "COMPLETED"),   # overlapping, same
                                          ("FAILED", "1:0", (99.5, 100.5), "uncertain", None),   # overlapping, earlier start
                                          ("FAILED", "1:0", (98, 99), "stale", "COMPLETED")):
            a = att()
            got = L.apply_observation(a, "5", state, "sacct", "t", end={"state": state, "rc": rc, "evidence": "sacct"},
                                      win=win)
            self.assertEqual((got, (a["result"] or {}).get("state")), (how, want), (state, rc, win))
            if how == "replaced":
                self.assertEqual(a["result"]["rc"], rc)


class Identity(Base):
    """Finding 5: a box process is the launched one only on the same boot, pid AND /proc start."""

    def ended(self) -> None:
        self.box_run()
        S.record(self.led, self.led.state(), [box_obs(False, 1000.0)])
        self.assertFalse(L.is_live(self.att()))

    def test_an_unreadable_start_or_boot_is_uncertain_not_reopened(self):
        self.ended()
        notes = S.record(self.led, self.led.state(), [box_obs(True, 1100.0, pstart="")])
        att = self.att()
        self.assertTrue(L.is_live(att), att)                       # not ended either: the next read decides
        self.assertEqual(self.reopens(), [])
        self.assertIn("process start cannot be compared", att["submissions"][0]["uncertain"]["why"])
        self.assertEqual(att["submissions"][0]["end"]["state"], "ENDED")
        self.assertTrue(any("uncertain" in n for n in notes), notes)
        S.record(self.led, self.led.state(), [box_obs(False, 1200.0)])                 # gone: the end stands again
        att = self.att()
        self.assertFalse(L.is_live(att), att)
        self.assertNotIn("uncertain", att["submissions"][0])
        self.assertEqual(att["result"]["state"], "ENDED")
        self.ended_boot_unknown()

    def ended_boot_unknown(self) -> None:
        o = box_obs(True, 1300.0, boot="")
        S.record(self.led, self.led.state(), [o])
        self.assertIn("boot_id", self.att()["submissions"][0]["uncertain"]["why"])

    def test_the_pid_file_naming_another_pid_is_uncertain(self):
        self.ended()
        S.record(self.led, self.led.state(), [box_obs(True, 1100.0, pid="5555")])
        att = self.att()
        self.assertTrue(L.is_live(att))
        self.assertIn("pid 5555", att["submissions"][0]["uncertain"]["why"])

    def test_a_receipt_without_start_is_uncertain(self):
        self.led.record_attempt(name="exp--a01", target="fx-box", kind="nohup", nonce="n1", submit="adopted",
                                proc={"pid": "4242", "boot_id": "boot-1", "log": LOG})
        S.record(self.led, self.led.state(), [box_obs(False, 1000.0)])
        S.record(self.led, self.led.state(), [box_obs(True, 1100.0)])
        self.assertEqual(L.attempt_state(self.att()), "UNCERTAIN")


class Budget(Base):
    """Finding 7: record() never waits past its deadline, and writes nothing once stopped or out of time."""

    def test_a_past_deadline_or_a_set_stop_writes_nothing(self):
        import threading
        import time
        self.slurm_run()
        o = slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")
        notes = S.record(self.led, self.led.state(), [o], deadline=time.monotonic() - 1)
        self.assertTrue(any("not updated" in n and "in memory only" in n for n in notes), notes)
        ev = threading.Event()
        ev.set()
        notes = S.record(self.led, self.led.state(), [o], cancel=ev)
        self.assertTrue(any("not updated (stopped)" in n for n in notes), notes)
        self.assertIsNone(self.att()["result"])

    def test_the_lock_wait_ends_at_the_deadline(self):
        import threading
        import time
        self.slurm_run()
        held, release = threading.Event(), threading.Event()

        def holder():
            with self.led.locked():
                held.set()
                release.wait(10)
        threading.Thread(target=holder, daemon=True).start()
        held.wait(5)
        t = time.monotonic()
        notes = S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")],
                         deadline=time.monotonic() + 0.4)
        took = time.monotonic() - t
        release.set()
        self.assertLess(took, 1.5, notes)                          # never its own 5 s
        self.assertTrue(any("not updated" in n for n in notes), notes)
        self.assertIsNone(self.att()["result"])

    def test_a_stop_while_waiting_for_the_lock_ends_the_wait(self):
        import threading
        import time
        self.slurm_run()
        held, release, stop = threading.Event(), threading.Event(), threading.Event()

        def holder():
            with self.led.locked():
                held.set()
                release.wait(10)
        threading.Thread(target=holder, daemon=True).start()
        held.wait(5)
        threading.Timer(0.2, stop.set).start()
        t = time.monotonic()
        S.record(self.led, self.led.state(), [slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")], cancel=stop)
        release.set()
        self.assertLess(time.monotonic() - t, 1.5)
        self.assertIsNone(self.att()["result"])

    def test_no_change_after_the_stop_mid_record(self):
        import threading
        self.slurm_run()
        self.led.record_attempt(name="other--a01", target="fx-slurm", kind="slurm", nonce="n2", submit="submitted",
                                job="102")
        o = slurm_obs("COMPLETED", 1000.0, "sacct", "0:0")
        o.jobs.append(observe.Job("102", "other--a01", "COMPLETED", exit_code="0:0", source="sacct"))
        stop = threading.Event()
        real, calls = L.Ledger.apply_changes, []

        def first_then_stop(led, run, changes, **kw):
            calls.append(run)
            got = real(led, run, changes, **kw)
            stop.set()                                              # the wait stops right after the first run
            return got
        from unittest import mock
        with mock.patch.object(L.Ledger, "apply_changes", first_then_stop):
            notes = S.record(self.led, self.led.state(), [o], cancel=stop)
        self.assertEqual(len(calls), 1, calls)
        done = [r for r in ("exp", "other") if self.led.read_run(r).data["attempts"]["a01"]["result"]]
        self.assertEqual(len(done), 1, done)
        self.assertTrue(any("1 run(s) not recorded, in memory only" in n for n in notes), notes)


class ObsWindow(unittest.TestCase):
    def test_started_at_else_observed_at(self):
        self.assertEqual(observe.obs_window(observe.Observation(SLURM, observed_at=9.0, started_at=5.0)), (5.0, 9.0))
        self.assertEqual(observe.obs_window(observe.Observation(SLURM, observed_at=9.0)), (9.0, 9.0))

    def test_observe_stamps_when_its_ssh_started(self):
        import time
        t0 = time.time()
        o = observe.observe([harness.Place("x", kind="slurm", error="broken")], 1)[0]
        self.assertGreaterEqual(o.started_at, t0)
        self.assertLessEqual(o.started_at, o.observed_at)

    def test_a_live_box_run_carries_its_proc_start(self):
        text = ("@@start\n@@now 2000\n@@pwd /r|/r\n@@boot b-1\n@@ws\n"
                f"{LOG} 1990 10 alive:30:4242:123456\nlogs/old-20261101-100000.log 1000 5 alive:9:77\n@@attempts\n@@end\n")
        o = observe.parse(BOX, text, 0, "")
        self.assertEqual([(j.pid, j.pstart) for j in o.jobs], [("4242", "123456"), ("77", "")])

    def test_rs_pst_reads_proc_stat_field_22(self):
        import os
        import subprocess
        if not os.path.exists(f"/proc/{os.getpid()}/stat"):
            self.skipTest("no /proc here")
        got = subprocess.run(["bash", "-c", observe._PSTART + f"\nrs_pst {os.getpid()}; echo; rs_pst 999999999; echo x"],
                             capture_output=True, text=True).stdout.split("\n")
        with open(f"/proc/{os.getpid()}/stat") as f:
            want = f.read().rsplit(")", 1)[1].split()[19]
        self.assertEqual(got[:2], [want, "x"])
        self.assertIn("rs_pst", observe.NOHUP)
        self.assertIn('alive:$1:$pid:$(rs_pst "$pid")', observe.NOHUP)


class NamedLogs(Base):
    """Round 3 P2: the nohup read lists the newest 50 logs; a caller (rsk wait) names the logs it watches, read beside
    them — checked in Python and again remotely, the same per-file bounds; rsk status names none."""

    def read(self, d: str, logs=(), raw: str | None = None) -> observe.Observation:
        import subprocess
        place = harness.Place("fx-box", kind="nohup", host="b", remote_dir=d, deploy=".ws")
        body = observe.script(place, 2, (), False, logs)
        if raw is not None:                      # LOGS as a caller that skipped the Python check would send it
            body = body.replace("LOGS=''\n", "LOGS=" + raw + "\n", 1)
        done = subprocess.run(["bash", "-s"], input=body, capture_output=True, text=True, timeout=60)
        return observe.parse(place, done.stdout, done.returncode, done.stderr)

    def setUp(self) -> None:
        import os
        import tempfile
        super().setUp()
        self.d = tempfile.mkdtemp()
        os.makedirs(self.d + "/logs")
        self.old = "logs/exp--a01-20261101-000000.log"
        with open(f"{self.d}/{self.old}", "w") as f:
            f.write("x")
        with open(f"{self.d}/{self.old}.rc", "w") as f:
            f.write("rc=3 term=0 at=5\n")
        os.utime(f"{self.d}/{self.old}", (1, 1))
        for i in range(55):
            with open(f"{self.d}/logs/new{i}-20261102-0000{i:02d}.log", "w") as f:
                f.write("y")

    def tearDown(self) -> None:
        import shutil
        shutil.rmtree(self.d, ignore_errors=True)
        super().tearDown()

    def test_a_named_log_older_than_the_newest_50_is_read(self):
        o = self.read(self.d)
        self.assertTrue(o.ok)
        self.assertEqual((len(o.jobs), [j for j in o.jobs if j.log == self.old]), (50, []))   # rsk status: unchanged
        o = self.read(self.d, [self.old, self.old])
        self.assertEqual(len(o.jobs), 51)
        self.assertEqual([(j.state, j.exit_code) for j in o.jobs if j.log == self.old], [("ENDED", "3")])
        new = "logs/new54-20261102-000054.log"                    # named and discovered: listed once
        self.assertEqual(sum(j.log == new for j in self.read(self.d, [new]).jobs), 1)

    def test_rsk_status_names_no_log(self):
        from unittest import mock
        place = harness.Place("fx-box", kind="nohup", host="b", remote_dir=self.d, deploy=".ws")
        with mock.patch.object(observe, "observe", return_value=[]) as m:
            S.read(self.led, [place], 2, 5.0)
        self.assertNotIn("logs", m.call_args.kwargs)

    def test_a_name_outside_the_logs_dir_or_the_shape_is_never_read(self):
        import os
        os.symlink(f"{self.d}/{self.old}", f"{self.d}/logs/lnk-20261101-000000.log")
        os.makedirs(f"{self.d}/logs/sub")
        with open(f"{self.d}/logs/sub/x-20261101-000000.log", "w") as f:
            f.write("z")
        bad = ["../etc/x-20261101-000000.log", "logs/../x-20261101-000000.log", "logs/sub/x-20261101-000000.log",
               "/etc/passwd", "logs/a b-20261101-000000.log", "logs/x.log", "logs/lnk-20261101-000000.log"]
        place = harness.Place("fx-box", kind="nohup", host="b", remote_dir=self.d, deploy=".ws")
        self.assertIn(" LOGS=logs/lnk-20261101-000000.log\n", observe.script(place, 2, (), False, bad))
        o = self.read(self.d, bad)
        self.assertEqual(len(o.jobs), 50)                         # the symlink passes the shape, not the remote check
        o = self.read(self.d, raw="'logs/sub/x-20261101-000000.log ../x-20261101-000000.log /etc/passwd "
                                  "logs/lnk-20261101-000000.log logs/*'")
        self.assertEqual(len(o.jobs), 50)
        import shlex
        head = observe.script(place, 2, (), False, [f"logs/r{i}-20261101-000000.log" for i in range(500)])
        named = shlex.split(head.split("\n", 1)[0])[-1]
        self.assertEqual(len(named.removeprefix("LOGS=").split()), observe.LOGS_MAX)


if __name__ == "__main__":
    unittest.main()
