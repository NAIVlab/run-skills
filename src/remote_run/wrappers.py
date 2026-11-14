"""`rsk sync | bootstrap | pull | avail`: the harness's bin/run-sync, run-bootstrap, run-pull, run-avail, exec'd with
the project as cwd and TARGET set — no logic of their own (bash stays the one implementation; the exit code is the
script's). The harness is this rsk's own tree (paths.harness_src(), the one harness.py drives), so what a sync
deploys matches what this rsk speaks. RS_VIA_RSK=1 tells the scripts they were reached through rsk.

    rsk sync -T T [-C DIR] [run-sync args: -n -D --also PATH --take-over | -n --root PATH] [--approve]
    rsk bootstrap -T T [-C DIR] [--job [submit.sh flags]] [--approve]
    rsk pull -T T [-C DIR] [-n] [--root] PATH...      (--root: PATH relative to the conf's OUTPUT_ROOT, run-pull's)
    rsk avail [-T T]... [-C DIR] [--type X] [--min N] [--timeout S]     (-T = the targets run-avail reads)
Every argument rsk does not know is passed on as it stands (after `--` too).
Two of them are the user's call every time (no grant covers them): `rsk sync -D` (deletes files in the remote dir
the local tree lacks; with a real -n / --dry-run it only lists them) and `rsk bootstrap --job` (a Slurm job no plan
card showed). Which call is which is read with the script's own grammar, word by word, never by set membership:
run-sync takes -n|--dry-run, -D|--delete, --also PATH and --root PATH (the next word, whatever it is: `--also -n` and
`--root -n` are paths, not a dry run), --also=PATH, --root=PATH and --take-over — anything else it refuses itself (exit
2, nothing done). A root push (`--root`: local paths into the conf's OUTPUT_ROOT, -u, never --delete) is no deletion;
with -D run-sync refuses it (exit 2), and the gate still reads that -D as one (asks first). run-bootstrap is in
job mode when its first word is --job (any --job word is gated). They run only with --approve (a flag: the user OK'd
this command; words after it are accepted and never recorded), recorded in the ledger's audit.jsonl with the command
line (event `approved_command`, no words) before the script starts; without it `needs user: …`, exit 4, nothing run.
A record is bookkeeping, not proof the user agreed.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from remote_run import harness, paths
from remote_run.errors import NEEDS_USER, USAGE, RskError

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


def sync_modes(words: list[str]) -> tuple[bool, bool]:
    """(dry run, delete) as bin/run-sync's parser reads WORDS: -n|--dry-run, -D|--delete, --also PATH and --root PATH
    (each consumes the next word whatever it is), --also=PATH, --root=PATH, --take-over; any other word is run-sync's
    usage error (it then does nothing) and is skipped here."""
    dry = delete = False
    i = 0
    while i < len(words):
        w = words[i]
        if w in ("-n", "--dry-run"):
            dry = True
        elif w in ("-D", "--delete"):
            delete = True
        elif w in ("--also", "--root"):
            i += 1
        i += 1
    return dry, delete


def needs_words(args: argparse.Namespace, argv: list[str]) -> str:
    """'' unless this call is one only the user's OK allows (sync -D without a real -n, bootstrap --job); else what
    it is — read with the script's own grammar (sync_modes), never as a set of words."""
    w = argv[2:]
    if args.command == "sync":
        dry, delete = sync_modes(w)
        if delete and not dry:
            return "remote deletion: rsk sync -D removes files in the remote dir that the local tree lacks"
    if args.command == "bootstrap" and (w[:1] == ["--job"] or any(x == "--job" or x.startswith("--job=") for x in w)):
        return "a Slurm job (run-bootstrap --job) that no plan card showed"
    return ""


def gate(args: argparse.Namespace, argv: list[str], cwd: Path) -> None:
    """Refuse (exit 4) a call needs_words() names without --approve; with it, audit the command first."""
    what = needs_words(args, argv)
    if not what:
        return
    if getattr(args, "approve", None) is None:
        print(f"needs user: approval ({what}) — never a grant's call: ask the user, then run it again with --approve",
              flush=True)
        raise RskError(f"rsk {args.command} {' '.join(argv[2:])}: {what} — only with the user's OK (--approve); "
                       "nothing run", NEEDS_USER)
    from remote_run import ledger as L
    L.Ledger(cwd).audit("approved_command", command=args.command, target=getattr(args, "target", ""),
                        argv=argv[2:], what=what)


def cmd_wrap(args: argparse.Namespace) -> int:
    argv, env, cwd = plan(args)
    if args.command in ("sync", "bootstrap"):
        gate(args, argv, cwd)
    sys.stdout.flush()
    sys.stderr.flush()
    os.chdir(cwd)
    os.execvpe(argv[0], argv, env)
    return 0   # not reached


def add_parsers(sub) -> None:
    helps = {"sync": "push the project and deploy the harness (bin/run-sync; --root PATH: only PATH, into OUTPUT_ROOT)",
             "bootstrap": "build the project's env on the target (bin/run-bootstrap)",
             "pull": "copy results back (bin/run-pull; --root: paths relative to OUTPUT_ROOT)",
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
        if name in ("sync", "bootstrap"):
            p.add_argument("--approve", nargs="?", const=True, default=None, metavar="WORDS",
                           help="the user OK'd it (a flag; words after it are accepted and ignored), for " + ("-D (remote deletion)" if name == "sync" else
                                                            "--job (a Slurm job no plan card showed)"))
        p.set_defaults(func=cmd_wrap, passthrough=True)
