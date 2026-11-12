"""grants.py, from two days of agents on Slurm: (a) a run whose name holds a space (a zsh word-splitting slip let one
through: the ledger attempt keeps the decoded name, request.bound.name the %q form `a\\ b`) — check() read the decoded
name as a %q value, two words, unreadable, so cancel_own could never cover the run; the bound form is read now (the
decoded name, quoted, only as the fallback). (b) I4: a relaunch_after-any grant blocked by an attempt whose cancel was
sent but whose end no read has shown says so (CANCELLING / CANCELLING?), pointing at rsk status / rsk cancel --wait S,
never at --same-name-ok."""

import hashlib
import unittest

from helpers import ScratchHome

from remote_run import grants as G
from remote_run import ledger as L

SLURM_BOUND = ("kind", "target", "partition", "gres", "cpus", "mem", "time", "account", "name", "extra", "payload",
               "env_kind", "env_name", "wandb_mode", "env_hook", "venv_dir", "uv_sync_args", "conf_extra", "flags",
               "chain")
RAW = "x--pilot--a b--scratch--s42"            # the decoded name, as the ledger attempt keeps it
BOUND = "x--pilot--a\\ b--scratch--s42"        # the same name in the plan block (%q), as request.bound keeps it


def block(**kv: str) -> dict:
    """A parsed Slurm plan block as remote/submit.sh prints it (values %q, bound_hash over kind= … chain=)."""
    base = {"kind": "slurm", "target": "fx", "partition": "gpu", "gres": "gpu:gt-a:1", "cpus": "8", "mem": "32G",
            "time": "0-04:00:00", "account": "''", "name": BOUND, "extra": "", "payload": "python\\ t.py",
            "env_kind": "uv", "env_name": "''", "wandb_mode": "online", "env_hook": "''", "venv_dir": "''",
            "uv_sync_args": "''", "conf_extra": "", "flags": "", "chain": "0", "info_prior": "0"}
    base.update(kv)
    bound = [f"{k}={base[k]}" for k in SLURM_BOUND]
    h = hashlib.sha256(("\n".join(bound) + "\n").encode()).hexdigest()
    text = ("@@plan v1\napi=3\n" + "".join(ln + "\n" for ln in bound) + f"info_prior={base['info_prior']}\n"
            + f"warnings_avail=0\nwarnings_id={'0' * 64}\nwarnings=0\nbound_hash={h}\n@@end\n")
    return G.parse_plan(text)


def grant(scope: dict, actions=("launch", "cancel_own"), **lim) -> dict:
    return G.new_grant("stop your own runs yourself", scope, list(actions),
                       **{"max_live": None, "max_launches": None, "expires": None, **lim})


class SpacedName(ScratchHome):
    """The ledger as rsk launch writes it (record_attempt with the plan block), then the cancel check rsk cancel makes."""

    def setUp(self) -> None:
        super().setUp()
        self.proj = self.home / "proj"
        self.proj.mkdir()
        self.led = L.Ledger(self.proj)
        self.run, self.aid = self.led.record_attempt(
            name=RAW, target="fx", kind="slurm", nonce="n-1", submit="submitted", plan=block(), plan_id="p-1",
            grant="g-x", action="launch", cls="pilot", job="7")

    def cancel(self, *recs: dict, job: str = "7") -> G.Decision:
        st = self.led.state()
        st.grants = list(recs)
        return G.check(st, "cancel", job=job, run=self.run, ident=G.cancel_ident("slurm", "fx", job, RAW, "/r/proj"),
                       plan={"target": "fx", "kind": "slurm", "name": RAW, "warnings": "0"})   # as cancel.py passes it

    def test_the_ledger_is_shaped_like_the_real_one(self):
        att = self.led.read_run(self.run).data["attempts"][self.aid]
        self.assertEqual((self.run, att["name"], att["request"]["bound"]["name"]), (RAW, RAW, BOUND))
        self.assertEqual(G.facts({"name": RAW}).unreadable, ("name",))      # the decoded name as %q: two words
        self.assertEqual(G.facts({"name": G.att_name(att)}).name, RAW)

    def test_cancel_own_covers_it_now(self):
        for scope in ({"targets": ["fx"]}, {"names": ["x--pilot--*"]}, {"names": ["x--pilot--a?b--scratch--s42"]},
                      {"classes": ["pilot"]}):     # (a scope item never holds a space: validate() refuses it)
            with self.subTest(scope=scope):
                d = self.cancel(g := grant(scope))
                self.assertTrue(d.covered, d.reasons)
                self.assertEqual(d.record["id"], g["id"])

    def test_a_deny_glob_still_matches_it(self):
        for names in (["x--pilot--*"], ["x--pilot--a?b*"], ["x--pilot--a?b--scratch--s42--a01"],
                      ["x--pilot--a?b--scratch--s42--a*"]):     # the run, an attempt's job name, every attempt (R7-1)
            with self.subTest(names=names):
                d = self.cancel(grant({"targets": ["fx"]}), G.new_deny("never stop those", {"names": names}, ["cancel"]))
                self.assertTrue(d.denied, d.reasons)
        own_off = G.new_deny("only I stop those", {"names": ["x--pilot--*"]}, ["cancel_own"])
        d = self.cancel(grant({"targets": ["fx"]}), own_off)
        self.assertFalse(d.covered)
        self.assertIn("cancel_own is denied", " ".join(d.reasons))
        d = self.cancel(grant({"targets": ["fx"]}), G.new_deny("not those", {"names": ["y--*"]}, ["cancel"]))
        self.assertTrue(d.covered, d.reasons)                               # another run's deny: not this one

    def test_a_scope_it_is_outside_still_does_not_cover_it(self):
        for scope, why in (({"names": ["y--*"]}, f"name {RAW} matches none of y--*"),
                           ({"targets": ["other"]}, "target fx not in other"),
                           ({"classes": ["train"]}, "class pilot not in train")):
            with self.subTest(scope=scope):
                d = self.cancel(grant(scope))
                self.assertFalse(d.covered)
                self.assertIn(why, " ".join(d.reasons))
        self.assertFalse(self.cancel(grant({"targets": ["fx"]}, actions=("launch",))).covered)   # no cancel_own

    def test_without_a_bound_name_the_decoded_one_is_read(self):   # an attempt from before request.bound held it
        def drop(rec: dict) -> None:
            rec["attempts"][self.aid]["request"]["bound"].pop("name")
        self.led.update_run(self.run, drop)
        att = self.led.read_run(self.run).data["attempts"][self.aid]
        self.assertEqual(G.facts({"name": G.att_name(att)}).name, RAW)
        self.assertTrue(self.cancel(grant({"names": ["x--pilot--*"]})).covered)
        self.assertTrue(self.cancel(grant({}), G.new_deny("no", {"names": ["x--pilot--*"]}, ["cancel"])).denied)

    def test_two_forms_naming_different_runs_are_unreadable(self):   # fail closed: no grant, every names deny
        def swap(rec: dict) -> None:
            rec["attempts"][self.aid]["request"]["bound"]["name"] = "z--other--s1"
        self.led.update_run(self.run, swap)
        att = self.led.read_run(self.run).data["attempts"][self.aid]
        self.assertEqual(G.facts({"name": G.att_name(att)}).unreadable, ("name",))
        d = self.cancel(grant({"targets": ["fx"]}))
        self.assertFalse(d.covered)
        self.assertIn("unreadable plan field(s): name", " ".join(d.reasons))
        self.assertTrue(self.cancel(grant({}), G.new_deny("no", {"names": ["q--*"]}, ["cancel"])).denied)

    def test_att_name_forms(self):
        for att, want in (({"name": "a--a01", "request": {"bound": {"name": "a--a01"}}}, "a--a01"),
                          ({"name": RAW, "request": {"bound": {"name": BOUND}}}, BOUND),
                          ({"name": RAW}, f"'{RAW}'"),
                          ({"name": 'q"b', "request": {"bound": {"name": 'q"b'}}}, "'q\"b'"),   # a box's %s name
                          ({"name": "", "request": {}}, "")):
            with self.subTest(att=att):
                self.assertEqual(G.att_name(att), want)
                self.assertEqual(G.facts({"name": want}).name, att["name"])


class CancelSent(ScratchHome):
    """I4 in grants._any_misses: the earlier attempt's cancel was sent (ledger CANCELLING / CANCELLING?) and no read has
    shown its end — the relaunch waits, and the reason says why and where to look."""

    RUN = "exp--train--a--scratch--s0"

    def setUp(self) -> None:
        super().setUp()
        self.proj = self.home / "proj"
        self.proj.mkdir()
        self.led = L.Ledger(self.proj)
        p = block(name=f"{self.RUN}--a01")
        self.run, self.aid = self.led.record_attempt(name=f"{self.RUN}--a01", target="fx", kind="slurm", nonce="n-1",
                                                     submit="submitted", plan=p, plan_id="p-1", grant="g-x",
                                                     action="launch", cls="train", job="7")
        self.g = grant({"targets": ["fx"], "relaunch_after": "any"}, actions=("launch", "relaunch"))

    def relaunch(self, **extra) -> G.Decision:
        st = self.led.state()
        st.grants = [self.g]
        p = {**block(name=f"{self.RUN}--a02", info_prior="1"), "plan_id": "p-2", **extra}
        return G.check(st, "relaunch", plan=p, run=self.run)

    def test_a_cancel_not_confirmed_is_said_as_that(self):
        self.led.observe(self.run, self.aid, "7", "CANCELLING", "rsk cancel (scancel rc=0)")
        d = self.relaunch()
        why = " ".join(d.reasons)
        self.assertFalse(d.covered)
        self.assertIn(f"the cancel of {self.RUN} a01 (job 7 on fx) is not confirmed yet: sent", why)
        self.assertIn("scancel accepted it; no read of fx has shown its end since", why)
        self.assertIn("--wait S waits for its end (nothing is sent again), or rsk status shows it", why)
        self.assertNotIn("may still be live: a01", why)
        self.assertNotIn("--same-name-ok", why)
        d = self.relaunch(unreadable_now=["fx"])                 # launch.refresh could not read fx just now
        self.assertIn("scancel accepted it; fx is not readable now — rsk cancel", " ".join(d.reasons))

    def test_an_unconfirmed_scancel_too(self):
        self.led.observe(self.run, self.aid, "7", "CANCELLING?", "rsk cancel", detail="scancel exit 1, not confirmed")
        why = " ".join(self.relaunch().reasons)
        self.assertIn("scancel's answer did not confirm it (CANCELLING?)", why)
        self.assertIn("rsk status shows whether it ends; rsk cancel exp--train--a--scratch--s0 would send it again", why)

    def test_its_end_seen_lets_the_relaunch_go_and_a_live_run_is_said_as_before(self):
        self.led.observe(self.run, self.aid, "7", "RUNNING", "squeue")
        why = " ".join(self.relaunch().reasons)
        self.assertIn("earlier attempt(s) of exp--train--a--scratch--s0 may still be live: a01 (RUNNING)", why)
        self.assertNotIn("cancel", why)
        self.led.observe(self.run, self.aid, "7", "CANCELLED", "sacct", end={"state": "CANCELLED", "rc": "0:15",
                                                                            "evidence": "sacct"})
        d = self.relaunch()
        self.assertTrue(d.covered, d.reasons)


if __name__ == "__main__":
    unittest.main()
