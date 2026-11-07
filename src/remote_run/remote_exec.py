"""`rsk exec -T T -- ARGV`: one read-only command on a target, from the project's remote dir, bounded.

What it guarantees, checked here before anything reaches the target:
- read-only: every command has an allowlist of options and operands (not a blocklist), so an unlisted option, a GNU
  abbreviation (`--env` for `--env-vars`) or an option a newer version adds is refused; nvidia-smi takes queries
  only (no `-f`, no subcommand but `topo -m`), scontrol only `show`, date no operand but +FORMAT and hostname none
  (an operand sets them);
- secret-safe: no option that prints a file's content or a process environment (`date -f`, `wc --files0-from`, BSD
  `ps e`, `sacct --env-vars/--batch-script/--json`); file content only through `head -c N` / `tail -c N`
  (N ≤ 1 MiB) of relative paths in the project dir: no `/`, `~` or `..`, no credential file (`.wandb_env`,
  `.netrc`, `.ssh/`, …). The check is on the words: a symlink inside the project dir is followed;
- not a shell: the argv is quoted word by word (no globbing, no chaining) and shell operators are refused outright,
  so a chained request is an error rather than a silent no-op;
- bounded: output is cut at 64 KiB, the command stopped at the deadline.
Exit: 0 ok (also when the output was cut) · 1 the command ran and failed (`remote exit N`) · 2 refused here, or no
remote dir · 5 no answer (ssh failed, or the deadline stopped it). Project code, writes and scheduler actions are not
here: they go through the commands that check and record them.
"""

from __future__ import annotations

import argparse
import math
import re
import shlex
import subprocess

from remote_run import harness, paths
from remote_run.errors import FAILED, OK, UNKNOWN, USAGE, RskError
from remote_run.status import project_dir, select

# command: (short flags, short options taking a value, long options ('=': takes a value), operands allowed)
OPTS = {
    "squeue": ("ahlrsvV", "AjLMnoOpqRStuw", "all noheader long array steps start me json yaml verbose noconvert "
               "account= jobs= licenses= clusters= name= format= Format= partition= qos= reservation= sort= "
               "states= user= nodelist=", False),
    "sinfo": ("adeNlrRshvVT", "MnoOpSt", "all dead exact Node long responding list-reasons summarize noheader "
              "reservation verbose json yaml noconvert clusters= nodes= format= Format= partition= sort= states=", False),
    # no --env-vars / --batch-script, nor --json / --yaml (a job record can carry the script and the environment)
    "sacct": ("abDLlnPpXv", "AEjMNoqrsSu", "allusers brief duplicates allclusters long noheader parsable parsable2 "
              "allocations verbose helpformat noconvert accounts= endtime= jobs= clusters= nodelist= format= qos= "
              "partition= state= starttime= user= name= units= delimiter=", False),
    "sshare": ("ahlmnPpUv", "AMou", "all noheader long partition parsable parsable2 Users verbose "
               "accounts= clusters= format= users=", False),
    "sprio": ("hlnwv", "jMopSu", "noheader long norm weights verbose jobs= clusters= format= partition= sort= user=",
              False),
    "scontrol": ("ado", "", "all details oneliner", True),                        # operands: show ENTITY [NAME…]
    "nvidia-smi": ("Lqx", "di", "list-gpus query xml-format help-query-gpu help-query-compute-apps display= id= "
                   "query-gpu= query-compute-apps= format=", False),              # + `topo -m`
    "ps": ("AacdefFHjlLmMNPTwy", "CDGgOopqstUu", "deselect context headers no-headers signames forest cumulative "
           "Group= group= pid= ppid= quick-pid= sid= tty= user= User= format= cols= columns= width= rows= lines= "
           "sort=", True),                                                        # operands: PIDs, BSD letters (PS_BSD)
    "df": ("ahHiklPTv", "Btx", "all human-readable si inodes local portability print-type total output no-sync "
           "block-size= type= exclude-type=", True),
    "ls": ("1aAdFghiklLnoprRsStuUvx", "", "all almost-all directory classify human-readable si inode numeric-uid-gid "
           "reverse recursive size full-time group-directories-first dereference color sort= time= time-style= "
           "block-size=", True),
    "stat": ("Lft", "c", "dereference file-system terse format= printf=", True),
    "wc": ("clmwL", "", "bytes chars lines words max-line-length total=", True),  # never --files0-from: it echoes F
    "free": ("bkmghlLtvw", "", "bytes kilo mega giga tera peta kibi mebi gibi tebi pebi human si lohi line total "
             "committed wide", False),
    "uptime": ("ps", "", "pretty since", False),
    "hostname": ("aAdfiIsy", "", "alias all-fqdns domain fqdn long ip-address all-ip-addresses short yp nis", False),
    "nproc": ("", "", "all ignore=", False),
    "date": ("uR", "d", "utc universal rfc-email iso-8601 debug date= rfc-3339=", True),   # operands: +FORMAT only
    "id": ("agGnruzZ", "", "context group groups name real user zero", True),
    "quota": ("glqsuvw", "", "group local-only quiet human-readable user verbose no-wrap", True),
    # a distributed filesystem's directory quota (a group dir's usage vs its soft / hard limits, which `quota` cannot
    # show): only the number formats (-n plain, -h/-H IEC/SI, -k/-m/-g units); operands = directories (mfssetquota sets)
    "mfsgetquota": ("nhHkmg", "", "", True),
}
PS_BSD = ("acfjlLmnrsSTuvwxXH", "kOopqtU")            # BSD-style ps letters: never `e` (prints each environment)
SCONTROL_SHOW = {"job", "jobs", "node", "nodes", "partition", "partitions", "reservation", "reservations", "step",
                 "steps", "hostnames", "hostlist", "licenses", "topology"}
READ_ONLY = set(OPTS) | {"head", "tail"}
# credential files a project dir can hold: the key run-sync pushes, copies of ~/.netrc / ssh / git / gh state, a
# dotenv file, an HF login (env.sh keeps HF_HOME in the project)
CREDENTIALS = {".wandb_env", "wandb_env", ".netrc", ".ssh", ".git-credentials", ".env", "token", "stored_tokens"}
OPERATORS = re.compile(r"[;&|`$<>\n\r]")
MAX_READ = 1 << 20
CAP = 1 << 16


def _allowed(spec: tuple) -> str:
    flags, valued, longs, _ = spec
    return " ".join([f"-{c}" for c in flags] + [f"-{c} V" for c in valued]
                    + [f"--{n}V" if n.endswith("=") else f"--{n}" for n in longs.split()])


def _operands(cmd: str, args: list[str], spec: tuple, bsd: tuple | None = None, exact: bool = False) -> list[str]:
    """A getopt-style walk of ARGS against SPEC; returns the operands. A value given as its own word must not start
    with '-' and a short option taking a value must end its cluster (`-eo FMT`, not `-oFMT`), so an option whose
    argument is optional, or a value we misread, can never hide another option. EXACT: no clusters (nvidia-smi's
    short options are words: `-pm` is not `-p -m`)."""
    flags, valued, longs, _ = spec
    takes = {n.rstrip("="): n.endswith("=") for n in longs.split()}
    out, i = [], 0

    def refuse(why: str) -> None:
        raise RskError(f"{cmd}: {why} — rsk exec takes a fixed set of read-only options per command; {cmd}: "
                       f"{_allowed(spec) or 'none'}", USAGE)

    def value(opt: str) -> None:
        nonlocal i
        if i >= len(args) or args[i].startswith("-"):
            refuse(f"{opt} needs a value as the next word, not one starting with '-' (attach it: --long=VALUE)")
        i += 1

    while i < len(args):
        a = args[i]
        i += 1
        if a == "--" and not bsd:                               # ps has no `--`: its BSD words stay checked
            out += args[i:]
            break
        if a.startswith("--"):
            name, eq, _ = a[2:].partition("=")
            if name not in takes:
                refuse(f"option {a!r} is not allowed")
            if takes[name] and not eq:
                value(a)
            continue
        if a.startswith("-") and a != "-":
            dash, (fl, val) = "-", (flags, valued)
        elif bsd and not re.fullmatch(r"[0-9,]+", a):           # ps: a word of BSD letters, not a PID list
            dash, (fl, val) = "", bsd
        else:
            out.append(a)
            continue
        word = a[len(dash):]
        if exact and len(word) != 1:
            refuse(f"option {a!r} is not allowed")
        for j, c in enumerate(word, 1):
            if c in val:
                if j != len(word):
                    refuse(f"{a!r}: {c} takes a value, so it must end its cluster")
                value(dash + c)
            elif c not in fl:
                refuse(f"option {dash + c!r}{f' (in {a!r})' if len(word) > 1 else ''} is not allowed")
    return out


def project_file(cmd: str, p: str, after: str = " (and no further options after -c N)") -> None:
    """P names a file under the project dir by a relative path without '..', and no credential file (on the words)."""
    parts = [x for x in p.split("/") if x not in ("", ".")]
    if p.startswith(("-", "/", "~")) or not parts or ".." in parts:
        raise RskError(f"{cmd}: {p!r}: only files under the project dir, by a relative path without '..'{after}",
                       USAGE)
    if CREDENTIALS & set(parts) or "/.config/gh/" in f"/{'/'.join(parts)}/":
        raise RskError(f"{cmd}: {p!r} is a credential file: rsk never prints one", USAGE)


def _read(cmd: str, args: list[str]) -> None:
    if len(args) < 3 or args[0] != "-c" or not re.fullmatch(r"[0-9]+", args[1]) or int(args[1]) > MAX_READ:
        raise RskError(f"{cmd}: only `{cmd} -c <bytes ≤ {MAX_READ}> <file>…` (byte-bounded reads)", USAGE)
    for p in args[2:]:
        project_file(cmd, p)


def check(argv: list[str]) -> None:
    """Raise RskError unless ARGV is one allowed read-only, secret-safe command."""
    if not argv:
        raise RskError("rsk exec -T <target> -- <command> [args]: nothing to run", USAGE)
    cmd, args = argv[0], argv[1:]
    if cmd not in READ_ONLY:
        raise RskError(f"{cmd!r} is not on rsk exec's read-only list ({' '.join(sorted(READ_ONLY))}); project code "
                       "runs through a launch, files move through sync/pull", USAGE)
    bad = [a for a in argv if OPERATORS.search(a)]
    if bad:
        raise RskError(f"shell operators are not run (one command, no chaining or expansion): {bad[0]!r}", USAGE)
    if cmd in ("head", "tail"):
        _read(cmd, args)
    elif cmd != "nvidia-smi" or args not in (["topo", "-m"], ["topo", "--matrix"]):
        ops = _operands(cmd, args, OPTS[cmd], bsd=PS_BSD if cmd == "ps" else None, exact=cmd == "nvidia-smi")
        if ops and not OPTS[cmd][3]:
            why = {"nvidia-smi": "queries only (subcommands set, reset or write files; `topo -m` is the one allowed)",
                   "hostname": "an operand sets the host name"}.get(cmd, "takes no operand here")
            raise RskError(f"{cmd}: {ops[0]!r}: {why}", USAGE)
        sets = [o for o in ops if not o.startswith("+")]
        if cmd == "date" and sets:
            raise RskError(f"date: only a +FORMAT operand ({sets[0]!r} would set the clock)", USAGE)
        if cmd == "scontrol" and (ops[:1] != ["show"] or len(ops) < 2 or ops[1].lower() not in SCONTROL_SHOW):
            raise RskError(f"scontrol: only `scontrol show {'|'.join(sorted(SCONTROL_SHOW))} [NAME]` (anything else "
                           "changes state)", USAGE)


def cmd_exec(args: argparse.Namespace) -> int:
    argv = [a for a in args.argv if a != "--"] if args.argv[:1] == ["--"] else list(args.argv)
    check(argv)
    proj = project_dir(args.dir)
    place = select(harness.places(paths.harness_src(), proj), [args.target])[0]
    line = " ".join(shlex.quote(a) for a in argv)
    secs = max(1, math.ceil(args.deadline))                 # `timeout 0` would disable the deadline
    body = (f"RDIR={shlex.quote(place.remote_dir)}\n"
            'rs_exec() {\n  case "$RDIR" in "~/"*) RDIR="$HOME/${RDIR#\\~/}" ;; esac\n'
            '  cd "$RDIR" 2>/dev/null || { echo "rsk exec: cannot cd to $RDIR" >&2; return 66; }\n'
            f'  if command -v timeout >/dev/null; then timeout {secs} {line}; else {line}; fi\n}}\n'
            f"rs_exec 2>&1 | head -c {CAP}; exit ${{PIPESTATUS[0]}}\n")
    try:
        done = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=30", place.host, "bash -s"],
                              input=body.encode(), capture_output=True, timeout=args.deadline + 30)
    except subprocess.TimeoutExpired:
        print(f"rsk exec: no answer from {place.host} — unknown", flush=True)
        return UNKNOWN
    text = done.stdout.decode("utf-8", errors="replace")   # a cut or a tail window can split a character
    print(text, end="" if text.endswith("\n") or not text else "\n", flush=True)
    cut = len(done.stdout) >= CAP
    if cut:
        print(f"[rsk exec: output cut at {CAP} bytes]", flush=True)
    rc = done.returncode
    if rc == 255:
        print(f"rsk exec: ssh failed: {done.stderr.decode('utf-8', errors='replace').strip()[:200]}", flush=True)
        return UNKNOWN
    if rc == 124:                                           # timeout(1): the outcome is not known
        print(f"rsk exec: stopped at the {secs}s deadline — unknown", flush=True)
        return UNKNOWN
    if rc == 66 and text.startswith("rsk exec: cannot cd"):
        return USAGE
    if rc == 0 or (rc == 141 and cut):                      # 141 = SIGPIPE: still writing when the cut closed the pipe
        return OK
    print(f"rsk exec: remote exit {rc}", flush=True)
    return FAILED


def add_parser(sub) -> None:
    e = sub.add_parser("exec", help="one read-only command on a target, from the project's remote dir")
    e.add_argument("-T", "--target", required=True)
    e.add_argument("-C", dest="dir", default=None, help="project root (default: the current directory)")
    e.add_argument("--deadline", type=float, default=60.0, help="seconds before the remote command is stopped")
    e.add_argument("argv", nargs=argparse.REMAINDER, help="-- COMMAND [ARGS]")
    e.set_defaults(func=cmd_exec)
