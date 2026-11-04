"""rsk — install, update and check the run-skills harness (more commands arrive phase by phase).

    rsk setup                       install the harness copy + skills from this rsk (re-run after any pack change)
    rsk update [--check] [--dry-run] [--packs-only|--tool-only] [--to REF]     (alias: upgrade)
    rsk pack list | rsk pack add <git-url|dir> [--name N]
    rsk status [-T T]... [--days N] [--json]   read-only: this project's jobs on every target its conf names
    rsk logs -T T <jobid|log> [ckpt-dir] [-n N]  read-only: the bounded digest of one run (remote status.sh)
    rsk exec -T T -- <cmd> [args]   read-only allowlist (squeue sacct sinfo nvidia-smi ps df ls stat head/tail -c …)
    rsk doctor                      offline checks: install, skills, packs, targets, ssh aliases, config
    rsk config [--template]         rsk's own settings (~/.config/run-skills/config.toml)

Exit codes: 0 ok · 1 the remote command ran and failed (rsk exec / rsk logs print its code) · 2 usage/config/setup ·
3 refused · 4 needs the user · 5 unknown/unreachable · 6 conflict · 141 stdout's reader left (`| head`).
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from remote_run import __version__, config, harness, install, packs, paths, state
from remote_run import remote_exec
from remote_run import status as status_cmd
from remote_run.errors import OK, UNKNOWN, USAGE, RskError


def out(msg: str = "") -> None:
    print(msg, flush=True)


# ---------------------------------------------------------------------------------------------------- setup
def cmd_setup(args: argparse.Namespace) -> int:
    src = paths.harness_src()
    with state.locked(paths.state_dir() / "setup.lock", "rsk setup"):
        if args.after_update:
            out(f"== rsk {args.from_version or '?'} -> {__version__}: refreshing the installed harness and skills ==")
        rc = harness.run_install(src)
        inst = install.current()
        state.write_json(paths.state_dir() / "install.json", {
            "version": __version__, "kind": inst.kind, "source": inst.source, "commit": inst.commit,
            "harness_src": str(src), "harness_root": str(paths.harness_root()), "install_rc": rc, "at": state.now()})
    if rc != 0:
        hint = f"; to go back: rsk update --to {args.from_commit}" if args.after_update and args.from_commit else ""
        packs_hint = f"; pack(s) not updated either: {args.packs_failed}" if args.pack_rc else ""
        raise RskError(f"install.sh exited {rc} — read the FAIL lines above{hint}{packs_hint}", USAGE)
    return _pack_verdict(args.pack_rc, args.packs_failed)


def _setup_args(pack_rc: int = OK, packs_failed: str = "") -> argparse.Namespace:
    return argparse.Namespace(after_update=False, from_version="", from_commit="", pack_rc=pack_rc,
                              packs_failed=packs_failed)


def _pack_verdict(rc: int, failed: str) -> int:
    """rsk update's own exit once everything else ran: a pack clone it could not fast-forward is not a success."""
    if rc:
        raise RskError(f"pack(s) not updated: {failed} — see their lines under == packs ==", rc)
    return OK


# ---------------------------------------------------------------------------------------------------- update
def _run(cmd: tuple[str, ...], dry: bool) -> int:
    out("  $ " + " ".join(cmd))
    return 0 if dry else subprocess.call(list(cmd))


PINNED = "rsk update --to main follows the branch again"


def _check(inst: install.Install, plist: list[packs.Pack]) -> int:
    """Report only; exit UNKNOWN when something could not be read (a stale answer is never "up to date")."""
    rc = OK
    if inst.kind == "git":
        kind, head, err = install.remote_ref(inst.source, inst.ref)
        if not head:
            rc = UNKNOWN
            out(f"  tool: cannot read {inst.source} {inst.ref or 'HEAD'} ({err})")
        elif kind == "commit":
            out(f"  tool: pinned to {inst.ref} — {PINNED}")
        elif head == inst.commit:
            out(f"  tool: up to date ({head[:12]})" + (f"; pinned to tag {inst.ref} — {PINNED}" if kind == "tag" else ""))
        else:
            out(f"  tool: {inst.commit[:12] or '?'} installed, {head[:12]} available at {inst.ref or 'HEAD'} — rsk update")
    else:
        out(f"  tool: {inst.manual}")
    for p in plist:
        if p.kind != "clone" or not p.upstream:
            out(f"  pack {p.name}: {p.kind}{'' if p.kind != 'clone' else ', no upstream'} — not checked")
            continue
        fetch = subprocess.run(["git", "-C", str(p.path), "fetch", "--quiet"], capture_output=True, text=True, timeout=60)
        if fetch.returncode != 0:
            rc = UNKNOWN
            out(f"  pack {p.name}: cannot fetch ({' '.join(fetch.stderr.split())[:120]})")
            continue
        n = subprocess.run(["git", "-C", str(p.path), "rev-list", "--count", f"HEAD..{p.upstream}"],
                           capture_output=True, text=True, timeout=60).stdout.strip()
        news = "up to date" if n == "0" else f"{n or '?'} new commit(s) on {p.upstream}"
        out(f"  pack {p.name}: {news}")
    return rc


def _setup_is_current(commit: str) -> bool:
    """install.json proves the harness copy and skills were installed, without a failure, by this commit's rsk from
    this tool env — the only case where rsk update may skip setup (`uv tool upgrade` alone never runs it)."""
    rec = state.read_json(paths.state_dir() / "install.json") or {}
    try:
        src = str(paths.harness_src())
    except RskError:
        return False
    root = paths.harness_root()
    return (bool(commit) and rec.get("commit") == commit and rec.get("harness_src") == src
            and rec.get("harness_root") == str(root) and rec.get("install_rc") == 0 and (root / "bin" / "run-sync").is_file())


def _nothing_new(inst: install.Install, commit: str) -> str:
    """A tag or commit stays put: say so instead of "the newest" (only a branch ref, or none, follows upstream)."""
    if inst.ref and install.remote_ref(inst.source, inst.ref)[0] != "branch":
        return f"pinned to {inst.ref} ({commit[:12]}) — {PINNED}"
    return f"already the newest ({commit[:12]}{' on ' + inst.ref if inst.ref else ''})"


def cmd_update(args: argparse.Namespace) -> int:
    cfg = config.load(paths.config_file())
    inst = install.current()
    uv = install.find_uv()
    plist = packs.all_packs(paths.packs_dir())
    with state.locked(paths.state_dir() / "update.lock", "rsk update"):
        out(f"rsk {__version__}: {inst.describe()}")
        if args.check:
            return _check(inst, plist)
        changed, pack_rc, failed = False, OK, []
        if not args.tool_only and not cfg.get("update", "packs"):
            if args.packs_only:
                raise RskError(f"--packs-only, but packs are disabled in {cfg.path} (update.packs = false)", USAGE)
            out(f"== packs == off (update.packs = false in {cfg.path})")
        elif not args.tool_only:
            out("== packs ==")
            for p in plist:
                if args.dry_run:
                    out(f"  {p.name}: {p.kind}" + (" (would fast-forward)" if p.kind == "clone" else " (left alone)"))
                    continue
                did, msg, code = packs.fast_forward(p)
                changed |= did
                if code != OK:
                    pack_rc, failed = max(pack_rc, code), [*failed, p.name]
                out("  " + msg)
            if not plist:
                out(f"  none under {paths.packs_dir()}")
        packs_failed = ", ".join(failed)
        if args.packs_only:
            if args.dry_run or not changed:
                return _pack_verdict(pack_rc, packs_failed)
            return cmd_setup(_setup_args(pack_rc, packs_failed))
        out("== rsk ==")
        steps = install.steps_to(inst, args.to, uv) if args.to else inst.steps
        if args.to and not steps:
            raise RskError(f"--to needs a uv tool install from git ({inst.describe()})", USAGE)
        if not steps:
            out(f"  {inst.describe()} — rsk does not update it itself:\n  {inst.manual}")
            if inst.kind in ("editable", "source") and not args.dry_run:
                out("  re-running setup from this checkout")
                return cmd_setup(_setup_args(pack_rc, packs_failed))
            return max(pack_rc, OK if inst.kind in ("editable", "source") else USAGE)
        for cmd in steps:
            rc = _run(cmd, args.dry_run)
            if rc != 0:
                raise RskError(f"`{' '.join(cmd)}` exited {rc}; the installed rsk is unchanged unless uv said otherwise",
                               UNKNOWN)
        if args.dry_run:
            out("  then: rsk setup --after-update (run by the new rsk)")
            return OK
        now_commit = str(((install.read_direct_url() or {}).get("vcs_info") or {}).get("commit_id", ""))
        if inst.kind == "git" and now_commit and now_commit == inst.commit and not changed:
            if _setup_is_current(now_commit):
                out(f"  {_nothing_new(inst, now_commit)}\n  the harness copy and skills are from it: nothing to set up again")
                return _pack_verdict(pack_rc, packs_failed)
            out(f"  {now_commit[:12]} is installed, but install.json shows no successful rsk setup from it — running it")
        state.append_jsonl(paths.state_dir() / "update-history.jsonl", {
            "at": state.now(), "from_version": __version__, "from_commit": inst.commit, "source": inst.source,
            "ref": args.to or inst.ref})
    new = install.entry_path(install.read_receipt(Path(sys.prefix)))
    if not new:
        out("updated; now run: rsk setup")
        return _pack_verdict(pack_rc, packs_failed)
    argv = [new, "setup", "--after-update", "--from", __version__, "--from-commit", inst.commit or ""]
    if pack_rc:   # the new rsk's setup ends with this verdict, so rsk update's exit still reports the packs
        out(f"  pack(s) not updated: {packs_failed} — setup runs now, then rsk update exits {pack_rc}")
        argv += ["--pack-rc", str(pack_rc), "--packs-failed", packs_failed]
    sys.stdout.flush()
    os.execv(new, argv)
    return OK   # not reached


# ---------------------------------------------------------------------------------------------------- pack
def cmd_pack(args: argparse.Namespace) -> int:
    if args.pack_command == "add":
        path, msg = packs.add(paths.packs_dir(), args.source, args.name)
        out(msg)
        out("next: rsk setup   (puts the pack's targets into the skills' INDEX and runs its tests)")
        return OK
    plist = packs.all_packs(paths.packs_dir())
    if not plist:
        out(f"no packs under {paths.packs_dir()}")
    for p in plist:
        extra = {"clone": f"{p.origin} [{p.branch}{', dirty' if p.dirty else ''}{', no upstream' if not p.upstream else ''}]",
                 "link": f"-> {p.origin} (your working tree{', origin ' + p.remote if p.remote else ''})",
                 "dir": "plain directory"}[p.kind]
        out(f"{p.name}\t{p.kind}\t{extra}")
    return OK


# ---------------------------------------------------------------------------------------------------- doctor
def _ssh_alias_ok(host: str) -> bool:
    done = subprocess.run(["ssh", "-G", host], capture_output=True, text=True, timeout=20)
    if done.returncode != 0:
        return False
    conf = dict(line.split(" ", 1) for line in done.stdout.splitlines() if " " in line)
    return conf.get("hostname", host) != host and "<" not in conf.get("user", "")


def cmd_doctor(args: argparse.Namespace) -> int:
    fails = 0

    def report(level: str, msg: str) -> None:
        nonlocal fails
        fails += level == "FAIL"
        out(f"  {level:<4} {msg}")

    inst = install.current()
    out(f"rsk {__version__} — {inst.describe()}")
    out("== config ==")
    try:
        cfg = config.load(paths.config_file())
        report("ok", f"{cfg.path} {'read' if cfg.exists else '(absent: defaults)'}")
        for key in cfg.unknown:
            report("WARN", f"{cfg.path}: unknown key {key} (see: rsk config --template)")
    except RskError as exc:
        report("FAIL", str(exc))
    out("== harness and skills ==")
    try:
        src = paths.harness_src()
        report("ok", f"harness shipped at {src}")
    except RskError as exc:
        report("FAIL", str(exc))
        return USAGE
    rec = state.read_json(paths.state_dir() / "install.json")
    root = paths.harness_root()
    if not (root / "bin" / "run-sync").is_file():
        report("FAIL", f"no harness copy at {root} — run: rsk setup")
    elif not rec:
        report("WARN", f"{root} was not installed by rsk setup — run: rsk setup")
    elif rec.get("version") != __version__ or rec.get("harness_src") != str(src):
        report("WARN", f"{root} is from rsk {rec.get('version')} — run: rsk setup")
    elif inst.commit and rec.get("commit") != inst.commit:   # every dev commit shares one version string
        report("WARN", f"{root} is from commit {str(rec.get('commit') or '?')[:12]}, this rsk is {inst.commit[:12]} — "
                       "run: rsk setup")
    elif rec.get("install_rc") not in (0, None):
        report("WARN", f"the last rsk setup ended with exit {rec.get('install_rc')} — run it again and read its FAIL lines")
    else:
        report("ok", f"{root} installed by rsk setup at {rec.get('at')}")
    for s in ("hpc-run", "ws-run"):
        copy = paths.skills_root() / s / "SKILL.md"
        link = paths.home() / ".claude" / "skills" / s
        if not copy.is_file():
            report("FAIL", f"skill {s}: {copy} missing — run: rsk setup")
        elif link.resolve() != copy.parent.resolve():
            report("WARN", f"skill {s}: {link} does not point at {copy.parent} — Claude Code will not see it")
        else:
            report("ok", f"skill {s}: {copy.parent} (+ {link})")
    out("== packs ==")
    plist = packs.all_packs(paths.packs_dir())
    if not plist:
        report("ok", f"no packs under {paths.packs_dir()}")
    for p in plist:
        report("WARN" if p.dirty else "ok", f"{p.name}: {p.kind} {p.origin}{' (uncommitted changes)' if p.dirty else ''}")
    out("== targets ==")
    tlist = harness.targets(src)
    if not tlist:
        report("WARN", "no targets registered — INSTALL.md Steps 2-6, or rsk pack add <url>")
    hosts: set[str] = set()
    for t in tlist:
        if t.error:
            report("FAIL", f"{t.name}: {t.error}")
            continue
        report("ok", f"{t.name}: {t.kind} via {t.host}{f', files via {t.xfer_host}' if t.xfer_host else ''} ({t.dir})")
        hosts.update(h for h in (t.host, t.xfer_host) if h)
    out("== local tools ==")
    for tool in ("bash", "ssh", "rsync", "git"):
        report("ok" if shutil.which(tool) else "FAIL", f"{tool}: {shutil.which(tool) or 'not found'}")
    uv = install.find_uv()
    report("ok" if uv else "WARN", f"uv: {uv or 'not found (needed by rsk update)'}")
    entry = install.entry_path(install.read_receipt(Path(sys.prefix)))
    if entry and str(Path(entry).parent) not in os.environ.get("PATH", "").split(os.pathsep):
        report("WARN", f"{Path(entry).parent} is not on PATH — agents must call {entry} (or: uv tool update-shell)")
    if shutil.which("ssh"):
        missing = sorted(h for h in hosts if not _ssh_alias_ok(h))
        report("WARN" if missing else "ok", f"ssh aliases missing: {' '.join(missing)}" if missing
               else f"ssh aliases resolve: {' '.join(sorted(hosts)) or '-'}")
    out(f"== {'no failures' if not fails else f'{fails} failure(s)'} ==")
    return OK if not fails else USAGE


# ---------------------------------------------------------------------------------------------------- config
def cmd_config(args: argparse.Namespace) -> int:
    if args.template:
        out(config.describe())
        return OK
    cfg = config.load(paths.config_file())
    out(f"# {cfg.path} ({'read' if cfg.exists else 'absent: defaults'})")
    for section, keys in cfg.values.items():
        for key, value in keys.items():
            out(f"{section}.{key} = {value}")
    for key in cfg.unknown:
        out(f"# unknown: {key}")
    return OK


# ---------------------------------------------------------------------------------------------------- main
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="rsk", description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog=__doc__.split("\n\n", 1)[1])
    p.add_argument("--version", action="version", version=f"rsk {__version__}")
    sub = p.add_subparsers(dest="command", required=True, metavar="<command>")
    s = sub.add_parser("setup", help="install the harness copy and skills from this rsk")
    s.add_argument("--after-update", action="store_true", help=argparse.SUPPRESS)
    s.add_argument("--from", dest="from_version", default="", help=argparse.SUPPRESS)
    s.add_argument("--from-commit", default="", help=argparse.SUPPRESS)
    s.add_argument("--pack-rc", type=int, default=OK, help=argparse.SUPPRESS)       # rsk update's pack verdict
    s.add_argument("--packs-failed", default="", help=argparse.SUPPRESS)
    s.set_defaults(func=cmd_setup)
    u = sub.add_parser("update", aliases=["upgrade"], help="update rsk (uv) and the pack clones, then re-run setup")
    u.add_argument("--check", action="store_true", help="only report what is newer (reads the network)")
    u.add_argument("--dry-run", action="store_true", help="print the steps without running them")
    g = u.add_mutually_exclusive_group()
    g.add_argument("--packs-only", action="store_true", help="only fast-forward the pack clones")
    g.add_argument("--tool-only", action="store_true", help="leave the packs alone")
    u.add_argument("--to", metavar="REF", default="", help="install this git ref (tag, branch or commit) instead")
    u.set_defaults(func=cmd_update)
    k = sub.add_parser("pack", help="list or register target packs")
    ksub = k.add_subparsers(dest="pack_command", required=True, metavar="list|add")
    ksub.add_parser("list", help="the packs under ~/.config/run-skills/packs")
    ka = ksub.add_parser("add", help="clone a pack (git URL) or link one (local directory)")
    ka.add_argument("source")
    ka.add_argument("--name", default=None, help="directory name under packs/ (default: repo name minus run-skills-)")
    k.set_defaults(func=cmd_pack)
    status_cmd.add_parsers(sub)
    remote_exec.add_parser(sub)
    d = sub.add_parser("doctor", help="offline checks of this install")
    d.set_defaults(func=cmd_doctor)
    c = sub.add_parser("config", help="show rsk's settings")
    c.add_argument("--template", action="store_true", help="print every key with its default and meaning")
    c.set_defaults(func=cmd_config)
    return p


def _isolate() -> None:
    """An installed rsk ignores PYTHONPATH/PYTHONHOME/user site: re-exec isolated (python -I) when they are set."""
    if sys.flags.isolated or not paths.PACKAGED.is_dir():
        return
    if any(os.environ.get(k) for k in ("PYTHONPATH", "PYTHONHOME", "PYTHONUSERBASE")):
        os.execv(sys.executable, [sys.executable, "-I", "-m", "remote_run", *sys.argv[1:]])


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        _isolate()
    args = build_parser().parse_args(argv)
    try:
        rc = args.func(args)
        sys.stdout.flush()        # a reader that went away surfaces here, not as a traceback at interpreter exit
        return rc
    except BrokenPipeError:       # `rsk status | head`: stdout's reader left before the end — say so the shell's way
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())   # the exit-time flush must not fail again
        return 141
    except RskError as exc:
        print(f"rsk: {exc}", file=sys.stderr, flush=True)
        return exc.code
    except subprocess.TimeoutExpired as exc:
        print(f"rsk: timed out: {' '.join(map(str, exc.cmd))}", file=sys.stderr, flush=True)
        return UNKNOWN
    except KeyboardInterrupt:
        return 130

