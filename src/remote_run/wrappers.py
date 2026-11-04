"""`rsk sync | bootstrap | pull | avail`: the harness's bin/run-sync, run-bootstrap, run-pull, run-avail, exec'd with
the project as cwd and TARGET set — no logic of their own (bash stays the one implementation; the exit code is the
script's). The harness is this rsk's own tree (paths.harness_src(), the one harness.py drives), so what a sync
deploys matches what this rsk speaks. RS_VIA_RSK=1 tells the scripts they were reached through rsk.

    rsk sync -T T [-C DIR] [run-sync args: -n -D --also PATH --take-over]
    rsk bootstrap -T T [-C DIR] [--job [submit.sh flags]]
    rsk pull -T T [-C DIR] [-n] PATH...
    rsk avail [-T T]... [-C DIR] [--type X] [--min N] [--timeout S]     (-T = the targets run-avail reads)
Every argument rsk does not know is passed on as it stands (after `--` too).
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from remote_run import harness, paths
from remote_run.errors import USAGE, RskError

SCRIPTS = {"sync": "run-sync", "bootstrap": "run-bootstrap", "pull": "run-pull", "avail": "run-avail"}


def plan(args: argparse.Namespace) -> tuple[list[str], dict[str, str], Path]:
    """(argv, env, cwd) of the exec — pure, so it is testable without exec'ing."""
    from remote_run.status import project_dir   # status imports grants, which imports nothing of this
    src = paths.harness_src()
    script = src / "bin" / SCRIPTS[args.command]
    if not script.is_file():
        raise RskError(f"{script} is missing (a broken install?)", USAGE)
    extra = list(getattr(args, "extra", []) or [])
    if extra[:1] == ["--"]:
        extra = extra[1:]
    env = harness.env(src)
    env["RS_VIA_RSK"] = "1"
    for k in ("CLUSTER", "STATION"):     # TARGET wins in rs_init anyway; an inherited alias must not surprise
        env.pop(k, None)
    if args.command == "avail":
        cwd = Path(args.dir).resolve() if args.dir else Path.cwd()
        env.pop("TARGET", None)
        return ["bash", str(script), *extra, *(args.targets or [])], env, cwd
    if not args.target:
        raise RskError(f"rsk {args.command} -T <target>", USAGE)
    env["TARGET"] = args.target
    return ["bash", str(script), *extra], env, project_dir(args.dir)


def cmd_wrap(args: argparse.Namespace) -> int:
    argv, env, cwd = plan(args)
    sys.stdout.flush()
    sys.stderr.flush()
    os.chdir(cwd)
    os.execvpe(argv[0], argv, env)
    return 0   # not reached


def add_parsers(sub) -> None:
    helps = {"sync": "push the project and deploy the harness (bin/run-sync)",
             "bootstrap": "build the project's env on the target (bin/run-bootstrap)",
             "pull": "copy results back (bin/run-pull)",
             "avail": "free GPUs on every target now (bin/run-avail)"}
    for name, text in helps.items():
        p = sub.add_parser(name, help=text, allow_abbrev=False,
                           description=f"{text}; every other argument goes to {SCRIPTS[name]} unchanged")
        p.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory)")
        if name == "avail":
            p.add_argument("-T", "--target", dest="targets", action="append", default=[],
                           help="a target to read (repeatable; default: all)")
        else:
            p.add_argument("-T", "--target", required=True)
        p.set_defaults(func=cmd_wrap, passthrough=True)
