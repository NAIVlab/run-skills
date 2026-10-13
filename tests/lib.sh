# run-skills tests/lib.sh — stub + helper library, sourced by every tests/NN-*.sh and targets/*/tests.sh.
# Caller sets RS_HOME (harness root) and RS_USER_DIR (fixtures in phase A, the real overlay in phase B).
# Scratch dir $T (removed on exit); counters PASS/FAIL; helpers ok bad has hasnt nosub mk_proj sub with_path
# stub_sinfo stub_fail stub_rsync. Stubs sbatch scontrol squeue sinfo ssh uv live in $T/bin, on PATH ONLY
# for invocations prefixed PATH="$T/bin:$PATH" (sub/with_path do this) — forget it and you hit real binaries.
: "${RS_HOME:?tests/lib.sh: set RS_HOME}"
export RS_USER_DIR="${RS_USER_DIR:-$HOME/.config/run-skills}"
T=$(mktemp -d); PASS=0; FAIL=0
trap 'rm -rf "$T"' EXIT
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
has(){ echo "$1" | grep -qe "$2" && ok "$3" || { bad "$3"; echo "$1" | head -10 | sed 's/^/    | /'; }; }
hasnt(){ echo "$1" | grep -qe "$2" && bad "$3" || ok "$3"; }
nosub(){ [ ! -s "$T/sbatch.log" ] && ok "$1" || { bad "$1"; sed 's/^/    | /' "$T/sbatch.log"; }; }

# ---------- stubs ----------
mkdir -p "$T/bin" "$T/sinfo.d"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/sbatch.log"\nfor a in "$@"; do echo "ARG:$a"; done\necho "Submitted batch job 1"\n' "$T" > "$T/bin/sbatch"
printf '#!/usr/bin/env bash\necho "NodeName=node01 AllocTRES=cpu=8,gres/gpu=1"\n' > "$T/bin/scontrol"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/squeue"
cat > "$T/bin/sinfo" <<EOS
#!/usr/bin/env bash
# prints the line registered with stub_sinfo PATTERN whose PATTERN occurs in the sinfo arguments
for f in "$T"/sinfo.d/*; do [ -f "\$f" ] || continue; case "\$*" in *"\$(basename "\$f")"*) cat "\$f"; exit 0 ;; esac; done
echo "nodeZ   gpu:whatever:4   gpu:whatever:0   idle"
EOS
cat > "$T/bin/ssh" <<EOS
#!/usr/bin/env bash
echo "\$1" >> "$T/ssh-host.log"
shift; cmd="\$*"          # \$1 is the host
case "\$cmd" in
  *query-gpu=index,name*) printf '0, F, 0 %%, 8000 MiB, 49140 MiB\n1, F, 0 %%, 2 MiB, 49140 MiB\n2, F, 0 %%, 5 MiB, 49140 MiB\n3, F, 0 %%, 9000 MiB, 49140 MiB\n' ;;
  *query-gpu=index,memory.used*) printf '0, 8000\n1, 2\n2, 5\n3, 9000\n' ;;
  *) echo "\$cmd" >> "$T/launch.log"; echo "[fake] started PID 4242" ;;
esac
EOS
# uv stub: bootstrap.sh must find *an* uv on PATH or it would curl the installer (tests never touch the network)
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo "uv 0.0.0-stub" ;; sync) shift; echo "[stub] uv sync $*" ;; esac\nexit 0\n' > "$T/bin/uv"
chmod +x "$T/bin/"*

stub_sinfo(){ printf '%s\n' "$2" > "$T/sinfo.d/$1"; }                       # stub_sinfo PATTERN LINE
stub_fail(){ printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/$1"; chmod +x "$T/bin/$1"; }   # stub_fail CMD
stub_rsync(){ printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "%s/rsync.log"\n' "$T" > "$T/bin/rsync"; chmod +x "$T/bin/rsync"; : > "$T/rsync.log"; }
with_path(){ PATH="$T/bin:$PATH" "$@"; }

# mk_proj TARGET CONF_TEXT -> prints $T/proj_N holding the deploy dir (.<t>/ or .ws/) with the remote scripts,
# the target's profile.sh (+ T_NAME line, as run-sync deploys it), any policy*.sh, and the conf file.
mk_proj(){
  local t="$1" conf="$2" n p; n=$(ls -d "$T"/proj_* 2>/dev/null | wc -l); p="$T/proj_$((n+1))"
  ( . "$RS_HOME/lib/common.sh"; rs_load_target "$t"; d="$p/$(rs_deploy_dir)"; mkdir -p "$d" || exit 1
    for f in $(rs_deploy_files); do cp "$f" "$d/" || exit 1; done
    { cat "$T_DIR/profile.sh"; printf '\nT_NAME=%s\n' "'$t'"; } > "$d/profile.sh"
    chmod +x "$d"/*.sh; printf '%s\n' "$conf" > "$p/$(rs_conf_file)" ) || return 1
  echo "$p"
}
# sub PROJ TARGET ARGS... : run the deployed submit.sh with the stub PATH, stderr dropped (assert rejections by
# exit status); sbatch.log is truncated first so a following `nosub` is meaningful.
sub(){ local p="$1" t="$2"; shift 2; : > "$T/sbatch.log"; PATH="$T/bin:$PATH" bash "$p/.$t/submit.sh" "$@" 2>/dev/null; }
