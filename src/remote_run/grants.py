"""What the user allowed or forbade for one project: one record type, kept in the ledger's grants.json.

Principle (the user's): no need to ask again every time, but every action checks whether an authorisation exists.
Every launch / relaunch / resubmit / chain / cancel calls check() first; only an action no record covers ends in
`needs user: approval`. A record is bookkeeping, not proof: its `quote` is what the agent wrote down as the user's
words, and an agent can write anything — the rails (show the card, wait for the user's words) are what make it the
user's decision; this file only keeps those decisions from being asked twice or stretched.

RECORD (validate() is strict: every key below present, nothing else; covers() ignores a record validate() rejects —
except a deny, which then matches everything: fail closed — and so does a record whose id says deny (d-…) or whose
kind is missing or damaged, until it is fixed by hand or revoked (a well-formed `revoked` ends it)):
  {"id": str, "kind": "approval"|"grant"|"deny", "quote": str (non-empty: the user's words),
   "created_at": iso, "created_via": "cli"|"import"|"plan-approve", "source": str (non-empty for import),
   "scope": {"targets": [..], "partitions": [..], "gpu_types": [..], "classes": [..], "names": [glob..],
             "runs": [bound_hash..], "plans": [plan id..], "jobs": [job id..], "idents": [identity..],
             "max_gpus": int, "max_cpus": int, "max_mem_gb": num, "max_time_s": int,
             "allow_warnings": "availability"|"any" (a stored true reads as "any", false as none)},
             (every scope key optional: absent = any; a deny takes only the list keys)
   "actions": [⊆ launch relaunch resubmit chain cancel cancel_own] (no command checks `resubmit` — run-watch
              budgets its own resubmits under `#@ allow`, --relaunch is `relaunch` — so `rsk grant add` / import
              refuse it in a standing grant; a deny may still name it),
   "limits": grant: {"max_live": int|null, "max_launches": int|null, "expires": "YYYY-MM-DD"|iso|null} — all three
                    keys REQUIRED; null = the user's words set no limit (shown as "no limit (user's words)"), never
                    a value the agent made up;
             approval: {"max_launches": int (uses per listed hash; 1 = once), "max_live"?, "expires"?};
             deny: {} or {"expires": ...},
   "used": [{"nonce", "action", "hash", "job", "at"}, ...] (idempotent by nonce),
   "revoked": null | {"at", "quote"}}

The kinds:
  approval  the user approved specific plans: scope.plans = their plan ids and scope.runs = their bound hashes (one
            quote may cover a sweep), each usable limits.max_launches times (1; N for an approved chain of N
            segments), expiring with the plans (PLAN_TTL, 24 h): a later plan of the same configuration is a new
            plan, never covered by an old approval (an approval without scope.plans is invalid). Or an explicit request to
            cancel named jobs ("cancel job 123"): actions [cancel], scope.jobs = the ids, scope.idents = the identity
            each was asked for (Slurm: target, job id, run name, WorkDir; nohup: target, pid, start, boot_id), expiring
            CANCEL_TTL_S (1 h) after it was given and used up by the first cancel of that job that passed
            authorisation, whatever its outcome (never given back) — the caller still verifies the job's identity
            (name, WorkDir, user / pid+start+boot_id) on the target before it acts.
  grant     a standing permission (a predicate): launches in scope, within max_live / max_launches / expires.
            `cancel_own` lets the agent stop ITS OWN runs in scope (ledger attempts it launched, never adopted ones)
            at its own discretion — without it, stopping a run is the user's call; each such cancel counts against
            max_launches (shown as "uses" / "cancels"). A plan with warnings > 0 (a -y gate: charged partition,
            availability, occupancy) is covered only with scope.allow_warnings: "availability" covers a plan whose
            only warnings are the harness's own availability gate (warnings == warnings_avail), "any" every -y gate
            (policy gates too, e.g. a charged partition — only when the user's words say so). More resources than
            max_gpus / max_cpus / max_mem_gb / max_time_s is not covered (a time of 0 / UNLIMITED is unlimited; max_time_s
            holds for every time limit sbatch could read: the bound time and each --time / -t of extra — a site
            policy's, which comes after the harness's and wins, included), nor
            is a Slurm plan whose conf_extra (the conf's SBATCH_EXTRA words) holds a word outside EXTRA_ALLOW — any
            time / resource / node option in any spelling or abbreviation, an unknown option, a bare word (the card
            names it); the policy's own SB_ARGS words never count either way, but a Slurm plan with policy flags
            (the bound flags=: --<word> handed to the target's policy, which may add any sbatch option for them) or
            from a deploy that does not bind them is never covered. relaunch / resubmit are covered only when the
            run's LATEST attempt that may have run — the one whose end it relies on — ended with positive evidence of
            an infrastructure end (INFRA_END: Slurm PREEMPTED / NODE_FAIL / BOOT_FAIL, nohup REBOOT; never
            CANCELLED, COMPLETED, FAILED, TIMEOUT, OUT_OF_MEMORY or an unknown end) AND the plan repeats THAT
            attempt's configuration (same bound fields; the name may differ in --aNN; never an older attempt's the
            plan is named after). scope.names globs match the plan's name as it is (a glob for the run id alone does
            not match its --aNN attempts: fails closed; write 'run*' to cover them). A run's class is its first
            attempt's: a run whose first attempt had none has no class (a classes scope never covers it).
  deny      the user forbade it: a matching deny always wins (exit 3, quote shown), whatever else exists; a plan fact
            that cannot be read or is not known counts as matching (fail closed: a cancel of a job without a plan, a
            run-watch row — a deny of plans (bound hashes), names, classes, partitions or GPU types then matches).
            A deny of `launch` also stops relaunch / resubmit / chain; a deny that names a run (scope.names) and lists
            relaunch or resubmit stops every launch-type action of it, launch included, on any target in its scope
            (run_deny(), R6-1: "do not relaunch a" — the run's earlier attempts may be where rsk cannot see them); a
            deny naming no run keeps the derived action. Its names globs match the name or its run id
            (the name minus --aNN), and a glob that itself ends in --aNN (an attempt's job name, as squeue / sacct
            show it) or in a glob that matches one (x--a*, x--a0?) matches with that suffix removed too: it stands for
            the whole run (run_glob(), R7-1 — the run run_deny() names is that stripped form); its classes match the
            class the name carries, the --class label or any class the run was recorded with (an attempt recorded
            without one: any class). Its targets are compared as
            target_key() names (`fx/`, `fx/.`, `FX` are fx; a spelling that is not one plain name matches every
            target deny). scope.jobs is for cancels only: a deny with jobs and any launch action is invalid
            (`rsk grant deny --job` refuses it, exit 2; a stored one matches everything) — a run's launches are
            denied by name. `rsk grant add|deny|import` refuse a target the harness does not know (exit 2); a
            partition is never refused (R7-2: T_PARTITIONS is the profile's display list, policy.sh is the
            authority — one it does not list is recorded with a NOTE saying so; a GPU type has no list: echoed only);
            `rsk grant list`, `rsk status` and `rsk doctor` flag a stored record whose targets are unknown ("never
            matches — fix or revoke": scope_problems()), and list / status add the NOTE for an unlisted partition.
  A grants.json that cannot be read at all (corrupt, no good .prev) holds denies that cannot be ruled out: check()
  raises RskError(CONFLICT) (unreadable()) and deny_match() matches everything — never "no deny".
  The class of a plan is the one its name carries (<exp>--<class>--…); --class only labels a name without one. The
  action of a launch is derived (launch.py): a run that already has attempts → relaunch, a chain=1 plan → chain;
  every action that applies is checked — a deny of any of them matches, a record must allow all of them.

API:
  parse_plan(text) -> dict          the one `@@plan v1` … `@@end` block of a plan reply; values as printed (%q kept)
  qwords(value) -> [str]            decode a bash %q value into words (shlex; $'…' handled); unq(value) -> str
  facts(plan) -> Facts              what a plan asks for, parsed (gpus, type, cpus, mem, time, class, warnings)
  validate(record) -> record        RskError(USAGE) listing every problem
  new_grant / new_deny / new_approval / new_cancel_approval(...) -> record (validated, not stored)
  add(led, record) -> record        store + audit (with `after_deny` when it follows a deny of the same scope)
  revoke(led, id, quote)            use(led, id, nonce, action, hash='', job='')   refund(led, id, nonce, why)
  recount(led) -> str               rebuild `used` from audit.jsonl and clear "budgets unknown"
  covers(plan, action, state, *, orig=None, job='', own=False, extending=None, also=(), prev=None, ident='')
                                    -> (record|None, reasons)   pure
  check(ledger_or_state, action, *, plan=None, job='', run='', extending=None, also=(), ident='') -> Decision(covered,
                                    record, reasons, needs)  (plan may carry "class" — a label —, "classes_recorded"
                                    (run_classes(): each attempt's, oldest first, '' = none) and "plan_id"; extending =
                                    the (run, attempt) a chain segment extends: not counted against max_live; also = the
                                    other actions that apply; ident = the cancel identity; a cancel_own grant covers
                                    only a LIVE ledger submission of the job) the one entry point; Decision.code = 0 |
                                    3 (deny) | 4 (needs the user); RskError(CONFLICT) when grants.json is unreadable
  deny_match(plan, actions, state, *, job=None) -> (deny|None, reason, cancel_own deny|None)   pure (job None = any)
  conf_extra_bad(words) -> [word]   the conf SBATCH_EXTRA words outside EXTRA_ALLOW (they make a plan uncoverable)
  run_deny(deny) -> bool            it names a run and lists relaunch / resubmit: it matches every launch of that run
  run_globs(names) -> [glob]        a deny's globs that end in --aNN (or a glob matching one: x--a*), with it removed
                                    (R7-1: an attempt's name = its run)
  check_scope(scope, targets)       rsk grant add|deny|import: unknown target → RskError(USAGE); NOTE lines (an
                                    unlisted partition, a GPU type)
  scope_problems(rec, targets)      a stored record's targets the harness does not know (list, status, doctor)
  scope_notes(rec, targets)         a stored record's partitions its targets' T_PARTITIONS do not list (list, status)
  unreadable(state) -> str          '' unless grants.json could not be read (the refusal text: exit 6)
  attempt_class(att) / run_classes(run_record)   the class an attempt was recorded with / each attempt's, oldest first
  describe(record) -> str           what it covers, one line;  balance(record, state) -> str;  after_deny(...)
Hold `with led.locked():` from check() to use() so two launches cannot both pass one budget.
"""

from __future__ import annotations

import argparse
import fnmatch
import functools
import hashlib
import json
import math
import re
import secrets
import shlex
import subprocess
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from remote_run import ledger as L
from remote_run.errors import CONFLICT, NEEDS_USER, OK, REFUSED, USAGE, RskError

KINDS = ("approval", "grant", "deny")
VIA = ("cli", "import", "plan-approve")
ACTIONS = ("launch", "relaunch", "resubmit", "chain", "cancel", "cancel_own")
LAUNCHES = frozenset({"launch", "relaunch", "resubmit", "chain"})
LISTS = ("targets", "partitions", "gpu_types", "classes", "names", "runs", "plans", "jobs", "idents")
NUMS = ("max_gpus", "max_cpus", "max_mem_gb", "max_time_s")
SCOPE_KEYS = LISTS + NUMS + ("allow_warnings",)
WARN_KINDS = ("availability", "any")      # scope.allow_warnings: the harness's availability gate only | every -y gate
INFRA_END = ("PREEMPTED", "NODE_FAIL", "BOOT_FAIL", "REBOOT")   # a relaunch grant resumes only after one of these
CANCEL_TTL_S = 3600                       # a cancel approval ("cancel job 123") lives this long
KEYS = ("id", "kind", "quote", "created_at", "created_via", "source", "scope", "actions", "limits", "used", "revoked")
CLASSES = ("smoke", "pilot", "train", "eval", "ablate", "bench")       # experiment-conventions.md §1
GRANT_LIMITS = ("max_live", "max_launches", "expires")
NO_LIMIT = "no limit (user's words)"
FLAG_WINDOW_S = 3600            # a grant created (or a deny revoked) within this long after a deny is flagged
HEX64 = re.compile(r"[0-9a-f]{64}")
SLURM_BOUND = ("partition", "gres", "cpus", "mem", "time", "account", "name", "extra", "payload", "env_kind",
               "env_name", "wandb_mode", "env_hook", "venv_dir", "uv_sync_args", "conf_extra", "flags", "chain")
NOHUP_BOUND = ("name", "gpus_req", "exclude", "nice", "launch_cfg", "busy_ok", "payload", "env_kind", "env_hook",
               "venv_dir", "uv_sync_args", "env_name")
# keys this rsk needs in a plan block (an api=3 deploy from before them lacks them: needs a sync) — bound ones (slurm
# flags: the policy flags submit.sh handed to the policy, T_FLAGS), and the envelope's warnings identity (warnings_id: what
# rsk sends back as --rs-warnings; warnings_avail: the harness's own availability gate's share of the warnings; nohup
# info_run_gpu: its launch.sh refuses a RUN that sets or clears a GPU variable — an older one would let RUN pick the GPUs;
# nohup info_launchers: it also warns on a launcher's GPU config and on container runtimes, and refuses env -i anywhere —
# an older one gives a card without those WARNINGs, which a grant would then cover; nohup launch_cfg (bound, R7-5): the
# launcher config / hostfile files those checks read, `<path>:<sha256>[,…]` — an older block does not bind them, so a
# config edited after the card would launch unseen)
NEEDED = {"slurm": ("env_hook", "venv_dir", "uv_sync_args", "conf_extra", "flags", "warnings_avail", "warnings_id"),
          "nohup": ("busy_ok", "launch_cfg", "env_hook", "venv_dir", "uv_sync_args", "info_run_gpu", "warnings_avail",
                    "warnings_id", "info_launchers")}
# D1: the conf's SBATCH_EXTRA words a standing grant may cover — exactly these spellings (sbatch also takes unique
# long-option prefixes: an abbreviation is "anything else", uncoverable). A value is `--opt=V`, `-oV` or the NEXT word
# (always consumed, whatever it is: getopt_long gives a required argument the next word even when it starts with '-').
EXTRA_VALUE_LONG = ("qos", "account", "exclude", "constraint", "reservation", "signal", "mail-type", "mail-user", "comment")
EXTRA_VALUE_SHORT = "qAxC"                # -q qos, -A account, -x exclude, -C constraint
EXTRA_FLAGS = ("requeue", "no-requeue")   # no value
# --dependency=singleton / -d singleton (the value must be exactly singleton); --nice / --nice=N (optional: never takes
# the next word)
EXTRA_ALLOW = (" ".join(f"--{o}" for o in EXTRA_VALUE_LONG) + " " + " ".join(f"-{c}" for c in EXTRA_VALUE_SHORT)
               + " --dependency=singleton -d singleton --requeue --no-requeue --nice --nice=N")
TARGET_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")   # a plain target name (a dir under a targets root)


def target_key(t: object) -> str | None:
    """The name a deny compares (R5-8): path decorations dropped ('x/', 'x/.', './x', 'x//' find the same profile dir),
    case folded (a case-insensitive filesystem finds it too); None when that is not ONE plain target name — such a
    spelling may be any target (a deny then matches it: fail closed)."""
    parts = [p for p in str(t or "").strip().split("/") if p not in ("", ".")]
    if len(parts) != 1 or not TARGET_NAME.fullmatch(parts[0]):
        return None
    return parts[0].casefold()


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
    if "warnings_avail" in out and not out["warnings_avail"].isdigit():
        raise PlanError(f"warnings_avail={out['warnings_avail']!r} is not a count")
    if "warnings_id" in out and not HEX64.fullmatch(out["warnings_id"]):
        raise PlanError("warnings_id is not 64 lowercase hex digits")
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
    cls: str | None = None             # the run's class: the name's, else the --class label; None = unknown (also when
                                       # the run's first attempt was recorded without one: a class is set only there)
    classes: tuple[str, ...] = field(default=())   # every class it may be (the name's, the label, recorded): denies
    class_unknown: bool = False        # an attempt of the run was recorded without a class: a class deny matches
    bound_hash: str = ""
    plan_id: str = ""
    warnings: int | None = None        # the de-duplicated WARNING: lines (-y gates) the plan printed
    warnings_avail: int | None = None  # how many of them the harness's own availability gate printed
    extra_res: tuple[str, ...] = field(default=())  # conf_extra words outside EXTRA_ALLOW: no standing grant covers it
    conf_extra: bool = False           # the block names the conf's SBATCH_EXTRA words (an older deploy's does not)
    flags: tuple[str, ...] = field(default=())   # slurm: the policy flags submit.sh handed to the policy (bound flags=)
    flags_known: bool = False          # the block names them (an older deploy's does not: no standing grant covers it)
    time_extra: str = ""               # an SBATCH_EXTRA / policy --time / -t (shown on the card: sbatch takes the last)
    time_max_s: float | None = None    # the longest of time and every --time / -t in extra (max_time_s caps it)
    unreadable: tuple[str, ...] = field(default=())


def slurm_seconds(t: str) -> float:
    """sbatch --time: minutes, minutes:seconds, hours:minutes:seconds, days-hours, days-hours:minutes,
    days-hours:minutes:seconds (sbatch(1)); UNLIMITED/INFINITE = inf, and so is a total of zero (sbatch(1): "A time
    limit of zero requests that no time limit be imposed"). ValueError otherwise."""
    t = t.strip()
    if t.upper() in ("UNLIMITED", "INFINITE"):
        return math.inf
    m = re.fullmatch(r"(?:([0-9]+)-)?([0-9]+)(?::([0-9]+))?(?::([0-9]+))?", t)
    if not m:
        raise ValueError(f"not a Slurm time: {t!r}")
    d, a, b, c = (int(x) if x is not None else None for x in m.groups())
    if d is not None:
        s = d * 86400 + a * 3600 + (b or 0) * 60 + (c or 0)
    elif c is not None:
        s = a * 3600 + b * 60 + c
    elif b is not None:
        s = a * 60 + b
    else:
        s = a * 60
    return math.inf if s == 0 else s


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


def name_class(name: str) -> str | None:
    """The run class a name carries (<exp>--<class>--…, experiment-conventions.md §2), None without one."""
    f = str(name).split("--")
    return f[1] if len(f) > 1 and f[1] in CLASSES else None


def attempt_class(att: dict) -> str:
    """The class an attempt was recorded with: its --class label / the name's at the time, else its name's (an adopted
    attempt records none); '' = none."""
    return str((att.get("request") or {}).get("class") or "") or name_class(str(att.get("name") or "")) or ""


def run_classes(run_rec: dict | None) -> list[str]:
    """The class of each attempt of a run, oldest attempt first ('' = recorded without one): what a plan's
    "classes_recorded" carries. The first one is the run's class (a class is set only at a run's first attempt)."""
    atts = (run_rec or {}).get("attempts") or {}
    order = sorted(atts, key=lambda k: (int(k[1:]) if k[1:].isdigit() else 0, k))
    return [attempt_class(atts[k]) for k in order]


def conf_extra_bad(words: list[str]) -> list[str]:
    """The words of the conf's SBATCH_EXTRA (conf_extra) a standing grant cannot cover — everything outside
    EXTRA_ALLOW, in the exact grammar: --opt=V | -oV | --opt V / -o V (the next word, whatever it is, only for an option
    that requires a value) for EXTRA_VALUE_*; --dependency=singleton | --dependency singleton | -d singleton |
    -dsingleton; --requeue / --no-requeue (no value); --nice | --nice=N (never the next word). Anything else — a time /
    resource / node option in any spelling or abbreviation, an unknown option, a bare word, a value option at the end
    without its value — is returned (as the card shows it). [] = every word is coverable."""
    bad, i = [], 0
    while i < len(words):
        w = words[i]
        nxt = words[i + 1] if i + 1 < len(words) else None
        if w.startswith("--") and len(w) > 2:
            opt, eq, val = w[2:].partition("=")
            if opt in EXTRA_VALUE_LONG:
                if not eq:
                    if nxt is None:
                        bad.append(f"{w} (no value)")
                    i += 1
            elif opt == "dependency":
                v = val if eq else nxt
                if not eq:
                    i += 1
                if v != "singleton":
                    bad.append(w if eq else f"{w} {nxt if nxt is not None else '(no value)'}")
            elif opt in EXTRA_FLAGS:
                if eq:
                    bad.append(w)
            elif opt == "nice":
                if eq and not re.fullmatch(r"[+-]?[0-9]+", val):
                    bad.append(w)
            else:
                bad.append(w)
        elif len(w) >= 2 and w[0] == "-" and w[1] != "-":
            c = w[1]
            if c in EXTRA_VALUE_SHORT:
                if len(w) == 2:
                    if nxt is None:
                        bad.append(f"{w} (no value)")
                    i += 1
            elif c == "d":
                v = w[2:] if len(w) > 2 else nxt
                if len(w) == 2:
                    i += 1
                if v != "singleton":
                    bad.append(w if len(w) > 2 else f"{w} {nxt if nxt is not None else '(no value)'}")
            else:
                bad.append(w)
        else:
            bad.append(w or "''")
        i += 1
    return bad


def extra_time(words: list[str]) -> str:
    """For the card only (never coverage): the last --time / -t value among the SBATCH_EXTRA / policy words (they
    come after the harness's --time: sbatch takes the last). A word an allowlisted value option takes is its value."""
    t, i = "", 0
    while i < len(words):
        w = words[i]
        nxt = words[i + 1] if i + 1 < len(words) else ""
        opt = w[2:].partition("=")[0] if w.startswith("--") else ""
        if w.startswith("--time="):
            t = w[7:]
        elif w in ("--time", "-t"):
            t, i = nxt, i + 1
        elif len(w) > 2 and w.startswith("-t") and not w.startswith("--"):
            t = w[2:]
        elif (opt in EXTRA_VALUE_LONG + ("dependency",) and "=" not in w) or w in [f"-{c}" for c in EXTRA_VALUE_SHORT + "d"]:
            i += 1
        i += 1
    return t


def extra_times(words: list[str]) -> list[str]:
    """Every --time / -t value sbatch could read among the extra words (--time=V --ti=V --tim=V, --time V, -tV, -t V),
    also one another option takes as its value (`--comment -t1`): a grant's max_time_s holds for each of them, as
    submit.sh holds each to MaxTime. A value word is read as a word too (never skipped)."""
    out = []
    for i, w in enumerate(words):
        nxt = words[i + 1] if i + 1 < len(words) else ""
        if w.startswith("--") and w[2:].partition("=")[0] in ("ti", "tim", "time"):
            out.append(w.partition("=")[2] if "=" in w else nxt)
        elif w == "-t":
            out.append(nxt)
        elif len(w) > 2 and w.startswith("-t"):
            out.append(w[2:])
    return out


def facts(plan: dict) -> Facts:
    bad: list[str] = []

    def get(key: str) -> str | None:
        try:
            return unq(str(plan[key])) if key in plan else None
        except RskError:
            bad.append(key)
            return None

    kind, name = str(plan.get("kind", "")), get("name") or ""
    label = str(plan.get("class") or "") or None
    cls = name_class(name) or label
    w, wa = str(plan.get("warnings", "")), str(plan.get("warnings_avail", ""))
    raw = [str(c or "") for c in plan.get("classes_recorded") or []]     # the run's attempts, oldest first ('' = none)
    recorded = [c for c in raw if c]
    if raw and not raw[0]:          # its first attempt carried no class: the run has none (a later label never sets it)
        cls = None
    common = dict(target=str(plan.get("target", "")), kind=kind, name=name, run=L.run_id(name) if name else "",
                  cls=cls, classes=tuple(dict.fromkeys(c for c in (name_class(name), label, *recorded) if c)),
                  class_unknown="" in raw,
                  bound_hash=str(plan.get("bound_hash", "")), plan_id=str(plan.get("plan_id", "")),
                  warnings=int(w) if w.isdigit() else None, warnings_avail=int(wa) if wa.isdigit() else None)
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
    t_extra, t_all, res = "", [], []
    if "extra" in plan:                        # policy + SBATCH_EXTRA words: shown, and their times capped (never D1's allowlist)
        try:
            xw = qwords(str(plan["extra"]))
            t_extra, t_all = extra_time(xw), extra_times(xw)
        except RskError:
            bad.append("extra")
    if "conf_extra" in plan:                   # the conf's SBATCH_EXTRA alone: every word must be in EXTRA_ALLOW
        try:
            res = conf_extra_bad(qwords(str(plan["conf_extra"])))
        except RskError:
            bad.append("conf_extra")
    pflags: list[str] = []
    if "flags" in plan:                        # the policy flags (T_FLAGS): bound, and never a standing grant's call
        try:
            pflags = [x for x in qwords(str(plan["flags"])) if x]
        except RskError:
            bad.append("flags")
    try:
        mem_gb = slurm_mem_gb(mem) if mem else None
    except ValueError:
        mem_gb, _ = None, bad.append("mem")
    try:
        time_s = slurm_seconds(t) if t else None
    except ValueError:
        time_s, _ = None, bad.append("time")
    time_max = time_s
    try:
        if time_s is not None and t_all:
            time_max = max([time_s, *(slurm_seconds(v) for v in t_all)])
    except ValueError:
        time_max, _ = None, bad.append("extra")
    return Facts(**common, partition=part, gpu_type=gt, gpus=gn, cpus=cpus_n, mem_gb=mem_gb, time_s=time_s,
                 extra_res=tuple(res), conf_extra="conf_extra" in plan, flags=tuple(pflags), flags_known="flags" in plan,
                 time_extra=t_extra, time_max_s=time_max, unreadable=tuple(bad))


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
        elif va != vb and _unq_or(va) != _unq_or(vb):   # '' = "''" (%q of empty) = absent (an attempt from before the key)
            diff.append(f"{k} {va[:60]!r} -> {vb[:60]!r}")
    return diff


def _unq_or(v: str) -> str | list[str]:
    """The decoded words of a %q value, with one empty word (`''`) the same as none: '' == "''" == absent."""
    try:
        w = qwords(v)
    except RskError:
        return v
    return [] if w == [""] else w


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
            if "allow_warnings" in scope and not (isinstance(scope["allow_warnings"], bool)
                                                  or scope["allow_warnings"] in WARN_KINDS):
                errs.append(f"scope.allow_warnings must be one of {', '.join(WARN_KINDS)} (an older record's true "
                            "reads as any)")
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
        if scope.get("jobs") or scope.get("idents"):
            errs.append("scope.jobs / scope.idents belong to a cancel approval, not a standing grant")
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
            if not scope.get("plans"):
                errs.append("an approval of plans names their plan ids in scope.plans (one written before rsk "
                            "scoped approvals to plans covers nothing: plan again)")
        elif acts == ["cancel"]:
            if not scope.get("jobs"):
                errs.append("a cancel approval names the job(s) in scope.jobs")
            if not scope.get("idents") or len(scope.get("idents") or []) != len(scope.get("jobs") or []):
                errs.append("a cancel approval binds each job's identity in scope.idents (one written before identity "
                            "binding covers nothing: ask the user again)")
            if limits.get("expires") is None:
                errs.append("a cancel approval expires (limits.expires): it is for the cancel the user asked for now")
        elif acts:
            errs.append("an approval covers launches of approved plans or cancel of named jobs, not both")
        v = limits.get("max_launches")
        if isinstance(v, bool) or not isinstance(v, int) or v < 1:
            errs.append("an approval's limits.max_launches is the uses per approved plan (>= 1)")
        for k in sorted(set(limits) - set(GRANT_LIMITS)):
            errs.append(f"unknown limit {k!r}")
    elif kind == "deny":
        for k in NUMS + ("allow_warnings", "idents"):
            if k in scope:
                errs.append(f"a deny takes targets/partitions/gpu_types/classes/names/runs/jobs, not {k} (resource "
                            "caps are a grant's scope, or the target's policy.local.sh)")
        if scope.get("jobs") and set(acts) & LAUNCHES:      # R5-1: a launch has no job id to compare: it never matched
            errs.append(f"a deny by job id (scope.jobs) is for cancels only (cancel, cancel_own), not "
                        f"{'/'.join(a for a in acts if a in LAUNCHES)}: a deny of a run's launches names the run "
                        "(scope.names, --name '<run>') — revoke this one with the user's words and record it again")
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


def no_resubmit(rec: dict) -> dict:
    """A NEW standing grant (rsk grant add / import) never lists `resubmit`: nothing checks it (run-watch budgets its
    resubmits under the table's `#@ allow`, --relaunch is `relaunch`) — a deny may name it."""
    if rec.get("kind") == "grant" and "resubmit" in (rec.get("actions") or []):
        raise RskError(f"grant record {rec.get('id', '?')}: 'resubmit' is not a standing grant's action — no command "
                       "checks it (run-watch resubmits under its table's '#@ allow preempt=N …' approved with "
                       "'#@ ok'; a new attempt of a run is 'relaunch')", USAGE)
    return rec


def _record(kind: str, quote: str, scope: dict, actions: list[str], limits: dict, via: str, source: str) -> dict:
    return validate({"id": new_id(kind), "kind": kind, "quote": quote, "created_at": L.now(), "created_via": via,
                     "source": source, "scope": {k: v for k, v in scope.items() if v not in (None, [], ())},
                     "actions": list(actions), "limits": limits, "used": [], "revoked": None})


def new_grant(quote: str, scope: dict, actions: list[str], *, max_live: int | None, max_launches: int | None,
              expires: str | None, via: str = "cli", source: str = "") -> dict:
    return no_resubmit(_record("grant", quote, scope, actions,
                               {"max_live": max_live, "max_launches": max_launches, "expires": expires}, via, source))


def new_deny(quote: str, scope: dict, actions: list[str] | None = None, *, expires: str | None = None,
             via: str = "cli", source: str = "") -> dict:
    return _record("deny", quote, scope, list(actions or ACTIONS), {} if expires is None else {"expires": expires},
                   via, source)


APPROVAL_TTL_S = 24 * 3600      # = launch.PLAN_TTL_S: an approval never outlives the plans it names


def _in(ttl_s: float) -> str:
    return datetime.fromtimestamp(time.time() + ttl_s, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_approval(quote: str, plans: list[dict], *, plan_ids: list[str], actions: tuple[str, ...] = ("launch",),
                 launches: int = 1, allow_warnings: bool | str = False, via: str = "plan-approve", source: str = "",
                 ttl_s: int = APPROVAL_TTL_S) -> dict:
    """The user approved these plans (parsed blocks + their ids; one quote may cover a sweep): each `launches`
    times, only these plan ids (a later identical plan is another plan), until the plan TTL from now.
    allow_warnings: the approved cards showed warnings the user saw (stored as "any": the exact warnings are bound by
    the plan's warnings_id, which the target recomputes)."""
    hashes = list(dict.fromkeys(str(p["bound_hash"]) for p in plans))
    targets = sorted({str(p.get("target", "")) for p in plans} - {""})
    aw = warn_kind(allow_warnings)
    return _record("approval", quote, {"runs": hashes, "plans": list(dict.fromkeys(plan_ids)), "targets": targets,
                                       **({"allow_warnings": aw} if aw else {})},
                   list(actions), {"max_launches": launches, "max_live": None, "expires": _in(ttl_s)}, via, source)


def cancel_ident(kind: str, target: str, job: str, *who: str) -> str:
    """The identity a cancel approval is bound to, one string: Slurm (target, job id, run name, WorkDir), nohup
    (target, pid, /proc start, boot_id) — JSON, so a '|' or a space in a name cannot shift a field."""
    return json.dumps([kind, target, str(job), *(str(w) for w in who)], ensure_ascii=False, separators=(",", ":"))


def new_cancel_approval(quote: str, target: str, jobs: list[str], *, idents: list[str], via: str = "cli",
                        source: str = "", ttl_s: int = CANCEL_TTL_S) -> dict:
    """An explicit user request to cancel these jobs: covers `cancel` of exactly them, each bound to the identity it
    was asked for (IDENTS: cancel_ident(), one per job), for TTL_S (1 h); each job once, never given back (the caller
    still verifies the identity on the target before it acts)."""
    if len(idents) != len(jobs):
        raise RskError("new_cancel_approval: one identity per job", USAGE)
    return _record("approval", quote, {"jobs": [str(j) for j in jobs], "idents": list(idents),
                                       "targets": [target] if target else []},
                   ["cancel"], {"max_launches": 1, "max_live": None, "expires": _in(ttl_s)}, via, source)


def warn_kind(v: Any) -> str:
    """scope.allow_warnings as a kind: '' (none), 'availability' or 'any' (a stored true is 'any')."""
    if v is True:
        return "any"
    return v if v in WARN_KINDS else ""


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
        if isinstance(r, dict) and r.get("id") == rid:
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
        if _revoked_ok(r):
            raise RskError(f"{rid} was revoked at {r['revoked'].get('at')}", USAGE)
        r["revoked"] = {"at": L.now(), "quote": quote}     # (a damaged `revoked` is replaced: revoking ends it)
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
    — on grants.json and on every recovered run record. A use the audit holds is never dropped, nor a deny or the
    revocation of a grant / approval (a grants.json recovered from .prev lost the last write: the audit line of a
    deny made in it puts the deny back — one that cannot be rebuilt cleanly stays a fail-closed deny —, that of a
    revoke the revocation; a lost grant or approval stays lost: the user's words again)."""
    with led.locked():
        doc, got = load(led)
        made, gone = led.audit_grants()
        have = {r.get("id") for r in doc["records"] if isinstance(r, dict) and isinstance(r.get("id"), str)}
        back = [rid for rid, r in made.items() if r["kind"] == "deny" and rid not in have]
        doc["records"] += [{**made[rid], "revoked": gone.get(rid)} for rid in back]
        revoked = []
        for r in doc["records"]:      # a revoked grant / approval never comes back (a deny's revoke is the user's again)
            if (isinstance(r, dict) and r.get("kind") in ("grant", "approval") and isinstance(r.get("id"), str)
                    and r["id"] in gone and not r.get("revoked")):
                r["revoked"] = gone[r["id"]]
                revoked.append(r["id"])
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
        led.audit("recount", added=added, bad_lines=bad, runs_cleared=cleared, records_restored=back,
                  revocations_restored=revoked)
        led.write_grants(doc)
        return (f"{added} use(s) restored from the audit; {note}"
                + (f"; record(s) {', '.join(back)} restored from the audit (lost with grants.json)" if back else "")
                + (f"; revocation(s) of {', '.join(revoked)} restored from the audit" if revoked else "")
                + (f"; run record(s) {', '.join(cleared)} trusted again — any job they lost shows as UNLEDGERED in "
                   "rsk status" if cleared else ""))


def import_file(led: L.Ledger, path: Path, check: Any = None) -> list[dict]:
    """A JSON list of records the user's existing authorisations were written as (memory notes, a conf comment).
    Every user-facing field must be in the file; only id / created_at / used / revoked may be left for rsk. CHECK(records)
    runs on the validated records before anything is stored (rsk grant import: every scope target must be known)."""
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
            out.append(no_resubmit(validate(rec)))
        except RskError as exc:
            errs.append(f"#{i}: {exc}")
    if errs:
        raise RskError(f"{path}: nothing imported — " + " | ".join(errs), USAGE)
    if check is not None:
        check(out)
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


_ATT_GLOB = re.compile(r"(?:[0-9*?]|\[[^]]*\])+")    # an attempt suffix written as a glob: digits, *, ?, [...]
_ATT_SAMPLE = tuple(f"{i:02d}" for i in range(100)) + tuple(str(i) for i in range(100, 1000))   # a01 … a999


@functools.lru_cache(maxsize=4096)
def run_glob(g: str) -> str:
    """R7-1: the run a deny's names glob G stands for when G ends in an attempt's suffix — literally (`<run>--a02`: two
    or more digits, ledger.run_id), or as a glob that matches one (`x--a*`, `x--a0?`, `x--a[0-9][0-9]`: every attempt
    of x) —, else ''. A suffix that cannot match two or more digits (`x--a?`, `x--a[!0-9]*`) is no attempt's."""
    if L.run_id(g) != g:
        return L.run_id(g)
    i = g.rfind("--a")
    r = g[i + 3:] if i > 0 else ""
    if r and _ATT_GLOB.fullmatch(r) and any(fnmatch.fnmatchcase(d, r) for d in _ATT_SAMPLE):
        return g[:i]
    return ""


def run_globs(names: list[str]) -> list[str]:
    """R7-1: the runs a deny's names globs stand for (run_glob(), once each) — a deny written with an attempt's job
    name (`<run>--a02`, as squeue / sacct / the log show it), or a glob over a run's attempt names, stands for the
    whole run: an attempt is launched once, so a launch-type deny of one attempt has no other meaning."""
    return list(dict.fromkeys(r for r in map(run_glob, names) if r))


def _warn_miss(scope: dict, f: Facts) -> str:
    """'' when SCOPE's allow_warnings covers F's warnings: none at all; "any"; or "availability" and every warning is
    the harness's own availability gate's (warnings == warnings_avail). Else why not."""
    if f.warnings == 0:
        return ""
    kind = warn_kind(scope.get("allow_warnings"))
    if kind == "any":
        return ""
    n = f.warnings if f.warnings is not None else "unknown"
    if kind == "availability":
        if f.warnings is not None and f.warnings_avail is not None and f.warnings == f.warnings_avail:
            return ""
        a = f.warnings_avail if f.warnings_avail is not None else "unknown"
        return (f"the plan has {n} warning(s), {a} of them the availability gate's — the scope allows only the "
                "availability gate's (a policy gate: charged partition, occupancy … needs the user)")
    return (f"the plan has {n} warning(s) (a -y gate: charged partition, availability, occupancy) — needs the user "
            "unless the scope allows warnings")


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

    want_tg = scope.get("targets") or []
    if want_tg and deny:           # R5-8: normalised names; a spelling that is not one plain name may be any target
        have, keys = target_key(f.target), {target_key(x) for x in want_tg}
        if f.target and have is not None and None not in keys and have not in keys:
            miss.append(f"target {f.target} not in {', '.join(want_tg)}")
    else:
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
    want_c = scope.get("classes") or []
    if want_c and deny:            # the name's class, the label or a recorded one: any of them denied is enough; an
        if f.classes and not f.class_unknown and not set(f.classes) & set(want_c):   # attempt without one: may be any
            miss.append(f"class {'/'.join(f.classes)} not in {', '.join(want_c)}")
    elif want_c:
        lst("classes", f.cls, "class")
    names = scope.get("names") or []
    hit = f.name and (_glob(names, f.name) or (deny and (_glob(names, f.run) or _glob(run_globs(names), f.run))))
    if names and not hit:          # a deny: the run id's attempts too, and a glob written as an attempt's job name
                                   # (<run>--aNN, R7-1) is the whole run
        if not (deny and not f.name):
            miss.append(f"name {f.name or '?'} matches none of {', '.join(names)}")
    runs = scope.get("runs") or []         # a deny: a plan whose bound hash / plan id is not known here (a cancel of a
    if runs and f.bound_hash not in runs and not (deny and not f.bound_hash):   # job without a plan, a run-watch row)
        miss.append("not one of the approved plans (bound hash differs)")      # may be it: it matches (fail closed)
    plans = scope.get("plans") or []
    if plans and f.plan_id not in plans and not (deny and not f.plan_id):
        miss.append(f"not one of the approved plans ({f.plan_id or 'no plan id'} not in {', '.join(plans[:4])})")
    if not deny:
        for key, have, label, show in (("max_gpus", f.gpus, "GPUs", str), ("max_cpus", f.cpus, "CPUs", str),
                                       ("max_mem_gb", f.mem_gb, "GB memory", lambda v: f"{v:g}"),
                                       ("max_time_s", f.time_s if f.time_max_s is None else f.time_max_s,
                                        "time", _dur)):
            cap = scope.get(key)
            if cap is None:
                continue
            if have is None:
                miss.append(f"{label} not known (the scope caps them at {show(cap)})")
            elif have > cap:
                miss.append(f"{'unlimited' if have == math.inf else show(have)} {label} > {show(cap)}")
        w = _warn_miss(scope, f)
        if w:
            miss.append(w)
        if f.unreadable:
            miss.append(f"unreadable plan field(s): {', '.join(f.unreadable)}")
    return miss


def _dur(s: float) -> str:
    if s == math.inf:
        return "unlimited"
    s = int(s)
    d, r = divmod(s, 86400)
    return f"{d}-{r // 3600:02d}:{r % 3600 // 60:02d}:{r % 60:02d}" if d else f"{r // 3600}:{r % 3600 // 60:02d}:{r % 60:02d}"


def live_under(rid: str, state: L.LedgerState, extending: tuple[str, str] | None = None) -> int:
    """Live attempts under RID; EXTENDING = (run, attempt) a chain is adding a segment to (it holds its own slot)."""
    return sum(1 for run, rec in state.runs.items() for aid, a in (rec.get("attempts") or {}).items()
               if (a.get("request") or {}).get("grant") == rid and L.is_live(a)
               and (extending is None or (str(rec.get("run") or run), aid) != tuple(extending)))


def launches_used(rec: dict) -> int:
    return sum(1 for u in rec.get("used") or [] if u.get("action") in LAUNCHES)


def cancels_used(rec: dict) -> int:
    """The cancels counted under REC (a cancel_own grant counts them against max_launches)."""
    return sum(1 for u in rec.get("used") or [] if u.get("action") in ("cancel", "cancel_own"))


def _deny_actions(action: str) -> set[str]:
    """The deny actions that stop ACTION: a deny of launch stops every way of starting a run."""
    if action == "cancel":
        return {"cancel", "cancel_own"}
    return {action, "launch"} if action in LAUNCHES else {action}


def valid(rec: Any) -> str:
    """'' when REC passes validate(); else its problems."""
    try:
        validate(rec)
        return ""
    except RskError as exc:
        return str(exc)


def _revoked_ok(r: Any) -> bool:
    rv = r.get("revoked") if isinstance(r, dict) else None
    return isinstance(rv, dict) and bool(str(rv.get("quote", "")).strip()) and bool(L.epoch(rv.get("at")))


def fail_closed(r: Any) -> str:
    """'' unless R must count as a deny that matches everything: an invalid deny, a record whose id says deny (d-…)
    while its kind does not (or which validate() rejects), a record whose kind is missing or not one of the three,
    or an entry that is not a JSON object. A well-formed `revoked` ({at, quote}) ends it: it then matches nothing."""
    if not isinstance(r, dict):
        return "not a JSON object"
    kind, rid = r.get("kind"), str(r.get("id", ""))
    bad = valid(r)
    if kind in ("approval", "grant") and not rid.startswith("d-"):
        return ""                         # an invalid approval / grant covers nothing; never a deny
    if kind == "deny" and not bad:
        return ""                         # a valid deny: its scope decides
    if _revoked_ok(r):
        return ""
    if kind not in KINDS:
        return bad or f"kind {kind!r}"
    if kind != "deny":
        return f"its id {rid!r} says deny, its kind says {kind}" + (f"; {bad}" if bad else "")
    return bad


def unreadable(state: L.LedgerState) -> str:
    """'' unless the ledger's grants.json could not be read at all (corrupt, and no good .prev): then no deny can be
    ruled out — rsk launch, rsk cancel and rsk watch --act refuse (exit 6) with this text instead of acting as if there
    were no deny."""
    why = getattr(state, "grants_unreadable", "")
    if not why:
        return ""
    return (f"grants unreadable — rsk grant recount / restore: {why[:300]} — no deny it holds can be ruled out, so "
            "nothing is done: restore grants.json (or move it and its .prev aside and run rsk grant recount: every deny "
            "audit.jsonl shows comes back, a revoked grant stays revoked; re-import the user's grants with rsk grant "
            "import)")


def deny_match(plan: dict, actions: tuple[str, ...] | list[str], state: L.LedgerState, *,
               job: str | None = "") -> tuple[dict | None, str, dict | None]:
    """Pure. The deny that stops any of ACTIONS on PLAN: (record, reason, None). A cancel that only a cancel_own deny
    matches: (None, '', that deny) — the agent's own discretion is off, the user's named cancels stand. Else
    (None, '', None). JOB: a cancel's job id; None = not known (a deny naming job ids then matches: fail closed).
    A record fail_closed() names matches everything (a stand-in deny record is returned for it), and so does an
    unreadable grants.json (unreadable())."""
    t = time.time() if state.now is None else state.now
    bad_file = unreadable(state)
    if bad_file:
        return ({"id": "grants.json", "kind": "deny", "quote": "(unreadable)", "damaged": True},
                f"denied: {bad_file}", None)
    f = facts(plan or {})
    for r in state.grants:
        bad = fail_closed(r)
        if bad:
            d = r if isinstance(r, dict) else {}
            rid = str(d.get("id", "?"))
            stand_in = {"id": rid, "kind": "deny", "quote": str(d.get("quote") or "(a damaged record)"), "damaged": True}
            return stand_in, (f"denied by {rid}: a damaged record that may be a deny matches everything (fail closed: "
                              f"fix it by hand, or revoke it with the user's words) — {bad[:200]}; its words: "
                              f"\"{stand_in['quote']}\""), None
    wanted = set().union(*(_deny_actions(a) for a in actions)) if actions else set(ACTIONS)
    own: dict | None = None
    for d in state.grants:
        if d.get("kind") != "deny" or d.get("revoked") or valid(d):
            continue
        sc = d.get("scope") or {}
        acts = set(d.get("actions") or ACTIONS)
        widened = run_deny(d) and not (wanted & acts)
        if run_deny(d):              # R6-1: it names a run — every way of starting that run, wherever (see run_deny)
            acts |= LAUNCHES
        if _expired(d, t) or not (wanted & acts):
            continue
        jobs = sc.get("jobs") or []
        if jobs and job is not None and job not in jobs:
            continue
        if _scope_misses({k: v for k, v in sc.items() if k != "jobs"}, f, deny=True):
            continue
        if set(actions) == {"cancel"} and "cancel" not in acts:
            own = own or d               # cancel_own only
            continue
        return d, f"denied by {d['id']}: \"{d['quote']}\"" + (f" — {RUN_DENY_NOTE}" if widened else ""), None
    return None, "", own


RUN_DENY_NOTE = ("a deny of relaunching a run stops every launch of it, on any target in its scope: rsk cannot see "
                 "every earlier attempt (another target, run-watch, an older harness, another checkout)")


def run_deny(d: dict) -> bool:
    """R6-1: a deny that names a run (scope.names) and lists relaunch or resubmit — "do not relaunch run a" — matches
    EVERY launch-type action (launch, relaunch, resubmit, chain) of a plan whose name or run id its globs match (a glob
    written as an attempt's name, <run>--aNN, names that run: run_globs(), R7-1), on any target its scope allows: the
    action is derived from the history rsk can see, and a run's history may be where it cannot look (another target's
    journal, run-watch's state, a pre-journal harness, sacct only). A deny naming no run keeps the derived-action
    rule."""
    sc = d.get("scope") or {}
    return bool(sc.get("names")) and bool({"relaunch", "resubmit"} & set(d.get("actions") or ACTIONS))


def covers(plan: dict, action: str, state: L.LedgerState, *, orig: dict | None = None, job: str = "",
           own: bool = False, extending: tuple[str, str] | None = None, also: tuple[str, ...] = (),
           prev: tuple[str, dict] | None = None, ident: str = "") -> tuple[dict | None, list[str]]:
    """Pure. (deny record, [why]) when a deny matches — it wins; (record, []) for the first approval, then standing
    grant, that covers ACTION (and every action in ALSO) of PLAN; (None, reasons) otherwise. PREV = (aid, attempt) the
    run's latest attempt that may have run (a grant resumes only after its infrastructure end), ORIG = its request
    (relaunch / resubmit under a grant must repeat it); JOB / OWN / IDENT for cancel (OWN: a live submission rsk
    launched for this project; IDENT: cancel_ident() of the job); EXTENDING = the (run, attempt) a chain segment is
    added to (not counted against max_live). A record validate() rejects covers nothing; fail_closed() ones deny
    everything."""
    needed = tuple(dict.fromkeys((action, *also)))
    for a in needed:
        if a not in ACTIONS:
            raise RskError(f"action {a!r} (one of {', '.join(ACTIONS)})", USAGE)
    t = time.time() if state.now is None else state.now
    f = facts(plan or {})
    d, why, own_denied = deny_match(plan or {}, needed, state, job=job if action == "cancel" else "")
    if d:
        return d, [why]
    recs = [r for r in state.grants if isinstance(r, dict) and not r.get("revoked") and not valid(r)]
    reasons: list[str] = []
    order = sorted((r for r in recs if r.get("kind") in ("approval", "grant")),
                   key=lambda r: (r.get("kind") != "approval", str(r.get("created_at", ""))))
    for r in order:
        miss = _misses(r, plan or {}, f, action, needed, state, t, orig, job, own and own_denied is None, extending,
                       prev, ident)
        if own_denied is not None and r.get("kind") == "grant" and action == "cancel":
            miss = [f"cancel_own is denied by {own_denied['id']}: \"{own_denied['quote']}\""]
        if not miss:
            return r, []
        reasons.append(f"{r['id']}: {'; '.join(miss)}")
    for r in state.grants:
        bad = valid(r) if isinstance(r, dict) and r.get("kind") in ("approval", "grant") else ""
        if bad:
            reasons.append(f"{r.get('id', '?')}: an INVALID record covers nothing — {bad[:160]}")
    if not order and not reasons:
        reasons.append("no approval or grant recorded for this project")
    return None, reasons


def _ident_text(ident: str) -> str:
    try:
        f = json.loads(ident)
    except ValueError:
        return ident[:80]
    if not isinstance(f, list) or len(f) < 3:
        return ident[:80]
    if f[0] == "slurm":
        return f"job {f[2]} on {f[1]}" + (f" ({f[3]}" if len(f) > 3 and f[3] else " (") + \
            (f" in {f[4]})" if len(f) > 4 and f[4] else ")")
    return f"pid {f[2]} on {f[1]}" + (f" (start {f[3]}, boot {str(f[4])[:8]})" if len(f) > 4 else "")


def _infra_miss(prev: tuple[str, dict] | None) -> list[str]:
    """[] when the run's previous attempt ended with positive evidence of an infrastructure end (INFRA_END)."""
    if not prev:
        return ["the ledger has no earlier attempt of the run that ran (a relaunch grant resumes an infrastructure end "
                "it recorded; one only the target's journal shows — run-watch's, another checkout's — is the user's "
                "call): the user decides"]
    aid, att = prev
    st = str((att.get("result") or {}).get("state") or "")
    if st in INFRA_END:
        return []
    what = (f"ended {st}" if st else "is live or its end is unknown" if L.is_live(att) else "has no recorded end")
    return [f"its previous attempt {aid} {what} — a relaunch grant resumes only an infrastructure end "
            f"({', '.join(INFRA_END)}): anything else is the user's call"]


def _misses(r: dict, plan: dict, f: Facts, action: str, needed: tuple[str, ...], state: L.LedgerState, t: float,
            orig: dict | None, job: str, own: bool, extending: tuple[str, str] | None = None,
            prev: tuple[str, dict] | None = None, ident: str = "") -> list[str]:
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
                return [f"job {job} was cancelled under it already (a cancel approval is used once, whatever came of it)"]
            if sc.get("targets") and f.target and f.target not in sc["targets"]:
                return [f"target {f.target} not in {', '.join(sc['targets'])}"]
            idents = sc.get("idents") or []
            if not ident or ident not in idents:
                return [f"it was given for {', '.join(_ident_text(x) for x in idents[:3]) or 'nothing'}, not "
                        f"{_ident_text(ident) if ident else 'this (no identity)'}: the user's words were for that one"]
            return []
        if "cancel_own" not in acts:
            return ["no cancel_own in its actions"]
        if not own:
            return ["the job is not a live run rsk launched for this project — not one rsk launched, or one the ledger "
                    "shows ended (cancel_own covers only the agent's own live runs)"]
        mx = lim.get("max_launches")
        if mx is not None and cancels_used(r) >= mx:
            return [f"used {cancels_used(r)} of {mx} (its max_launches counts cancel_own uses too)"]
        return [m for m in _scope_misses({k: v for k, v in sc.items() if k not in NUMS + ("allow_warnings",)}, f,
                                         deny=False)]
    missing = [a for a in needed if a not in acts]
    if missing:
        return [f"action {'/'.join(missing)} not in {', '.join(acts)}"]
    if r["kind"] == "approval":
        miss = _scope_misses(sc, f, deny=False)
        if not miss:
            n = sum(1 for u in r.get("used") or [] if u.get("hash") == f.bound_hash)
            if n >= int(lim.get("max_launches") or 1):
                miss.append(f"this plan was used {n} time(s) under it already")
            ml = lim.get("max_live")
            if ml is not None and live_under(r["id"], state, extending) >= ml:
                miss.append(f"{live_under(r['id'], state, extending)} of {ml} live runs under it")
    else:
        miss = _scope_misses(sc, f, deny=False)
        if f.kind == "slurm" and not f.conf_extra:
            miss.append("the plan does not name the conf's SBATCH_EXTRA words (no conf_extra: a deploy older than this "
                        "rsk) — the user decides")
        if f.extra_res:
            miss.append(f"SBATCH_EXTRA word(s) no standing grant covers ({', '.join(f.extra_res)}): the user decides "
                        "(an approval of this card covers them)")
        if f.kind == "slurm" and not f.flags_known:
            miss.append("the plan does not name its policy flags (no flags=: a deploy older than this rsk) — the user "
                        "decides")
        if f.flags:
            miss.append(f"policy flag(s) {' '.join(f.flags)}: what the target's policy makes of them is outside any "
                        "scope — no standing grant covers a plan with policy flags (an approval of this card does)")
        if {"relaunch", "resubmit"} & set(needed):
            if not orig or not (orig.get("bound") or orig.get("bound_hash")):
                miss.append(f"its previous attempt {prev[0]} has no recorded plan (adopted?): the user decides" if prev
                            else "no previous attempt in the ledger to repeat: the user decides")
            else:
                diff = same_config(orig, plan)
                if diff:
                    miss.append(f"not the configuration of {prev[0] if prev else 'the attempt'} it resumes: "
                                + "; ".join(diff[:4]))
            miss += _infra_miss(prev)
        mx = lim.get("max_launches")
        if mx is not None and launches_used(r) >= mx:
            miss.append(f"used {launches_used(r)} of {mx} launches")
        ml = lim.get("max_live")
        if ml is not None and live_under(r["id"], state, extending) >= ml:
            miss.append(f"{live_under(r['id'], state, extending)} of {ml} live runs under it")
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


def _anum(aid: str) -> int:
    return int(aid[1:]) if aid[1:].isdigit() else 0


def _ran(att: dict) -> bool:
    """An attempt that may have run: any submission submitted, adopted or unknown (not only not_submitted ones)."""
    return any(s.get("submit") != "not_submitted" for s in att.get("submissions") or [])


def prior_attempts(runs: dict, run: str, plan_id: str = "") -> list[tuple[str, dict]]:
    """RUN's attempts that may have run, oldest first, without PLAN_ID's own (a chain's segments, a retried plan)."""
    atts = (runs.get(run) or {}).get("attempts") or {}
    return sorted(((k, a) for k, a in atts.items()
                   if not (plan_id and (a.get("request") or {}).get("plan") == plan_id) and _ran(a)),
                  key=lambda kv: _anum(kv[0]))


def _original(prev: tuple[str, dict] | None) -> dict | None:
    """The configuration a relaunch / resubmit must repeat: that of PREV, the run's latest attempt that may have run —
    the one whose end a relaunch grant relies on (never an older attempt the plan happens to be named after)."""
    if not prev:
        return None
    att = prev[1]
    return {**dict(att.get("request") or {}), "target": att.get("target", ""), "kind": att.get("kind", "")}


def check(ledger: L.Ledger | L.LedgerState, action: str, *, plan: dict | None = None, job: str = "", run: str = "",
          now: float | None = None, extending: tuple[str, str] | None = None, also: tuple[str, ...] = (),
          ident: str = "") -> Decision:
    """The one entry point: may ACTION (and every action in ALSO) happen without asking the user again?
    launch / chain: plan=parsed block (+ optional "class", "classes_recorded", "plan_id"). relaunch / resubmit: plan +
    run=<run id> (the original attempt's configuration must be repeated, and a grant needs the previous attempt's
    infrastructure end). cancel: job=<id> + ident=cancel_ident() (+ run=<run id> for cancel_own, plan={"target": t}
    when the run is not in the ledger)."""
    state = ledger.state(now) if isinstance(ledger, L.Ledger) else ledger
    if now is not None:
        state.now = now
    needed = tuple(dict.fromkeys((action, *also)))
    if any(a in LAUNCHES for a in needed) and not plan:
        raise RskError(f"check({action}) needs the plan", USAGE)
    why = unreadable(state)
    if why:
        raise RskError(why, CONFLICT)
    orig, prev, own, facts_plan = None, None, False, dict(plan or {})
    if {"relaunch", "resubmit"} & set(needed):
        if not run:
            raise RskError(f"check({action}) needs the run id", USAGE)
        prior = prior_attempts(state.runs, run, str(facts_plan.get("plan_id", "")))
        prev = prior[-1] if prior else None
        orig = _original(prev)
    if action == "cancel":
        if not job:
            raise RskError("check(cancel) needs the job id (or the nohup pid)", USAGE)
        run_rec = state.runs.get(run) or {}
        hits = [(a, s) for a in (run_rec.get("attempts") or {}).values() for s in a.get("submissions") or []
                if job in (s.get("job"), str((s.get("proc") or {}).get("pid", "")))]
        live = [(a, s) for a, s in hits if not a.get("result") and not s.get("end")
                and s.get("submit") != "not_submitted" and (s.get("seen") or {}).get("state", "") not in L.TERMINAL]
        if hits:   # the submission the cancel is about: a live one (cancel_own covers only that), else the last that ended
            a, s = (live or hits)[-1]
            req = a.get("request") or {}
            own = bool(live) and req.get("action") in LAUNCHES and s.get("submit") != "adopted" and bool(req.get("plan"))
            facts_plan = {"target": a.get("target", ""), "kind": a.get("kind", ""), "warnings": "0",
                          **req.get("bound", {}), "name": a.get("name", ""),
                          "bound_hash": str(req.get("bound_hash") or ""), "plan_id": str(req.get("plan") or ""),
                          "classes_recorded": run_classes(run_rec),
                          **({"class": req["class"]} if req.get("class") else {})}
    rec, reasons = covers(facts_plan, action, state, orig=orig, job=job, own=own, extending=extending, also=also,
                          prev=prev, ident=ident)
    if rec and rec.get("kind") == "deny":
        return Decision(False, rec, reasons, "")
    if rec:
        return Decision(True, rec, [], "")
    what = {"cancel": f"cancel job {job}"}.get(action, f"{'/'.join(needed)} of {facts(facts_plan).name or 'this plan'}")
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
        who = "; ".join(_ident_text(x) for x in (sc.get("idents") or [])[:4])
        return (f"cancel of job(s) {', '.join(sc.get('jobs') or [])}{on} — each once, used up by its first cancel "
                f"whatever came of it" + (f"; bound to {who}" if who else "")
                + (f"; until {lim['expires']}" if lim.get("expires") else "") + "; identity checked at cancel time")
    if rec.get("kind") == "approval":
        runs = sc.get("runs") or []
        shown = ", ".join(h[:12] for h in runs[:4]) + (f" +{len(runs) - 4}" if len(runs) > 4 else "")
        ids = sc.get("plans") or []
        return (f"{'/'.join(acts)} of {len(runs)} approved plan(s) [{shown}]{on} — each {lim.get('max_launches', 1)}x"
                f"; {'warnings the user saw' if warn_kind(sc.get('allow_warnings')) else 'no plan with warnings'}"
                + (f"; only plan(s) {', '.join(ids[:4])}{f' +{len(ids) - 4}' if len(ids) > 4 else ''}" if ids else "")
                + (f"; until {lim['expires']}" if lim.get("expires") else ""))
    parts = []
    for key, label in (("targets", "targets"), ("partitions", "partitions"), ("gpu_types", "GPU types"),
                       ("classes", "classes"), ("names", "names"), ("jobs", "jobs")):
        if sc.get(key):
            parts.append(f"{label} {', '.join(sc[key])}")
            if key == "names" and rec.get("kind") == "deny" and run_globs(sc[key]):
                parts[-1] += f" (= run {', '.join(run_globs(sc[key]))}: every attempt of it)"
    if sc.get("runs"):
        parts.append(f"plans {', '.join(h[:12] for h in sc['runs'])}")
    for key, show in (("max_gpus", lambda v: f"<= {v} GPUs"), ("max_cpus", lambda v: f"<= {v} CPUs"),
                      ("max_mem_gb", lambda v: f"<= {v:g} GB"), ("max_time_s", lambda v: f"<= {_dur(v)}")):
        if sc.get(key) is not None:
            parts.append(show(sc[key]))
    where = "; ".join(parts) or "anything"
    if rec.get("kind") == "deny":
        also = (" (it names a run: every launch of it too — rsk cannot see every earlier attempt)"
                if run_deny(rec) and not LAUNCHES <= set(acts) else "")
        return f"DENY {'every action' if set(acts) == set(ACTIONS) else ', '.join(acts)}{also}: {where}"
    extra = {"any": "plans with warnings too (every -y gate, policy gates included)",
             "availability": "plans whose only warnings are the availability gate's (-y)"}.get(
        warn_kind(sc.get("allow_warnings")), "no plan with warnings")
    if "cancel_own" in acts:
        extra += "; may stop its own runs in scope"
    if "relaunch" in acts or "resubmit" in acts:
        extra += f"; a relaunch only after an infrastructure end ({'/'.join(INFRA_END)})"
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
        out = f"jobs used {len(done)}/{len(sc.get('jobs') or [])} (each by its first cancel, whatever came of it)"
    elif rec.get("kind") == "approval":
        hashes = sc.get("runs") or []
        n = sum(1 for h in hashes if any(u.get("hash") == h for u in rec.get("used") or []))
        out = f"plans used {n}/{len(hashes)}"
    else:
        unknown = state.affected(rec)
        acts = rec.get("actions") or []
        launching = any(a in LAUNCHES for a in acts)
        parts = []
        if launching or "cancel_own" not in acts:
            u = "?" if unknown else str(launches_used(rec))
            lv = "?" if unknown else str(live_under(rec["id"], state))
            parts += [f"launches {u}/{_limit_text(lim.get('max_launches'))}",
                      f"live {lv}/{_limit_text(lim.get('max_live'))}"]
        if "cancel_own" in acts:     # each cancel_own counts against max_launches too
            c = "?" if unknown else str(cancels_used(rec))
            parts.append(f"{'cancels' if launching else 'uses'} {c}/{_limit_text(lim.get('max_launches'))}")
        out = " · ".join(parts + [f"expires {_limit_text(lim.get('expires'))}"])
    return f"{state_txt} · {out}" if state_txt else out


def _overlap(a: dict, b: dict) -> bool:
    def acts(r: dict) -> set[str]:
        s = set(r.get("actions") or ACTIONS) | (set(LAUNCHES) if r.get("kind") == "deny" and run_deny(r) else set())
        return s | ({"cancel", "cancel_own"} if s & {"cancel", "cancel_own"} else set())
    if not acts(a) & acts(b):
        return False
    sa, sb = a.get("scope") or {}, b.get("scope") or {}
    for k in LISTS:
        x, y = sa.get(k) or [], sb.get(k) or []
        if not x or not y:
            continue
        if k == "names":           # a deny's attempt name (<run>--aNN) stands for its run (R7-1)
            x = x + (run_globs(x) if a.get("kind") == "deny" else [])
            y = y + (run_globs(y) if b.get("kind") == "deny" else [])
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
    if not isinstance(rec, dict) or rec.get("kind") == "deny":
        return []
    records = [r for r in records if isinstance(r, dict)]
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


def lines(state: L.LedgerState, show_all: bool = False, indent: str = "  ", known: list | None = None) -> list[str]:
    """`rsk grant list` / `rsk status`: one block per record. KNOWN (harness_targets()): flag an active record whose
    scope names a target the harness does not know (R6-9: scope_warning()), and NOTE a partition its targets'
    T_PARTITIONS display lists do not name (R7-2: scope_notes())."""
    out = []
    if state.budgets_unknown:
        out.append(f"{indent}BUDGETS UNKNOWN: {state.budgets_unknown[:300]} — records from before it cover nothing "
                   "until `rsk grant recount` (rebuilds the counts from audit.jsonl)")
    t = time.time() if state.now is None else state.now
    for r in state.grants:
        bad = valid(r)
        closed = fail_closed(r)
        if bad and not closed and not show_all and isinstance(r, dict) and r.get("kind") == "approval":
            continue                   # covers nothing; an approval from before plan scoping is history (--all shows it)
        if bad or closed:
            rid = r.get("id", "?") if isinstance(r, dict) else "?"
            if closed:
                what = ("not a record: a deny matching EVERYTHING until it is removed from grants.json by hand (fail "
                        "closed)" if not isinstance(r, dict) else
                        "taken as a deny: matches EVERYTHING until fixed by hand or revoked (fail closed)")
            elif _revoked_ok(r) and (r.get("kind") == "deny" or str(rid).startswith("d-") or r.get("kind") not in KINDS):
                what = "revoked: matches nothing"
            else:
                what = "covers nothing"
            out.append(f"{indent}{rid}  INVALID — {what}: {(bad or closed)[:300]}")
            continue
        if not show_all and (r.get("revoked") or _expired(r, t)):
            continue
        out.append(f"{indent}{r['id']}  {r['kind']}  via {r.get('created_via')}{' (' + r['source'] + ')' if r.get('source') else ''}"
                   f"  {r.get('created_at')}")
        out.append(f"{indent}  covers: {describe(r)}")
        out.append(f"{indent}  {balance(r, state)}")
        out.append(f"{indent}  quote: \"{r.get('quote', '')}\"")
        for f in after_deny(r, state.grants):
            out.append(f"{indent}  FLAG: {f} — confirm with the user that it replaces the deny")
        if known is not None and active(r, t):
            problems, whole = scope_problems(r, known)
            if problems:
                out.append(f"{indent}  {scope_warning(r, problems, whole)}")
            out += [f"{indent}  {n}" for n in scope_notes(r, known)]
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
        sc["allow_warnings"] = args.allow_warnings
    return sc


def harness_targets() -> list:
    """Every target the harness knows, as harness.Target (lib/common.sh's rs_targets: overlay, packs, shipped — also one
    whose profile does not load), with the profile's T_PARTITIONS. A listing that fails is a usage error: no -T can be
    checked then."""
    from remote_run import harness, paths
    try:
        return harness.targets(paths.harness_src())
    except (OSError, subprocess.SubprocessError) as exc:
        raise RskError(f"cannot list the harness's targets ({exc}): no target can be checked — nothing recorded",
                       USAGE) from exc


def known_targets() -> list[str]:
    return [t.name for t in harness_targets()]


def check_targets(names: list[str], what: str, tl: list | None = None) -> None:
    """R5-9: every target a record names must be one the harness knows (a misspelt one would make a deny match
    nothing): exit 2 'unknown target', nothing recorded. TL: harness_targets(), when the caller has it."""
    names = [n for n in dict.fromkeys(names) if n]
    if not names:
        return
    known = [t.name for t in (harness_targets() if tl is None else tl)]
    bad = [n for n in names if n not in known]
    if not bad:
        return
    near = {n: [k for k in known if target_key(k) is not None and target_key(k) == target_key(n)] for n in bad}
    hint = "; ".join(f"{n!r} is spelled {', '.join(near[n])} here" for n in bad if near[n])
    raise RskError(f"unknown target {', '.join(repr(n) for n in bad)} ({what}): the harness knows "
                   f"{', '.join(known) or 'none'}{' — ' + hint if hint else ''} — nothing recorded", USAGE)


def _scoped(targets: list[str], tl: list, deny: bool = False) -> list:
    """The harness.Target entries TARGETS names (every one the harness knows when TARGETS is empty); DENY: compared as
    target_key() names, as a deny compares them."""
    if not targets:
        return list(tl)
    if deny:
        keys = {target_key(x) for x in targets}
        return [t for t in tl if target_key(t.name) is not None and target_key(t.name) in keys]
    return [t for t in tl if t.name in targets]


def partition_lists(scoped: list) -> tuple[list[str], list[str]]:
    """(the partitions the SCOPED targets' profiles list in T_PARTITIONS — a DISPLAY list: policy.sh's t_partition is
    the authority, and the profile may list fewer —, the scoped Slurm targets whose profile lists none). A workstation
    has no partitions; a target whose profile does not load lists none."""
    known: list[str] = []
    unchecked: list[str] = []
    for t in scoped:
        if t.kind == "nohup":
            continue
        if t.partitions is None:
            unchecked.append(t.name)
        else:
            known += [p for p in t.partitions if p not in known]
    return known, unchecked


def partition_note(parts: list[str], scoped: list, where: str, what: str = "") -> str:
    """R7-2: '' unless a partition of PARTS is not in the SCOPED targets' T_PARTITIONS display lists — then the NOTE
    that says so. Never a refusal: T_PARTITIONS is display-only (the shipped template: policy.sh is the authority), so
    a partition the profile does not list may be real; the record is kept as given and matches a plan whose partition
    is spelled so (a deny that cannot be recorded would be lost, and a grant of an unlisted one covers only that)."""
    parts = [p for p in dict.fromkeys(parts) if p]
    if not parts:
        return ""
    known, unchecked = partition_lists(scoped)
    bad = [p for p in parts if p not in known]
    if not bad:
        return ""
    lists = [f"{t.name}: {', '.join(t.partitions)}" for t in scoped if t.kind != "nohup" and t.partitions]
    lists += [f"{', '.join(unchecked)}: none"] if unchecked else []
    slurm = [t for t in scoped if t.kind != "nohup"]
    return (f"NOTE: partition {', '.join(bad)}{f' ({what})' if what else ''} is not in the profile's display list "
            "(T_PARTITIONS of "
            + ("; ".join(lists) if lists else f"{where}: none") + ") — recorded as given: policy.sh, not the profile, "
            "decides which partitions exist; the record matches only a plan whose partition is spelled exactly so"
            + ("" if slurm else f" ({where}: a workstation has no partitions — no launch there names one)"))


def check_scope(scope: dict, tl: list, t_what: str = "-T", p_what: str = "--partition") -> list[str]:
    """R5-9 for a record about to be stored: its targets must be known (exit 2 'unknown target': a deny on a misspelt
    target would match nothing). Its partitions are never refused (R7-2: T_PARTITIONS is a display list, policy.sh is
    the authority): one the scoped targets' profiles do not list gets a NOTE (partition_note()). A GPU type has no list
    anywhere: echoed in a NOTE, never checked. Returns the NOTE lines (P_WHAT: where the partitions were given)."""
    targets = [x for x in scope.get("targets") or [] if x]
    check_targets(targets, t_what, tl)
    notes: list[str] = []
    parts = [p for p in dict.fromkeys(scope.get("partitions") or []) if p]
    if parts:
        n = partition_note(parts, _scoped(targets, tl), ", ".join(targets) if targets else "the targets the harness knows",
                           p_what if p_what != "--partition" else "")
        if n:
            notes.append(n)
    gts = [g for g in dict.fromkeys(scope.get("gpu_types") or []) if g]
    if gts:
        notes.append(f"NOTE: GPU type {', '.join(gts)} is not checked (no list of GPU types exists): the record matches "
                     "only a plan whose GPU type is spelled so (any case) — compare it with the target's reference")
    return notes


def _stored_targets(rec: dict, tl: list) -> tuple[list[str], list[str]]:
    """(REC's scope targets, the ones the harness does not know) — a deny compares target_key() names (a spelling that
    is not one plain name matches every target: never unknown), a grant / approval the exact name."""
    sc, deny = rec["scope"], rec.get("kind") == "deny"
    names = [t.name for t in tl]
    keys = {target_key(n) for n in names}
    tg = [x for x in sc.get("targets") or [] if isinstance(x, str) and x]
    if deny:
        return tg, [x for x in tg if target_key(x) is not None and target_key(x) not in keys]
    return tg, [x for x in tg if x not in names]


def scope_problems(rec: Any, tl: list) -> tuple[list[str], bool]:
    """R6-9 / R7-2 for a STORED record: ([the targets in its scope the harness does not know], whether the whole record
    is inert) — only TARGETS: a partition the profiles do not list is a NOTE (scope_notes(): T_PARTITIONS is a display
    list, policy.sh decides), never "never matches". ([], False) for a record without such a part."""
    if not isinstance(rec, dict) or not isinstance(rec.get("scope"), dict):
        return [], False
    tg, unknown = _stored_targets(rec, tl)
    if not unknown:
        return [], False
    return ([f"target {', '.join(unknown)} is not one the harness knows ({', '.join(t.name for t in tl) or 'none'})"],
            len(unknown) == len(tg))


def scope_notes(rec: Any, tl: list) -> list[str]:
    """R7-2 for a STORED record: the NOTE for a partition its scoped targets' T_PARTITIONS display lists do not name
    (it may be real: policy.sh decides; the record matches a plan whose partition is spelled so). [] otherwise."""
    if not isinstance(rec, dict) or not isinstance(rec.get("scope"), dict):
        return []
    tg, unknown = _stored_targets(rec, tl)
    parts = [p for p in rec["scope"].get("partitions") or [] if isinstance(p, str) and p]
    live = [x for x in tg if x not in unknown]
    if not parts or (tg and not live):
        return []
    deny = rec.get("kind") == "deny"   # (a deny target that is not one plain name may be any target: all of them)
    scoped = _scoped([] if deny and any(target_key(x) is None for x in live) else live, tl, deny)
    n = partition_note(parts, scoped, ", ".join(live) if live else "the targets the harness knows")
    return [n] if n else []


def scope_warning(rec: dict, problems: list[str], whole: bool) -> str:
    """The one line `rsk grant list`, `rsk status` and `rsk doctor` print for a record scope_problems() flags: a target
    the harness does not know is never a launch's, a cancel's or a run-watch row's (run-watch takes only a listed name)."""
    rid = rec.get("id", "?")
    what = ("the user's deny is not enforced there" if rec.get("kind") == "deny" else "it covers nothing there")
    return (f"WARNING: {rid} ({rec.get('kind')}): {'; '.join(problems)} — never matches{'' if whole else ' there'} "
            f"({what}) — fix or revoke: rsk grant revoke {rid} --quote \"<the user's words>\", then record it again "
            "with a scope the harness knows")


def active(rec: Any, t: float) -> bool:
    """A record that still counts: valid, not revoked, not expired."""
    return isinstance(rec, dict) and not valid(rec) and not rec.get("revoked") and not _expired(rec, t)


def stale_records(tl: list) -> list[str]:
    """R6-9 for `rsk doctor`: every active record of every project ledger in this state dir whose scope names a target
    the harness does not know (R7-2: targets only — an unlisted partition is a NOTE in rsk grant list / status) — one
    line each (read-only; a ledger that cannot be read is said so)."""
    from remote_run import paths
    root = paths.state_dir() / "projects"
    out: list[str] = []
    try:
        dirs = sorted(d for d in root.iterdir() if d.is_dir())
    except OSError:
        return out
    t = time.time()
    for d in dirs:
        try:
            proj = (d / "project").read_text(encoding="utf-8").strip()
        except OSError:
            proj = ""
        got = L.read_json(d / "grants.json", L._is_grants)     # (a .prev when the file is torn: what list shows)
        if got.data is None:
            if got.source == "corrupt":
                out.append(f"{proj or d}: grants.json unreadable ({got.why[:160]}) — rsk grant list -C {proj or '<project>'}")
            continue
        for r in got.data.get("records") or []:
            if not active(r, t):
                continue
            problems, whole = scope_problems(r, tl)
            if problems:
                out.append(f"{proj or d}: {scope_warning(r, problems, whole).removeprefix('WARNING: ')}")
    return out


def attempt_name_notes(names: list[str]) -> list[str]:
    """R7-1 at record time: a deny name written as an attempt's job name (<run>--aNN), or as a glob over attempt
    names (run_glob()) — the NOTE that it stands for the whole run (every attempt of it, launches and cancels alike)."""
    out = []
    for g in dict.fromkeys(names):
        if run_glob(g):
            what = "is an attempt's name" if L.run_id(g) != g else "matches attempts' names"
            out.append(f"NOTE: name {g} {what} (--aNN): the deny stands for run {run_glob(g)} — every attempt of it, "
                       "the next one included (an attempt is launched once)")
    return out


def _job_runs(led: L.Ledger, jobs: list[str]) -> list[str]:
    """The ledger runs whose submissions carry one of JOBS (a Slurm id or a nohup pid): what a deny of their launches
    names."""
    out = []
    for run, got in sorted(led.runs().items()):
        for att in ((got.data or {}).get("attempts") or {}).values():
            for s in att.get("submissions") or []:
                if str(s.get("job") or "") in jobs or str((s.get("proc") or {}).get("pid", "")) in jobs:
                    out.append(str((got.data or {}).get("run") or run))
    return list(dict.fromkeys(out))


def cmd_grant(args: argparse.Namespace) -> int:
    from remote_run.status import project_dir   # status imports this module
    led = L.Ledger(project_dir(args.dir))
    c = args.grant_command
    if c in ("add", "deny"):
        acts = _split(args.actions)
        if c == "deny" and _split(args.jobs) and set(acts or ACTIONS) & LAUNCHES:    # R5-1
            runs = _job_runs(led, _split(args.jobs))
            raise RskError(f"rsk grant deny --job {','.join(_split(args.jobs))}: a deny by job id is for cancels only "
                           f"(--action cancel / cancel_own), not {'/'.join(a for a in (acts or ACTIONS) if a in LAUNCHES)}"
                           f": a deny of a run's launches names the run: "
                           + (" ".join(f"--name '{r}'" for r in runs) if runs else "--name '<run>'")
                           + " — nothing recorded", USAGE)
        scope_args = {k: _split(getattr(args, k, [])) for k in ("targets", "partitions", "gpu_types")}
        notes = check_scope(scope_args, harness_targets()) if scope_args["targets"] or scope_args["partitions"] else \
            check_scope({"gpu_types": scope_args["gpu_types"]}, [])
        if c == "deny":                         # R7-1: an attempt's job name stands for its run
            notes += attempt_name_notes(_split(args.names))
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
        for n in notes:
            print(f"  {n}")
        return OK
    if c == "revoke":
        r = revoke(led, args.id, args.quote)
        print(f"{r['id']} revoked: {describe(r)}")
        return OK
    if c == "import":
        notes: dict[str, list[str]] = {}

        def check(rs: list[dict]) -> None:        # every record's targets (R5-9: all or nothing); partitions: NOTEs (R7-2)
            tl = harness_targets() if any((r.get("scope") or {}).get(k) for r in rs for k in ("targets", "partitions")) \
                else []
            for i, r in enumerate(rs):
                notes[r["id"]] = check_scope(r.get("scope") or {}, tl, f"scope.targets in {args.file}",
                                             f"scope.partitions of #{i} in {args.file}")
                if r.get("kind") == "deny":
                    notes[r["id"]] += attempt_name_notes((r.get("scope") or {}).get("names") or [])
        recs = import_file(led, Path(args.file), check=check)
        st = led.state()
        for r in recs:
            print(f"{r['id']}  {r['kind']}  imported from {r['source']}  covers: {describe(r)}  ({balance(r, st)})")
            for f in after_deny(r, st.grants):
                print(f"  FLAG: {f}")
            for n in notes.get(r["id"], []):
                print(f"  {n}")
        return OK
    if c == "recount":
        print(recount(led))
        return OK
    st = led.state()
    try:                                        # R6-9: a record naming what the harness does not know is flagged
        tl: list | None = harness_targets()
        tl_note = ""
    except RskError as exc:
        tl, tl_note = None, f"  NOTE: unknown targets not checked: {exc}"
    if args.json:
        print(json.dumps({"ledger": str(led.dir), "budgets_unknown": st.budgets_unknown, "records": [
            {**r, "covers": describe(r), "balance": balance(r, st), "flags": after_deny(r, st.grants),
             "fail_closed": "", "scope_problems": scope_problems(r, tl)[0] if tl is not None else None,
             "scope_notes": scope_notes(r, tl) if tl is not None else None}
            if isinstance(r, dict) and not valid(r) else
            {"record": r, "invalid": valid(r), "fail_closed": fail_closed(r)}
            for r in st.grants]}, indent=1, ensure_ascii=False))
        return OK
    body = lines(st, args.all, known=tl)
    print(f"grants of {led.project} (ledger {led.dir})")
    print("\n".join(body) if body else "  none recorded — every launch and cancel needs the user's approval")
    if tl_note:
        print(tl_note)
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
        p.add_argument("-T", "--target", dest="targets", action="append", default=[],
                       help="a target the harness knows (exit 2 otherwise)")
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
    a.add_argument("--allow-warnings", default=None, choices=WARN_KINDS, metavar="availability|any",
                   help="also plans with warnings, only when the user's words say so: availability = only the "
                   "harness's own availability gate (\"queue it even if the cluster is busy\"); any = every -y gate, "
                   "policy gates too (a charged partition …)")
    a.add_argument("--max-live", required=True, metavar="N|none")
    a.add_argument("--max-launches", required=True, metavar="N|none")
    a.add_argument("--expires", required=True, metavar="YYYY-MM-DD|none")
    d = gs.add_parser("deny", help="the user forbade it: a matching deny always wins")
    scope(d, True)
    d.add_argument("--job", dest="jobs", action="append", default=[],
                   help="a job id / pid — for cancels only (--action cancel, cancel_own); a run's launches: --name RUN")
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
