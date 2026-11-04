"""`rsk status` and `rsk logs`: read-only views of a project on its targets.

status: what runs (or ran in the last --days) from this project's remote dir on every target its conf names, with the
age and source of the evidence; an unobservable target says so and why — its last state is unknown, not "nothing".
It also reads the local ledger (ledger.py) and records what it saw there — never anything on a target:
- ledger runs, one line each: the latest attempt's state, the age and source of that evidence (a failed read leaves
  the last good observation in place and says the target is unobservable now);
- UNLEDGERED: live jobs/runs of this dir the ledger does not know (adopt them: rsk adopt), and journal attempts
  (.rs/attempts/<nonce>/) the ledger does not know whose outcome is open;
- SUBMIT_UNKNOWN attempts reconciled from the remote journal: a receipt, or a job whose comment carries rs=<nonce>
  = submitted; result verdict refused|failed = not submitted (its grant use is given back); anything else stays
  SUBMIT_UNKNOWN (sticky: never resubmitted blind) and becomes a `needs user:` line;
- nohup end states from <log>.rc, the watch lease, every active grant with its balance, and `needs user:` lines.
  A needs-user line names the decision, never a ready-to-run --approve command (the user's words come first).
logs: the deployed bounded digest (remote/status.sh) for one job id or log path — the one monitoring read.
"""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import time
from pathlib import Path

from remote_run import grants, harness, observe, paths
from remote_run import ledger as L
from remote_run.errors import FAILED, OK, UNKNOWN, USAGE, RskError

ORDER = {"RUNNING": 0, "ALIVE": 0, "PENDING": 1, "REQUEUED": 1, "SUSPENDED": 1, "CONFIGURING": 1, "COMPLETING": 1}


def project_dir(arg: str | None) -> Path:
    d = Path(arg or ".").resolve()
    if not ((d / ".hpc.conf").is_file() or (d / ".ws.conf").is_file()):
        raise RskError(f"no .hpc.conf or .ws.conf in {d} — run from the project root (or -C DIR); a new project: "
                       "references/project-setup.md", USAGE)
    return d


def select(all_places: list[harness.Place], wanted: list[str] | None) -> list[harness.Place]:
    by = {p.target: p for p in all_places}
    if wanted:
        missing = [t for t in wanted if t not in by]
        if missing:
            raise RskError(f"no remote dir for {', '.join(missing)} in this project's conf (resolvable here: "
                           f"{', '.join(t for t, p in by.items() if not p.error) or 'none'}) — never guess it", USAGE)
        chosen = [by[t] for t in dict.fromkeys(wanted)]
        for p in chosen:
            if p.error:
                raise RskError(f"target {p.target}: its profile does not load: {p.error}", USAGE)
    else:
        chosen = all_places
    slurm = [p for p in chosen if p.kind == "slurm"]
    if len(slurm) > 1 and any(p.remote_host for p in slurm):   # bin/run-watch refuses the same
        raise RskError(f"REMOTE_HOST in the conf is not per target: name one Slurm target with -T "
                       f"({', '.join(p.target for p in slurm)} would all be read on {slurm[0].host})", USAGE)
    return chosen


def _line(j: observe.Job, now: int) -> str:
    if j.source == "pid":
        if j.state == "ALIVE":
            return f"  ALIVE     pid {j.pid:<8} {j.name}  up {observe.age(now - j.start)}  log {j.log}"
        why = {"gone": "pid gone", "reused": "pid reused by another process", "nopid": "no .pid file",
               "unknown": "pid unreadable"}.get(j.reason, j.reason)
        if j.rc:
            why = f"rc {j.rc.get('rc')}" + (" after TERM" if j.rc.get("term") == "1" else "") + " (.rc)"
            return f"  {j.state:<9} {'':12} {j.name}  {why}; ended {observe.age(now - j.end)} ago  log {j.log}"
        return f"  {j.state:<9} {'':12} {j.name}  {why}; log written {observe.age(now - j.end)} ago  log {j.log}"
    extra = ""
    if j.state == "PENDING" and j.reason:
        extra = f"  ({j.reason})"
    elif j.state == "RUNNING":
        extra = f"  up {observe.age(now - j.start)}" if j.start else ""
        extra += f"  restarts {j.restarts}" if j.restarts not in ("", "0") else ""
    elif j.end:
        extra = f"  rc {j.exit_code}" if j.exit_code and j.exit_code != "0:0" else ""
        extra += f"  ended {observe.age(now - j.end)} ago"
    return f"  {j.state:<9} job {j.id:<8} {j.name}{extra}"


def render(o: observe.Observation, days: int, known: set[str] | None = None) -> list[str]:
    """KNOWN: the job ids / logs the ledger holds on this target (None: no ledger view, no UNLEDGERED tags)."""
    p = o.place
    head = f"[{p.target}] {p.host}:{p.remote_dir}" if p.host else f"[{p.target}]"
    if not o.ok:
        return [f"{head}  UNOBSERVABLE: {o.why} — its runs' state is unknown, not 'none'"]
    now = o.now or int(o.observed_at)
    lines = [f"{head}  observed {time.strftime('%H:%M:%SZ', time.gmtime(o.observed_at))} "
             f"({'squeue + sacct ' + str(days) + 'd' if p.kind == 'slurm' else 'logs/*.log + .pid'})"]
    lines += [f"  partial: {x}" for x in o.partial]
    live = [j for j in o.jobs if j.state not in observe.TERMINAL and j.state not in ("ENDED", "NOPID", "UNKNOWN")]
    ended = [j for j in o.jobs if j not in live]
    for j in sorted(live, key=lambda j: (ORDER.get(j.state, 2), j.name)):
        tag = "" if known is None or (j.id if p.kind == "slurm" else j.log) in known else "  UNLEDGERED"
        lines.append(_line(j, now) + tag)
    if p.kind == "slurm":
        counts: dict[str, int] = {}
        for j in ended:
            counts[j.state] = counts.get(j.state, 0) + 1
        if counts:
            lines.append(f"  ended in {days}d: " + ", ".join(f"{n} {s}" for s, n in sorted(counts.items())))
        latest: dict[str, observe.Job] = {}
        for j in ended:   # the newest ended job per name, unless a live job of that name exists
            if j.state != "COMPLETED" and not any(x.name == j.name for x in live):
                if j.name not in latest or j.end > latest[j.name].end:
                    latest[j.name] = j
        lines += [_line(j, now) for j in sorted(latest.values(), key=lambda j: -j.end)[:10]]
    else:
        lines += [_line(j, now) for j in ended[:10]]
    if o.nodir:
        lines.append(f"  not synced here: {p.remote_dir} does not exist on {p.host}" + (" (jobs above ran there)" if o.jobs else ""))
    elif not o.jobs:
        lines.append(f"  no jobs from this dir {'in the last ' + str(days) + 'd' if p.kind == 'slurm' else 'with a log'}")
    elif any(j.state not in ("COMPLETED",) for j in o.jobs):
        lines.append(f"  digest: rsk logs -T {p.target} <job id | log path>")
    return lines


GRACE_S = 300     # an open attempt younger than this may still be running somewhere: not yet a decision for the user


def _subs(state: L.LedgerState, target: str):
    """(run, attempt id, attempt, submission) for every ledger submission on TARGET."""
    for run, rec in state.runs.items():
        for aid, att in (rec.get("attempts") or {}).items():
            if att.get("target") == target:
                for sub in att.get("submissions") or []:
                    yield run, aid, att, sub


def known_keys(state: L.LedgerState, target: str) -> tuple[set[str], set[str]]:
    """The job ids / logs and the nonces the ledger holds on TARGET."""
    keys, nonces = set(), set()
    for _r, _a, _att, sub in _subs(state, target):
        nonces.add(str(sub.get("nonce", "")))
        for k in (sub.get("job"), (sub.get("proc") or {}).get("log")):
            if k:
                keys.add(str(k))
    return keys, nonces


def _iso(t: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def _proc(receipt: dict) -> dict:
    return {k: receipt.get(k, "") for k in ("pid", "pgid", "start", "boot_id", "log", "gpu_ids")}


def reconcile(state: L.LedgerState, o: observe.Observation) -> list[tuple]:
    """Pure: what a GOOD observation O says about the ledger's submissions on its target.
    ("submitted", run, aid, nonce, fields) | ("not_submitted", run, aid, nonce, evidence, grant id) |
    ("observe", run, aid, key, state, source, end|None)."""
    if not o.ok:
        return []
    out: list[tuple] = []
    kind = o.place.kind
    by_id = {j.id: j for j in o.jobs if j.id and j.source != "pid"}
    by_log = {j.log: j for j in o.jobs if j.log}
    carried = {n: jid for jid, n in o.comments.items()} if o.comments_ok else {}
    def seen(run: str, aid: str, key: str) -> None:
        j = (by_id if kind == "slurm" else by_log).get(key)
        if not j:
            return            # not in this read (older than --days, or not listed): absence is no evidence
        end = None
        if kind == "slurm" and j.state in observe.TERMINAL:
            end = {"state": j.state, "rc": j.exit_code, "evidence": j.source}
        elif kind == "nohup" and j.rc:
            end = {"state": "ENDED", "rc": j.rc.get("rc", ""), "evidence": f"{key}.rc term={j.rc.get('term', '?')}"}
        elif kind == "nohup" and j.state == "ENDED":
            end = {"state": "ENDED", "rc": "", "evidence": f"pid {j.reason}, no .rc"}
        out.append(("observe", run, aid, key, j.state, j.source, end))

    for run, aid, att, sub in _subs(state, o.place.target):
        nonce, a = str(sub.get("nonce", "")), o.attempts.get(str(sub.get("nonce", "")))
        if sub.get("submit") == "unknown":
            rcpt = (a or {}).get("receipt") or {}
            verdict = ((a or {}).get("result") or {}).get("verdict", "")
            fields: dict = {}
            if kind == "slurm" and rcpt.get("job"):
                fields = {"submit": "submitted", "job": rcpt["job"], "evidence": "remote receipt (reconciled)"}
            elif kind == "nohup" and rcpt.get("pid") and (a or {}).get("gate") == "go":
                fields = {"submit": "submitted", "proc": _proc(rcpt), "evidence": "remote receipt (reconciled)"}
            elif nonce in carried:
                fields = {"submit": "submitted", "job": carried[nonce],
                          "evidence": f"squeue comment rs={nonce} (reconciled)"}
            elif verdict in ("refused", "failed") and not rcpt and (a or {}).get("gate", "") != "go":
                r = (a or {}).get("result") or {}
                out.append(("not_submitted", run, aid, nonce,
                            f"remote result verdict={verdict} rc={r.get('rc', '?')} stage={r.get('stage', '?')}",
                            str((att.get("request") or {}).get("grant", ""))))
            if fields:
                out.append(("submitted", run, aid, nonce, fields))
                seen(run, aid, str(fields.get("job") or (fields.get("proc") or {}).get("log") or ""))
            continue
        if sub.get("submit") in ("submitted", "adopted") and not sub.get("end"):
            seen(run, aid, str(sub.get("job") or (sub.get("proc") or {}).get("log") or ""))
    return out


def record(led: L.Ledger, state: L.LedgerState, obs: list[observe.Observation]) -> list[str]:
    """Apply reconcile() for every good observation; the ledger lock is waited for briefly, never for long."""
    todo = [(o, c) for o in obs for c in reconcile(state, o)]
    if not todo:
        return []
    notes = []
    try:
        with led.locked(timeout=5):
            for o, c in todo:
                at = _iso(o.observed_at)
                if c[0] == "submitted":
                    led.set_submission(c[1], c[2], c[3], **c[4])
                    led.audit("reconciled", run=c[1], attempt=c[2], nonce=c[3], to="submitted", **{
                        k: v for k, v in c[4].items() if k in ("job", "evidence")})
                    notes.append(f"{c[1]} {c[2]}: SUBMIT_UNKNOWN -> submitted ({c[4]['evidence']})")
                elif c[0] == "not_submitted":
                    led.set_submission(c[1], c[2], c[3], submit="not_submitted", evidence=c[4])
                    led.audit("reconciled", run=c[1], attempt=c[2], nonce=c[3], to="not_submitted", evidence=c[4])
                    if c[5] and grants.refund(led, c[5], c[3], c[4]):
                        notes.append(f"{c[1]} {c[2]}: use of {c[5]} given back")
                    notes.append(f"{c[1]} {c[2]}: SUBMIT_UNKNOWN -> not submitted ({c[4]})")
                else:
                    led.observe(c[1], c[2], c[3], c[4], c[5], at=at, end=c[6])
    except RskError as exc:
        notes.append(f"ledger not updated: {exc}")
    return notes


def _att_line(run: str, aid: str, att: dict, now: float, observed: dict[str, observe.Observation]) -> str:
    st = L.attempt_state(att)
    subs = att.get("submissions") or []
    last = subs[-1] if subs else {}
    where = f"job {last.get('job')}" if last.get("job") else (
        f"pid {(last.get('proc') or {}).get('pid')}" if last.get("proc") else f"nonce {last.get('nonce', '?')}")
    if len([s for s in subs if s.get("job")]) > 1:
        where += f" (+{len([s for s in subs if s.get('job')]) - 1} earlier)"
    res, ob = att.get("result") or {}, att.get("observed") or {}
    if res and res.get("rc") not in ("", None, "0:0") and st != "NOT_SUBMITTED":
        st += f" rc={res['rc']}"
    ev = ""
    src = res or ob
    if src.get("at"):
        ev = f"  {src.get('evidence') or src.get('source') or '?'}, {observe.age(now - L.epoch(src['at']))} ago"
    elif st == "SUBMITTED":
        ev = "  not observed yet"
    o = observed.get(str(att.get("target")))
    if o is not None and not o.ok and L.is_live(att):
        ev += f"  (target UNOBSERVABLE now: {o.why[:80]} — state unknown)"
    g = (att.get("request") or {}).get("grant")
    return f"  {run:<28} {aid}  {st:<16} [{att.get('target')}] {where}{ev}{'  under ' + g if g else ''}"


def view(led: L.Ledger, state: L.LedgerState, obs: list[observe.Observation], days: int,
         targets: set[str]) -> dict:
    now = time.time()
    observed = {o.place.target: o for o in obs}
    runs, needs, unledgered = [], [], []
    for run, rec in sorted(state.runs.items()):
        atts = rec.get("attempts") or {}
        mine = {k: a for k, a in atts.items() if a.get("target") in targets}
        if not mine:
            continue
        aid = sorted(mine, key=lambda k: (int(k[1:]) if k[1:].isdigit() else 0, k))[-1]
        att = mine[aid]
        res = att.get("result") or {}
        if not L.is_live(att) and res and now - L.epoch(res.get("at")) > days * 86400:
            continue
        runs.append((run, aid, att))
        o = observed.get(str(att.get("target")))
        for sub in att.get("submissions") or []:
            if sub.get("submit") != "unknown":
                continue
            if o is None or not o.ok or not o.attempts_ok:
                continue      # unobservable (said above) or the journal unread: unknown, not yet a decision
            a = o.attempts.get(str(sub.get("nonce")))
            age = now - max(L.epoch(sub.get("at")), float((a or {}).get("mtime") or 0))
            if age < GRACE_S:
                continue
            else:
                if a is None or a.get("missing"):
                    what = "no attempt dir on the target (the call may never have arrived)"
                else:
                    r = a.get("result") or {}
                    what = (f"stage {a.get('stage') or '?'}, result {('verdict=' + r['verdict']) if r.get('verdict') else 'absent'}"
                            f", no receipt{', a process still names it' if a.get('procs') else ''}")
                needs.append(f"{run} {aid} on {att.get('target')}: SUBMIT_UNKNOWN (nonce {sub.get('nonce')}: {what}; "
                             f"no job carries rs={sub.get('nonce')}) — only the user can say it may be marked not "
                             "submitted (rsk adopt --not-submitted, with their words); never resubmit it blind")
    for o in obs:
        if not o.ok:
            continue
        keys, nonces = known_keys(state, o.place.target)
        for n, a in sorted(o.attempts.items(), key=lambda x: -int(x[1].get("mtime") or 0)):
            if n in nonces or a.get("missing"):
                continue
            rc = a.get("receipt") or {}
            k = rc.get("job") or rc.get("log") or ""
            if k and k in keys:
                continue
            v = (a.get("result") or {}).get("verdict", "")
            if v in ("refused", "failed", "planned"):
                continue
            live = any(j for j in o.jobs if (j.id == k or j.log == k) and k and
                       j.state not in observe.TERMINAL and j.state not in ("ENDED", "NOPID", "UNKNOWN"))
            if v in ("submitted", "launched") and not live:
                continue      # an old submit of another tool, long over: the job lines above already say so
            unledgered.append({"target": o.place.target, "nonce": n, "verdict": v or "open", "stage": a.get("stage"),
                               "job": rc.get("job", ""), "log": rc.get("log", ""), "name": rc.get("name", ""),
                               "age": int(now - int(a.get("mtime") or now))})
    for r in state.grants:
        if r.get("revoked"):
            continue
        for f in grants.after_deny(r, state.grants):
            needs.append(f"{r['kind']} {r['id']} ({r.get('created_via')}): {f} — confirm with the user that it replaces "
                         "the deny before relying on it")
    lease = led.lease().data
    return {"runs": runs, "needs": needs, "unledgered": unledgered, "lease": lease,
            "lease_state": L.lease_state(lease)}


def _lease_line(v: dict) -> str:
    le = v["lease"]
    if not le:
        return "watch lease: none"
    until = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float(le.get("until") or 0)))
    return (f"watch lease: {v['lease_state']} — pid {le.get('pid')} on {le.get('host')} since {le.get('started')} "
            f"until {until}")


def cmd_status(args: argparse.Namespace) -> int:
    proj = project_dir(args.dir)
    places = select(harness.places(paths.harness_src(), proj), args.target)
    if not places:
        raise RskError(f"no target resolves a remote dir from {proj}'s conf (REMOTE_DIR / <TAG>_REMOTE_DIR / "
                       "WS_REMOTE_DIR) — see references/project-setup.md", USAGE)
    led = L.Ledger(proj)
    st0 = led.state()
    asked = {p.target: sorted({str(s.get("nonce")) for _r, _a, _t, s in _subs(st0, p.target)
                               if s.get("submit") == "unknown"}) for p in places}
    comments = {p.target: p.kind == "slurm" and bool(asked[p.target]) for p in places}
    obs = observe.observe(places, args.days, args.deadline, nonces=asked, comments=comments)
    notes = record(led, st0, obs)
    st = led.state()
    targets = {p.target for p in places}
    v = view(led, st, obs, args.days, targets)
    keys = {p.target: known_keys(st, p.target)[0] for p in places}
    if args.json:
        print(json.dumps({
            "project": str(proj), "ledger": str(led.dir),
            "targets": [{"target": o.place.target, "host": o.place.host, "remote_dir": o.place.remote_dir,
                         "observed": o.ok, "why": o.why, "synced": not o.nodir, "partial": o.partial,
                         "observed_at": int(o.observed_at), "remote_now": o.now,
                         "jobs": [{**vars(j), "ledgered": (j.id if o.place.kind == "slurm" else j.log) in keys[o.place.target]}
                                  for j in o.jobs],
                         "attempts_listed": o.attempts_ok} for o in obs],
            "runs": [{"run": r, "attempt": a, "state": L.attempt_state(att), **att} for r, a, att in v["runs"]],
            "unledgered": v["unledgered"], "grants": [{**g, "covers": grants.describe(g), "balance": grants.balance(g, st)}
                                                      for g in st.grants if not g.get("revoked")],
            "budgets_unknown": st.budgets_unknown, "lease": v["lease"], "lease_state": v["lease_state"],
            "needs_user": v["needs"], "notes": notes}, indent=1, ensure_ascii=False))
        return OK if all(o.ok for o in obs) else UNKNOWN
    for o in obs:
        lines = render(o, args.days, keys[o.place.target] if o.ok else None)
        for u in (x for x in v["unledgered"] if x["target"] == o.place.target):
            what = f"job {u['job']}" if u["job"] else f"log {u['log']}" if u["log"] else f"stage {u['stage'] or '?'}"
            lines.append(f"  UNLEDGERED attempt {u['nonce']}  {u['verdict']}  {what}  {u['name']}  "
                         f"({observe.age(u['age'])} ago)")
        if o.ok and any(t.endswith("UNLEDGERED") for t in lines):
            lines.append(f"  adopt a job of yours into the ledger: rsk adopt -T {o.place.target} "
                         f"{'--job <id>' if o.place.kind == 'slurm' else '--log <log>'} --as <run>")
        print("\n".join(lines), flush=True)
    now = time.time()
    observed = {o.place.target: o for o in obs}
    print(f"== ledger {led.dir} ==")
    for n in notes:
        print(f"  {n}")
    if v["runs"]:
        for r, a, att in v["runs"]:
            print(_att_line(r, a, att, now, observed))
    else:
        print("  no ledger runs on " + ", ".join(sorted(targets)) + f" (live or ended in {args.days}d)")
    print("== grants ==")
    print("\n".join(grants.lines(st)) or "  none recorded — every launch and cancel needs the user's approval")
    print(_lease_line(v))
    for n in v["needs"]:
        print(f"needs user: {n}")
    sys.stdout.flush()
    return OK if all(o.ok for o in obs) else UNKNOWN


DIGEST = r'''rs_digest() {
  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\~/}" ;; esac
  cd "$RDIR" 2>/dev/null || { echo "rsk logs: cannot cd to $RDIR"; return 66; }
  [ -f "$DEPLOY/status.sh" ] || { echo "rsk logs: $RDIR/$DEPLOY/status.sh is not deployed (the deploy predates it) — read the log" \
    "bounded (rsk exec -T $TGT -- tail -c 20000 <log>) and re-sync only with the user's OK: a sync also pushes local code into the" \
    "dir a running job reads"; return 66; }
  bash "$DEPLOY/status.sh" "$@"
}
rs_digest'''


def cmd_logs(args: argparse.Namespace) -> int:
    proj = project_dir(args.dir)
    place = select(harness.places(paths.harness_src(), proj), [args.target])[0]
    argv = ["-n", str(args.lines), args.run] + ([args.ckpt] if args.ckpt else [])
    body = (f"RDIR={shlex.quote(place.remote_dir)} DEPLOY={shlex.quote(place.deploy)} TGT={shlex.quote(place.target)}\n"
            + DIGEST + " " + " ".join(shlex.quote(a) for a in argv) + "\n")
    try:
        done = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=30", place.host, "bash -s"],
                              input=body, text=True, timeout=args.deadline)
    except subprocess.TimeoutExpired:
        print(f"rsk logs: no answer from {place.host} within {args.deadline:.0f} s — state unknown", flush=True)
        return UNKNOWN
    rc = done.returncode
    if rc in (0, 2, 66):   # 2: status.sh's own usage error, 66: no dir / no deployed status.sh (both said above)
        return OK if rc == 0 else USAGE
    if rc == 255:          # ssh's own failure (its message is above): the run's state is unknown
        return UNKNOWN
    print(f"rsk logs: status.sh exit {rc}", flush=True)
    return FAILED


def add_parsers(sub) -> None:
    s = sub.add_parser("status", help="what runs (or ran) from this project on its targets (read-only there), "
                       "its ledger runs, grants and the watch lease")
    s.add_argument("-T", "--target", action="append", help="only this target (repeatable); default: every target "
                   "the project's conf gives a remote dir")
    s.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory)")
    s.add_argument("--days", type=int, default=2, help="ended Slurm jobs from the last N days (default 2)")
    s.add_argument("--deadline", type=float, default=60.0, help="seconds per target before it counts as unobservable")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_status)
    g = sub.add_parser("logs", help="the bounded digest of one run (remote status.sh) — read-only")
    g.add_argument("-T", "--target", required=True)
    g.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory)")
    g.add_argument("-n", dest="lines", type=int, default=5, help="displayed log lines (status.sh caps at 200)")
    g.add_argument("--deadline", type=float, default=60.0)
    g.add_argument("run", help="Slurm job id, or a log path (absolute or relative to the project dir)")
    g.add_argument("ckpt", nargs="?", default="", help="checkpoint dir to report activity of (optional)")
    g.set_defaults(func=cmd_logs)
