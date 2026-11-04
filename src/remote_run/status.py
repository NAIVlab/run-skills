"""`rsk status` and `rsk logs`: read-only views of a project on its targets.

status: what runs (or ran in the last --days) from this project's remote dir on every target its conf names, with the
age and source of the evidence; an unobservable target says so and why — its last state is unknown, not "nothing".
logs: the deployed bounded digest (remote/status.sh) for one job id or log path — the one monitoring read.
"""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import time
from pathlib import Path

from remote_run import harness, observe, paths
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


def render(o: observe.Observation, days: int) -> list[str]:
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
        lines.append(_line(j, now))
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


def cmd_status(args: argparse.Namespace) -> int:
    proj = project_dir(args.dir)
    places = select(harness.places(paths.harness_src(), proj), args.target)
    if not places:
        raise RskError(f"no target resolves a remote dir from {proj}'s conf (REMOTE_DIR / <TAG>_REMOTE_DIR / "
                       "WS_REMOTE_DIR) — see references/project-setup.md", USAGE)
    obs = observe.observe(places, args.days, args.deadline)
    if args.json:
        print(json.dumps([{"target": o.place.target, "host": o.place.host, "remote_dir": o.place.remote_dir,
                           "observed": o.ok, "why": o.why, "synced": not o.nodir, "partial": o.partial, "observed_at": int(o.observed_at),
                           "remote_now": o.now, "jobs": [vars(j) for j in o.jobs]} for o in obs], indent=1))
    else:
        for o in obs:
            print("\n".join(render(o, args.days)), flush=True)
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
    s = sub.add_parser("status", help="what runs (or ran) from this project on its targets — read-only")
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
