"""What the user allowed or forbade for one project: one record type, kept in the ledger's grants.json.

Principle (the user's): no need to ask again every time, but every action checks whether an authorisation exists.
Every launch / relaunch / resubmit / chain / cancel calls check() first; only an action no record covers ends in
`needs user: approval`. A record is bookkeeping, not proof: its `quote` is what the agent wrote down as the user's
words, and an agent can write anything — the rails (show the card, wait for the user's words) are what make it the
user's decision; this file only keeps those decisions from being asked twice or stretched.

RECORD (validate() is strict: every key below present, nothing else):
  {"id": str, "kind": "approval"|"grant"|"deny", "quote": str (non-empty: the user's words),
   "created_at": iso, "created_via": "cli"|"import"|"plan-approve", "source": str (non-empty for import),
   "scope": {"targets": [..], "partitions": [..], "gpu_types": [..], "classes": [..], "names": [glob..],
             "runs": [bound_hash..], "jobs": [job id..],
             "max_gpus": int, "max_cpus": int, "max_mem_gb": num, "max_time_s": int, "allow_warnings": bool},
             (every scope key optional: absent = any; a deny takes only the list keys)
   "actions": [⊆ launch relaunch resubmit chain cancel cancel_own],
   "limits": grant: {"max_live": int|null, "max_launches": int|null, "expires": "YYYY-MM-DD"|iso|null} — all three
                    keys REQUIRED; null = the user's words set no limit (shown as "no limit (user's words)"), never
                    a value the agent made up;
             approval: {"max_launches": int (uses per listed hash; 1 = once), "max_live"?, "expires"?};
             deny: {} or {"expires": ...},
   "used": [{"nonce", "action", "hash", "job", "at"}, ...] (idempotent by nonce),
   "revoked": null | {"at", "quote"}}

The kinds:
  approval  the user approved specific plans: scope.runs = their bound hashes (one quote may cover a sweep), each hash
            usable limits.max_launches times (1; N for an approved chain of N segments). Or an explicit request to
            cancel named jobs ("cancel job 123"): actions [cancel], scope.jobs = the ids — the caller still verifies
            the job's identity (name, WorkDir, user / pid+start+boot_id) before it acts.
  grant     a standing permission (a predicate): launches in scope, within max_live / max_launches / expires.
            `cancel_own` lets the agent stop ITS OWN runs in scope (ledger attempts it launched, never adopted ones)
            at its own discretion — without it, stopping a run is the user's call. A plan with warnings > 0 (a -y
            gate: charged partition, availability, occupancy) is covered only with scope.allow_warnings = true; more
            resources than max_gpus / max_cpus / max_mem_gb / max_time_s is not covered. relaunch / resubmit are
            covered only with the ORIGINAL attempt's configuration (same bound fields; the name may differ in --aNN).
  deny      the user forbade it: a matching deny always wins (exit 3, quote shown), whatever else exists; a plan fact
            that cannot be read counts as matching.

API:
  parse_plan(text) -> dict          the one `@@plan v1` … `@@end` block of a plan reply; values as printed (%q kept)
  qwords(value) -> [str]            decode a bash %q value into words (shlex; $'…' handled); unq(value) -> str
  facts(plan) -> Facts              what a plan asks for, parsed (gpus, type, cpus, mem, time, class, warnings)
  validate(record) -> record        RskError(USAGE) listing every problem
  new_grant / new_deny / new_approval / new_cancel_approval(...) -> record (validated, not stored)
  add(led, record) -> record        store + audit (with `after_deny` when it follows a deny of the same scope)
  revoke(led, id, quote)            use(led, id, nonce, action, hash='', job='')   refund(led, id, nonce, why)
  recount(led) -> str               rebuild `used` from audit.jsonl and clear "budgets unknown"
  covers(plan, action, state, *, orig=None, job='', run='') -> (record|None, reasons)   pure
  check(ledger_or_state, action, *, plan=None, job='', run='') -> Decision(covered, record, reasons, needs)
                                    the one entry point; Decision.code = 0 | 3 (deny) | 4 (needs the user)
  describe(record) -> str           what it covers, one line;  balance(record, state) -> str;  after_deny(...)
Hold `with led.locked():` from check() to use() so two launches cannot both pass one budget.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import math
import re
import secrets
import shlex
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from remote_run import ledger as L
from remote_run.errors import NEEDS_USER, OK, REFUSED, USAGE, RskError

KINDS = ("approval", "grant", "deny")
VIA = ("cli", "import", "plan-approve")
ACTIONS = ("launch", "relaunch", "resubmit", "chain", "cancel", "cancel_own")
LAUNCHES = frozenset({"launch", "relaunch", "resubmit", "chain"})
LISTS = ("targets", "partitions", "gpu_types", "classes", "names", "runs", "jobs")
NUMS = ("max_gpus", "max_cpus", "max_mem_gb", "max_time_s")
SCOPE_KEYS = LISTS + NUMS + ("allow_warnings",)
KEYS = ("id", "kind", "quote", "created_at", "created_via", "source", "scope", "actions", "limits", "used", "revoked")
CLASSES = ("smoke", "pilot", "train", "eval", "ablate", "bench")       # experiment-conventions.md §1
GRANT_LIMITS = ("max_live", "max_launches", "expires")
NO_LIMIT = "no limit (user's words)"
FLAG_WINDOW_S = 3600            # a grant created (or a deny revoked) within this long after a deny is flagged
HEX64 = re.compile(r"[0-9a-f]{64}")
SLURM_BOUND = ("partition", "gres", "cpus", "mem", "time", "account", "name", "extra", "payload", "env_kind",
               "env_name", "wandb_mode", "chain")
NOHUP_BOUND = ("name", "gpus_req", "exclude", "nice", "payload", "env_kind", "env_name")


# ================================================================================================ the plan block
class PlanError(RskError):
    def __init__(self, message: str) -> None:
        super().__init__(f"plan block: {message}", USAGE)


_KEY = re.compile(r"[a-z][a-z0-9_]*")
_ANSI = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v",
         "\\": "\\", "'": "'", '"': '"', "?": "?"}


def parse_plan(text: str) -> dict[str, str]:
    """The `@@plan v1` block of TEXT (a plan reply also carries the submit's other output: ignored). Strict: exactly
    one block, ended by `@@end`, `key=value` lines with unique lowercase keys, api/kind/target/warnings/bound_hash
    present, and bound_hash = sha256 of the printed bound lines (`kind=` … `chain=` for Slurm, … `env_name=` for
    nohup, each + newline: remote/submit.sh and launch.sh rs_bound). Values are kept as printed (bash %q: decode
    them with qwords()/unq()). Nothing is evaluated."""
    lines = text.splitlines()
    starts = [i for i, ln in enumerate(lines) if ln == "@@plan v1"]
    if not starts:
        raise PlanError("no '@@plan v1' line (a deploy without plan mode: sync first)")
    if len(starts) > 1:
        raise PlanError(f"{len(starts)} '@@plan v1' blocks in one reply")
    out: dict[str, str] = {}
    body: list[str] = []
    for ln in lines[starts[0] + 1:]:
        if ln == "@@end":
            break
        key, eq, value = ln.partition("=")
        if not eq or not _KEY.fullmatch(key):
            raise PlanError(f"not a key=value line: {ln[:120]!r}")
        if key in out:
            raise PlanError(f"key {key!r} twice")
        out[key] = value
        body.append(ln)
    else:
        raise PlanError("no '@@end' (the reply was cut off)")
    missing = [k for k in ("api", "kind", "target", "warnings", "bound_hash") if k not in out]
    if missing:
        raise PlanError(f"missing {', '.join(missing)}")
    if out["kind"] not in ("slurm", "nohup"):
        raise PlanError(f"kind={out['kind']!r}")
    if not HEX64.fullmatch(out["bound_hash"]):
        raise PlanError("bound_hash is not 64 lowercase hex digits")
    if not out["warnings"].isdigit():
        raise PlanError(f"warnings={out['warnings']!r} is not a count")
    keys = [ln.partition("=")[0] for ln in body]
    last = "chain" if out["kind"] == "slurm" else "env_name"
    if keys.count("kind") != 1 or last not in keys or keys.index(last) < keys.index("kind"):
        raise PlanError(f"no bound list kind= … {last}=")
    bound_lines = body[keys.index("kind"):keys.index(last) + 1]
    if hashlib.sha256(("\n".join(bound_lines) + "\n").encode("utf-8")).hexdigest() != out["bound_hash"]:
        raise PlanError("bound_hash does not match the printed bound fields (a damaged reply, or another format)")
    return out


def _ansi(body: str) -> str:
    """The inside of a bash $'…' segment. Octal/hex escapes are BYTES (bash in the C locale prints UTF-8 text as
    \\303\\257): collected, then decoded as UTF-8."""
    out, i = bytearray(), 0
    while i < len(body):
        c = body[i]
        if c != "\\" or i + 1 >= len(body):
            out += c.encode("utf-8")
            i += 1
            continue
        n = body[i + 1]
        m = (re.match(r"[0-7]{1,3}", body[i + 1:]) if n in "01234567" else
             re.match(r"[0-9A-Fa-f]{1,2}", body[i + 2:]) if n == "x" else
             re.match(r"[0-9A-Fa-f]{1,4}", body[i + 2:]) if n == "u" else
             re.match(r"[0-9A-Fa-f]{1,8}", body[i + 2:]) if n == "U" else None)
        if n in _ANSI:
            out += _ANSI[n].encode("utf-8")
            i += 2
        elif m and n in "01234567":
            out.append(int(m.group(0), 8) & 0xFF)
            i += 1 + len(m.group(0))
        elif m and n == "x":
            out.append(int(m.group(0), 16))
            i += 2 + len(m.group(0))
        elif m and n in "uU":
            out += chr(int(m.group(0), 16)).encode("utf-8", "replace")
            i += 2 + len(m.group(0))
        else:
            out += ("\\" + n).encode("utf-8")
            i += 2
    return out.decode("utf-8", "replace")


def qwords(value: str) -> list[str]:
    """Words of a bash `printf %q` value (backslash escapes, '' and $'…' segments). Never evaluated."""
    if "$'" in value:   # shlex has no $'…': rewrite each segment as a single-quoted one, outside other quotes
        buf, i, q = [], 0, ""
        while i < len(value):
            c = value[i]
            if q:
                buf.append(c)
                if c == q:
                    q = ""
                elif c == "\\" and q == '"' and i + 1 < len(value):
                    buf.append(value[i + 1])
                    i += 1
                i += 1
            elif c == "\\" and i + 1 < len(value):
                buf.append(value[i:i + 2])
                i += 2
            elif c in "'\"":
                q = c
                buf.append(c)
                i += 1
            elif value.startswith("$'", i):
                j, body = i + 2, []
                while j < len(value) and value[j] != "'":
                    body.append(value[j:j + 2] if value[j] == "\\" else value[j])
                    j += 2 if value[j] == "\\" else 1
                if j >= len(value):
                    raise PlanError(f"unterminated $'…' in {value[:80]!r}")
                buf.append(shlex.quote(_ansi("".join(body))))
                i = j + 1
            else:
                buf.append(c)
                i += 1
        value = "".join(buf)
    try:
        return shlex.split(value, posix=True)
    except ValueError as exc:
        raise PlanError(f"cannot decode {value[:80]!r}: {exc}") from exc


def unq(value: str) -> str:
    w = qwords(value)
    if len(w) > 1:
        raise PlanError(f"{value[:80]!r} is several words, not one value")
    return w[0] if w else ""


# ================================================================================================ plan facts
@dataclass(frozen=True)
class Facts:
    target: str = ""
    kind: str = ""
    name: str = ""
    run: str = ""
    partition: str | None = None       # None: no partition (nohup) or unreadable
    gpu_type: str | None = None        # 'any' = none requested, '' = no GPU, None = unknown
    gpus: int | None = None
    cpus: int | None = None
    mem_gb: float | None = None        # math.inf = unbounded (--mem=0, or no limit at all)
    time_s: float | None = None        # math.inf = unlimited (a nohup run has no time limit)
    cls: str | None = None
    bound_hash: str = ""
    warnings: int | None = None
    unreadable: tuple[str, ...] = field(default=())


def slurm_seconds(t: str) -> float:
    """sbatch --time: minutes, minutes:seconds, hours:minutes:seconds, days-hours, days-hours:minutes,
    days-hours:minutes:seconds (sbatch(1)); UNLIMITED/INFINITE = inf. ValueError otherwise."""
    t = t.strip()
    if t.upper() in ("UNLIMITED", "INFINITE"):
        return math.inf
    m = re.fullmatch(r"(?:([0-9]+)-)?([0-9]+)(?::([0-9]+))?(?::([0-9]+))?", t)
    if not m:
        raise ValueError(f"not a Slurm time: {t!r}")
    d, a, b, c = (int(x) if x is not None else None for x in m.groups())
    if d is not None:
        return d * 86400 + a * 3600 + (b or 0) * 60 + (c or 0)
    if c is not None:
        return a * 3600 + b * 60 + c
    if b is not None:
        return a * 60 + b
    return a * 60


def slurm_mem_gb(m: str) -> float:
    """sbatch --mem: a number with an optional K|M|G|T suffix, megabytes without one (sbatch(1)); 0 = all of the
    node's memory (inf here). ValueError otherwise."""
    g = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([KMGTkmgt]?)[Bb]?", m.strip())
    if not g:
        raise ValueError(f"not a Slurm memory size: {m!r}")
    n = float(g.group(1))
    if n == 0:
        return math.inf
    return n * {"K": 1 / 1048576, "M": 1 / 1024, "": 1 / 1024, "G": 1.0, "T": 1024.0}[g.group(2).upper()]


def _gres(g: str) -> tuple[str, int]:
    g = g.removeprefix("--gres=")
    if not g:
        return "", 0
    for part in g.split(","):
        f = part.split(":")
        if f[0] != "gpu":
            continue
        if len(f) == 1:
            return "any", 1
        if len(f) == 2 and f[1].isdigit():
            return "any", int(f[1])
        if len(f) == 3 and f[2].isdigit():
            return f[1], int(f[2])
        raise ValueError(f"gres {g!r}")
    return "", 0


def facts(plan: dict) -> Facts:
    bad: list[str] = []

    def get(key: str) -> str | None:
        try:
            return unq(str(plan[key])) if key in plan else None
        except RskError:
            bad.append(key)
            return None

    kind, name = str(plan.get("kind", "")), get("name") or ""
    cls = plan.get("class") or None
    if cls is None:
        f = name.split("--")
        cls = f[1] if len(f) > 1 and f[1] in CLASSES else None
    w = str(plan.get("warnings", ""))
    common = dict(target=str(plan.get("target", "")), kind=kind, name=name, run=L.run_id(name) if name else "",
                  cls=cls, bound_hash=str(plan.get("bound_hash", "")), warnings=int(w) if w.isdigit() else None)
    if kind == "nohup":
        req = get("gpus_req") or ""
        gpus = None
        if req.startswith("n=") and req[2:].isdigit():
            gpus = int(req[2:])
        elif req.startswith("ids=") and re.fullmatch(r"[0-9]+(,[0-9]+)*", req[4:]):
            gpus = len(req[4:].split(","))
        elif req:
            bad.append("gpus_req")
        return Facts(**common, gpus=gpus, time_s=math.inf, mem_gb=math.inf, unreadable=tuple(bad))
    part = get("partition") or None
    gt, gn = None, None
    gres = get("gres")
    if gres is not None:
        try:
            gt, gn = _gres(gres)
        except ValueError:
            bad.append("gres")
    cpus = get("cpus")
    cpus_n = int(cpus) if cpus and cpus.isdigit() else None
    mem, t = get("mem"), get("time")
    try:
        mem_gb = slurm_mem_gb(mem) if mem else None
    except ValueError:
        mem_gb, _ = None, bad.append("mem")
    try:
        time_s = slurm_seconds(t) if t else None
    except ValueError:
        time_s, _ = None, bad.append("time")
    return Facts(**common, partition=part, gpu_type=gt, gpus=gn, cpus=cpus_n, mem_gb=mem_gb, time_s=time_s,
                 unreadable=tuple(bad))


def bound(plan: dict) -> dict[str, str]:
    keys = SLURM_BOUND if plan.get("kind") == "slurm" else NOHUP_BOUND
    return {k: str(plan.get(k, "")) for k in keys}


def same_config(orig: dict, plan: dict) -> list[str]:
    """[] when PLAN repeats the original attempt's configuration: same target, kind and bound fields; the name may
    differ only in its --aNN. Else the differences."""
    if orig.get("bound_hash") and orig.get("bound_hash") == plan.get("bound_hash"):
        return []
    diff = []
    for k in ("target", "kind"):
        if str(orig.get(k, "")) != str(plan.get(k, "")):
            diff.append(f"{k} {orig.get(k)!r} -> {plan.get(k)!r}")
    a, b = orig.get("bound") or {}, bound(plan)
    for k in sorted(set(a) | set(b)):
        va, vb = str(a.get(k, "")), str(b.get(k, ""))
        if k == "name":
            try:
                if L.run_id(unq(va)) != L.run_id(unq(vb)):
                    diff.append(f"name {va!r} -> {vb!r} (another run)")
            except RskError:
                diff.append("name unreadable")
        elif va != vb:
            diff.append(f"{k} {va[:60]!r} -> {vb[:60]!r}")
    return diff


# ================================================================================================ records
def new_id(kind: str) -> str:
    prefix = {"grant": "g", "deny": "d", "approval": "ap"}[kind]
    return f"{prefix}-{datetime.now(UTC).strftime('%Y%m%d')}-{secrets.token_hex(3)}"


def _expires_at(v: Any) -> float:
    """'YYYY-MM-DD' = through the end of that day (local time); an iso instant = that instant."""
    s = str(v)
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", s):
        d = datetime.strptime(s, "%Y-%m-%d") + timedelta(days=1)
        return time.mktime(d.timetuple())
    t = L.epoch(s)
    if not t:
        raise ValueError(s)
    return t


def validate(rec: Any) -> dict:
    """Raise RskError(USAGE) listing every problem; return REC unchanged when it is a valid record."""
    errs: list[str] = []
    if not isinstance(rec, dict):
        raise RskError("a grant record must be a JSON object", USAGE)
    rid = rec.get("id", "?")
    extra = sorted(set(rec) - set(KEYS))
    if extra:
        errs.append(f"unknown key(s) {', '.join(extra)}")
    missing = [k for k in KEYS if k not in rec]
    if missing:
        errs.append(f"missing {', '.join(missing)}")
    kind = rec.get("kind")
    if "id" in rec and not (isinstance(rid, str) and L.NONCE_RE.fullmatch(rid)):
        errs.append(f"id {rid!r} must match {L.NONCE_RE.pattern}")
    if "kind" in rec and kind not in KINDS:
        errs.append(f"kind {kind!r} (one of {', '.join(KINDS)})")
    if "quote" in rec and not (isinstance(rec["quote"], str) and rec["quote"].strip()):
        errs.append("quote must be the user's words (non-empty)")
    if "created_at" in rec and not L.epoch(rec["created_at"]):
        errs.append(f"created_at {rec['created_at']!r} is not YYYY-MM-DDTHH:MM:SSZ")
    if "created_via" in rec and rec["created_via"] not in VIA:
        errs.append(f"created_via {rec['created_via']!r} (one of {', '.join(VIA)})")
    if "source" in rec and not isinstance(rec["source"], str):
        errs.append("source must be a string")
    if rec.get("created_via") == "import" and not str(rec.get("source", "")).strip():
        errs.append("an imported record names its source (where the user's words were found)")
    scope = rec.get("scope")
    acts = rec.get("actions")
    if "scope" in rec:
        if not isinstance(scope, dict):
            errs.append("scope must be an object")
            scope = {}
        else:
            for k in sorted(set(scope) - set(SCOPE_KEYS)):
                errs.append(f"unknown scope key {k!r}")
            for k in LISTS:
                if k in scope and not (isinstance(scope[k], list) and all(isinstance(x, str) and x for x in scope[k])):
                    errs.append(f"scope.{k} must be a list of non-empty strings")
            for x in scope.get("runs") or []:
                if isinstance(x, str) and not HEX64.fullmatch(x):
                    errs.append(f"scope.runs: {x[:20]!r} is not a bound hash (64 hex)")
            for k in NUMS:
                v = scope.get(k)
                if k in scope and (isinstance(v, bool) or not isinstance(v, (int, float)) or v <= 0
                                   or (k != "max_mem_gb" and not isinstance(v, int))):
                    errs.append(f"scope.{k} must be a positive {'number' if k == 'max_mem_gb' else 'integer'}")
            if "allow_warnings" in scope and not isinstance(scope["allow_warnings"], bool):
                errs.append("scope.allow_warnings must be true or false")
    else:
        scope = {}
    if "actions" in rec:
        if not (isinstance(acts, list) and acts and all(a in ACTIONS for a in acts) and len(set(acts)) == len(acts)):
            errs.append(f"actions must be a non-empty list of distinct {', '.join(ACTIONS)}")
            acts = []
    else:
        acts = []
    limits = rec.get("limits")
    if "limits" in rec and not isinstance(limits, dict):
        errs.append("limits must be an object")
        limits = {}
    limits = limits or {}
    if kind == "grant":
        if "cancel" in acts:
            errs.append("a standing grant takes cancel_own (its own runs); cancelling named jobs is an approval")
        if scope.get("jobs"):
            errs.append("scope.jobs belongs to a cancel approval, not a standing grant")
        for k in GRANT_LIMITS:
            if k not in limits:
                errs.append(f"limits.{k} is required for a standing grant: the user's value, or null (none) when "
                            "their words set no limit — never left out, never made up")
        for k in sorted(set(limits) - set(GRANT_LIMITS)):
            errs.append(f"unknown limit {k!r}")
    elif kind == "approval":
        if acts and set(acts) <= LAUNCHES:
            if not scope.get("runs"):
                errs.append("an approval of plans lists their bound hashes in scope.runs")
        elif acts == ["cancel"]:
            if not scope.get("jobs"):
                errs.append("a cancel approval names the job(s) in scope.jobs")
        elif acts:
            errs.append("an approval covers launches of approved plans or cancel of named jobs, not both")
        v = limits.get("max_launches")
        if isinstance(v, bool) or not isinstance(v, int) or v < 1:
            errs.append("an approval's limits.max_launches is the uses per approved plan (>= 1)")
        for k in sorted(set(limits) - set(GRANT_LIMITS)):
            errs.append(f"unknown limit {k!r}")
    elif kind == "deny":
        for k in NUMS + ("allow_warnings",):
            if k in scope:
                errs.append(f"a deny takes targets/partitions/gpu_types/classes/names/runs/jobs, not {k} (resource "
                            "caps are a grant's scope, or the target's policy.local.sh)")
        for k in sorted(set(limits) - {"expires"}):
            errs.append(f"a deny's limits take only expires, not {k}")
    for k in ("max_live", "max_launches"):
        v = limits.get(k)
        if v is not None and (isinstance(v, bool) or not isinstance(v, int) or v < 1):
            errs.append(f"limits.{k} must be a positive integer or null (no limit)")
    if limits.get("expires") is not None:
        try:
            _expires_at(limits["expires"])
        except ValueError:
            errs.append(f"limits.expires {limits['expires']!r} is not YYYY-MM-DD, YYYY-MM-DDTHH:MM:SSZ or null")
    used = rec.get("used")
    if "used" in rec:
        if not isinstance(used, list) or not all(isinstance(u, dict) and isinstance(u.get("nonce"), str) for u in used):
            errs.append("used must be a list of {nonce, action, hash, job, at}")
        elif len({u["nonce"] for u in used}) != len(used):
            errs.append("used lists a nonce twice")
    rv = rec.get("revoked")
    if "revoked" in rec and rv is not None and not (isinstance(rv, dict) and str(rv.get("quote", "")).strip()
                                                    and L.epoch(rv.get("at"))):
        errs.append("revoked must be null or {at, quote}")
    if errs:
        raise RskError(f"grant record {rid}: " + "; ".join(errs), USAGE)
    return rec


def _record(kind: str, quote: str, scope: dict, actions: list[str], limits: dict, via: str, source: str) -> dict:
    return validate({"id": new_id(kind), "kind": kind, "quote": quote, "created_at": L.now(), "created_via": via,
                     "source": source, "scope": {k: v for k, v in scope.items() if v not in (None, [], ())},
                     "actions": list(actions), "limits": limits, "used": [], "revoked": None})


def new_grant(quote: str, scope: dict, actions: list[str], *, max_live: int | None, max_launches: int | None,
              expires: str | None, via: str = "cli", source: str = "") -> dict:
    return _record("grant", quote, scope, actions,
                   {"max_live": max_live, "max_launches": max_launches, "expires": expires}, via, source)


def new_deny(quote: str, scope: dict, actions: list[str] | None = None, *, expires: str | None = None,
             via: str = "cli", source: str = "") -> dict:
    return _record("deny", quote, scope, list(actions or ACTIONS), {} if expires is None else {"expires": expires},
                   via, source)


def new_approval(quote: str, plans: list[dict], *, actions: tuple[str, ...] = ("launch",), launches: int = 1,
                 allow_warnings: bool = False, via: str = "plan-approve", source: str = "") -> dict:
    """The user approved these plans (parsed blocks; one quote may cover a sweep): each bound hash `launches` times.
    allow_warnings: the approved cards showed warnings the user saw."""
    hashes = list(dict.fromkeys(str(p["bound_hash"]) for p in plans))
    targets = sorted({str(p.get("target", "")) for p in plans} - {""})
    return _record("approval", quote, {"runs": hashes, "targets": targets, "allow_warnings": allow_warnings},
                   list(actions), {"max_launches": launches, "max_live": None, "expires": None}, via, source)


def new_cancel_approval(quote: str, target: str, jobs: list[str], *, via: str = "cli", source: str = "") -> dict:
    """An explicit user request to cancel these jobs: covers `cancel` of exactly them (identity checked by the caller)."""
    return _record("approval", quote, {"jobs": [str(j) for j in jobs], "targets": [target] if target else []},
                   ["cancel"], {"max_launches": 1, "max_live": None, "expires": None}, via, source)


# ================================================================================================ the store
def load(led: L.Ledger) -> tuple[dict, L.Loaded]:
    got = led.grants()
    if got.source == "corrupt":
        raise RskError(f"grants unreadable: {got.why} — move {led.dir / 'grants.json'} aside (its .prev too) and "
                       "re-import the user's authorisations", USAGE)
    doc = got.data or {"version": 1, "records": [], "budgets_unknown": None}
    if got.recovered and not doc.get("budgets_unknown"):   # the records .prev holds may have lost uses
        doc = {**doc, "budgets_unknown": {"at": L.now(), "why": got.why,
                                          "ids": [r.get("id") for r in doc.get("records") or []]}}
    return doc, got


def _save(led: L.Ledger, doc: dict, got: L.Loaded) -> None:
    if got.recovered:
        led.audit("recovered", file="grants.json", why=got.why)
    led.write_grants(doc)


def _find(doc: dict, rid: str) -> dict:
    for r in doc["records"]:
        if r.get("id") == rid:
            return r
    raise RskError(f"no grant record {rid!r} (rsk grant list --all)", USAGE)


def add(led: L.Ledger, rec: dict) -> dict:
    validate(rec)
    with led.locked():
        doc, got = load(led)
        if any(r.get("id") == rec["id"] for r in doc["records"]):
            raise RskError(f"grant record {rec['id']} exists already", USAGE)
        flags = after_deny(rec, doc["records"])
        doc["records"].append(rec)
        led.audit(f"grant_{rec['kind']}", id=rec["id"], created_via=rec["created_via"], source=rec["source"],
                  quote=rec["quote"], scope=rec["scope"], actions=rec["actions"], limits=rec["limits"],
                  **({"after_deny": flags} if flags else {}))
        _save(led, doc, got)
    return rec


def revoke(led: L.Ledger, rid: str, quote: str) -> dict:
    if not quote.strip():
        raise RskError("revoke takes the user's words (--quote)", USAGE)
    with led.locked():
        doc, got = load(led)
        r = _find(doc, rid)
        if r.get("revoked"):
            raise RskError(f"{rid} was revoked at {r['revoked'].get('at')}", USAGE)
        r["revoked"] = {"at": L.now(), "quote": quote}
        led.audit("grant_revoke", id=rid, quote=quote)
        _save(led, doc, got)
        return r


def use(led: L.Ledger, rid: str, nonce: str, action: str, hash: str = "", job: str = "") -> bool:
    """Count one use of RID by NONCE (idempotent: the same nonce again changes nothing; returns False). The audit
    line goes first, so audit.jsonl always holds every use (what recount() rebuilds from)."""
    with led.locked():
        doc, got = load(led)
        r = _find(doc, rid)
        if any(u.get("nonce") == nonce for u in r["used"]):
            return False
        entry = {"nonce": nonce, "action": action, "hash": hash, "job": job, "at": L.now()}
        led.audit("grant_used", id=rid, **entry)
        r["used"].append(entry)
        _save(led, doc, got)
        return True


def refund(led: L.Ledger, rid: str, nonce: str, why: str) -> bool:
    """Give back a use whose submit provably did not happen (verdict refused, or the user's not-submitted)."""
    with led.locked():
        doc, got = load(led)
        r = _find(doc, rid)
        keep = [u for u in r["used"] if u.get("nonce") != nonce]
        if len(keep) == len(r["used"]):
            return False
        led.audit("grant_refund", id=rid, nonce=nonce, why=why)
        r["used"] = keep
        _save(led, doc, got)
        return True


def recount(led: L.Ledger) -> str:
    """Rebuild every record's `used` from audit.jsonl (uses minus refunds, in order) and clear "budgets unknown"
    — on grants.json and on every recovered run record. A use the audit holds is never dropped."""
    with led.locked():
        doc, got = load(led)
        recs, bad = led.read_audit()
        uses: dict[str, dict[str, dict]] = {}
        for a in recs:
            if a.get("event") == "grant_used" and a.get("id") and a.get("nonce"):
                uses.setdefault(a["id"], {})[a["nonce"]] = {k: a.get(k, "") for k in ("nonce", "action", "hash",
                                                                                       "job", "at")}
            elif a.get("event") == "grant_refund" and a.get("id"):
                uses.get(a["id"], {}).pop(a.get("nonce"), None)
        added = 0
        for r in doc["records"]:
            have = {u.get("nonce") for u in r["used"]}
            for n, u in uses.get(r["id"], {}).items():
                if n not in have:
                    r["used"].append(u)
                    added += 1
        if bad:
            note = f"audit.jsonl has {bad} unreadable line(s): budgets stay unknown"
            doc["budgets_unknown"] = {"at": L.now(), "why": note, "ids": [r.get("id") for r in doc["records"]]}
        else:
            doc["budgets_unknown"] = None
            note = "budgets known again"
        cleared = []
        for run, g in led.runs().items():
            if g.data and (g.data.get("recovered") or g.recovered):
                led.update_run(run, lambda rec: rec.update(recovered=None))
                cleared.append(run)
        led.audit("recount", added=added, bad_lines=bad, runs_cleared=cleared)
        led.write_grants(doc)
        return (f"{added} use(s) restored from the audit; {note}"
                + (f"; run record(s) {', '.join(cleared)} trusted again — any job they lost shows as UNLEDGERED in "
                   "rsk status" if cleared else ""))


def import_file(led: L.Ledger, path: Path) -> list[dict]:
    """A JSON list of records the user's existing authorisations were written as (memory notes, a conf comment).
    Every user-facing field must be in the file; only id / created_at / used / revoked may be left for rsk."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RskError(f"{path}: cannot read a JSON list: {exc}", USAGE) from exc
    if not isinstance(data, list) or not data:
        raise RskError(f"{path}: expected a non-empty JSON list of records", USAGE)
    out, errs = [], []
    for i, raw in enumerate(data):
        if not isinstance(raw, dict):
            errs.append(f"#{i}: not an object")
            continue
        if raw.get("created_via", "import") != "import":
            errs.append(f"#{i}: created_via must be import (or absent)")
            continue
        rec = {"created_via": "import", "used": [], "revoked": None, **raw}
        rec.setdefault("id", new_id(str(raw.get("kind", "grant")) if raw.get("kind") in KINDS else "grant"))
        rec.setdefault("created_at", L.now())
        try:
            out.append(validate(rec))
        except RskError as exc:
            errs.append(f"#{i}: {exc}")
    if errs:
        raise RskError(f"{path}: nothing imported — " + " | ".join(errs), USAGE)
    with led.locked():
        doc, got = load(led)
        ids = {r.get("id") for r in doc["records"]}
        clash = [r["id"] for r in out if r["id"] in ids] + [r["id"] for i, r in enumerate(out) if r["id"] in
                                                            {x["id"] for x in out[:i]}]
        if clash:
            raise RskError(f"{path}: nothing imported — id(s) exist already: {', '.join(clash)}", USAGE)
        for rec in out:
            flags = after_deny(rec, doc["records"])
            doc["records"].append(rec)
            led.audit(f"grant_{rec['kind']}", id=rec["id"], created_via="import", source=rec["source"],
                      quote=rec["quote"], scope=rec["scope"], actions=rec["actions"], limits=rec["limits"],
                      **({"after_deny": flags} if flags else {}))
        _save(led, doc, got)
    return out


# ================================================================================================ the decision
def _expired(rec: dict, t: float) -> bool:
    e = (rec.get("limits") or {}).get("expires")
    try:
        return e is not None and t > _expires_at(e)
    except ValueError:            # a hand-edited, unreadable date: expired, never open-ended
        return True


def _glob(names: list[str], name: str) -> bool:
    return any(fnmatch.fnmatchcase(name, g) for g in names)


def _scope_misses(scope: dict, f: Facts, deny: bool) -> list[str]:
    """Allow (deny=False): why F is outside SCOPE ([] = inside; a fact that cannot be read is outside).
    Deny: [] when F may be inside (a fact that cannot be read counts as inside)."""
    miss: list[str] = []

    def lst(key: str, have: str | None, label: str, na: bool = False) -> None:
        want = scope.get(key) or []
        if not want:
            return
        if have is None:
            if deny and not na:
                return
            miss.append(f"{label} not known" if not na else f"no {label}")
            return
        if have not in want:
            miss.append(f"{label} {have or '-'} not in {', '.join(want)}")

    lst("targets", f.target or None, "target")
    lst("partitions", f.partition, "partition", na=f.kind == "nohup")
    want_t = [x.lower() for x in scope.get("gpu_types") or []]
    if want_t:
        t = f.gpu_type
        if t is None or t == "any":
            if not deny:
                miss.append("GPU type " + ("not known" if t is None else "not requested (any type may be placed)"))
        elif t == "":
            if not deny:
                miss.append("no GPU requested (the scope names GPU types)")
            else:
                miss.append("no GPU")
        elif t.lower() not in want_t:
            miss.append(f"GPU type {t} not in {', '.join(scope['gpu_types'])}")
    lst("classes", f.cls, "class")
    names = scope.get("names") or []
    if names and not (f.name and _glob(names, f.name)):
        if not (deny and not f.name):
            miss.append(f"name {f.name or '?'} matches none of {', '.join(names)}")
    runs = scope.get("runs") or []
    if runs and f.bound_hash not in runs:
        miss.append("not one of the approved plans (bound hash differs)")
    if not deny:
        for key, have, label, show in (("max_gpus", f.gpus, "GPUs", str), ("max_cpus", f.cpus, "CPUs", str),
                                       ("max_mem_gb", f.mem_gb, "GB memory", lambda v: f"{v:g}"),
                                       ("max_time_s", f.time_s, "time", _dur)):
            cap = scope.get(key)
            if cap is None:
                continue
            if have is None:
                miss.append(f"{label} not known (the scope caps them at {show(cap)})")
            elif have > cap:
                miss.append(f"{'unlimited' if have == math.inf else show(have)} {label} > {show(cap)}")
        if f.warnings is None or f.warnings > 0:
            if not scope.get("allow_warnings"):
                miss.append(f"the plan has {f.warnings if f.warnings is not None else 'unknown'} warning(s) (a -y "
                            "gate: charged partition, availability, occupancy) — needs the user unless the scope "
                            "allows warnings")
        if f.unreadable:
            miss.append(f"unreadable plan field(s): {', '.join(f.unreadable)}")
    return miss


def _dur(s: float) -> str:
    if s == math.inf:
        return "unlimited"
    s = int(s)
    d, r = divmod(s, 86400)
    return f"{d}-{r // 3600:02d}:{r % 3600 // 60:02d}:{r % 60:02d}" if d else f"{r // 3600}:{r % 3600 // 60:02d}:{r % 60:02d}"


def live_under(rid: str, state: L.LedgerState) -> int:
    return sum(1 for rec in state.runs.values() for a in (rec.get("attempts") or {}).values()
               if (a.get("request") or {}).get("grant") == rid and L.is_live(a))


def launches_used(rec: dict) -> int:
    return sum(1 for u in rec.get("used") or [] if u.get("action") in LAUNCHES)


def _deny_actions(action: str) -> set[str]:
    return {"cancel", "cancel_own"} if action == "cancel" else {action}


def covers(plan: dict, action: str, state: L.LedgerState, *, orig: dict | None = None, job: str = "",
           own: bool = False) -> tuple[dict | None, list[str]]:
    """Pure. (deny record, [why]) when a deny matches — it wins; (record, []) for the first approval, then standing
    grant, that covers ACTION of PLAN; (None, reasons) otherwise. ORIG = the original attempt's request (relaunch /
    resubmit must repeat it); JOB / OWN for cancel (OWN: the run is one rsk launched for this project)."""
    if action not in ACTIONS:
        raise RskError(f"action {action!r} (one of {', '.join(ACTIONS)})", USAGE)
    t = time.time() if state.now is None else state.now
    f = facts(plan or {})
    recs = [r for r in state.grants if not r.get("revoked")]
    own_denied: dict | None = None
    for d in (r for r in recs if r.get("kind") == "deny"):
        acts = set(d.get("actions") or ACTIONS)
        if _expired(d, t) or not (_deny_actions(action) & acts):
            continue
        sc = d.get("scope") or {}
        jobs = sc.get("jobs") or []
        if jobs and job not in jobs:
            continue
        if _scope_misses({k: v for k, v in sc.items() if k != "jobs"}, f, deny=True):
            continue
        if action == "cancel" and "cancel" not in acts:
            own_denied = own_denied or d     # cancel_own only: the agent's own discretion is off, the user's named
            continue                         # cancels (approvals) still stand
        return d, [f"denied by {d['id']}: \"{d['quote']}\""]
    reasons: list[str] = []
    order = sorted((r for r in recs if r.get("kind") in ("approval", "grant")),
                   key=lambda r: (r.get("kind") != "approval", str(r.get("created_at", ""))))
    for r in order:
        why = _misses(r, plan or {}, f, action, state, t, orig, job, own and own_denied is None)
        if own_denied is not None and r.get("kind") == "grant" and action == "cancel":
            why = [f"cancel_own is denied by {own_denied['id']}: \"{own_denied['quote']}\""]
        if not why:
            return r, []
        reasons.append(f"{r['id']}: {'; '.join(why)}")
    if not order:
        reasons.append("no approval or grant recorded for this project")
    return None, reasons


def _misses(r: dict, plan: dict, f: Facts, action: str, state: L.LedgerState, t: float, orig: dict | None,
            job: str, own: bool) -> list[str]:
    acts = r.get("actions") or []
    sc, lim = r.get("scope") or {}, r.get("limits") or {}
    if _expired(r, t):
        return [f"expired {lim.get('expires')}"]
    if state.affected(r):
        return [f"budgets unknown ({state.budgets_unknown[:160]}) — rsk grant recount"]
    if action == "cancel":
        if r["kind"] == "approval":
            if "cancel" not in acts:
                return ["not a cancel approval"]
            if job not in (sc.get("jobs") or []):
                return [f"names job(s) {', '.join(sc.get('jobs') or [])}, not {job or '?'}"]
            if any(u.get("job") == job for u in r.get("used") or []):
                return [f"job {job} was cancelled under it already"]
            if sc.get("targets") and f.target and f.target not in sc["targets"]:
                return [f"target {f.target} not in {', '.join(sc['targets'])}"]
            return []
        if "cancel_own" not in acts:
            return ["no cancel_own in its actions"]
        if not own:
            return ["the run is not one rsk launched for this project (cancel_own covers only the agent's own runs)"]
        return [m for m in _scope_misses({k: v for k, v in sc.items() if k not in NUMS + ("allow_warnings",)}, f,
                                         deny=False)]
    if action not in acts:
        return [f"action {action} not in {', '.join(acts)}"]
    if r["kind"] == "approval":
        miss = _scope_misses(sc, f, deny=False)
        if not miss:
            n = sum(1 for u in r.get("used") or [] if u.get("hash") == f.bound_hash)
            if n >= int(lim.get("max_launches") or 1):
                miss.append(f"this plan was used {n} time(s) under it already")
            ml = lim.get("max_live")
            if ml is not None and live_under(r["id"], state) >= ml:
                miss.append(f"{live_under(r['id'], state)} of {ml} live runs under it")
    else:
        miss = _scope_misses(sc, f, deny=False)
        if action in ("relaunch", "resubmit"):
            if not orig or not (orig.get("bound") or orig.get("bound_hash")):
                miss.append("the original attempt has no recorded plan (adopted?): the user decides")
            else:
                diff = same_config(orig, plan)
                if diff:
                    miss.append("not the original configuration: " + "; ".join(diff[:4]))
        mx = lim.get("max_launches")
        if mx is not None and launches_used(r) >= mx:
            miss.append(f"used {launches_used(r)} of {mx} launches")
        ml = lim.get("max_live")
        if ml is not None and live_under(r["id"], state) >= ml:
            miss.append(f"{live_under(r['id'], state)} of {ml} live runs under it")
    return miss


@dataclass
class Decision:
    covered: bool
    record: dict | None
    reasons: list[str]
    needs: str                         # '' when covered or denied; else what only the user can decide

    @property
    def denied(self) -> bool:
        return bool(self.record) and self.record.get("kind") == "deny"

    @property
    def code(self) -> int:
        return OK if self.covered else REFUSED if self.denied else NEEDS_USER


def _original(state: L.LedgerState, run: str, plan: dict) -> dict | None:
    rec = state.runs.get(run) or {}
    atts = rec.get("attempts") or {}
    if not atts:
        return None
    name = ""
    try:
        name = unq(str(plan.get("name", "")))
    except RskError:
        pass
    same = [a for a in atts.values() if a.get("name") == name]
    pick = same[-1] if same else atts[sorted(atts, key=lambda k: int(k[1:]) if k[1:].isdigit() else 0)[-1]]
    req = dict(pick.get("request") or {})
    return {**req, "target": pick.get("target", ""), "kind": pick.get("kind", "")}


def check(ledger: L.Ledger | L.LedgerState, action: str, *, plan: dict | None = None, job: str = "", run: str = "",
          now: float | None = None) -> Decision:
    """The one entry point: may ACTION happen without asking the user again?
    launch / chain: plan=parsed block (+ optional "class"). relaunch / resubmit: plan + run=<run id> (the original
    attempt's configuration must be repeated). cancel: job=<id> (+ run=<run id> for cancel_own, plan={"target": t}
    when the run is not in the ledger)."""
    state = ledger.state(now) if isinstance(ledger, L.Ledger) else ledger
    if now is not None:
        state.now = now
    if action in LAUNCHES and not plan:
        raise RskError(f"check({action}) needs the plan", USAGE)
    orig, own, facts_plan = None, False, dict(plan or {})
    if action in ("relaunch", "resubmit"):
        if not run:
            raise RskError(f"check({action}) needs the run id", USAGE)
        orig = _original(state, run, facts_plan)
    if action == "cancel":
        if not job:
            raise RskError("check(cancel) needs the job id (or the nohup pid)", USAGE)
        for a in ((state.runs.get(run) or {}).get("attempts") or {}).values():
            for s in a.get("submissions") or []:
                if job in (s.get("job"), str((s.get("proc") or {}).get("pid", ""))):
                    own = (a.get("request") or {}).get("action") in LAUNCHES and s.get("submit") != "adopted" \
                        and bool((a.get("request") or {}).get("plan"))
                    facts_plan = {"target": a.get("target", ""), "kind": a.get("kind", ""), "warnings": "0",
                                  **(a.get("request") or {}).get("bound", {}), **{"name": a.get("name", "")}}
    rec, reasons = covers(facts_plan, action, state, orig=orig, job=job, own=own)
    if rec and rec.get("kind") == "deny":
        return Decision(False, rec, reasons, "")
    if rec:
        return Decision(True, rec, [], "")
    what = {"cancel": f"cancel job {job}"}.get(action, f"{action} of {facts(facts_plan).name or 'this plan'}")
    return Decision(False, None, reasons, f"approval — no record covers {what} (show the card and ask the user)")


# ================================================================================================ display
def _limit_text(v: Any) -> str:
    return NO_LIMIT if v is None else str(v)


def _ago(s: float) -> str:
    s = int(max(0, s))
    return f"{s}s" if s < 90 else f"{s // 60}m" if s < 5400 else f"{s // 3600}h{s % 3600 // 60:02d}m"


def describe(rec: dict) -> str:
    """What REC covers (or forbids), in one line."""
    sc, acts, lim = rec.get("scope") or {}, rec.get("actions") or [], rec.get("limits") or {}
    on = f" on {', '.join(sc['targets'])}" if sc.get("targets") else ""
    if rec.get("kind") == "approval" and acts == ["cancel"]:
        return f"cancel of job(s) {', '.join(sc.get('jobs') or [])}{on} — each once; identity checked at cancel time"
    if rec.get("kind") == "approval":
        runs = sc.get("runs") or []
        shown = ", ".join(h[:12] for h in runs[:4]) + (f" +{len(runs) - 4}" if len(runs) > 4 else "")
        return (f"{'/'.join(acts)} of {len(runs)} approved plan(s) [{shown}]{on} — each {lim.get('max_launches', 1)}x"
                f"; {'warnings the user saw' if sc.get('allow_warnings') else 'no plan with warnings'}")
    parts = []
    for key, label in (("targets", "targets"), ("partitions", "partitions"), ("gpu_types", "GPU types"),
                       ("classes", "classes"), ("names", "names"), ("jobs", "jobs")):
        if sc.get(key):
            parts.append(f"{label} {', '.join(sc[key])}")
    if sc.get("runs"):
        parts.append(f"plans {', '.join(h[:12] for h in sc['runs'])}")
    for key, show in (("max_gpus", lambda v: f"<= {v} GPUs"), ("max_cpus", lambda v: f"<= {v} CPUs"),
                      ("max_mem_gb", lambda v: f"<= {v:g} GB"), ("max_time_s", lambda v: f"<= {_dur(v)}")):
        if sc.get(key) is not None:
            parts.append(show(sc[key]))
    where = "; ".join(parts) or "anything"
    if rec.get("kind") == "deny":
        return f"DENY {'every action' if set(acts) == set(ACTIONS) else ', '.join(acts)}: {where}"
    extra = "plans with warnings too (-y gates)" if sc.get("allow_warnings") else "no plan with warnings"
    if "cancel_own" in acts:
        extra += "; may stop its own runs in scope"
    return f"{', '.join(a for a in acts if a != 'cancel_own') or 'no launches'}: {where}; {extra}"


def balance(rec: dict, state: L.LedgerState) -> str:
    lim, sc = rec.get("limits") or {}, rec.get("scope") or {}
    if rec.get("revoked"):
        state_txt = f"REVOKED {rec['revoked'].get('at')}"
    elif _expired(rec, time.time() if state.now is None else state.now):
        state_txt = f"EXPIRED {lim.get('expires')}"
    else:
        state_txt = ""
    if rec.get("kind") == "deny":
        out = f"expires {lim['expires']}" if lim.get("expires") else "no expiry"
    elif rec.get("kind") == "approval" and rec.get("actions") == ["cancel"]:
        done = {u.get("job") for u in rec.get("used") or []}
        out = f"jobs cancelled {len(done)}/{len(sc.get('jobs') or [])}"
    elif rec.get("kind") == "approval":
        hashes = sc.get("runs") or []
        n = sum(1 for h in hashes if any(u.get("hash") == h for u in rec.get("used") or []))
        out = f"plans used {n}/{len(hashes)}"
    else:
        unknown = state.affected(rec)
        u = "?" if unknown else str(launches_used(rec))
        lv = "?" if unknown else str(live_under(rec["id"], state))
        out = (f"launches {u}/{_limit_text(lim.get('max_launches'))} · live {lv}/{_limit_text(lim.get('max_live'))}"
               f" · expires {_limit_text(lim.get('expires'))}")
    return f"{state_txt} · {out}" if state_txt else out


def _overlap(a: dict, b: dict) -> bool:
    def acts(r: dict) -> set[str]:
        s = set(r.get("actions") or ACTIONS)
        return s | ({"cancel", "cancel_own"} if s & {"cancel", "cancel_own"} else set())
    if not acts(a) & acts(b):
        return False
    sa, sb = a.get("scope") or {}, b.get("scope") or {}
    for k in LISTS:
        x, y = sa.get(k) or [], sb.get(k) or []
        if not x or not y:
            continue
        if k == "names":
            if not any(p == q or fnmatch.fnmatchcase(p, q) or fnmatch.fnmatchcase(q, p) for p in x for q in y):
                return False
        elif k == "gpu_types":
            if not {v.lower() for v in x} & {v.lower() for v in y}:
                return False
        elif not set(x) & set(y):
            return False
    return True


def after_deny(rec: dict, records: list[dict], window: float = FLAG_WINDOW_S) -> list[str]:
    """A grant/approval created shortly after a deny of an overlapping scope (or after one was revoked): the order
    an agent would work around a refusal in. Shown by status, list and the audit; it blocks nothing by itself."""
    if rec.get("kind") == "deny":
        return []
    ids = [r.get("id") for r in records]
    before = records[:ids.index(rec.get("id"))] if rec.get("id") in ids else records   # stored in creation order
    t, out = L.epoch(rec.get("created_at")), []
    for d in before:
        if d.get("kind") != "deny" or not _overlap(d, rec):
            continue
        dt = t - L.epoch(d.get("created_at"))
        if 0 <= dt <= window:
            out.append(f"created {_ago(dt)} after deny {d['id']} of an overlapping scope")
        rv = d.get("revoked") or {}
        if rv and 0 <= t - L.epoch(rv.get("at")) <= window:
            out.append(f"created {_ago(t - L.epoch(rv.get('at')))} after deny {d['id']} was revoked")
    return out


def lines(state: L.LedgerState, show_all: bool = False, indent: str = "  ") -> list[str]:
    """`rsk grant list` / `rsk status`: one block per record."""
    out = []
    if state.budgets_unknown:
        out.append(f"{indent}BUDGETS UNKNOWN: {state.budgets_unknown[:300]} — records from before it cover nothing "
                   "until `rsk grant recount` (rebuilds the counts from audit.jsonl)")
    t = time.time() if state.now is None else state.now
    for r in state.grants:
        if not show_all and (r.get("revoked") or _expired(r, t)):
            continue
        out.append(f"{indent}{r['id']}  {r['kind']}  via {r.get('created_via')}{' (' + r['source'] + ')' if r.get('source') else ''}"
                   f"  {r.get('created_at')}")
        out.append(f"{indent}  covers: {describe(r)}")
        out.append(f"{indent}  {balance(r, state)}")
        out.append(f"{indent}  quote: \"{r.get('quote', '')}\"")
        for f in after_deny(r, state.grants):
            out.append(f"{indent}  FLAG: {f} — confirm with the user that it replaces the deny")
    return out


# ================================================================================================ rsk grant
def _split(vals: list[str]) -> list[str]:
    return [x for v in vals or [] for x in v.split(",") if x]


def _limit_arg(v: str, what: str) -> int | None:
    if v.lower() == "none":
        return None
    if not v.isdigit() or int(v) < 1:
        raise RskError(f"{what} takes a positive integer or 'none' (the user's words set no limit), not {v!r}", USAGE)
    return int(v)


def _scope_from(args: argparse.Namespace, deny: bool) -> dict:
    sc: dict[str, Any] = {k: _split(getattr(args, k, [])) for k in ("targets", "partitions", "gpu_types", "classes",
                                                                   "names")}
    bad = [c for c in sc["classes"] if c not in CLASSES]
    if bad:
        raise RskError(f"--class {', '.join(bad)}: one of {', '.join(CLASSES)} (experiment-conventions.md §1)", USAGE)
    if deny:
        sc["jobs"] = _split(args.jobs)
        sc["runs"] = _split(args.runs)
        return sc
    for k in ("max_gpus", "max_cpus", "max_mem_gb"):
        if getattr(args, k) is not None:
            sc[k] = getattr(args, k)
    if args.max_time:
        try:
            s = slurm_seconds(args.max_time)
        except ValueError as exc:
            raise RskError(f"--max-time: {exc}", USAGE) from exc
        if s == math.inf:
            raise RskError("--max-time: leave it out for no time cap", USAGE)
        sc["max_time_s"] = int(s)
    if args.allow_warnings:
        sc["allow_warnings"] = True
    return sc


def cmd_grant(args: argparse.Namespace) -> int:
    from remote_run.status import project_dir   # status imports this module
    led = L.Ledger(project_dir(args.dir))
    c = args.grant_command
    if c in ("add", "deny"):
        acts = _split(args.actions)
        if c == "add":
            if not acts:
                raise RskError("--action: what the user allowed (launch relaunch resubmit chain cancel_own)", USAGE)
            rec = new_grant(args.quote, _scope_from(args, False), acts,
                            max_live=_limit_arg(args.max_live, "--max-live"),
                            max_launches=_limit_arg(args.max_launches, "--max-launches"),
                            expires=None if args.expires.lower() == "none" else args.expires, source=args.source)
        else:
            rec = new_deny(args.quote, _scope_from(args, True), acts or None,
                           expires=None if (args.expires or "none").lower() == "none" else args.expires,
                           source=args.source)
        with led.locked():
            doc, _ = load(led)
            flags = after_deny(rec, doc["records"])
            add(led, rec)
        print(f"{rec['id']}  {rec['kind']}  covers: {describe(rec)}")
        print(f"  {balance(rec, led.state())}")
        for f in flags:
            print(f"  FLAG: {f} — confirm with the user that it replaces the deny")
        return OK
    if c == "revoke":
        r = revoke(led, args.id, args.quote)
        print(f"{r['id']} revoked: {describe(r)}")
        return OK
    if c == "import":
        recs = import_file(led, Path(args.file))
        st = led.state()
        for r in recs:
            print(f"{r['id']}  {r['kind']}  imported from {r['source']}  covers: {describe(r)}  ({balance(r, st)})")
            for f in after_deny(r, st.grants):
                print(f"  FLAG: {f}")
        return OK
    if c == "recount":
        print(recount(led))
        return OK
    st = led.state()
    if args.json:
        print(json.dumps({"ledger": str(led.dir), "budgets_unknown": st.budgets_unknown, "records": [
            {**r, "covers": describe(r), "balance": balance(r, st), "flags": after_deny(r, st.grants)}
            for r in st.grants]}, indent=1, ensure_ascii=False))
        return OK
    body = lines(st, args.all)
    print(f"grants of {led.project} (ledger {led.dir})")
    print("\n".join(body) if body else "  none recorded — every launch and cancel needs the user's approval")
    return OK


def add_parsers(sub) -> None:
    g = sub.add_parser("grant", help="what the user allowed or forbade for this project: grants, denies, approvals")
    gs = g.add_subparsers(dest="grant_command", required=True, metavar="add|deny|list|revoke|import|recount")

    def proj(p: argparse.ArgumentParser) -> None:
        p.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory)")

    def scope(p: argparse.ArgumentParser, deny: bool) -> None:
        p.add_argument("--quote", required=True, help="the user's words, verbatim")
        p.add_argument("--action", dest="actions", action="append", default=[],
                       help=("what it forbids (default: everything)" if deny else
                             "what the user allowed: launch relaunch resubmit chain cancel_own") + " (repeatable, a,b)")
        p.add_argument("-T", "--target", dest="targets", action="append", default=[])
        p.add_argument("--partition", dest="partitions", action="append", default=[])
        p.add_argument("--gpu-type", dest="gpu_types", action="append", default=[])
        p.add_argument("--class", dest="classes", action="append", default=[], help=" ".join(CLASSES))
        p.add_argument("--name", dest="names", action="append", default=[], help="run-name glob (repeatable)")
        p.add_argument("--source", default="", help="where the words were said (a session, a note)")
        proj(p)

    a = gs.add_parser("add", help="a standing grant: the user's words, scope and all three limits (a value or none)")
    scope(a, False)
    a.add_argument("--max-gpus", type=int, default=None)
    a.add_argument("--max-cpus", type=int, default=None)
    a.add_argument("--max-mem-gb", type=float, default=None)
    a.add_argument("--max-time", default="", help="Slurm time (e.g. 2-00:00:00)")
    a.add_argument("--allow-warnings", action="store_true", help="also plans with warnings (charged partition, "
                   "availability, occupancy) — only when the user's words say so")
    a.add_argument("--max-live", required=True, metavar="N|none")
    a.add_argument("--max-launches", required=True, metavar="N|none")
    a.add_argument("--expires", required=True, metavar="YYYY-MM-DD|none")
    d = gs.add_parser("deny", help="the user forbade it: a matching deny always wins")
    scope(d, True)
    d.add_argument("--job", dest="jobs", action="append", default=[])
    d.add_argument("--run", dest="runs", action="append", default=[], help="a plan's bound hash")
    d.add_argument("--expires", default="none", metavar="YYYY-MM-DD|none")
    ls = gs.add_parser("list", help="every record with what it covers and its balance")
    ls.add_argument("--all", action="store_true", help="also revoked and expired records")
    ls.add_argument("--json", action="store_true")
    proj(ls)
    r = gs.add_parser("revoke", help="end a record (the user's words)")
    r.add_argument("id")
    r.add_argument("--quote", required=True)
    proj(r)
    i = gs.add_parser("import", help="records from a JSON list (existing authorisations; created_via=import)")
    i.add_argument("file")
    proj(i)
    rc = gs.add_parser("recount", help="rebuild the use counts from audit.jsonl after a recovered file")
    proj(rc)
    g.set_defaults(func=cmd_grant)
