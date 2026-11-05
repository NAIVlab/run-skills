"""`rsk launch`: plan on the target, then the user's words (or a record that already covers the plan), then the
submit — every step recorded in the project's ledger (ledger.py) and checked against what the user allowed (grants.py).

    rsk launch -T T [-C DIR] [--class C] [--same-name-ok] [--relaunch RUN] [--deadline S]
               slurm: [-p PART] [-g N] [-G TYPE] [-t TIME] [-m MEM] [-c CPUS] [-n NAME] [--chain N] [--<policy-flag>…]
                      -- CMD…
               nohup: [-g N | -d IDS] [-N NAME] [--nice N] [--gpu-busy-ok] [-- CMD…]
    rsk launch --plan ID [--plan ID…] [--approve "the user's words"] [-C DIR] [--deadline S]

1. Local duplicate: a live ledger attempt of the run (the name minus --aNN) on that target → exit 6 unless
   --same-name-ok (also passed on to the remote guard). A --chain skips it, as submit.sh skips singleton chains.
2. PLAN — slurm: ONE ssh that reads <REMOTE_DIR>/.<t>/API and, only when it says api=3, runs
   `bash <REMOTE_DIR>/.<t>/submit.sh --rs-attempt <nonce> --rs-mode plan …`; nohup: `RS_VIA_RSK=1 bin/run-launch
   --rs-attempt <nonce> --rs-mode plan …` from the harness (cwd = the project, TARGET set). A deploy that does not speak
   api=3 → exit 6 `needs: sync`. A plan never submits: its refusal (policy 3, duplicate 6, usage 2, too few free GPUs
   8, the env gate 1) is the exit code, with the target's lines.
3. The plan and its card are stored (plans/<id>.json, never rewritten). grants.check() decides: a deny → exit 3 with its
   quote; a record that covers the plan → submit now; else the card and `needs user: approval — plan <id>` → exit 4. A
   standing grant never covers a workstation plan that lands on a GPU in use (only the user's words naming it).
4. --plan … --approve "words": each plan unused, younger than PLAN_TTL_S, not superseded by a newer plan of the same
   target + name (else exit 6, nothing submitted); denies checked again; one approval record (created_via
   plan-approve) per kind of request covers them all (a sweep is one approval); each plan claimed (single use), then
   submitted with a fresh nonce and --rs-expect <bound_hash>: -y only when its card showed warnings, --rs-chain on each
   of N chain segments (slurm), --gpu-busy-ok only when the request asked for it and the card listed busy GPUs (nohup).
   --plan without --approve submits only when a record covers the plan now.
5. Each submission is recorded as SUBMIT_UNKNOWN before it is sent (sticky); the reply settles it: a receipt (or the
   launch line) = submitted; the remote verdict refused/failed = not submitted, and the grant use is given back; ssh
   255, a timeout or no receipt stays SUBMIT_UNKNOWN — `rsk status` reconciles it from the remote journal; never
   resubmitted blind.
A record is bookkeeping, not proof that the user agreed: the card shown and the user's words are what make it theirs.
The ledger lock is held for each check-then-record step, never across an ssh.
Exit: 0 submitted · 1 failed on the target · 2 usage · 3 refused (policy, deny) · 4 needs the user · 5 unknown ·
6 conflict (duplicate, stale / used / superseded plan, drift, an old deploy) · 8 placement (too few free GPUs).
"""

from __future__ import annotations

import argparse
import os
import re
import secrets
import shlex
import subprocess
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from remote_run import grants, harness, observe, paths
from remote_run import ledger as L
from remote_run.errors import (CONFLICT, FAILED, NEEDS_USER, OK, PLACEMENT, REFUSED, UNKNOWN, USAGE, RskError)

API = "api=3"                    # the protocol this rsk speaks (remote/API)
PLAN_TTL_S = 24 * 3600           # an older plan is expired: plan again (the target may have changed meanwhile)
POLICY_FLAG = re.compile(r"--[A-Za-z0-9][A-Za-z0-9-]*")   # submit.sh hands an unknown --word to the policy
INTERESTING = re.compile(r"^(WARNING|NOTE|ERROR|REFUSED)\b")
OLD_DEPLOY = ("no .ws/launch.sh in the remote dir", "unknown arg '--rs-", "unknown arg '--gpu-busy-ok'")
FEW_FREE = re.compile(r"only [0-9]+ GPU id\(s\) free")


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
    p.add_argument("--approve", default=None, metavar="WORDS", help="the user's words approving the --plan card(s)")
    p.add_argument("--class", dest="cls", default="", choices=grants.CLASSES, help="the run class (grant scopes)")
    p.add_argument("--same-name-ok", action="store_true", help="also when a run of this name is live (both wanted)")
    p.add_argument("--relaunch", default="", metavar="RUN", help="the run's next attempt (aNN), same configuration")
    p.add_argument("--deadline", type=float, default=180.0, help="seconds per ssh (default 180)")
    p.add_argument("-g", dest="gpus", default=None, help="GPU count")
    s = p.add_argument_group("slurm (submit.sh)")
    for flag, dest, what in (("-p", "part", "partition"), ("-G", "gtype", "GPU type"), ("-t", "time", "time limit"),
                             ("-m", "mem", "memory"), ("-c", "cpus", "CPUs"), ("-n", "name", "job name")):
        s.add_argument(flag, dest=dest, default=None, help=what)
    s.add_argument("-y", action="store_true", help="accepted, never sent as typed: the card decides (-y only when "
                   "the approved card showed warnings)")
    s.add_argument("--chain", type=int, default=0, metavar="N", help="N singleton segments (--rs-chain), one approval")
    n = p.add_argument_group("nohup (run-launch)")
    n.add_argument("-d", dest="ids", default=None, help="exactly these GPU ids")
    n.add_argument("-N", dest="wsname", default=None, help="run name")
    n.add_argument("--nice", default=None)
    n.add_argument("--gpu-busy-ok", action="store_true", help="plan onto GPUs with a compute process (the card then "
                   "needs the user's words naming them; never a standing grant)")
    return p


def parse(extra: list[str]) -> argparse.Namespace:
    """ARGS = everything after `rsk launch` (cli.py hands it over unparsed): rsk's flags, then `--` and the command."""
    words = list(extra)
    head, cmd = (words[:words.index("--")], words[words.index("--") + 1:]) if "--" in words else (words, [])
    ns, rest = parser().parse_known_args(head)
    bad = [w for w in rest if not POLICY_FLAG.fullmatch(w)]
    if bad:
        raise RskError(f"rsk launch: unrecognized {' '.join(bad)} (rsk launch -h; the command goes after --)", USAGE)
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
    """(flags, payload, chain) that ask for the original attempt's bound fields again (a relaunch, nothing typed)."""
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
        return f + ["-n", name], grants.qwords(b.get("payload", "")), 1 if b.get("chain") == "1" else 0
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
            "when the approved card showed one")
    name = ns.name if kind == "slurm" else ns.wsname
    action = "chain" if ns.chain else "launch"
    req = Request(place.target, kind, [], list(ns.cmd), name or "", ns.cls, ns.chain, action,
                  same_name_ok=ns.same_name_ok, gpu_busy_ok=bool(ns.gpu_busy_ok))
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
            return req
    req.flags = _slurm_flags(ns, req.name) if kind == "slurm" else _nohup_flags(ns, req.name)
    if kind == "slurm" and not req.payload:
        raise RskError("no command: rsk launch -T <t> [flags] -- <cmd…> (submit.sh needs one)", USAGE)
    return req


# ================================================================================================ the remote calls
SLURM_BODY = r'''rs_launch() {   # the deployed API first: an older submit.sh is never handed rsk's flags
  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\~/}" ;; esac
  a=$(head -c 64 "$RDIR/$DEPLOY/API" 2>/dev/null | head -n 1); echo "@@api $a"
  [ "$a" = "$WANT" ] || return 65
  bash "$RDIR/$DEPLOY/submit.sh" "$@" </dev/null; rc=$?
  d=$RDIR/.rs/attempts/$NONCE; echo "@@rc $rc"
  [ ! -f "$d/result" ] || echo "@@result $(head -c 256 "$d/result" | head -n 1)"
  [ ! -f "$d/receipt" ] || LC_ALL=C grep -a -E '^(job|name|nonce|at|partition)=' "$d/receipt" | head -c 2048 | sed 's/^/@@k /'
  return "$rc"
}'''


@dataclass
class Reply:
    rc: int | None                 # None: no answer (the deadline, or ssh could not start)
    out: str = ""
    err: str = ""
    api: str | None = None         # slurm: the deployed API line (None: not read)
    result: dict = field(default_factory=dict)
    receipt: dict = field(default_factory=dict)
    why: str = ""

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
            f"WANT={shlex.quote(API)}\n")
    return head + SLURM_BODY + "\nrs_launch " + " ".join(shlex.quote(w) for w in words) + "\n"


def parse_slurm(done: subprocess.CompletedProcess) -> Reply:
    r = Reply(done.returncode, done.stdout or "", done.stderr or "")
    after = False
    for ln in r.out.splitlines():
        if ln.startswith("@@api ") and r.api is None:
            r.api = ln[6:].strip()
        elif ln.startswith("@@rc "):
            after = True
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


def submit_words(rec: dict, nonce: str) -> list[str]:
    """The approved request again: a fresh nonce, --rs-expect, -y only after warnings the card showed, --rs-chain per
    segment; --gpu-busy-ok only when asked AND the card listed busy GPUs (a busy GPU since the plan is refused)."""
    common = ["--rs-attempt", nonce, "--rs-expect", rec["bound_hash"]]
    if rec["kind"] == "slurm":
        return [*common, *(["-y"] if int(rec.get("warnings") or 0) > 0 else []),
                *(["--rs-chain"] if rec.get("chain") else []), *rec["flags"], "--", *rec["payload"]]
    busy = str((rec.get("block") or {}).get("info_busy", ""))
    return [*common, *rec["flags"], *(["--gpu-busy-ok"] if rec.get("gpu_busy_ok") and busy else []),
            "--", *rec["payload"]]


def call(src: Path, proj: Path, place: harness.Place, nonce: str, words: list[str], deadline: float) -> Reply:
    if place.kind == "slurm":
        return call_slurm(place, nonce, words, deadline)
    return call_nohup(src, proj, place.target, words, deadline)


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
    if reply.rc is None:
        return RskError(f"[{place.target}] {reply.why} — the plan's outcome is unknown, but a plan never submits", UNKNOWN)
    if place.kind == "slurm" and reply.api is not None and reply.api != API:
        return _needs_sync(place, f"its .{place.target}/API says {reply.api or 'nothing (no API file)'}")
    if place.kind == "nohup" and reply.rc == 2 and any(s in t for s in OLD_DEPLOY):
        return _needs_sync(place, "its .ws/launch.sh does not know rsk's flags")
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
               "needs the user's words naming the GPU")
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


def busy_landing(rec: dict) -> str:
    """'' unless a workstation plan (asked with --gpu-busy-ok) lands on a GPU with a compute process, or cannot tell."""
    b = rec.get("block") or {}
    if rec.get("kind") != "nohup" or not rec.get("gpu_busy_ok"):
        return ""
    busy = str(b.get("info_busy", ""))
    if busy == "unknown":
        return "which GPUs are busy is unknown"
    used = {x.split(":", 1)[0] for x in busy.split(",") if x}
    hit = sorted(used & set(str(b.get("info_gpus", "")).split(",")) - {""}, key=lambda x: int(x) if x.isdigit() else 0)
    return f"GPU(s) {','.join(hit)} run another compute process ({busy})" if hit else ""


def render_card(rec: dict) -> str:
    b, kind = rec["block"], rec["kind"]
    o = [f"plan {rec['id']} — {rec['action']} on {rec['target']} ({kind}), {rec['created_at']}"]
    head = f"  run        {rec['run']}"
    if rec.get("class"):
        head += f"   class {rec['class']}"
    if rec.get("relaunch_of"):
        head += f"   next attempt of {rec['relaunch_of']}"
    o.append(head)
    if kind == "slurm":
        rows = [("name", _dec(b.get("name", ""))), ("partition", _dec(b.get("partition", ""))),
                ("gres", _dec(b.get("gres", ""))), ("cpus", _dec(b.get("cpus", ""))), ("mem", _dec(b.get("mem", ""))),
                ("time", _dec(b.get("time", ""))), ("account", _dec(b.get("account", ""))),
                ("extra", _words(b.get("extra", ""))), ("payload", _words(b.get("payload", ""))),
                ("env", " ".join(x for x in (_dec(b.get("env_kind", "")), _dec(b.get("env_name", ""))) if x)),
                ("wandb_mode", _dec(b.get("wandb_mode", ""))),
                ("chain", "singleton (--rs-chain)" if b.get("chain") == "1" else "no")]
    else:
        rows = [("name", b.get("name", "")), ("gpus", b.get("gpus_req", "")), ("exclude", b.get("exclude", "")),
                ("nice", b.get("nice", "")), ("payload", _dec(b.get("payload", ""))),
                ("env", " ".join(x for x in (_dec(b.get("env_kind", "")), _dec(b.get("env_name", ""))) if x))]
    o += [f"  {k:<11}{v or '-'}" for k, v in rows]
    if policy_flags(rec):
        o.append(f"  policy     {' '.join(policy_flags(rec))}  (passed to the target's policy; not bound)")
    if rec.get("same_name_ok"):
        o.append("  same name  --same-name-ok: a live run of this name may share its logs/ckpts")
    if rec.get("chain"):
        o.append(f"  segments   {rec['chain']} (each waits for the one before: --dependency=singleton)")
    o.append(f"  warnings   {rec['warnings']}" + ("" if rec["warnings"] else "  (no -y gate)"))
    shown = rec.get("lines") or []
    o += [f"    {ln}" for ln in shown]
    if kind == "slurm":
        o.append(f"  available  {_dec(b.get('info_avail', '')) or '-'}")
        dc, dd = _dec(b.get("info_source_commit", "none")), _dec(b.get("info_source_dirty", "none"))
        lc, ld = rec["local"]["commit"], rec["local"]["dirty"]
        same = "same commit" if dc == lc and dc != "none" else "DIFFERENT code than this checkout's HEAD"
        o.append(f"  source     deployed {dc[:12]} dirty={dd} · local HEAD {lc[:12]} dirty={ld} — {same}")
        o.append("  files      " + " · ".join(f"{k.replace('_', '.')} {str(b.get(f'info_{k}_sha256', '?'))[:12]}"
                                           for k in ("conf", "profile", "policy", "policy_local")))
    else:
        o.append(f"  GPUs now   {b.get('info_gpus') or '-'}  ({b.get('info_uuids') or '-'}) — the envelope: a count "
                 "is picked again at submit time")
        o.append(f"  busy now   {b.get('info_busy') or 'none'}")
        hit = busy_landing(rec)
        if hit:
            o.append(f"  ON A BUSY GPU: {hit} — only with the user's words naming it")
    for r in rec.get("references") or ["-"]:
        o.append(f"  reference  {r}")
    o.append(f"  bound_hash {rec['bound_hash']}")
    return "\n".join(o)


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
        raise _needs_sync(place, f"its API file says {reply.api or 'nothing'}")
    if "api=" + block.get("api", "") != API:
        raise _needs_sync(place, f"its plan block says api={block.get('api')}")
    if block.get("kind") != place.kind or _dec(block.get("target", "")) != place.target:
        raise RskError(f"[{place.target}] the plan block is for {block.get('target')} ({block.get('kind')}): another "
                       f"target's deploy in {place.remote_dir}? — rsk sync -T {place.target}", CONFLICT)
    name = _dec(block.get("name", ""))
    rec = {"id": new_plan_id(), "created_at": L.now(), "created_ns": time.time_ns(), "target": place.target,
           "kind": place.kind, "host": place.host, "remote_dir": place.remote_dir, "name": name, "run": L.run_id(name),
           "action": req.action, "class": req.cls, "chain": req.chain, "relaunch_of": req.relaunch_of,
           "same_name_ok": req.same_name_ok, "gpu_busy_ok": req.gpu_busy_ok, "flags": req.flags,
           "payload": req.payload, "plan_nonce": nonce, "block": block, "bound_hash": block["bound_hash"],
           "warnings": int(block["warnings"]), "lines": interesting(reply, place.target),
           "references": references(reply) or [r for r in [harness.reference(src, place.target)] if r],
           "local": local_source(proj)}
    rec["card"] = render_card(rec)
    return rec


# ================================================================================================ decisions
def check_plan(rec: dict) -> dict:
    plan = dict(rec["block"])
    if rec.get("class"):
        plan["class"] = rec["class"]
    return plan


def room(rec: dict, bound_hash: str) -> float:
    """Launches left under a grant / approval for this plan (inf: no limit)."""
    lim = rec.get("limits") or {}
    if rec.get("kind") == "approval":
        used = sum(1 for u in rec.get("used") or [] if u.get("hash") == bound_hash)
        return int(lim.get("max_launches") or 1) - used
    mx = lim.get("max_launches")
    return float("inf") if mx is None else mx - grants.launches_used(rec)


def decide(source: L.Ledger | L.LedgerState, rec: dict, need: int | None = None) -> grants.Decision:
    """grants.check() plus the two things only a whole request shows: N chain segments need N launches (NEED: the
    segments still to send), and a standing grant never covers a workstation plan that lands on a GPU in use."""
    d = grants.check(source, rec["action"], plan=check_plan(rec), run=rec["run"])
    if not d.covered:
        return d
    why = []
    n = max(1, int(rec.get("chain") or 0)) if need is None else need
    left = room(d.record, rec["bound_hash"])
    if left < n:
        why.append(f"room for {int(left)} of the {n} chain segments")
    hit = busy_landing(rec)
    if hit and d.record.get("kind") == "grant":
        why.append(f"{hit}: a GPU another job uses is never a standing grant's call — only the user's words naming it")
    asked = [f for f in policy_flags(rec) if f.endswith("-user-asked")]
    if asked and d.record.get("kind") == "grant":
        why.append(f"{' '.join(asked)} is the user's own OK for a policy gate, per submit — never a standing grant's call")
    if why:
        return grants.Decision(False, None, [f"{d.record['id']}: {'; '.join(why)}"],
                               f"approval — no record covers {rec['action']} of {rec['name']} (show the card and ask "
                               "the user)")
    return d


def only(led: L.Ledger, rid: str) -> L.LedgerState:
    """The ledger's state with one allowing record left (denies stay): who covers this submit is never another record."""
    st = led.state()
    st.grants = [r for r in st.grants if r.get("kind") == "deny" or r.get("id") == rid]
    return st


def live_attempts(led: L.Ledger, target: str, run: str) -> list[str]:
    rec = led.read_run(run).data or {}
    return [f"{k} ({L.attempt_state(a)})" for k, a in sorted((rec.get("attempts") or {}).items())
            if a.get("target") == target and L.is_live(a)]


def duplicate(led: L.Ledger, target: str, name: str, same_ok: bool, chain: int) -> None:
    if same_ok or chain or not name:
        return
    live = live_attempts(led, target, L.run_id(name))
    if live:
        raise RskError(f"run {L.run_id(name)} is live on {target} in the ledger: {', '.join(live)} — follow it (rsk "
                       "status), or --same-name-ok when both are wanted (a second copy shares its logs/ckpts)",
                       CONFLICT)


def plan_state(led: L.Ledger, rec: dict, now: float | None = None) -> str:
    """'' when REC may still be submitted; else why not (used, expired, superseded)."""
    claim = led.plan_claim(rec["id"])
    if claim:
        return f"plan {rec['id']} was used already ({claim.get('at', '?')})"
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
STARTED = re.compile(r"started PID ([0-9]+) on GPU\(s\) ([0-9,]+) ; log .*?(logs/[^ ;/]+\.log) ; pid file")


def settle(led: L.Ledger, place: harness.Place, rec: dict, run: str, aid: str, nonce: str, rid: str, reply: Reply,
           deadline: float) -> int:
    """Record what the reply proves about one submission and say it; the exit code of that submission."""
    t = reply.text
    unknown = (f"SUBMIT_UNKNOWN: {run} {aid} (nonce {nonce}) — {reply.why or 'no receipt in the reply'}; rsk status "
               f"reconciles it from {place.target}'s journal (.rs/attempts/{nonce}/); never resubmit it blind")

    def refused(code: int, why: str) -> int:
        ev = f"not submitted: {why}"
        led.set_submission(run, aid, nonce, submit="not_submitted", evidence=ev[:300])
        given = grants.refund(led, rid, nonce, why[:200])
        led.audit("submit_result", run=run, attempt=aid, nonce=nonce, to="not_submitted", rc=reply.rc, why=why[:200])
        out(f"not submitted: {run} {aid} — {why}{f'; the use of {rid} is given back' if given else ''}")
        return code

    if place.kind == "slurm":
        job = reply.receipt.get("job", "")
        if job:      # the receipt arrived: the job exists, whatever ssh said after it
            led.set_submission(run, aid, nonce, submit="submitted", job=job, evidence="remote receipt (job=" + job + ")")
            led.audit("submit_result", run=run, attempt=aid, nonce=nonce, to="submitted", job=job)
            out(f"submitted: {run} {aid} job {job} on {place.target} (nonce {nonce}, under {rid})")
            return OK
        if reply.rc is None or reply.rc == 255:
            out(unknown.replace("no receipt in the reply", f"ssh exit {reply.rc}" if reply.rc else reply.why))
            return UNKNOWN
        if reply.rc == 65 and reply.api != API:
            return refused(CONFLICT, f"the deploy no longer speaks {API} ({reply.api or 'no API file'}): nothing ran — "
                                     f"rsk sync -T {place.target}, then plan again")
        v = reply.result.get("verdict", "")
        if v in ("refused", "failed"):
            st = reply.result.get("stage", "?")
            if reply.rc == 6 and "differs from the approved plan" in t:
                return refused(CONFLICT, "the resolved submission differs from the approved plan (the conf, policy or "
                                         "deploy changed since): plan again — the new card goes to the user")
            if reply.rc == 1:
                return refused(CONFLICT, f"a warning the approved card did not show (stage {st}): plan again")
            code = {3: REFUSED, 6: CONFLICT, 2: USAGE}.get(reply.rc, FAILED)
            return refused(code, f"remote verdict={v} rc={reply.rc} stage={st} (its lines are above)")
        out(unknown.replace("no receipt in the reply", f"exit {reply.rc}, verdict {v or 'absent'}, no receipt"))
        return UNKNOWN
    # nohup: run-launch's reply (launch.sh replays its journal once the receipt and the gate are on disk, so the launch
    # line proves the start whatever ssh said after it; every other launch.sh failure exit is a not-started one)
    m = STARTED.search(t)
    if not m and (reply.rc is None or reply.rc not in (1, 2, 6)):
        why = "exit 0 without the launch line" if reply.rc == 0 else reply.why or f"exit {reply.rc}"
        out(unknown.replace("no receipt in the reply", why))
        return UNKNOWN
    if m:
        proc = {"pid": m.group(1), "pgid": m.group(1), "start": "", "boot_id": "", "log": m.group(3),
                "gpu_ids": m.group(2)}
        led.set_submission(run, aid, nonce, submit="submitted", proc=proc, evidence="launch.sh: started PID " + m.group(1))
        o = observe.observe([place], 1, deadline, nonces={place.target: [nonce]})[0]
        rc = (o.attempts.get(nonce) or {}).get("receipt") or {} if o.ok else {}
        if rc.get("pid") == proc["pid"]:
            proc.update({k: rc.get(k, proc[k]) for k in ("pgid", "start", "boot_id", "log", "gpu_ids")})
            led.set_submission(run, aid, nonce, proc=proc, evidence="remote receipt (pid + start + boot_id)")
        led.audit("submit_result", run=run, attempt=aid, nonce=nonce, to="submitted", pid=proc["pid"], log=proc["log"])
        out(f"launched: {run} {aid} pid {proc['pid']} on GPU(s) {proc['gpu_ids']} of {place.target}, log {proc['log']} "
            f"(nonce {nonce}, under {rid})" + ("" if proc["start"] else " — receipt not read yet (rsk status)"))
        return OK
    if reply.rc == 6 and "differs from the approved plan" in t:
        return refused(CONFLICT, "the resolved launch differs from the approved plan (the conf changed since): plan "
                                 "again — the new card goes to the user")
    if reply.rc == 6:
        return refused(CONFLICT, "refused on the box (a live run of that name, or a GPU in use since the plan; its "
                                 "lines are above)")
    if reply.rc == 2 and any(s in t for s in OLD_DEPLOY):
        return refused(CONFLICT, f"the deploy no longer speaks {API}: rsk sync -T {place.target}, then plan again")
    if reply.rc == 1 and FEW_FREE.search(t):
        return refused(PLACEMENT, "too few free GPUs now (placement; its lines are above)")
    return refused(USAGE if reply.rc == 2 else FAILED, f"exit {reply.rc} on the box (its lines are above)")


def submit_plan(led: L.Ledger, src: Path, proj: Path, place: harness.Place, rec: dict, rid: str, quote: str,
                deadline: float) -> int:
    """Every segment of one plan, each: (lock) re-check that RID covers it, claim the plan (first), count the use,
    record SUBMIT_UNKNOWN — (no lock) the ssh — (lock) settle it."""
    n, aid = max(1, int(rec.get("chain") or 0)), ""
    for seg in range(n):
        nonce = new_nonce()
        with led.locked():
            if seg == 0:
                duplicate(led, rec["target"], rec["name"], rec.get("same_name_ok", False), rec.get("chain", 0))
            d = decide(only(led, rid), rec, need=n - seg)
            if not d.covered:
                done = f" ({seg} of {n} segments were submitted)" if seg else ""
                out(f"not covered any more{done}: " + "; ".join(d.reasons))
                out(f"needs user: approval — plan {rec['id']}" if not seg else
                    f"needs user: approval — the remaining {n - seg} segment(s) of {rec['name']}")
                return REFUSED if d.denied else NEEDS_USER
            if seg == 0:
                led.claim_plan(rec["id"], record=rid, nonce=nonce)
            grants.use(led, rid, nonce, rec["action"], hash=rec["bound_hash"])
            run, aid = led.record_attempt(name=rec["name"], target=rec["target"], kind=rec["kind"], nonce=nonce,
                                          submit="unknown", plan=rec["block"], plan_id=rec["id"], grant=rid,
                                          quote=quote, card=rec["card"], action=rec["action"], cls=rec.get("class", ""),
                                          evidence="sent; no reply yet", attempt=aid)
        reply = call(src, proj, place, nonce, submit_words(rec, nonce), deadline)
        shown = [ln for ln in reply.shown() if ln.strip()]
        if shown:
            out("\n".join(shown))
        code = settle(led, place, rec, run, aid, nonce, rid, reply, deadline)
        if code != OK:
            if seg + 1 < n:
                out(f"the chain stops: {n - seg - 1} later segment(s) not sent")
            return code
    return OK


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
    duplicate(led, place.target, req.name, req.same_name_ok, req.chain)      # before any ssh when the name is known
    rec = make_plan(led, src, proj, place, req, ns.deadline)
    duplicate(led, place.target, rec["name"], req.same_name_ok, req.chain)    # the resolved name (conf JOB_NAME)
    with led.locked():
        led.create_plan(rec)
        d = decide(led, rec)
    out(rec["card"])
    if d.denied:
        out(f"denied: {d.reasons[0]}")
        raise RskError(f"denied by {d.record['id']} — the user forbade it: \"{d.record['quote']}\"", REFUSED)
    if not d.covered:
        out("not covered: " + ("; ".join(d.reasons) or "no record"))
        out(f"needs user: approval — plan {rec['id']}")
        return NEEDS_USER
    out(f"covered by {d.record['id']} ({d.record['kind']}, \"{d.record['quote']}\"): {grants.describe(d.record)}")
    return submit_plan(led, src, proj, place, rec, d.record["id"], d.record["quote"], ns.deadline)


def cmd_plans(ns: argparse.Namespace, led: L.Ledger, src: Path, proj: Path) -> int:
    asked = [x for x in (ns.target, ns.relaunch, ns.cls, ns.cmd, ns.policy_flags) if x] + \
        [x for x in (ns.part, ns.gpus, ns.gtype, ns.time, ns.mem, ns.cpus, ns.name, ns.ids, ns.wsname, ns.nice)
         if x not in (None, "")] + [x for x in (ns.chain, ns.same_name_ok, ns.gpu_busy_ok, ns.y) if x]
    if asked:
        raise RskError("--plan submits a stored plan as it was planned: no -T / flags / command beside it", USAGE)
    words = ns.approve
    if words is not None and not words.strip():
        raise RskError("--approve takes the user's words, verbatim (non-empty)", USAGE)
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
    by: dict[str, str] = {}
    with led.locked():
        for rec in recs:
            d = grants.check(led, rec["action"], plan=check_plan(rec), run=rec["run"])
            if d.denied:
                out(rec["card"])
                out(f"denied: {d.reasons[0]}")
                raise RskError(f"plan {rec['id']} is denied by {d.record['id']}: \"{d.record['quote']}\" — nothing "
                               "submitted, no approval recorded", REFUSED)
        if words is None:
            for rec in recs:
                d = decide(led, rec)
                if not d.covered:
                    out(rec["card"])
                    out("not covered: " + ("; ".join(d.reasons) or "no record"))
                    out(f"needs user: approval — plan {rec['id']}")
                    return NEEDS_USER
                by[rec["id"]] = d.record["id"]
        else:
            groups: dict[tuple, list[dict]] = {}
            for rec in recs:   # one record per kind of request: the action, the uses per plan, warnings seen
                key = (rec["action"], max(1, int(rec.get("chain") or 0)), int(rec.get("warnings") or 0) > 0)
                groups.setdefault(key, []).append(rec)
            for (action, n, warned), members in groups.items():
                ap = grants.add(led, grants.new_approval(words, [m["block"] for m in members], actions=(action,),
                                                         launches=n, allow_warnings=warned))
                out(f"approval {ap['id']}: {grants.describe(ap)} — \"{words}\"")
                for m in members:
                    by[m["id"]] = ap["id"]
    first = OK
    quotes = {r["id"]: r["quote"] for r in led.state().grants}
    for rec in recs:
        if words is None:
            out(rec["card"])
            out(f"covered by {by[rec['id']]}: submitting")
        try:
            code = submit_plan(led, src, proj, places[rec["id"]], rec, by[rec["id"]], quotes.get(by[rec["id"]], ""),
                               ns.deadline)
        except RskError as exc:    # one plan's conflict never hides what the others did
            out(f"plan {rec['id']}: {exc}")
            code = exc.code
        first = first or code
    if len(recs) > 1:
        out(f"{len(recs)} plan(s): {'all submitted' if first == OK else 'not all submitted — see the lines above'}")
    return first


def cmd_launch(args: argparse.Namespace) -> int:
    from remote_run.status import project_dir
    extra = list(getattr(args, "extra", []) or [])
    head = extra[:extra.index("--")] if "--" in extra else extra
    if "-h" in head or "--help" in head:
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
    p = sub.add_parser("launch", add_help=False, help="plan a run on a target, then submit it with the user's words "
                       "(or a grant that covers it) — recorded in the ledger")
    p.set_defaults(func=cmd_launch, passthrough=True)
