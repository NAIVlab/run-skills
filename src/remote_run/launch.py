"""`rsk launch`: plan on the target, then the user's OK (or a record that already covers the plan), then the
submit — every step recorded in the project's ledger (ledger.py) and checked against what the user allowed (grants.py).

    rsk launch -T T [-C DIR] [--class C] [--same-name-ok] [--free-name] [--relaunch RUN] [--deadline S]
               [--check-after S]
               slurm: [-p PART] [-g N] [-G TYPE] [-t TIME] [-m MEM] [-c CPUS] [-n NAME] [--chain N] [--<policy-flag>…]
                      -- CMD…
               nohup: [-g N | -d IDS] [-N NAME] [--nice N] [--gpu-busy-ok] [-- CMD…]
    rsk launch --plan ID [--plan ID…] [--approve] [-C DIR] [--deadline S] [--check-after S]

0. Usage: --force (submit.sh's -y) is never a policy flag, and no word before `--` may contain --rs- (not even as an
   option's value: rsk sends those words itself); a value of -p -g -G -t -m -c -n -N -d --nice never starts with '-';
   a name that carries a class (<exp>--<class>--…) is that class — a different --class is exit 2; a run's class is
   sticky: the class recorded at its first attempt — another one (name or --class), or any one when its first attempt
   had none, is exit 2; --gpu-busy-ok needs -d. A run name (-n, -N, --relaunch; also one the plan resolves from the
   conf) holding whitespace or a control character is exit 2, before anything is planned (a word-splitting slip).
1. Local duplicate: a live ledger attempt of the run (the name minus --aNN) on that target → exit 6 unless
   --same-name-ok (also passed on to the remote guard). A --chain skips it, as submit.sh skips singleton chains. A
   SUBMIT_UNKNOWN attempt of the run blocks ALWAYS (--same-name-ok, chains, relaunch too): rsk status settles it.
   First (refresh), when the ledger counts an attempt of the run as live on any target: ONE read of each such target —
   the read rsk status makes, back to the oldest of them — is applied to the ledger, so a job that ended since is not
   refused as live and a relaunch decision sees its end; also before `--plan` submits; a target that cannot be read
   changes nothing (the ledger's state stands). An attempt rsk cancel signalled (CANCELLING, CANCELLING?: its end not
   observed yet) still blocks: the refusal says the cancel is not confirmed (and when the target could not be read
   now) and points at rsk status / rsk cancel --wait S, never at --same-name-ok.
2. PLAN — slurm: ONE ssh that reads the `# rs-api=N` marker line of the deployed <REMOTE_DIR>/.<t>/submit.sh itself
   and, only when it says api=3, runs `bash <REMOTE_DIR>/.<t>/submit.sh --rs-attempt <nonce> --rs-mode plan …`; nohup:
   `RS_VIA_RSK=1 bin/run-launch --rs-attempt <nonce> --rs-mode plan …` from the harness (cwd = the project, TARGET
   set; the block launch.sh prints is its own api= line). A deploy that does not speak api=3, an older parser's exit 2
   (`unknown arg …`), or a block that lacks a key this rsk needs (grants.NEEDED: env_hook venv_dir uv_sync_args,
   warnings_avail warnings_id; slurm conf_extra flags; nohup busy_ok launch_cfg info_run_gpu info_launchers) → exit
   6 `needs: sync`. A plan never submits: its refusal (policy 3, duplicate 6, usage 2, too few free GPUs 8, a nohup env that
   would fail the gate 1) is the exit code, with the target's lines (a nohup plan creates nothing outside .rs/).
   Every call (plan and submit) first asks the project dir's filesystem (observe's rs_dir, FS_WAIT s; slurm: inside
   that ssh, before the marker line; nohup: a read-only ssh of its own before run-launch): a hung mount ends it at once,
   nothing run — exit 5 `…: its filesystem gave no answer within 15 s (a hung mount?) — nothing was planned`; a submit
   stopped there is NOT_SUBMITTED (the use given back, the plan free again).
3. The plan and its card are stored (plans/<id>.json, never rewritten). Its action is derived, never a flag: a run that
   already has attempts that may have run (any target; not this plan's own) in the ledger, or in the target's journal
   (the block's envelope info_prior > 0: receipts named <run> / <run>--aNN, Slurm also live jobs of this WorkDir —
   run-watch's runs never enter the ledger), or whose block does not say (no readable info_prior: fail closed) →
   relaunch, a chain=1 block → chain, else
   launch — every one that applies is checked (a deny of any matches; a record must allow all; a deny that names the
   run and lists relaunch or resubmit matches every launch of it, launch included, R6-1: grants.run_deny). grants.check()
   decides: a deny → exit 3; a record that covers the plan → submit now; else the card and `needs
   user: approval — plan <id>` → exit 4. A standing grant never covers a workstation plan that lands on a GPU in use
   (only the user's OK naming it) or whose launch.sh counted launcher / container / env-dropping warnings
   (warnings_gpu > 0, or no warnings_gpu: an older launch.sh — whatever the grant's allow_warnings kind: the card's
   NO GRANT line), a plan with warnings its
   allow_warnings kind does not cover, or more resources / time than its caps. A grant covers policy flags (bound as
   flags=), conf SBATCH_EXTRA words outside grants.EXTRA_ALLOW and --same-name-ok like the rest of the plan (S3: the
   card NOTEs them). A grant with launch covers a relaunch judged as a launch, whatever the earlier attempt's end
   (S1), never while an earlier attempt may still be live; a grant with relaunch but no launch only after an
   infrastructure end (PREEMPTED NODE_FAIL BOOT_FAIL REBOOT) with the configuration repeated.
4. --plan … --approve (a flag: the user approved these cards; words after it are accepted, never recorded): in ONE
   ledger lock hold, each plan re-checked (unused, younger than PLAN_TTL_S, not superseded by a newer plan of the
   same target + name; else exit 6, nothing submitted, no approval), denies checked again, every plan claimed (single use), then one approval record (created_via plan-approve) per kind of request
   covers them all (a sweep is one approval) — scoped to those plan ids (scope.plans) and expiring with them (24 h): a
   later plan of the same configuration is a new card for the user, also after a refused submit gave its use back; a
   failure recording it revokes what was recorded. Each plan is then submitted with a fresh nonce, --rs-expect
   <bound_hash> and --rs-warnings <the card's warnings_id> (the target recomputes which WARNING: lines it printed and
   refuses a difference, exit 6): -y only when the approved card showed warnings or the covering grant's kind covers
   the plan's warnings, --rs-chain on each of N chain segments (slurm; a segment's own attempt is not counted against
   the grant's max_live), --gpu-busy-ok only when the card's own landing was on a busy GPU, pinned to it with -d <the
   card's GPUs> (nohup; launch.sh binds who is on it: another occupant since the plan is exit 6, the refusal names what
   changed).
   --plan without --approve submits only when a record covers the plan now.
5. Each submission is recorded as SUBMIT_UNKNOWN before it is sent (sticky); the reply settles it: a receipt = submitted
   (nohup: the receipt read back from the journal first — also after a non-zero exit, e.g. launch.sh killed after its
   gate said go; else, when the journal cannot be read and run-launch exited 0, launch.sh's own launch line, the last
   `[<t>] started PID … ; log … ; pid file …` line, its fields taken from the end — a look-alike line a payload printed
   proves nothing); proof that nothing was sent = not submitted: the remote verdict refused/failed with no receipt,
   submit.sh's exit with no attempt dir (it claims one before anything else), launch.sh's exit with no attempt dir in
   the journal read back (the same claim), run-launch failing before its launch ssh; then the use is given back and,
   for the plan's first segment, its claim released — `rsk launch --plan <id>` retries it under the same approval
   (--rs-expect still guards drift). A Slurm submit's ssh exit 255 without the remote's first marker (@@api) is
   SUBMIT_UNKNOWN whatever ssh's stderr says (R6-4: a ProxyCommand's fallback route or a login shell can print
   "Connection refused" / "Permission denied" lines on a session that did open), and so are a timeout, an exit the
   journal does not explain (nohup: it is always read before deciding) or no receipt — `rsk status` reconciles it from
   the remote journal; never resubmitted blind (the plan stays used).
6. --check-after S (1..CHECK_MAX_S, 0 = off): the start milestone in the same call — S seconds after the last submit,
   ONE read of the targets this call launched on (also applied to the ledger), and each submission it made (every
   chain segment) judged from that read: live (pending / running), ended as it should (Slurm COMPLETED, a box run's
   exit 0), ended otherwise — its state, exit code and the status.sh digest of that job / log, exit 1 (it was launched;
   a fix and a relaunch are a new decision) —, or not in the read / a target that cannot be read: state unknown.
7. Names and the tracker (experiment-conventions.md §2, §5) — hints, refusing only what is certain: a NEW run (no
   attempt of it in the ledger that may have run, none in the target's journal: info_prior not > 0, unknown counts as
   none) whose name — as resolved, also as the block prints it — is not <task>--<stage>--<variant>--<origin>--s<seed>
   [--aNN] (name_problems: lowercase a-z 0-9 and hyphens inside fields, a §1 class, origin scratch | none | fork-… |
   finetune-…, s<N>), or holds an opaque word (new final best r<N>), gets a NOTE (and a card line) and is launched as
   named; an existing run is not checked; --free-name = the user's own name: not checked, the card says so, a grant
   covers it as any plan. A smoke plan is exit 2 only when rsk can see its run reach the tracker: its command's env
   words (env_scan, GNU env's reading: a Slurm argv after `env`, a box line from its first word — the wrapper runs
   `env "$@"`) set another WANDB_MODE or unset it, or the Slurm conf binds one that is not disabled, the command
   leaves it and nothing applied later can change it. What it cannot tell — a box's conf, a line of several commands,
   an expansion in env's words, an env option, a conf value that an ENV_HOOK, a conda env or $PROJ/.wandb_env (the
   block's info_wandb_env; none on an older deploy) may change either way — is a WARNING on the card, and the plan
   goes on. Once a formal run (pilot train eval
   ablate bench) went out — or may have — with the tracker not known off, a NOTE lists the wandb fields §4 asks for
   (a run with earlier attempts: resume the same wandb run). Beyond these words, what the command and the trainer do
   is not rsk's to see.
A record is bookkeeping, not proof that the user agreed: the card shown and the user's OK are what make it theirs.
The ledger lock is held for each check-then-record step, never across an ssh.
Exit: 0 submitted · 1 failed on the target (or, --check-after, launched and already failed) · 2 usage (also a smoke
that would reach the tracker) · 3 refused
(policy, deny) · 4 needs the user · 5 unknown · 6 conflict (duplicate, stale / used / superseded plan, drift, an old
deploy) · 8 placement (too few free GPUs).
"""

from __future__ import annotations

import argparse
import os
import re
import secrets
import shlex
import subprocess
import time
import unicodedata
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from remote_run import grants, harness, observe, paths
from remote_run import ledger as L
from remote_run.errors import (CONFLICT, FAILED, NEEDS_USER, OK, PLACEMENT, REFUSED, UNKNOWN, USAGE, RskError)

API = "api=3"                    # the protocol this rsk speaks (the deployed submit.sh / launch.sh: `# rs-api=3`)
PLAN_TTL_S = 24 * 3600           # an older plan is expired: plan again (the target may have changed meanwhile)
POLICY_FLAG = re.compile(r"--[A-Za-z0-9][A-Za-z0-9-]*")   # submit.sh hands an unknown --word to the policy
NOT_POLICY = frozenset({"--force"})   # submit.sh's own alias of -y: never handed through as a policy flag
INTERESTING = re.compile(r"^(WARNING|NOTE|ERROR|REFUSED)\b")
# an older deploy's parser refusing what this rsk sends (exit 2, nothing submitted): both kinds → needs: sync
OLD_DEPLOY = ("no .ws/launch.sh in the remote dir", "unknown arg", "is not a flag of this submit.sh",
              "--rs-warnings takes one count", "does not speak rs-api=3")
FEW_FREE = re.compile(r"only [0-9]+ GPU id\(s\) free")
CHECK_MAX_S = 600                # --check-after: the longest wait for the first read after a submit
# experiment-conventions.md §2: <task>--<stage>--<variant>--<origin>--s<seed>, then the attempt's --aNN (ledger.run_id)
NAME_FIELD = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
NAME_ORIGIN = re.compile(r"scratch|none|(?:fork|finetune)-[a-z0-9]+(?:-[a-z0-9]+)*")
NAME_SEED = re.compile(r"s[0-9]+")
NAME_OPAQUE = re.compile(r"new|final|best|r[0-9]+")      # §2: no opaque new / final / best / r2
NAME_SHAPE = "<task>--<stage>--<variant>--<origin>--s<seed> (e.g. mytask-v3--train--lr-cosine--scratch--s0)"
FORMAL = ("pilot", "train", "eval", "ablate", "bench")     # §4: the classes that map into wandb
ENV_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*", re.S)


def out(msg: str = "") -> None:
    print(msg, flush=True)


def new_nonce(prefix: str = "rsk") -> str:
    return f"{prefix}-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}-{secrets.token_hex(4)}"


def new_plan_id() -> str:
    return f"p-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}-{secrets.token_hex(3)}"


# ================================================================================================ arguments
class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:          # a usage error is exit 2 with rsk's own message, never SystemExit
        raise RskError(f"rsk launch: {message} (rsk launch -h)", USAGE)


def parser() -> argparse.ArgumentParser:
    p = _Parser(prog="rsk launch", allow_abbrev=False, formatter_class=argparse.RawDescriptionHelpFormatter,
                description=__doc__.split("\n\n")[0], epilog=__doc__.split("\n\n", 1)[1])
    p.add_argument("-T", "--target", default="")
    p.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory)")
    p.add_argument("--plan", dest="plans", action="append", default=[], metavar="ID", help="a stored plan (repeatable)")
    p.add_argument("--approve", nargs="?", const=True, default=None, metavar="WORDS",
                   help="the user approved the --plan card(s) (a flag; words after it are accepted and ignored: rsk "
                   "does not record them)")
    p.add_argument("--class", dest="cls", default="", choices=grants.CLASSES, help="the run class (grant scopes)")
    p.add_argument("--same-name-ok", action="store_true", help="also when a run of this name is live (both wanted)")
    p.add_argument("--free-name", action="store_true", help="the run's name is the user's own: experiment-"
                   "conventions.md §2 not checked (no NOTE); the card says so")
    p.add_argument("--relaunch", default="", metavar="RUN", help="the run's next attempt (aNN), same configuration")
    p.add_argument("--deadline", type=float, default=180.0, help="seconds per ssh (default 180)")
    p.add_argument("--check-after", dest="check_after", type=int, default=0, metavar="S",
                   help=f"after a submit, wait S seconds (1-{CHECK_MAX_S}; 0 = off, the default) and read each "
                   "submission once: still pending / running, or already ended (state, exit code, the log's digest) "
                   "— one that failed at once is exit 1 (it was launched: no new launch is implied)")
    p.add_argument("-g", dest="gpus", default=None, help="GPU count")
    s = p.add_argument_group("slurm (submit.sh)")
    for flag, dest, what in (("-p", "part", "partition"), ("-G", "gtype", "GPU type"), ("-t", "time", "time limit"),
                             ("-m", "mem", "memory"), ("-c", "cpus", "CPUs"), ("-n", "name", "job name")):
        s.add_argument(flag, dest=dest, default=None, help=what)
    s.add_argument("-y", action="store_true", help="accepted, never sent as typed: the card decides (-y only when "
                   "the approved card showed warnings or the covering grant's kind covers the plan's warnings)")
    s.add_argument("--chain", type=int, default=0, metavar="N", help="N singleton segments (--rs-chain), one approval")
    n = p.add_argument_group("nohup (run-launch)")
    n.add_argument("-d", dest="ids", default=None, help="exactly these GPU ids")
    n.add_argument("-N", dest="wsname", default=None, help="run name")
    n.add_argument("--nice", default=None)
    n.add_argument("--gpu-busy-ok", action="store_true", help="with -d IDS: plan onto those GPUs even with a compute "
                   "process (the card then needs the user's OK for them; never a standing grant)")
    return p


NAME_UNSAFE = "a run name never holds whitespace or a control character"


def unsafe_name(name: str) -> bool:
    """A name holding whitespace or a control character: never a run name — a word-splitting slip in the caller's
    shell (two words joined into one argument). The Slurm plan block carries the name %q-escaped while the ledger,
    grant scopes and `rsk cancel RUN` hold it raw: two spellings of one run (cancel_own never matched one)."""
    return any(c.isspace() or unicodedata.category(c) == "Cc" for c in name)


def help_asked(extra: list[str]) -> bool:
    """`rsk launch -h` (before `--`): the help, no command run (cli.py prints no verdict line after it)."""
    head = extra[:extra.index("--")] if "--" in extra else extra
    return "-h" in head or "--help" in head


def parse(extra: list[str]) -> argparse.Namespace:
    """ARGS = everything after `rsk launch` (cli.py hands it over unparsed): rsk's flags, then `--` and the command."""
    words = list(extra)
    head, cmd = (words[:words.index("--")], words[words.index("--") + 1:]) if "--" in words else (words, [])
    rs = [w for w in head if "--rs-" in w]      # also inside a value (-n--rs-chain): the target's pre-scan would act on it
    if rs:
        raise RskError(f"rsk launch: {' '.join(rs)}: no word before -- may contain --rs- — rsk sends the --rs-* words "
                       "itself (-y only when the approved card showed warnings or the covering grant's kind covers the "
                       "plan's warnings)", USAGE)
    ns, rest = parser().parse_known_args(head)
    bad = [w for w in rest if not POLICY_FLAG.fullmatch(w)]
    if bad:
        raise RskError(f"rsk launch: unrecognized {' '.join(bad)} (rsk launch -h; the command goes after --)", USAGE)
    own = [w for w in rest if w in NOT_POLICY]
    if own:
        raise RskError(f"rsk launch: {' '.join(own)} is not a policy flag: rsk sends submit.sh's -y / --force itself "
                       "(-y only when the approved card showed warnings or the covering grant's kind covers the plan's "
                       "warnings)", USAGE)
    dash = [f"{flag} {v}" for flag, v in (("-p", ns.part), ("-g", ns.gpus), ("-G", ns.gtype), ("-t", ns.time),
                                         ("-m", ns.mem), ("-c", ns.cpus), ("-n", ns.name), ("-d", ns.ids),
                                         ("-N", ns.wsname), ("--nice", ns.nice), ("--relaunch", ns.relaunch))
            if isinstance(v, str) and v.startswith("-")]
    if dash:
        raise RskError(f"rsk launch: {', '.join(dash)}: a value never starts with '-' (the target would read it as a "
                       "flag)", USAGE)
    for flag, v in (("-n", ns.name), ("-N", ns.wsname), ("--relaunch", ns.relaunch)):   # (a relaunch's <run>--aNN too)
        if isinstance(v, str) and unsafe_name(v):
            raise RskError(f"rsk launch: {flag}: {NAME_UNSAFE}: {v!r} (a word-splitting slip? quote the name / pass "
                           "flags as an array)", USAGE)
    if not 0 <= ns.check_after <= CHECK_MAX_S:
        raise RskError(f"rsk launch: --check-after {ns.check_after}: 1 to {CHECK_MAX_S} seconds (0 = off)", USAGE)
    ns.policy_flags, ns.cmd = rest, cmd
    return ns


# ================================================================================================ the request
@dataclass
class Request:
    """What was asked: replayed word for word at submit time (only the rs-* words and -y / --gpu-busy-ok change)."""
    target: str
    kind: str
    flags: list[str]
    payload: list[str]
    name: str = ""                 # as asked ('' = the conf's JOB_NAME or the dir's name, resolved by the plan)
    cls: str = ""
    chain: int = 0
    action: str = "launch"
    relaunch_of: str = ""
    same_name_ok: bool = False
    gpu_busy_ok: bool = False
    free_name: bool = False


def _slurm_flags(ns: argparse.Namespace, name: str) -> list[str]:
    f: list[str] = []
    for flag, v in (("-p", ns.part), ("-g", ns.gpus), ("-G", ns.gtype), ("-t", ns.time), ("-m", ns.mem),
                    ("-c", ns.cpus), ("-n", name or None)):
        if v not in (None, ""):
            f += [flag, str(v)]
    return f + list(ns.policy_flags) + (["--same-name-ok"] if ns.same_name_ok else [])


def _nohup_flags(ns: argparse.Namespace, name: str) -> list[str]:
    f: list[str] = []
    if ns.ids:
        f += ["-d", ns.ids]
    elif ns.gpus:
        f += ["-n", str(ns.gpus)]
    if name:
        f += ["-N", name]
    if ns.nice not in (None, ""):
        f += ["--nice", str(ns.nice)]
    return f + (["--same-name-ok"] if ns.same_name_ok else [])


def _asked(ns: argparse.Namespace) -> bool:
    return any(v not in (None, "") for v in (ns.part, ns.gpus, ns.gtype, ns.time, ns.mem, ns.cpus, ns.ids, ns.nice)) \
        or bool(ns.policy_flags or ns.cmd)


def _from_bound(kind: str, bound: dict, name: str) -> tuple[list[str], list[str], int]:
    """(flags, payload, chain) that ask for the original attempt's bound fields again (a relaunch, nothing typed; the
    bound policy flags too)."""
    b = {k: str(v) for k, v in bound.items()}
    if kind == "slurm":
        f: list[str] = []
        part = grants.unq(b.get("partition", ""))
        if part:
            f += ["-p", part]
        gres = grants.unq(b.get("gres", ""))
        if gres:
            gt, gn = grants._gres(gres)
            f += ["-g", str(gn)] + (["-G", gt] if gt not in ("any", "") else [])
        for flag, key in (("-c", "cpus"), ("-m", "mem"), ("-t", "time")):
            v = grants.unq(b.get(key, ""))
            if v:
                f += [flag, v]
        pflags = [w for w in grants.qwords(b.get("flags", "")) if w]     # the policy flags it was planned with
        odd = [w for w in pflags if not POLICY_FLAG.fullmatch(w) or "--rs-" in w or w in NOT_POLICY]
        if odd:
            raise RskError(f"the recorded policy flags {' '.join(odd)} are not ones rsk launch would send: give the "
                           "relaunch's flags and command again", USAGE)
        return (f + ["-n", name] + pflags, grants.qwords(b.get("payload", "")),
                1 if b.get("chain") == "1" else 0)
    f = []
    req = b.get("gpus_req", "")
    if req.startswith("ids="):
        f += ["-d", req[4:]]
    elif req.startswith("n="):
        f += ["-n", req[2:]]
    if b.get("nice"):
        f += ["--nice", b["nice"]]
    pay = grants.unq(b.get("payload", ""))
    return f + ["-N", name], [pay] if pay else [], 0


def build_request(ns: argparse.Namespace, led: L.Ledger, place: harness.Place) -> Request:
    kind = place.kind
    if kind == "slurm":
        if ns.ids or ns.wsname or ns.nice not in (None, "") or ns.gpu_busy_ok:
            raise RskError(f"{place.target} is a Slurm target: -p -g -G -t -m -c -n (not -d / -N / --nice / "
                           "--gpu-busy-ok)", USAGE)
    else:
        if any(v not in (None, "") for v in (ns.part, ns.gtype, ns.time, ns.mem, ns.cpus, ns.name)) or ns.policy_flags:
            raise RskError(f"{place.target} is a workstation: -g N | -d IDS, -N NAME, --nice N, --gpu-busy-ok "
                           "(-n is the job name on Slurm targets)", USAGE)
        if ns.chain:
            raise RskError("--chain is for Slurm targets (singleton segments)", USAGE)
        if ns.ids and ns.gpus:
            raise RskError("-d and -g are exclusive (exactly these ids, or a count to pick)", USAGE)
    if ns.chain < 0:
        raise RskError("--chain N: N >= 1 segments", USAGE)
    if ns.y:
        out("NOTE: -y is not sent as typed: the plan shows every -y gate as a warning, and the submit carries -y only "
            "when the approved card showed warnings or the covering grant's kind covers the plan's warnings")
    name = ns.name if kind == "slurm" else ns.wsname
    class_check(ns.cls, name or "")
    if name:
        sticky_class(led, name, ns.cls)
    action = "chain" if ns.chain else "launch"
    req = Request(place.target, kind, [], list(ns.cmd), name or "", ns.cls, ns.chain, action,
                  same_name_ok=ns.same_name_ok, gpu_busy_ok=bool(ns.gpu_busy_ok), free_name=bool(ns.free_name))
    if ns.relaunch:
        if name:
            raise RskError("--relaunch names the attempt itself (<run>--aNN): no -n / -N", USAGE)
        got = led.read_run(ns.relaunch)
        atts = (got.data or {}).get("attempts") or {}
        if not atts:
            raise RskError(f"no ledger run {ns.relaunch!r} (rsk status lists them) — a relaunch repeats one", USAGE)
        last = atts[max(atts, key=lambda k: int(k[1:]) if k[1:].isdigit() else 0)]
        req.name = f"{ns.relaunch}--{L.next_attempt(atts)}"
        req.action, req.relaunch_of = "relaunch", ns.relaunch
        sticky_class(led, req.name, ns.cls)
        if last.get("kind") and last.get("kind") != kind:
            raise RskError(f"run {ns.relaunch} ran on a {last.get('kind')} target, {place.target} is {kind}", USAGE)
        if not _asked(ns):
            bound = (last.get("request") or {}).get("bound") or {}
            if not bound:
                raise RskError(f"run {ns.relaunch}'s last attempt has no recorded plan (adopted?): give its flags and "
                               "command again", USAGE)
            flags, req.payload, chain = _from_bound(kind, bound, req.name)
            req.flags = flags + (["--same-name-ok"] if ns.same_name_ok else [])
            req.chain = req.chain or chain
            return busy_named(req)
    req.flags = _slurm_flags(ns, req.name) if kind == "slurm" else _nohup_flags(ns, req.name)
    if kind == "slurm" and not req.payload:
        raise RskError("no command: rsk launch -T <t> [flags] -- <cmd…> (submit.sh needs one)", USAGE)
    return busy_named(req)


def busy_named(req: Request) -> Request:
    """--gpu-busy-ok names the GPUs (-d): a GPU another job uses is only ever the user's call for that GPU."""
    if req.gpu_busy_ok and "-d" not in req.flags:
        raise RskError("--gpu-busy-ok needs -d IDS: a GPU another job uses is the user's call for THAT GPU (their "
                       "words name it), never a count to pick from", USAGE)
    return req


def class_check(label: str, name: str) -> None:
    """A name that carries a class (<exp>--<class>--…) is that class: a different --class label is a usage error."""
    have = grants.name_class(name)
    if label and have and label != have:
        raise RskError(f"--class {label} contradicts the name {name!r}, whose class is {have} (the name's class is "
                       "the run's: drop --class or rename the run)", USAGE)


def recorded_classes(run_rec: dict | None) -> list[str]:
    """The classes a run's attempts were recorded with, oldest attempt first (de-duplicated; none left out)."""
    return [c for c in dict.fromkeys(grants.run_classes(run_rec)) if c]


def sticky_class(led: L.Ledger, name: str, label: str) -> str:
    """A run's class is the one recorded at its first attempt (from its name, or --class) — and only there: a later
    attempt whose name or --class says another one, or says one at all when the first attempt had none, is a usage
    error (exit 2). Returns the class of NAME's run ('' when it has none)."""
    run = L.run_id(name)
    classes = grants.run_classes(led.read_run(run).data)
    new = grants.name_class(name) or label
    if not classes:
        return new
    first = classes[0]
    if first and new and new != first:
        raise RskError(f"run {run} is class {first} (recorded at its first attempt): this attempt says {new} — a run's "
                       "class never changes (drop --class, or name a new run)", USAGE)
    if not first and new:
        raise RskError(f"run {run} has no class (its first attempt was recorded without one): this attempt says {new} "
                       "— a run's class is set only at its first attempt (drop --class, or name a new run)", USAGE)
    return first


def name_problems(name: str) -> list[str]:
    """What keeps NAME from experiment-conventions.md §2's shape ([] = nothing): <task>--<stage>--<variant>--<origin>--
    s<seed>, then an attempt's --aNN or nothing; lowercase ASCII letters, digits, hyphens only inside a field; the
    stage a §1 class; origin scratch | none | fork-<…> | finetune-<…>. (Opaque words: name_notes — a word is judged
    by what it means, which a pattern cannot tell: lora-r16 and best-of-16 are fine.)"""
    p: list[str] = []
    odd = sorted(set(re.sub(r"[a-z0-9-]", "", name)))
    if odd:
        p.append("characters " + " ".join(repr(c) for c in odd) + " (lowercase a-z, 0-9 and hyphens only)")
    f = L.run_id(name).split("--")
    if len(f) != 5:
        p.append(f"{len(f)} field(s) where §2 has 5")
    low = [x.lower() for x in f]
    bad = [x for x in f if not NAME_FIELD.fullmatch(x.lower())]
    if bad:
        p.append("field(s) " + ", ".join(repr(x) for x in bad) + " (a field is words joined by single hyphens; `--` "
                 "separates fields)")
    if len(f) == 5:
        if low[1] not in grants.CLASSES:
            p.append(f"stage {f[1]!r} is not a class ({', '.join(grants.CLASSES)})")
        if not NAME_ORIGIN.fullmatch(low[3]):
            p.append(f"origin {f[3]!r} (scratch | none | fork-<ckpt> | finetune-<source>: the model's lineage — a "
                     "dataset or setting belongs in the task or the variant)")
        if not NAME_SEED.fullmatch(low[4]):
            p.append(f"seed {f[4]!r} (s0, s1, …)")
    return p


def name_notes(name: str) -> list[str]:
    """§2's opaque words (new / final / best / r<N>) in the task, variant or origin field: a NOTE, never a refusal."""
    f = [x.lower() for x in L.run_id(name).split("--")]
    return sorted({w for i, x in enumerate(f) if i != 1 and (len(f) != 5 or i != 4)
                   for w in x.split("-") if NAME_OPAQUE.fullmatch(w)})


def new_run(led: L.Ledger, block: dict, name: str) -> bool:
    """A run never launched before as far as rsk can tell: no attempt of it in the ledger that may have run (any
    target; a provably unsent one — NOT_SUBMITTED — never ran: grants.prior_attempts) and none in the target's journal
    (the block's info_prior is not above 0; unknown counts as none here — the name is checked)."""
    run = L.run_id(name)
    if grants.prior_attempts({run: led.read_run(run).data or {}}, run):
        return False
    prior = info_prior(block)
    return not (prior and prior > 0)


def payload_words(rec: dict) -> list[str] | None:
    """The plan's command as words (Slurm: the argv job.sbatch runs; a box: its command line split as the shell
    would, quotes only), None when it cannot be read."""
    b = rec.get("block") or {}
    try:
        if rec.get("kind") == "slurm":
            return grants.qwords(str(b.get("payload", "")))
        return shlex.split(_dec(b.get("payload", "")))
    except (RskError, ValueError):
        return None


def _compound(line: str) -> bool:
    """A box command line that may run more than one command: launch.sh runs `eval "_rw_go $RUN"`, so the env words
    reach the first command only. Scanned as bash would, quotes and backslashes respected: an unquoted | ; & ( ) —
    in any run of operator characters (`;<`, `|>`, `&&>`) — a newline, a command substitution ($( or a backquote, also
    inside double quotes) is one; the redirections >& <& &> >| (2>&1) are not; a # starting a word ends the line.
    Over-cautious ($(date), <(…): refused), never a pass."""
    if "\n" in line or "\r" in line:
        return True
    q, i, n = "", 0, len(line)
    while i < n:
        c = line[i]
        if q == "'":
            q = "" if c == "'" else q
        elif q == '"':
            if c == "\\":
                i += 1
            elif c == '"':
                q = ""
            elif c == "`" or line.startswith("$(", i):
                return True
        elif c == "\\":
            i += 1
        elif c in "'\"":
            q = c
        elif c == "`" or (c == "#" and (i == 0 or line[i - 1] in " \t")):
            return c == "`"
        elif c in ";|&()":
            prev, nxt = line[i - 1] if i else "", line[i + 1] if i + 1 < n else ""
            if not ((c == "&" and (prev in "<>" or nxt == ">")) or (c == "|" and prev == ">")):
                return True
        i += 1
    return False


def env_scan(words: list[str], in_env: bool) -> tuple[str, str]:
    """GNU env's reading of WORDS for WANDB_MODE, as launch.sh's rs_gpuenv reads them for the GPU variables: options
    first (they end at the first non-option; `--` ends them), then every word holding '=' is NAME=VALUE, then the
    command — `env` (or …/env) again is read the same way. IN_ENV: WORDS are env's already (a box: the wrapper runs
    `env "$@"`); else (a Slurm argv) only after a first word `env`. -v --debug -C DIR pass; -u / --unset WANDB_MODE
    unsets it; any other option is unclear. A box line is eval'd first: a word env reads — up to the command word —
    holding $ ` { or a glob may expand into other words (rs_runwords stops there too): 'expands'. Returns ('inherit' |
    'set' | 'unset' | 'unclear' | 'expands', value)."""
    state, val, i, o = "inherit", "", 0, 1
    if not in_env:
        if not words or Path(words[0]).name != "env":
            return state, val
        i = 1
    while i < len(words):
        w = words[i]
        i += 1
        if in_env and re.search(r"[$`{*?\[]", w):
            return "expands", ""
        if o == 1:
            if w == "--":
                o = 2
                continue
            if w in ("-v", "--debug") or w.startswith("--chdir=") or (w.startswith("-C") and len(w) > 2):
                continue
            if w in ("-C", "--chdir") or w in ("-u", "--unset"):   # their value word is read (and eval'd) too
                if i >= len(words) or (in_env and re.search(r"[$`{*?\[]", words[i])):
                    return ("expands", "") if i < len(words) else ("unclear", "")
            if w in ("-C", "--chdir"):
                i += 1
                continue
            if w in ("-u", "--unset") or w.startswith("--unset=") or (w.startswith("-u") and len(w) > 2):
                if w in ("-u", "--unset"):
                    if i >= len(words):
                        return "unclear", ""
                    n, i = words[i], i + 1
                else:
                    n = w.split("=", 1)[1] if w.startswith("--unset=") else w[2:]
                if n == "WANDB_MODE":
                    state, val = "unset", ""
                continue
            if w.startswith("-"):              # '-' (= -i), -i, -S, a bundle, an abbreviation: may set or clear it
                return "unclear", ""
            o = 0
        elif o == 2:
            o = 0
            if w == "-":
                return "unclear", ""
        if "=" in w:
            k, v = w.split("=", 1)
            if k == "WANDB_MODE":
                state, val = "set", v
            continue
        if Path(w).name == "env":
            o = 1
            continue
        break
    return state, val


def tracker_mode(rec: dict) -> tuple[str, str]:
    """(WANDB_MODE the run starts with, where it is set). The command's env words (env_scan) win over everything
    env.sh set: a box line is env's from its first word (one command only: else 'compound'), a Slurm argv only after
    `env`; an unclear env option is 'env-options', an expansion in a box line's env words 'env-expands', `-u
    WANDB_MODE` 'command-unset'. Else the Slurm conf's bound
    wandb_mode — sure only when nothing env.sh applies after it can change it, in either direction: no ENV_HOOK, not a
    conda env (activate applies the env's own variables), and the plan's info_wandb_env (submit.sh: $PROJ/.wandb_env,
    sourced after the conf) says none / no; anything else, or an older deploy without it, is (the conf's mode,
    'conf-overridable'). A box conf is not on its card ('unknown')."""
    words = payload_words(rec)
    if words is None:
        return "", "unreadable"
    b = rec.get("block") or {}
    box = rec.get("kind") != "slurm"
    if box and _compound(_dec(b.get("payload", ""))):
        return "", "compound"
    state, val = env_scan(words, in_env=box)
    if state == "unclear":
        return "", "env-options"
    if state == "expands":
        return "", "env-expands"
    if state == "set":
        return val, "command"
    if state == "unset":
        return "", "command-unset"
    if not box and "wandb_mode" in b:
        mode = _dec(b["wandb_mode"])
        if (_dec(b.get("env_hook", "")) or _dec(b.get("env_kind", "")) == "conda"
                or _dec(b.get("info_wandb_env", "")) not in ("none", "no")):
            return mode, "conf-overridable"          # either way: what env.sh applies after the conf may change it
        return mode, "conf"
    return "", "unknown"


def smoke_problem(rec: dict) -> tuple[str, bool]:
    """('', False) unless a smoke plan's run may reach the tracker (experiment-conventions.md §5: every smoke goes out
    with WANDB_MODE=disabled; offline is not enough). certain=True — exit 2 — only when rsk can see it does: the
    command sets another WANDB_MODE or unsets it, or the Slurm conf's bound one is not disabled, the command leaves it
    and nothing applied later can change it; whatever rsk cannot tell (a box's conf, a line of several commands, an
    expansion, an env option, a conf value something applied later may change) is a WARNING on the card, and the
    launch goes on."""
    if rec.get("class") != "smoke":
        return "", False
    mode, where = tracker_mode(rec)
    if mode == "disabled" and where in ("command", "conf"):
        return "", False
    certain = where in ("command", "command-unset", "conf")
    said = {"command": f"its command sets WANDB_MODE={mode}", "conf": f"the conf's WANDB_MODE is {mode or 'unset'}",
            "unknown": "the conf's WANDB_MODE is not on a workstation's card",
            "unreadable": "its command cannot be read",
            "env-options": "its command's env options may unset what the conf set",
            "command-unset": "its command unsets WANDB_MODE (env -u)",
            "env-expands": "a word of its command up to the command itself holds an expansion ($ ` { or a glob) the "
                           "box expands before env reads it",
            "compound": "its command line holds shell operators or a newline (| ; & ( ): the env words reach the "
                        "first command only (env WANDB_MODE=disabled bash -c '…' covers them all)",
            "conf-overridable": f"the conf's WANDB_MODE is {mode or 'unset'}, but what env.sh applies after it may "
                                "change that (the ENV_HOOK, a conda env, the project's .wandb_env naming WANDB_MODE or "
                                "unreadable, or a deploy too old to say: rsk sync)"}[where]
    if not certain:
        return (f"smoke {rec['name']}: rsk cannot tell WANDB_MODE is disabled — {said}; make sure it is (experiment-"
                "conventions.md §5: `env WANDB_MODE=disabled` first in the command), and that the start log prints "
                "no wandb URL", False)
    return (f"smoke {rec['name']}: {said} — every smoke goes out with WANDB_MODE=disabled (experiment-conventions.md "
            "§5; offline still syncs later): start the command with `env WANDB_MODE=disabled` (plus the trainer's own "
            "logger-off flag)", True)


def tracker_note(rec: dict) -> None:
    """After a formal run went out (or may have) with the tracker not known off: what experiment-conventions.md §4
    asks of its wandb run — the agent sets it before the launch and checks it landed; never rsk's to see."""
    cls = rec.get("class") or ""
    if cls not in FORMAL:
        return
    mode, where = tracker_mode(rec)
    if mode == "disabled" and where in ("command", "conf"):
        return
    again = (" A relaunch continues the SAME wandb run (resume its id) when the trainer supports it, never a new one "
             "(§3)." if rec.get("earlier") else "")
    out(f"NOTE: {cls} run {rec['run']} — its wandb run per experiment-conventions.md §4: project = the task family, "
        f"group = the comparison cohort, name = the run name minus --aNN and the project's name, job_type = {cls}, "
        "notes = the question and the expected change, tags key:value, config run_name="
        f"{rec['name']} + source_commit, source_dirty, command, run_class, seed, origin, parent_run, parent_checkpoint, "
        "GPU count / world size — the trainer's own fields, else env WANDB_PROJECT / WANDB_RUN_GROUP / WANDB_JOB_TYPE / "
        "WANDB_NAME before the command. Once it prints its run URL, check they landed (nothing to check when the "
        f"project keeps wandb off).{again}")


# ================================================================================================ the remote calls
# Every call first asks the project dir's filesystem (observe's rs_dir: a child the session never waits for, FS_WAIT s):
# on a hung mount even the marker grep sits in a wait no timeout kills, until the local deadline. A hung one ends the
# call with `@@fail <dir>: its filesystem gave no answer within N s (a hung mount?)` BEFORE the marker line (@@api) —
# before anything ran: proof that nothing was planned or submitted (Reply.fail). The child stays behind until it answers.
_STOP_HUNG = "[ \"$(rs_dir \"$RDIR\")\" != h ] || { " + observe._HUNG + " 69; }"
SLURM_BODY = observe._DIRPROBE + "\n" + r'''rs_launch() {   # then submit.sh's marker line: an older one never gets rsk's flags
  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\~/}" ;; esac
  ''' + _STOP_HUNG + r'''
  f=$RDIR/$DEPLOY/submit.sh
  a=$(LC_ALL=C grep -a -m 1 -E '^# rs-api=[0-9]+([[:space:]]|$)' "$f" 2>/dev/null | head -n 1); a=${a#\# rs-}; a=${a%%[[:space:]]*}
  echo "@@api $a"
  [ "$a" = "$WANT" ] || return 65
  bash "$f" "$@" </dev/null; rc=$?
  d=$RDIR/.rs/attempts/$NONCE; echo "@@rc $rc"
  if [ -d "$d" ]; then echo "@@claimed 1"; else echo "@@claimed 0"; fi   # submit.sh claims it before anything else
  [ ! -f "$d/result" ] || echo "@@result $(head -c 256 "$d/result" | head -n 1)"
  [ ! -f "$d/receipt" ] || LC_ALL=C grep -a -E '^(job|name|nonce|at|partition)=' "$d/receipt" | head -c 2048 | sed 's/^/@@k /'
  return "$rc"
}'''
# a box: run-launch's own two ssh never look before `cd` — this read-only probe goes first, in an ssh of its own
DIR_BODY = observe._DIRPROBE + "\n" + r'''rs_probe() {
  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\~/}" ;; esac
  ''' + _STOP_HUNG + r'''
  echo "@@dir answered"
}'''


@dataclass
class Reply:
    rc: int | None                 # None: no answer (the deadline, or ssh could not start)
    out: str = ""
    err: str = ""
    api: str | None = None         # slurm: the deployed submit.sh's `# rs-api=` marker (None: not read)
    claimed: bool | None = None    # slurm: the attempt dir exists after submit.sh returned (None: not said)
    result: dict = field(default_factory=dict)
    receipt: dict = field(default_factory=dict)
    why: str = ""
    fail: str = ""                 # the call stopped before anything ran (a hung mount; a box's probe got no answer)

    @property
    def text(self) -> str:
        return "\n".join(x for x in (self.out.rstrip("\n"), self.err.rstrip("\n")) if x)

    def shown(self) -> list[str]:
        """The target's own lines (rsk's @@ markers and the plan block left out)."""
        lines, inside = [], False
        for ln in self.text.splitlines():
            if ln == "@@plan v1":
                inside = True
            if not inside and not ln.startswith("@@"):
                lines.append(ln)
            if ln == "@@end":
                inside = False
        return lines


def slurm_body(place: harness.Place, nonce: str, words: list[str]) -> str:
    head = (f"RDIR={shlex.quote(place.remote_dir)} DEPLOY={shlex.quote(place.deploy)} NONCE={shlex.quote(nonce)} "
            f"WANT={shlex.quote(API)} FS_WAIT={int(observe.FS_WAIT)}\n")
    return head + SLURM_BODY + "\nrs_launch " + " ".join(shlex.quote(w) for w in words) + "\n"


def parse_slurm(done: subprocess.CompletedProcess) -> Reply:
    r = Reply(done.returncode, done.stdout or "", done.stderr or "")
    after = False
    for ln in r.out.splitlines():
        if ln.startswith("@@fail ") and r.api is None and not after:   # the body's own, before @@api: nothing ran
            r.fail = r.fail or ln[7:].strip()
        elif ln.startswith("@@api ") and r.api is None:
            r.api = ln[6:].strip()
        elif ln.startswith("@@rc "):
            after = True
        elif after and ln.startswith("@@claimed ") and r.claimed is None:
            r.claimed = ln[10:].strip() == "1"
        elif after and ln.startswith("@@result "):
            r.result = observe._kv(ln[9:].strip())
        elif after and ln.startswith("@@k ") and "=" in ln:
            k, _, v = ln[4:].partition("=")
            r.receipt.setdefault(k, v)
    return r


def call_slurm(place: harness.Place, nonce: str, words: list[str], deadline: float) -> Reply:
    try:
        return parse_slurm(observe.run(place, slurm_body(place, nonce, words), deadline))
    except subprocess.TimeoutExpired:
        return Reply(None, why=f"no answer from {place.host} within {deadline:.0f} s")
    except OSError as exc:
        return Reply(None, why=f"ssh: {exc}")


def nohup_env(src: Path, target: str) -> dict[str, str]:
    env = harness.env(src)
    env["RS_VIA_RSK"] = "1"
    for k in ("CLUSTER", "STATION"):
        env.pop(k, None)
    env["TARGET"] = target
    return env


def call_nohup(src: Path, proj: Path, target: str, words: list[str], deadline: float) -> Reply:
    argv = ["bash", str(src / "bin" / "run-launch"), *words]
    try:
        done = subprocess.run(argv, cwd=proj, env=nohup_env(src, target), capture_output=True, encoding="utf-8",
                              errors="replace", timeout=deadline, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return Reply(None, why=f"run-launch gave no answer within {deadline:.0f} s")
    except OSError as exc:
        return Reply(None, why=f"run-launch: {exc}")
    return Reply(done.returncode, done.stdout or "", done.stderr or "")


def plan_words(req: Request, nonce: str) -> list[str]:
    if req.kind == "slurm":
        return ["--rs-attempt", nonce, "--rs-mode", "plan", *(["--rs-chain"] if req.chain else []), *req.flags,
                "--", *req.payload]
    return ["--rs-attempt", nonce, "--rs-mode", "plan", *req.flags, *(["--gpu-busy-ok"] if req.gpu_busy_ok else []),
            "--", *req.payload]


def _pinned(flags: list[str], ids: str) -> list[str]:
    """FLAGS with the GPU request replaced by exactly IDS (-d): the landing the card showed, nothing picked anew."""
    out, i = [], 0
    while i < len(flags):
        if flags[i] in ("-d", "-n", "-x") and i + 1 < len(flags):
            i += 2
            continue
        out.append(flags[i])
        i += 1
    return ["-d", ids, *out]


def submit_words(rec: dict, nonce: str) -> list[str]:
    """The approved request again: a fresh nonce, --rs-expect + --rs-warnings <the card's warnings_id> (which
    WARNING: lines the card showed: the target recomputes it and refuses a difference), -y only after warnings the
    card showed (the record that covers the plan covers them), --rs-chain per segment; --gpu-busy-ok only when the
    card's OWN landing was on a busy GPU, pinned to that landing with -d (launch.sh binds who is on it: another
    occupant since the plan is refused)."""
    wid = str((rec.get("block") or {}).get("warnings_id", ""))
    if not grants.HEX64.fullmatch(wid):
        raise RskError(f"plan {rec.get('id', '?')} has no warnings_id (planned by an older rsk or deploy): plan again",
                       CONFLICT)
    common = ["--rs-attempt", nonce, "--rs-expect", rec["bound_hash"], "--rs-warnings", wid]
    if rec["kind"] == "slurm":
        return [*common, *(["-y"] if int(rec.get("warnings") or 0) > 0 else []),
                *(["--rs-chain"] if rec.get("chain") else []), *rec["flags"], "--", *rec["payload"]]
    if busy_landing(rec):
        ids = str((rec.get("block") or {}).get("info_gpus", ""))
        return [*common, *_pinned(rec["flags"], ids), "--gpu-busy-ok", "--", *rec["payload"]]
    return [*common, *rec["flags"], "--", *rec["payload"]]


def probe_dir(place: harness.Place, deadline: float) -> Reply | None:
    """A box's call (plan or submit): ONE read-only ssh asks the project dir's filesystem first (DIR_BODY). A Reply
    with .fail stops the call — a hung mount, or no answer at all (nothing ran: a plan is not made, a submit not sent);
    None goes on to run-launch (the dir answered, or ssh failed otherwise: run-launch's own ssh says what it finds)."""
    body = f"RDIR={shlex.quote(place.remote_dir)} FS_WAIT={int(observe.FS_WAIT)}\n" + DIR_BODY + "\nrs_probe\n"
    wait = min(deadline, observe.FS_WAIT + 60.0)
    try:
        done = observe.run(place, body, wait)
    except subprocess.TimeoutExpired:
        why = f"no answer from {place.host} within {wait:.0f} s to the project dir's probe"
        return Reply(None, why=why, fail=why)
    except OSError:
        return None
    hung = [ln[7:].strip() for ln in (done.stdout or "").splitlines() if ln.startswith("@@fail ")]
    return Reply(done.returncode, done.stdout or "", done.stderr or "", fail=hung[0]) if hung else None


def call(src: Path, proj: Path, place: harness.Place, nonce: str, words: list[str], deadline: float) -> Reply:
    if place.kind == "slurm":
        return call_slurm(place, nonce, words, deadline)
    return probe_dir(place, deadline) or call_nohup(src, proj, place.target, words, deadline)


# ================================================================================================ the plan
def _dec(v: object) -> str:
    try:
        return grants.unq(str(v))
    except RskError:
        return str(v)


def _words(v: object) -> str:
    try:
        return shlex.join(grants.qwords(str(v)))
    except RskError:
        return str(v)


def interesting(reply: Reply, target: str) -> list[str]:
    seen, keep = set(), []
    for ln in reply.shown():
        s = ln.strip()
        if (INTERESTING.match(s) or s.startswith(f"[{target}] GPU(s) in use")) and s not in seen:
            seen.add(s)
            keep.append(s)
    return keep


def references(reply: Reply) -> list[str]:
    refs = []
    for ln in reply.shown():
        m = re.search(r"reference: (.+?) — ", ln)
        if m and m.group(1) not in refs:
            refs.append(m.group(1))
    return refs


def local_source(proj: Path) -> dict[str, str]:
    def git(*a: str) -> str | None:
        try:
            d = subprocess.run(["git", "-C", str(proj), *a], capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return d.stdout if d.returncode == 0 else None
    head = git("rev-parse", "-q", "--verify", "HEAD")
    if head is None:
        return {"commit": "none", "dirty": "-"}
    st = git("status", "--porcelain")
    return {"commit": head.strip() or "none", "dirty": str(len([x for x in (st or "").splitlines() if x])) if st is not None else "?"}


def plan_failure(reply: Reply, place: harness.Place) -> RskError:
    """No plan block: what the reply says instead, as rsk's exit code."""
    t = reply.text
    if reply.fail:                 # the call stopped before anything ran (a hung mount)
        return RskError(f"[{place.target}] {reply.fail} — nothing was planned (rsk status reads the target again)",
                        UNKNOWN)
    if reply.rc is None:
        return RskError(f"[{place.target}] {reply.why} — the plan's outcome is unknown, but a plan never submits", UNKNOWN)
    if place.kind == "slurm" and reply.api is not None and reply.api != API:
        return _needs_sync(place, f"its .{place.target}/submit.sh says {reply.api or 'no rs-api (no marker line)'}")
    if reply.rc == 2 and any(s in t for s in OLD_DEPLOY):
        return _needs_sync(place, f"its {'submit.sh' if place.kind == 'slurm' else '.ws/launch.sh'} does not know "
                                  "rsk's flags (an older parser: exit 2, nothing submitted)")
    if reply.rc == 255:
        return RskError(f"[{place.target}] ssh failed (exit 255) during the plan — nothing was submitted (a plan never "
                        "submits)", UNKNOWN)
    if reply.rc == 0:
        return _needs_sync(place, "the reply carries no @@plan block")
    what = {3: ("refused by the target's policy", REFUSED), 6: ("a conflict on the target", CONFLICT),
            2: ("a usage or config error", USAGE), 75: ("an attempt name clash", UNKNOWN)}
    msg, code = what.get(reply.rc, ("a failure on the target", FAILED))
    if reply.rc == 1 and place.kind == "nohup" and FEW_FREE.search(t):
        msg, code = "too few free GPUs (placement)", PLACEMENT
    if reply.rc == 6 and "already run a compute process" in t:
        msg = ("a GPU in use (another process on it): pick other GPUs, or plan with --gpu-busy-ok — that card then "
               "needs the user's OK for that GPU")
    return RskError(f"[{place.target}] the plan stopped with exit {reply.rc}: {msg} — its lines are above; nothing "
                    "was submitted", code)


def _needs_sync(place: harness.Place, why: str) -> RskError:
    out(f"needs: sync (the deploy predates rsk launch: rsk sync -T {place.target})")
    return RskError(f"[{place.target}] the deploy does not speak {API} ({why}) — rsk sync -T {place.target} deploys "
                    "this rsk's harness (it also pushes local code: with the user's OK while a job runs there)",
                    CONFLICT)


def policy_flags(rec: dict) -> list[str]:
    """The --<word> flags the request hands to the target's policy (slurm; not bound: shown on the card)."""
    if rec.get("kind") != "slurm":
        return []
    return [f for f in rec.get("flags") or [] if f.startswith("--") and f != "--same-name-ok"]


def busy_ids(ok: str) -> str:
    """The GPU ids of a bound busy_ok value: `<id>:<uuid>:<user>[,…]` (or the older `<id>[,…]`), 'unknown', ''."""
    if ok in ("", "unknown"):
        return ok
    return ",".join(dict.fromkeys(x.split(":", 1)[0] for x in ok.split(",") if x))


def busy_landing(rec: dict) -> str:
    """'' unless a workstation plan (asked with --gpu-busy-ok) lands on a GPU with a compute process, or cannot tell —
    the bound busy_ok field (launch.sh: who is on each busy GPU of the landing it accepted, `<id>:<uuid>:<user>`,
    'unknown', or empty)."""
    b = rec.get("block") or {}
    if rec.get("kind") != "nohup":
        return ""
    busy = str(b.get("info_busy", ""))
    if "busy_ok" in b:
        ok = _dec(b.get("busy_ok", ""))
        if ok not in ("", "unknown"):
            return f"GPU(s) {busy_ids(ok)} run another compute process ({ok}; now {busy or '-'})"
    elif not rec.get("gpu_busy_ok"):
        return ""
    elif busy == "unknown":
        ok = "unknown"
    else:   # (a block from before busy_ok: what the envelope shows)
        used = {x.split(":", 1)[0] for x in busy.split(",") if x}
        ok = ",".join(sorted(used & set(str(b.get("info_gpus", "")).split(",")) - {""},
                             key=lambda x: int(x) if x.isdigit() else 0))
    if ok == "unknown":
        return "which GPUs are busy is unknown"
    return f"GPU(s) {ok} run another compute process ({busy})" if ok else ""


def render_card(rec: dict) -> str:
    b, kind = rec["block"], rec["kind"]
    o = [f"plan {rec['id']} — {rec['action']} on {rec['target']} ({kind}), {rec['created_at']}"]
    head = f"  run        {rec['run']}"
    if rec.get("class"):
        head += f"   class {rec['class']}"
    if rec.get("relaunch_of"):
        head += f"   next attempt of {rec['relaunch_of']}"
    o.append(head)
    prior = info_prior(b)
    if prior is None:
        o.append("  prior      unknown — the deploy does not count the run's earlier attempts (rsk sync): taken as a "
                 "relaunch (fail closed)")
    elif prior:
        o.append(f"  prior      {prior} earlier attempt(s) of {rec['run']} on {rec['target']} (its journal / live "
                 "jobs, also ones the ledger never saw: run-watch's) — a relaunch")
    if kind == "slurm":
        rows = [("name", _dec(b.get("name", ""))), ("partition", _dec(b.get("partition", ""))),
                ("gres", _dec(b.get("gres", ""))), ("cpus", _dec(b.get("cpus", ""))), ("mem", _dec(b.get("mem", ""))),
                ("time", _dec(b.get("time", ""))), ("account", _dec(b.get("account", ""))),
                ("extra", _words(b.get("extra", ""))), ("conf extra", _words(b.get("conf_extra", ""))),
                ("payload", _words(b.get("payload", ""))),
                ("env", " ".join(x for x in (_dec(b.get("env_kind", "")), _dec(b.get("env_name", ""))) if x)),
                ("wandb_mode", _dec(b.get("wandb_mode", ""))),
                ("chain", "singleton (--rs-chain)" if b.get("chain") == "1" else "no")]
    else:
        rows = [("name", b.get("name", "")), ("gpus", b.get("gpus_req", "")), ("exclude", b.get("exclude", "")),
                ("nice", b.get("nice", "")), ("launch cfg", _cfgs(b.get("launch_cfg", ""))),
                ("busy ok", _dec(b.get("busy_ok", ""))),
                ("payload", _dec(b.get("payload", ""))),
                ("env", " ".join(x for x in (_dec(b.get("env_kind", "")), _dec(b.get("env_name", ""))) if x))]
    rows += [("env hook", _hook(b.get("env_hook", ""))), ("venv dir", _dec(b.get("venv_dir", ""))),
             ("uv sync", _dec(b.get("uv_sync_args", "")))]
    o += [f"  {k:<11}{v or '-'}" for k, v in rows]
    if kind == "slurm":
        f = grants.facts(b)
        if f.time_extra:
            o.append(f"  TIME       {f.time_extra} — an SBATCH_EXTRA / policy --time comes after the harness's and wins in "
                     "sbatch")
        if f.extra_res:
            o.append(f"  NOTE       SBATCH_EXTRA word(s) {' '.join(f.extra_res)} — beyond the usual qos / account / "
                     "exclude / constraint words (time, resources, nodes, anything unknown): a covering grant covers "
                     "them too; read them before approving")
    bound_flags = _words(b.get("flags", "")) if kind == "slurm" and "flags" in b else None
    if bound_flags:
        o.append(f"  policy     {bound_flags}  (bound: handed to the target's policy, which may add any sbatch option "
                 "for them)")
        o.append("  NOTE       policy flags: a covering grant covers them too; read them before approving")
    elif bound_flags is None and policy_flags(rec):
        o.append(f"  policy     {' '.join(policy_flags(rec))}  (passed to the target's policy; not bound)")
    if rec.get("same_name_ok"):
        o.append("  same name  --same-name-ok: a live run of this name may share its logs/ckpts")
        o.append("  NOTE       --same-name-ok: a covering grant covers it too")
    if rec.get("free_name"):
        o.append("  NAME       the user's own (--free-name): experiment-conventions.md §2 not checked")
    elif rec.get("name_problems"):
        o.append(f"  NAME       outside experiment-conventions.md §2 ({'; '.join(rec['name_problems'])}) — launched as "
                 "named")
    elif rec.get("name_notes"):
        o.append(f"  NAME       {', '.join(rec['name_notes'])}: an opaque word if a version marker (experiment-"
                 "conventions.md §2) — launched as named")
    if rec.get("tracker_warning"):
        o.append(f"  TRACKER    WARNING: {rec['tracker_warning']}")
    if rec.get("chain"):
        o.append(f"  segments   {rec['chain']} (each waits for the one before: --dependency=singleton)")
    wa, wg = str(b.get("warnings_avail", "")), str(b.get("warnings_gpu", ""))
    gpu = f"; {wg or 'unknown'} a launcher / container one's" if kind == "nohup" else ""
    o.append(f"  warnings   {rec['warnings']}" + ("  (no -y gate)" if not rec["warnings"] else
                                                  f"  ({wa or '?'} of them the availability gate's{gpu})"))
    shown = rec.get("lines") or []
    o += [f"    {ln}" for ln in shown]
    if kind == "nohup" and wg != "0":   # NF8: never a standing grant's call, whatever its --allow-warnings
        what = (f"{wg} launcher / container / env-dropping warning(s)" if wg else
                "launcher / container warnings not counted (no warnings_gpu=: an older launch.sh — rsk sync)")
        o.append(f"  NO GRANT   {what} — such a run may use GPUs beyond its landing, another user's too: only the "
                 "user's approval of this card")
    if kind == "slurm":
        o.append(f"  available  {_dec(b.get('info_avail', '')) or '-'}")
        dc, dd = _dec(b.get("info_source_commit", "none")), _dec(b.get("info_source_dirty", "none"))
        lc, ld = rec["local"]["commit"], rec["local"]["dirty"]
        o.append(f"  source     deployed {dc[:12]} dirty={dd} · local HEAD {lc[:12]} dirty={ld} — {source_cmp(dc, lc)}")
        o.append("  files      " + " · ".join(f"{k.replace('_', '.')} {str(b.get(f'info_{k}_sha256', '?'))[:12]}"
                                           for k in ("conf", "profile", "policy", "policy_local")))
    else:
        o.append(f"  GPUs now   {b.get('info_gpus') or '-'}  ({b.get('info_uuids') or '-'}) — the envelope: a count "
                 "is picked again at submit time")
        o.append(f"  busy now   {b.get('info_busy') or 'none'}")
        hit = busy_landing(rec)
        if hit:
            o.append(f"  ON A BUSY GPU: {hit} — only with the user's OK for that GPU")
    for r in rec.get("references") or ["-"]:
        o.append(f"  reference  {r}")
    o.append(f"  bound_hash {rec['bound_hash']}")
    return "\n".join(o)


NO_COMMIT = ("", "none", "-", "?")   # run-sync stamps commit=none outside a git checkout / before its first commit;
                                    # submit.sh prints none without a stamp; local_source() says none without a HEAD


def source_cmp(deployed: str, local: str) -> str:
    """The card's source verdict (NF8-card-source-unknown): two real commits compare (`same commit` / `DIFFERENT code
    than this checkout's HEAD`); when either is unknown there is nothing to compare — never "DIFFERENT"."""
    if deployed.strip() in NO_COMMIT or local.strip() in NO_COMMIT:
        return "unknown (not a git checkout, no commit yet, or no sync stamp) — cannot compare"
    return "same commit" if deployed == local else "DIFFERENT code than this checkout's HEAD"


def _hook(v: object) -> str:
    """env_hook = '<path>:<sha256>' (or '<path>:missing'), '' = no ENV_HOOK."""
    d = _dec(v)
    path, _, h = d.rpartition(":")
    return f"{path} (sha256 {h[:12]})" if path and len(h) == 64 else d


_CFG_SPLIT = re.compile(r"(?:(?<=:[0-9a-f]{64})|(?<=:unreadable)),")


def _cfgs(v: object) -> str:
    """launch_cfg (nohup, bound — R7-5) = '<path>:<sha256>[,…]': every launcher config / hostfile launch.sh read for its
    launcher checks (accelerate's config, deepspeed's /job/hostfile, and — R8-5 — each file deepspeed's -H / --hostfile
    names), sorted; '<path>:unreadable' for one it could not
    read; '' = none. Shown as '<path> (sha256 <12 hex>)' each; anything else as printed. Bound: a file changed after the
    card is the target's exit 6 (`changed: launch_cfg`)."""
    d = _dec(v)
    shown = []
    for item in (_CFG_SPLIT.split(d) if d else []):
        path, _, h = item.rpartition(":")
        shown.append(f"{path} (sha256 {h[:12]})" if path and grants.HEX64.fullmatch(h) else
                     f"{path} (UNREADABLE on the box: what the launcher reads there is unknown)" if path and
                     h == "unreadable" else item)
    return " · ".join(shown)


def make_plan(led: L.Ledger, src: Path, proj: Path, place: harness.Place, req: Request, deadline: float) -> dict:
    nonce = new_nonce()
    reply = call(src, proj, place, nonce, plan_words(req, nonce), deadline)
    try:
        block = grants.parse_plan(reply.out)
        if reply.rc != 0:
            raise RskError(f"exit {reply.rc} after the block", CONFLICT)
    except RskError:
        shown = "\n".join(reply.shown()).strip()
        if shown:
            out(shown)
        raise plan_failure(reply, place) from None
    if place.kind == "slurm" and reply.api != API:
        raise _needs_sync(place, f"its submit.sh's marker says {reply.api or 'nothing'}")
    if "api=" + block.get("api", "") != API:
        raise _needs_sync(place, f"its plan block says api={block.get('api')}")
    if block.get("kind") != place.kind or _dec(block.get("target", "")) != place.target:
        raise RskError(f"[{place.target}] the plan block is for {block.get('target')} ({block.get('kind')}): another "
                       f"target's deploy in {place.remote_dir}? — rsk sync -T {place.target}", CONFLICT)
    lacks = [k for k in grants.NEEDED[place.kind] if k not in block]
    if lacks:
        raise _needs_sync(place, f"its plan block lacks {', '.join(lacks)} (an api=3 deploy older than this rsk)")
    name = _dec(block.get("name", ""))
    if unsafe_name(name):     # no -n / -N (parse() checked those): the conf's JOB_NAME or the dir's name, resolved there
        raise RskError(f"[{place.target}] the plan names the run {name!r} (the conf's JOB_NAME, else the remote dir's "
                       f"name): {NAME_UNSAFE} — set JOB_NAME, or pass {'-n' if place.kind == 'slurm' else '-N'} NAME; "
                       "nothing was submitted", USAGE)
    class_check(req.cls, name)
    cls = sticky_class(led, name, req.cls)
    fresh = new_run(led, block, name)
    raw = str(block.get("name", ""))          # a box prints it as is (%s), Slurm %q: what the target names the run
    problems = (name_problems(name) or (name_problems(raw) if raw != name else [])) if fresh else []
    vague = name_notes(name) if fresh else []
    if req.free_name:                         # the user's own name: not checked, said on the card (and so in the ledger)
        problems, vague = [], []
    if problems:
        out(f"NOTE: run name {name!r} is outside experiment-conventions.md §2 ({'; '.join(problems)}) — a new run is "
            f"named {NAME_SHAPE}: rename it unless the user chose it (then --free-name); it is launched as named")
    if vague:
        out(f"NOTE: run name {name!r}: {', '.join(vague)} — if a version / revision marker (new, final, best, r2), "
            "experiment-conventions.md §2 asks for what changed instead (a word with a meaning, lora-r16, stays)")
    rec = {"id": new_plan_id(), "created_at": L.now(), "created_ns": time.time_ns(), "target": place.target,
           "kind": place.kind, "host": place.host, "remote_dir": place.remote_dir, "name": name, "run": L.run_id(name),
           "action": req.action, "class": cls, "chain": req.chain,
           "relaunch_of": req.relaunch_of,
           "same_name_ok": req.same_name_ok, "gpu_busy_ok": req.gpu_busy_ok, "flags": req.flags,
           "free_name": bool(req.free_name), "name_problems": problems, "name_notes": vague, "earlier": not fresh,
           "payload": req.payload, "plan_nonce": nonce, "block": block, "bound_hash": block["bound_hash"],
           "warnings": int(block["warnings"]), "lines": interesting(reply, place.target),
           "references": references(reply) or [r for r in [harness.reference(src, place.target)] if r],
           "local": local_source(proj)}
    acts = plan_actions(led.state().runs, rec)
    rec["action"], rec["actions"] = acts[0], list(acts)
    smoke, certain = smoke_problem(rec)
    if certain:
        raise RskError(smoke, USAGE)
    rec["tracker_warning"] = smoke
    rec["card"] = render_card(rec)
    return rec


# ================================================================================================ decisions
def info_prior(block: dict) -> int | None:
    """R5-4: the plan block's envelope `info_prior=<n>` — the receipts in the target's .rs/attempts journal whose name is
    the plan's run id or <run id>--aNN (Slurm: + live squeue rows of this WorkDir with such a name), i.e. attempts the
    ledger may not know (run-watch's, another checkout's). None: missing (a deploy older than R5-4) or unreadable."""
    if "info_prior" not in block:
        return None
    v = _dec(block.get("info_prior"))
    return int(v) if re.fullmatch(r"[0-9]{1,9}", v) else None


def plan_actions(runs: dict, rec: dict) -> tuple[str, ...]:
    """The actions a plan IS (D5), never a flag's say: relaunch when its run already has attempts that may have run
    (any target; not this plan's own: a chain's segments, a retry of it) in the ledger OR in the target's journal (the
    block's info_prior > 0: a run run-watch launched never enters the ledger) OR when the block cannot say (info_prior
    missing or unreadable: fail closed), chain when its block says chain=1 (an SBATCH_EXTRA singleton too), else
    launch. The first is the one shown and recorded; every one is checked."""
    acts = []
    prior = info_prior(rec.get("block") or {})
    if (rec.get("relaunch_of") or grants.prior_attempts(runs, rec["run"], rec["id"]) or prior is None
            or prior > 0):
        acts.append("relaunch")
    if str((rec.get("block") or {}).get("chain", "")) == "1" or rec.get("chain"):
        acts.append("chain")
    return tuple(acts) or ("launch",)


def check_plan(rec: dict, runs: dict | None = None, unread: set[str] | None = None) -> dict:
    """The plan as grants.check() reads it: the block, the class (sticky: the run's first), the class each attempt of
    the run was recorded with (a deny of any of them matches; one recorded without: any class), the plan id
    (approvals name plan ids); UNREAD (the targets launch.refresh could not read just now) only words a refusal."""
    plan = dict(rec["block"])
    if rec.get("class"):
        plan["class"] = rec["class"]
    plan["classes_recorded"] = grants.run_classes((runs or {}).get(rec["run"]))   # each attempt's, '' = none
    plan["plan_id"] = rec["id"]
    if rec.get("created_at"):          # relaunch_after any reads the journal count only from a fresh plan
        plan["plan_age_s"] = max(0.0, time.time() - L.epoch(rec["created_at"]))
    if unread:
        plan["unreadable_now"] = sorted(unread)
    return plan


def room(rec: dict, bound_hash: str) -> float:
    """Launches left under a grant / approval for this plan (inf: no limit)."""
    lim = rec.get("limits") or {}
    if rec.get("kind") == "approval":
        used = sum(1 for u in rec.get("used") or [] if u.get("hash") == bound_hash)
        return int(lim.get("max_launches") or 1) - used
    mx = lim.get("max_launches")
    return float("inf") if mx is None else mx - grants.launches_used(rec)


def decide(source: L.Ledger | L.LedgerState, rec: dict, need: int | None = None,
           extending: tuple[str, str] | None = None, unread: set[str] | None = None) -> grants.Decision:
    """grants.check() plus what only a whole request shows: N chain segments need N launches (NEED: the segments
    still to send; EXTENDING: the attempt they join, which holds its own max_live slot), and a standing grant never
    covers a workstation plan that lands on a GPU in use. The actions are
    derived from the ledger now (plan_actions): every one that applies is checked."""
    st = source.state() if isinstance(source, L.Ledger) else source
    acts = plan_actions(st.runs, rec)
    d = grants.check(st, acts[0], plan=check_plan(rec, st.runs, unread), run=rec["run"], extending=extending,
                     also=acts[1:])
    if not d.covered:
        return d
    why = []
    n = max(1, int(rec.get("chain") or 0)) if need is None else need
    left = room(d.record, rec["bound_hash"])
    if left < n:
        why.append(f"room for {int(left)} of the {n} chain segments")
    hit = busy_landing(rec)
    if hit and d.record.get("kind") == "grant":
        why.append(f"{hit}: a GPU another job uses is never a standing grant's call — only the user's OK for that GPU")
    if why:
        return grants.Decision(False, None, [f"{d.record['id']}: {'; '.join(why)}"],
                               f"approval — no record covers {'/'.join(acts)} of {rec['name']} (show the card and ask "
                               "the user)")
    return d


def only(led: L.Ledger, rid: str) -> L.LedgerState:
    """The ledger's state with one allowing record left (denies stay): who covers this submit is never another record."""
    st = led.state()
    st.grants = [r for r in st.grants if not isinstance(r, dict) or r.get("kind") == "deny" or grants.fail_closed(r)
                 or r.get("id") == rid]
    return st


def live_attempts(led: L.Ledger, target: str, run: str) -> list[tuple[str, str, dict]]:
    """(attempt id, ledger state, attempt) of each live attempt of RUN on TARGET."""
    rec = led.read_run(run).data or {}
    return [(k, L.attempt_state(a), a) for k, a in sorted((rec.get("attempts") or {}).items())
            if a.get("target") == target and L.is_live(a)]


def elsewhere(led: L.Ledger, target: str, name: str, unread: set[str] | None = None) -> None:
    """A NOTE (never a refusal: moving a run off a target that cannot be read is the user's call, and a grant's own
    rules judge a relaunch) for each live attempt of the run on ANOTHER target — one still running, or one whose cancel
    has no observed end: this launch would start a second copy beside it (the card's prior counts only TARGET's
    journal)."""
    if not name:
        return
    run = L.run_id(name)
    rec = led.read_run(run).data or {}
    for k, a in sorted((rec.get("attempts") or {}).items()):
        tg = str(a.get("target") or "")
        if not tg or tg == target or not L.is_live(a):
            continue
        why = grants.cancel_unconfirmed(run, k, a, time.time(), tg in (unread or ()))
        out(f"NOTE: {why} — a launch on {target} starts a second copy beside it" if why else
            f"NOTE: {run} {k} is live on {tg} in the ledger ({L.attempt_state(a)}"
            f"{': ' + tg + ' could not be read just now' if tg in (unread or ()) else ''}) — a launch on {target} "
            "starts a second copy beside it")


def unknown_attempts(led: L.Ledger, target: str, run: str) -> list[str]:
    rec = led.read_run(run).data or {}
    return [f"{k} (nonce {s.get('nonce')})" for k, a in sorted((rec.get("attempts") or {}).items())
            if a.get("target") == target for s in a.get("submissions") or [] if s.get("submit") == "unknown"]


def refresh(led: L.Ledger, src: Path, proj: Path, runs: set[str], deadline: float) -> set[str]:
    """Before the duplicate check and the grant decision: the ledger learns what a run's attempts did only from a
    read of their target (rsk status), so a job that ended since still looks live — the duplicate guard would refuse
    and a relaunch grant would see no end. For every target holding an attempt of RUNS the ledger counts as live,
    ONE read-only read (the read rsk status makes, back far enough for the oldest such attempt) is applied to the
    ledger first. A target that cannot be read changes nothing: the ledger's state stands (fail closed). Returns the
    targets holding such an attempt that could not be read now (the duplicate guard names them)."""
    from remote_run import status as S
    st0 = led.state()
    live = {(r, aid): att for r in runs for aid, att in ((st0.runs.get(r) or {}).get("attempts") or {}).items()
            if att.get("target") and L.is_live(att)}
    if not live:
        return set()
    places, unread = [], set()
    all_places = harness.places(src, proj)
    for t in sorted({att["target"] for att in live.values()}):
        try:
            places += S.select(all_places, [t])
        except RskError as exc:
            unread.add(t)
            out(f"NOTE: the ledger counts {', '.join(f'{r} {a}' for (r, a), att in sorted(live.items()) if att['target'] == t)}"
                f" as live on {t}, which this conf cannot read ({exc}) — the ledger's state there stands")
    if not places:
        return unread
    oldest = min((L.epoch(att.get("created_at")) or time.time()) for att in live.values()
                 if att["target"] in {p.target for p in places})
    days = max(2, min(30, int((time.time() - oldest) // 86400) + 2))
    asked = {p.target: sorted({str(s.get("nonce")) for _r, _a, _t, s in S._subs(st0, p.target)
                               if s.get("submit") == "unknown"}) for p in places}
    comments = {p.target: p.kind == "slurm" and bool(asked[p.target]) for p in places}
    obs = observe.observe(places, days, min(deadline, 60.0), nonces=asked, comments=comments)
    for n in S.record(led, st0, obs):
        out(f"ledger: {n}")
    after = led.state().runs
    for (r, aid), att in sorted(live.items()):
        now_att = ((after.get(r) or {}).get("attempts") or {}).get(aid) or att
        was, is_ = L.attempt_state(att), L.attempt_state(now_att)
        if was != is_:
            out(f"ledger: {r} {aid} on {att['target']}: {was} -> {is_} (read just now)")
    for o in obs:
        if not o.ok:
            unread.add(o.place.target)
            out(f"NOTE: {o.place.target} could not be read now ({o.why}) — the ledger's state of the run there stands")
    return unread


def duplicate(led: L.Ledger, target: str, name: str, same_ok: bool, chain: int,
              unread: set[str] | None = None) -> None:
    """A live ledger attempt of the run on TARGET -> exit 6 unless SAME_OK / a chain. A SUBMIT_UNKNOWN one blocks
    ALWAYS (--same-name-ok and chains too): its job may exist; only rsk status (the remote journal) or rsk adopt
    --not-submitted --approve (the user's OK) settles it. A live attempt with a cancel rsk sent and no observed end
    (ledger.cancel_pending) still blocks and the message says so (grants.cancel_unconfirmed: how to see its end), never
    --same-name-ok (a second copy beside a job that may still run). UNREAD: the targets refresh() could not read just
    now. An attempt of the run on another target: a NOTE only (elsewhere())."""
    if not name:
        return
    unk = unknown_attempts(led, target, L.run_id(name))
    if unk:
        raise RskError(f"run {L.run_id(name)} has a SUBMIT_UNKNOWN attempt on {target}: {', '.join(unk)} — its job may "
                       "exist; rsk status settles it from the remote journal (or rsk adopt --not-submitted --approve, "
                       "the user's OK); --same-name-ok never passes it", CONFLICT)
    if same_ok or chain:
        return
    live = live_attempts(led, target, L.run_id(name))
    if not live:
        return
    run = L.run_id(name)
    shown = ", ".join(f"{a} ({s})" for a, s, _att in live)
    t = time.time()
    ending = [grants.cancel_unconfirmed(run, a, att, t, target in (unread or ())) for a, _s, att in live]
    if all(ending):
        raise RskError(f"run {run} is live on {target} in the ledger: {shown} — " + "; ".join(ending)
                       + "; launch once it shows the end", CONFLICT)
    raise RskError(f"run {run} is live on {target} in the ledger: {shown} — follow it (rsk status), or "
                   "--same-name-ok when both are wanted (a second copy shares its logs/ckpts)"
                   + "".join(f"; {w}" for w in ending if w), CONFLICT)


def plan_state(led: L.Ledger, rec: dict, now: float | None = None) -> str:
    """'' when REC may still be submitted; else why not (used, expired, superseded, from an older rsk)."""
    claim = led.plan_claim(rec["id"])
    if claim:
        return f"plan {rec['id']} was used already ({claim.get('at', '?')})"
    lacks = [k for k in grants.NEEDED.get(str(rec.get("kind")), ()) if k not in (rec.get("block") or {})]
    if lacks:
        return f"plan {rec['id']} lacks {', '.join(lacks)} (planned by an older rsk or deploy)"
    if unsafe_name(str(rec.get("name", ""))):   # planned by an rsk that let it through
        return f"plan {rec['id']} names the run {rec.get('name')!r}: {NAME_UNSAFE}"
    t = time.time() if now is None else now
    age = t - L.epoch(rec.get("created_at"))
    if age > PLAN_TTL_S:
        return f"plan {rec['id']} expired ({observe.age(age)} old, plans live {PLAN_TTL_S // 3600} h)"
    def key(p: dict) -> tuple:
        return (int(p.get("created_ns") or L.epoch(p.get("created_at")) * 1e9), str(p.get("id")))
    newer = [p for p in led.plans() if p.get("target") == rec["target"] and p.get("name") == rec["name"]
             and key(p) > key(rec)]
    if newer:
        return f"plan {rec['id']} is superseded by {newer[-1]['id']} (a newer plan of {rec['name']} on {rec['target']})"
    return ""


# ================================================================================================ submit
LAUNCH_LINE = r" started PID ([0-9]+) on GPU\(s\) ([0-9,]+) ; log (.+) ; pid file (.+)$"


def started(text: str, target: str) -> re.Match | None:
    """The LAST line that is launch.sh's own launch line, `[<target>] started PID <pid> on GPU(s) <ids> ; log <path> ;
    pid file <path>` from its start — the log and pid-file fields taken from the end, so a remote dir with spaces or a
    run name with ';' still reads (the RUN echo, indented, or a payload printing look-alikes can match only an earlier
    line). The receipt in the journal is read first whenever it can be: this line is the fallback."""
    rx = re.compile(r"^\[" + re.escape(target) + r"\]" + LAUNCH_LINE, re.M)
    hits = list(rx.finditer(text))
    return hits[-1] if hits else None


def rel_log(path: str) -> str:
    """logs/<name>-<stamp>.log of the absolute log path a launch line names (as the receipt and rsk status say it)."""
    if path.startswith("logs/"):
        return path
    i = path.rfind("/logs/")
    return path[i + 1:] if i >= 0 else path


def launch_ssh_reached(reply: Reply, target: str) -> bool:
    """run-launch prints `[<t>] reference: …` right before its ONE launch ssh: without that line it ended earlier (its
    read-only GPU-table ssh failed), so launch.sh never ran."""
    return any(ln.startswith(f"[{target}] reference: ") for ln in reply.out.splitlines())


def drift(rec: dict, text: str) -> str:
    """What changed between the approved card and the block a refused --rs-expect printed: the bound keys that differ,
    named with both values; else the warnings; '' when no block can be read."""
    try:
        now = grants.parse_plan(text)
    except RskError:
        return ""
    old = rec.get("block") or {}
    keys = ("target", *(grants.SLURM_BOUND if rec.get("kind") == "slurm" else grants.NOHUP_BOUND))

    def show(k: str, v: object) -> str:
        if v is None:
            return "(absent)"
        if k in ("launch_cfg", "env_hook"):   # path (sha256 12 hex) each: the change is in the digest, never cut off
            return ({"launch_cfg": _cfgs, "env_hook": _hook}[k](v) or "none")[:400]
        return (_words(v) or "none")[:80]
    diffs = [f"{k}: {show(k, old.get(k))} → {show(k, now.get(k))}" for k in keys if old.get(k) != now.get(k)]
    if diffs:
        return "; ".join(diffs)
    if str(now.get("warnings_id", "")) != str(old.get("warnings_id", "")):
        return (f"the warnings: {old.get('warnings', '?')} on the card, {now.get('warnings', '?')} now (another set of "
                "-y gates)")
    return ""


def settle(led: L.Ledger, place: harness.Place, rec: dict, run: str, aid: str, nonce: str, rid: str, reply: Reply,
           deadline: float, first: bool = True) -> int:
    """Record what the reply proves about one submission and say it; the exit code of that submission. FIRST: the
    plan's first segment (a proof that nothing was submitted then also releases the plan's claim)."""
    t = reply.text
    unknown = (f"SUBMIT_UNKNOWN: {run} {aid} (nonce {nonce}) — {reply.why or 'no receipt in the reply'}; rsk status "
               f"reconciles it from {place.target}'s journal (.rs/attempts/{nonce}/); never resubmit it blind")

    def refused(code: int, why: str, retry: bool = True) -> int:
        ev = f"not submitted: {why}"
        led.set_submission(run, aid, nonce, submit="not_submitted", evidence=ev[:300])
        given = grants.refund(led, rid, nonce, why[:200])
        freed = first and led.release_plan(rec["id"], nonce=nonce, why=why[:200])
        led.audit("submit_result", run=run, attempt=aid, nonce=nonce, to="not_submitted", rc=reply.rc, why=why[:200],
                  released=bool(freed))
        out(f"not submitted: {run} {aid} — {why}{f'; the use of {rid} is given back' if given else ''}"
            + (f"; plan {rec['id']} is free again: once the cause is fixed, rsk launch --plan {rec['id']} submits it "
               "under the same record (--rs-expect still guards drift)" if freed and retry else ""))
        return code

    def changed(what_t: str) -> int | None:
        """A refused --rs-expect (exit 6): name what changed since the card (the block it printed)."""
        d = drift(rec, reply.out)
        if not d and "differs from the approved plan" not in t and "warning(s) now" not in t:
            return None
        warn = d.startswith("the warnings") or (not d and "warning(s) now" in t)
        what = ("the warnings differ from the approved card" if warn else
                f"the resolved {what_t} differs from the approved plan")
        return refused(CONFLICT, f"{what}{' — ' + d if d else ''}: plan again — the new card goes to the user",
                       retry=False)

    def sync_note() -> None:
        out(f"needs: sync (the deploy predates rsk launch: rsk sync -T {place.target})")

    if reply.fail:                   # the call stopped before submit.sh / run-launch ran: proof that nothing was sent
        return refused(UNKNOWN, f"{reply.fail} — the call stopped before anything ran: nothing was sent to "
                                f"{place.target}")
    if place.kind == "slurm":
        job = reply.receipt.get("job", "")
        if job and reply.rc != 75:   # the receipt arrived: the job exists, whatever ssh said after it
            led.set_submission(run, aid, nonce, submit="submitted", job=job, evidence="remote receipt (job=" + job + ")")
            led.audit("submit_result", run=run, attempt=aid, nonce=nonce, to="submitted", job=job)
            out(f"submitted: {run} {aid} job {job} on {place.target} (nonce {nonce}, under {rid})")
            return OK
        if reply.rc is None or reply.rc == 255:   # R6-4: whatever ssh's stderr says (a fallback route's word may be
            said = [ln.strip() for ln in reply.err.splitlines() if ln.strip()]   # in it): the journal is the only proof
            out(unknown.replace("no receipt in the reply", (f"ssh exit {reply.rc}" if reply.rc else reply.why)
                                + (f" ({said[-1][:160]})" if said else "")
                                + " — ssh's own words are no proof that nothing was sent"))
            return UNKNOWN
        if reply.rc == 75:           # submit.sh's claim of the nonce failed: this call ran nothing
            return refused(CONFLICT, f"the attempt name {nonce} was taken on the target (exit 75): this call claimed "
                                     "nothing and submitted nothing")
        if reply.rc == 65 and reply.api != API:
            sync_note()
            return refused(CONFLICT, f"the deploy no longer speaks {API} (its submit.sh says {reply.api or 'no rs-api'}"
                                     f"): nothing ran — rsk sync -T {place.target}, then plan again", retry=False)
        if reply.rc == 2 and any(s in t for s in OLD_DEPLOY):
            sync_note()
            return refused(CONFLICT, f"the deploy no longer speaks {API} (an older submit.sh refused rsk's flags, exit "
                                     f"2): rsk sync -T {place.target}, then plan again", retry=False)
        v = reply.result.get("verdict", "")
        if v in ("refused", "failed"):
            st = reply.result.get("stage", "?")
            if reply.rc == 6:
                c = changed("submission")
                if c is not None:
                    return c
            if reply.rc == 1 and "never submitted without that check" in t:
                return refused(CONFLICT, "squeue failed on the login node: the duplicate check could not run, and an "
                                         "approved plan never goes out without it — plan again once squeue answers")
            if reply.rc == 1:
                return refused(CONFLICT, f"a warning the approved card did not show (stage {st}): plan again",
                               retry=False)
            code = {3: REFUSED, 6: CONFLICT, 2: USAGE}.get(reply.rc, FAILED)
            return refused(code, f"remote verdict={v} rc={reply.rc} stage={st} (its lines are above)")
        if reply.claimed is False and reply.rc != 0:   # submit.sh claims .rs/attempts/<nonce> before anything else
            return refused(USAGE if reply.rc == 2 else FAILED,
                           f"submit.sh exit {reply.rc} with no .rs/attempts/{nonce} on the target (it claims that "
                           "before anything else): nothing ran (its lines are above)")
        out(unknown.replace("no receipt in the reply", f"exit {reply.rc}, verdict {v or 'absent'}, no receipt"))
        return UNKNOWN
    # nohup: run-launch's reply. The receipt in the journal decides whenever it can be read (launch.sh writes it, then
    # the gate, then prints its launch line last); a payload (RUN is echoed) may print look-alike lines. R4-8: nothing
    # but the journal proves a launch never started — launch.sh's verdict refused/failed with no receipt, or no attempt
    # dir at all (launch.sh claims it before anything else) — or run-launch ending before its launch ssh
    m = started(t, place.target)
    reached = launch_ssh_reached(reply, place.target)

    def unsent(where: str) -> int:
        """The exit code of a launch proven never started (WHERE: what proves it), named by run-launch's exit."""
        if reply.rc == 6:
            c = changed("launch")
            if c is not None:
                return c
            return refused(CONFLICT, f"refused on the box (a live run of that name, or a GPU in use since the plan; "
                                     f"its lines are above) — {where}")
        if reply.rc == 2 and any(s in t for s in OLD_DEPLOY):
            sync_note()
            return refused(CONFLICT, f"the deploy no longer speaks {API}: rsk sync -T {place.target}, then plan again",
                           retry=False)
        if reply.rc == 1 and FEW_FREE.search(t):
            return refused(PLACEMENT, f"too few free GPUs now (placement; its lines are above) — {where}")
        return refused(USAGE if reply.rc == 2 else FAILED, f"exit {reply.rc} on the box (its lines are above) — {where}")

    if reply.rc == 255 and not reached:
        return refused(UNKNOWN, f"run-launch's read-only GPU-table ssh failed (exit 255) before its launch ssh: nothing "
                                f"was sent to {place.target}")
    if reply.rc is None or reply.rc == 255:
        out(unknown.replace("no receipt in the reply", reply.why or f"exit {reply.rc}"))
        return UNKNOWN
    if reply.rc != 0 and not reached and not m:
        return unsent(f"run-launch ended (exit {reply.rc}) before its launch ssh: launch.sh never ran")
    if reply.rc == 75:              # launch.sh's claim of the nonce failed: this call started nothing (the dir is not its)
        return refused(CONFLICT, f"the attempt name {nonce} was taken on the box (exit 75): this call claimed nothing "
                                 "and launched nothing")
    o = observe.observe([place], 1, deadline, nonces={place.target: [nonce]})[0]
    a = (o.attempts.get(nonce) or {}) if o.ok and o.attempts_ok else None
    rc = (a or {}).get("receipt") or {}
    verdict = ((a or {}).get("result") or {}).get("verdict", "")
    proc: dict = {}
    if rc.get("pid") and (a or {}).get("gate") == "go":
        proc = {"pid": rc["pid"], "pgid": rc.get("pgid", rc["pid"]), "start": rc.get("start", ""),
                "boot_id": rc.get("boot_id", ""), "log": rc.get("log", rel_log(m.group(3)) if m else ""),
                "gpu_ids": rc.get("gpu_ids", m.group(2) if m else "")}
        ev = "remote receipt (pid + start + boot_id)" + ("" if reply.rc == 0 else f"; launch.sh exit {reply.rc} after it")
    elif a is None and reply.rc == 0 and m:   # the journal could not be read: launch.sh's own last line
        proc = {"pid": m.group(1), "pgid": m.group(1), "start": "", "boot_id": "", "log": rel_log(m.group(3)),
                "gpu_ids": m.group(2)}
        ev = "launch.sh: started PID " + m.group(1)
    elif a is not None and 0 < reply.rc < 128 and a.get("missing"):   # launch.sh's own exit (ssh's is 255; a killed
        # ssh is 128+N and a killed run-launch < 0: launch.sh may still be on its way to the claim, so no proof then)
        return unsent(f"no .rs/attempts/{nonce} on the box after launch.sh exited {reply.rc}: it never claimed it, so "
                      "it started nothing")
    elif a is not None and reply.rc != 0 and verdict in ("refused", "failed") and not rc:
        return unsent(f"the journal: verdict {verdict}, no receipt")   # a launch line in the reply was the payload's
    if not proc:
        shows = "nothing" if a is None else "a receipt whose gate is not go" if rc else "no receipt"
        why = (f"exit {reply.rc}" + (" with a launch line" if m else " without the launch line")
               + f", and the journal shows {shows} ({o.why or 'verdict ' + (verdict or 'absent')})")
        out(unknown.replace("no receipt in the reply", why))
        return UNKNOWN
    led.set_submission(run, aid, nonce, submit="submitted", proc=proc, evidence=ev)
    led.audit("submit_result", run=run, attempt=aid, nonce=nonce, to="submitted", pid=proc["pid"], log=proc["log"])
    out(f"launched: {run} {aid} pid {proc['pid']} on GPU(s) {proc['gpu_ids']} of {place.target}, log "
        f"{proc['log']} (nonce {nonce}, under {rid})" + ("" if proc["start"] else
                                                         " — receipt not read yet (rsk status)"))
    return OK


def submit_plan(led: L.Ledger, src: Path, proj: Path, place: harness.Place, rec: dict, rid: str, deadline: float, claimed: bool = False, launched: list | None = None,
                unread: set[str] | None = None) -> int:
    """Every segment of one plan, each: (lock) re-check that RID covers it, claim the plan (first; CLAIMED: the
    caller claimed it already, under the lock that created RID), count the use, record SUBMIT_UNKNOWN — (no lock)
    the ssh — (lock) settle it."""
    n, aid, run = max(1, int(rec.get("chain") or 0)), "", ""
    for seg in range(n):
        nonce = new_nonce()
        words = submit_words(rec, nonce)          # before anything is recorded: a plan it cannot replay sends nothing
        with led.locked():
            if seg == 0:
                duplicate(led, rec["target"], rec["name"], rec.get("same_name_ok", False), rec.get("chain", 0), unread)
            st = only(led, rid)
            d = decide(st, rec, need=n - seg, extending=(run, aid) if seg else None, unread=unread)
            if not d.covered:
                done = f" ({seg} of {n} segments were submitted)" if seg else ""
                out(f"not covered any more{done}: " + "; ".join(d.reasons))
                out(f"needs user: approval — plan {rec['id']}" if not seg else
                    f"needs user: approval — the remaining {n - seg} segment(s) of {rec['name']}")
                if seg:                            # earlier segments went out: their wandb run
                    tracker_note(rec)
                return REFUSED if d.denied else NEEDS_USER
            action = plan_actions(st.runs, rec)[0]
            if seg == 0 and not claimed:
                led.claim_plan(rec["id"], record=rid, nonce=nonce)
            grants.use(led, rid, nonce, action, hash=rec["bound_hash"])
            run, aid = led.record_attempt(name=rec["name"], target=rec["target"], kind=rec["kind"], nonce=nonce,
                                          submit="unknown", plan=rec["block"], plan_id=rec["id"], grant=rid,
                                          card=rec["card"], action=action, cls=rec.get("class", ""),
                                          evidence="sent; no reply yet", attempt=aid)
        reply = call(src, proj, place, nonce, words, deadline)
        shown = [ln for ln in reply.shown() if ln.strip()]
        if shown:
            out("\n".join(shown))
        code = settle(led, place, rec, run, aid, nonce, rid, reply, deadline, first=seg == 0)
        if code == OK and launched is not None:
            launched.append((run, aid, place.target, nonce))
        if code != OK:
            if seg + 1 < n:
                out(f"the chain stops: {n - seg - 1} later segment(s) not sent")
            if seg or maybe_sent(led, run, aid, nonce):   # a segment went out, or this one may have
                tracker_note(rec)
            return code
    tracker_note(rec)
    return OK


def maybe_sent(led: L.Ledger, run: str, aid: str, nonce: str) -> bool:
    """Whether the ledger counts submission NONCE of RUN's attempt AID as sent or maybe sent (not NOT_SUBMITTED)."""
    att = ((led.read_run(run).data or {}).get("attempts") or {}).get(aid) or {}
    return any(s.get("nonce") == nonce and s.get("submit") != "not_submitted" for s in att.get("submissions") or [])


def _seen(o: observe.Observation, kind: str, sub: dict) -> tuple[str, observe.Job | None]:
    """The submission's key (Slurm job id / box log) and its job in the read O (None: not in this read)."""
    key = str(sub.get("job") or "") if kind == "slurm" else str((sub.get("proc") or {}).get("log") or "")
    for j in o.jobs if key else ():
        if (kind == "slurm" and j.id == key and j.source != "pid") or (kind != "slurm" and j.log == key):
            return key, j
    return key, None


def _job_end(kind: str, j: observe.Job) -> tuple[str, str]:
    """('live' | 'ok' | 'failed' | 'unknown', what the read shows) for one job of a good read."""
    if kind == "slurm":
        if j.state in observe.TERMINAL:
            return ("ok" if j.state == "COMPLETED" else "failed"), j.state + (f" rc={j.exit_code}" if j.exit_code else "")
        return "live", j.state or "?"
    if j.rc:
        rc = str(j.rc.get("rc", ""))
        return ("ok" if rc == "0" else "failed"), (f"ENDED rc={rc}" if rc else "ENDED (no exit code)")
    if j.state == "ENDED":
        return "failed", "ENDED (pid gone, no exit code)"
    return ("live", "ALIVE") if j.state == "ALIVE" else ("unknown", j.state or "UNKNOWN")


def check_after(led: L.Ledger, src: Path, proj: Path, launched: list, secs: int, deadline: float, code: int) -> int:
    """--check-after S: the start milestone, read once S seconds after the submits (experiment-conventions.md §7):
    every submission this call made (each segment of a chain) is judged from that read itself — live (pending, with
    squeue's reason when the read has one: `PENDING (Priority)`; running), ended as it should (Slurm COMPLETED, a box
    run's exit 0), ended otherwise (its state, exit code and the status.sh digest of that job / log), or not in the
    read (unknown: absence is no evidence). The read is also applied
    to the ledger. One that ended otherwise is exit 1 when the submits themselves went through: it WAS launched — a fix
    is a new decision (rsk launch --relaunch)."""
    if not launched or secs <= 0:
        return code
    from remote_run import status as S
    out(f"--check-after: reading {len(launched)} submission(s) again in {secs} s")
    time.sleep(secs)
    places: dict[str, harness.Place] = {}
    for t in sorted({x[2] for x in launched}):
        try:
            places[t] = S.select(harness.places(src, proj), [t])[0]
        except RskError as exc:
            out(f"--check-after: cannot read {t} ({exc}) — rsk status / rsk logs")
    st0 = led.state()
    obs = {o.place.target: o for o in observe.observe(list(places.values()), 1, min(deadline, 60.0))} if places else {}
    for n in S.record(led, st0, list(obs.values())):
        out(f"ledger: {n}")
    failed = []
    for run, aid, t, nonce in launched:
        att = ((st0.runs.get(run) or {}).get("attempts") or {}).get(aid) or {}
        sub = next((x for x in att.get("submissions") or [] if x.get("nonce") == nonce), {})
        kind, o = att.get("kind", ""), obs.get(t)
        key, j = _seen(o, kind, sub) if o and o.ok else (str(sub.get("job") or ""), None)
        head = f"{run} {aid} on {t}" + (f" ({'job ' if kind == 'slurm' else ''}{key})" if key else "")
        if not o or not o.ok:
            out(f"{head}: not readable now ({o.why if o else 'no read'}) — state unknown (rsk status)")
            continue
        if j is None:
            out(f"{head}: not in this read — state unknown (rsk status / rsk logs)")
            continue
        verdict, what = _job_end(kind, j)
        if verdict == "live" and kind == "slurm" and j.state == "PENDING" and j.reason:   # I6: squeue's reason, as
            what += f" ({observe._short(j.reason, 80)})"                                   # rsk status shows it
        if verdict != "failed":
            out(f"{head}: {what} {secs} s after the launch" + (" — ended as it should" if verdict == "ok" else ""))
            continue
        out(f"{head}: {what} within {secs} s of the launch — it failed at once: read the digest below, fix, then decide "
            "on a relaunch")
        S.digest(places[t], key, 20, deadline=min(deadline, 60.0))
        failed.append(f"{run} {aid} ({key})")
    if failed and code == OK:
        out(f"--check-after: {', '.join(failed)} ended within {secs} s — launched, then failed (exit 1)")
        return FAILED
    return code


# ================================================================================================ the commands
def _place(src: Path, proj: Path, target: str) -> harness.Place:
    from remote_run.status import select
    return select(harness.places(src, proj), [target])[0]


def cmd_new(ns: argparse.Namespace, led: L.Ledger, src: Path, proj: Path) -> int:
    target = ns.target
    if not target and ns.relaunch:
        atts = (led.read_run(ns.relaunch).data or {}).get("attempts") or {}
        if atts:
            target = atts[max(atts, key=lambda k: int(k[1:]) if k[1:].isdigit() else 0)].get("target", "")
    if not target:
        raise RskError("rsk launch -T <target> [flags] -- <cmd…>  (or --plan ID … to submit stored plans)", USAGE)
    place = _place(src, proj, target)
    req = build_request(ns, led, place)
    unread: set[str] = set()   # targets refresh() could not read now (the duplicate guard names them)
    if req.name:          # a run that ended since the last read must not look live (duplicate guard, relaunch end)
        unread |= refresh(led, src, proj, {L.run_id(req.name)}, ns.deadline)
    duplicate(led, place.target, req.name, req.same_name_ok, req.chain, unread)   # before the plan ssh, the name known
    rec = make_plan(led, src, proj, place, req, ns.deadline)
    if rec["name"] and L.run_id(rec["name"]) != L.run_id(req.name or ""):
        unread |= refresh(led, src, proj, {L.run_id(rec["name"])}, ns.deadline)
    duplicate(led, place.target, rec["name"], req.same_name_ok, req.chain, unread)   # the resolved name (conf JOB_NAME)
    elsewhere(led, place.target, rec["name"], unread)   # the run live on another target: a NOTE, the user's call
    with led.locked():
        led.create_plan(rec)
        d = decide(led, rec, unread=unread)
    out(rec["card"])
    if d.denied:
        out(f"denied: {d.reasons[0]}")
        raise RskError(f"denied by {d.record['id']} — the user forbade it{grants.said(d.record)}", REFUSED)
    if not d.covered:
        out("not covered: " + ("; ".join(d.reasons) or "no record"))
        out(f"needs user: approval — plan {rec['id']}")
        return NEEDS_USER
    out(f"covered by {d.record['id']} ({d.record['kind']}): {grants.describe(d.record)}")
    launched: list = []
    code = submit_plan(led, src, proj, place, rec, d.record["id"], ns.deadline, launched=launched,
                       unread=unread)
    return check_after(led, src, proj, launched, ns.check_after, ns.deadline, code)


def cmd_plans(ns: argparse.Namespace, led: L.Ledger, src: Path, proj: Path) -> int:
    asked = [x for x in (ns.target, ns.relaunch, ns.cls, ns.cmd, ns.policy_flags) if x] + \
        [x for x in (ns.part, ns.gpus, ns.gtype, ns.time, ns.mem, ns.cpus, ns.name, ns.ids, ns.wsname, ns.nice)
         if x not in (None, "")] + [x for x in (ns.chain, ns.same_name_ok, ns.gpu_busy_ok, ns.y, ns.free_name) if x]
    if asked:
        raise RskError("--plan submits a stored plan as it was planned: no -T / flags / command beside it", USAGE)
    approved = ns.approve is not None        # S4: a flag; any words after it are not recorded
    recs, problems = [], []
    for pid in dict.fromkeys(ns.plans):
        got = led.read_plan(pid)
        if got.source != "ok":
            raise RskError(f"no plan {pid!r} in this project's ledger{': ' + got.why if got.why else ''}",
                           USAGE if got.source == "missing" else CONFLICT)
        why = plan_state(led, got.data)
        if why:
            problems.append(why)
        recs.append(got.data)
    if problems:
        raise RskError("; ".join(problems) + " — nothing submitted: plan again (rsk launch -T … ) and show the new card",
                       CONFLICT)
    all_places = harness.places(src, proj)
    from remote_run.status import select
    places = {}
    for rec in recs:
        p = select(all_places, [rec["target"]])[0]
        if (p.host, p.remote_dir) != (rec.get("host"), rec.get("remote_dir")):
            raise RskError(f"plan {rec['id']}: the conf now puts {rec['target']} at {p.host}:{p.remote_dir}, the plan "
                           f"was made at {rec.get('host')}:{rec.get('remote_dir')} — plan again", CONFLICT)
        places[rec["id"]] = p
    unread = refresh(led, src, proj, {rec["run"] for rec in recs if rec.get("run")}, ns.deadline)   # before the lock: ssh
    for rec in recs:
        elsewhere(led, rec["target"], rec.get("name", ""), unread)
    by: dict[str, str] = {}
    with led.locked():   # ONE hold: re-check, the denies, claim every plan, then the approval (revoked on a failure)
        problems = [w for w in (plan_state(led, r) for r in recs) if w]
        if problems:
            raise RskError("; ".join(problems) + " — nothing submitted, no approval recorded: plan again (rsk launch "
                           "-T … ) and show the new card", CONFLICT)
        st = led.state()
        acts_of = {rec["id"]: plan_actions(st.runs, rec) for rec in recs}
        for rec in recs:
            acts = acts_of[rec["id"]]
            d = grants.check(st, acts[0], plan=check_plan(rec, st.runs, unread), run=rec["run"], also=acts[1:])
            if d.denied:
                out(rec["card"])
                out(f"denied: {d.reasons[0]}")
                raise RskError(f"plan {rec['id']} is denied by {d.record['id']}{grants.said(d.record)} — nothing "
                               "submitted, no approval recorded", REFUSED)
        if not approved:
            for rec in recs:
                d = decide(led, rec, unread=unread)
                if not d.covered:
                    out(rec["card"])
                    out("not covered: " + ("; ".join(d.reasons) or "no record"))
                    out(f"needs user: approval — plan {rec['id']}")
                    return NEEDS_USER
                by[rec["id"]] = d.record["id"]
        else:
            groups: dict[tuple, list[dict]] = {}
            for rec in recs:   # one record per kind of request: the actions, the uses per plan, warnings seen
                key = (acts_of[rec["id"]], max(1, int(rec.get("chain") or 0)), int(rec.get("warnings") or 0) > 0)
                groups.setdefault(key, []).append(rec)
            aps = [(grants.new_approval([m["block"] for m in members], plan_ids=[m["id"] for m in members],
                                        actions=acts, launches=n, allow_warnings="any" if warned else ""), members)
                   for (acts, n, warned), members in groups.items()]
            for ap, members in aps:        # the plans first: each one single use, claimed for its approval
                for m in members:
                    led.claim_plan(m["id"], record=ap["id"], via="plan-approve")
                    by[m["id"]] = ap["id"]
            made: list[str] = []
            try:
                for ap, _members in aps:
                    grants.add(led, ap)
                    made.append(ap["id"])
                    out(f"approval {ap['id']}: {grants.describe(ap)}")
            except BaseException:
                for rid in made:
                    grants.revoke(led, rid, "rsk: revoked — recording the approval failed; its plans are used, plan "
                                            "again")
                raise
    first = OK
    launched: list = []
    for rec in recs:
        if not approved:
            out(rec["card"])
            out(f"covered by {by[rec['id']]}: submitting")
        try:
            code = submit_plan(led, src, proj, places[rec["id"]], rec, by[rec["id"]], ns.deadline, claimed=approved,
                               launched=launched, unread=unread)
        except RskError as exc:    # one plan's conflict never hides what the others did
            out(f"plan {rec['id']}: {exc}")
            code = exc.code
        first = first or code
    if len(recs) > 1:
        out(f"{len(recs)} plan(s): {'all submitted' if first == OK else 'not all submitted — see the lines above'}")
    return check_after(led, src, proj, launched, ns.check_after, ns.deadline, first)


def cmd_launch(args: argparse.Namespace) -> int:
    from remote_run.status import project_dir
    extra = list(getattr(args, "extra", []) or [])
    if help_asked(extra):
        parser().print_help()
        return OK
    ns = parse(extra)
    proj = project_dir(ns.dir)
    led, src = L.Ledger(proj), paths.harness_src()
    if ns.approve is not None and not ns.plans:
        raise RskError("--approve goes with --plan ID: plan first — the card is what the user approves", USAGE)
    if ns.plans:
        return cmd_plans(ns, led, src, proj)
    return cmd_new(ns, led, src, proj)


def add_parser(sub) -> None:
    p = sub.add_parser("launch", add_help=False, help="plan a run on a target, then submit it once the user approves the "
                       "card (--approve) or a grant covers it — recorded in the ledger")
    p.set_defaults(func=cmd_launch, passthrough=True)
