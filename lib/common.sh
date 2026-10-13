# run-skills lib/common.sh — LOCAL-ONLY helpers, sourced by bin/* and install.sh (never deployed).
# Caller sets RS_HOME (harness root). macOS bash 3.2 safe: no ${var^^}, declare -A, readarray.
# Target discovery (user overlay > target packs > shipped), profile/conf loading with CLI > <TAG>_KEY > KEY
# precedence (ovr), remote-dir resolution, deploy file list, conf linter, INDEX.
: "${RS_HOME:?lib/common.sh: RS_HOME must be set by the caller}"
RS_USER_DIR="${RS_USER_DIR:-$HOME/.config/run-skills}"
RS_PACKS_DIR="${RS_PACKS_DIR:-$RS_USER_DIR/packs}"   # each subdir is a target pack: targets/<t>/ [+ routing/<skill>.md]
RS_USER="${USER:-$(id -un)}"
RS_PREFIXABLE_SLURM='REMOTE_DIR ENV_NAME RUN DEFAULT_PARTITION DEFAULT_GPU_TYPE DEFAULT_GPUS DEFAULT_CPUS DEFAULT_MEM DEFAULT_TIME ACCOUNT SBATCH_EXTRA JOB_NAME VENV_DIR'
RS_PREFIXABLE_NOHUP='REMOTE_DIR ENV_NAME RUN DEFAULT_NGPU GPU_EXCLUDE NICE JOB_NAME VENV_DIR'

die() { echo "ERROR: $*" >&2; exit 2; }
rs_tag() { printf %s "$1" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]'; }
# expand ONLY $HOME/${HOME}/$USER/${USER} in a T_* path (local mirror of remote/env.sh's _rs_path; reserved, no bin/* caller yet)
rs_path() { printf %s "$1" | sed -e "s|\\\${HOME}|$HOME|g" -e "s|\\\$HOME|$HOME|g" -e "s|\\\${USER}|$RS_USER|g" -e "s|\\\$USER|$RS_USER|g"; }

rs_roots() {   # target roots, highest precedence first: user overlay, each pack (glob order), shipped
  local p; echo "$RS_USER_DIR/targets"
  for p in "$RS_PACKS_DIR"/*/; do [ -d "${p}targets" ] && echo "${p}targets"; done; echo "$RS_HOME/targets"
}
rs_targets() {   # names, sorted unique; a dir counts only with profile.sh; _template-* skipped
  local r d n
  rs_roots | while IFS= read -r r; do for d in "$r"/*/; do
    [ -f "$d/profile.sh" ] || continue
    n=$(basename "$d"); case "$n" in _*) ;; *) echo "$n" ;; esac
  done; done | sort -u
}
rs_target_dir() {   # dir whose profile.sh is authoritative (first root that has one)
  local d; d=$(rs_roots | while IFS= read -r r; do [ -f "$r/$1/profile.sh" ] && { echo "$r/$1"; break; }; done)
  [ -n "$d" ] && echo "$d" || die "unknown target '$1' (known: $(rs_targets | tr '\n' ' '))"
}
rs_target_local_dir() { [ -d "$RS_USER_DIR/targets/$1" ] && echo "$RS_USER_DIR/targets/$1"; return 0; }
rs_load_target() {   # sets T_NAME T_TAG T_DIR T_LOCAL_DIR + every T_* from profile.sh
  T_DIR=$(rs_target_dir "$1") || exit 2
  T_LOCAL_DIR=$(rs_target_local_dir "$1")
  unset T_KIND T_HOST T_DESC T_TRIGGERS T_GPUS T_CUDA_ARCH T_SUFFIX T_CONDA_INIT T_CUDA_HOME T_ENV_ROOT T_TMPDIR \
    T_COMPILE_CACHE T_REMOTE_DIR_REQUIRED T_CONF_KEYS T_DEFAULT_PARTITION T_DEFAULT_GPU_TYPE T_MAXTIME T_FORBIDDEN_QOS T_PARTITIONS T_XFER_HOST
  . "$T_DIR/profile.sh"
  T_NAME=$1; T_TAG=$(rs_tag "$1")
  case "${T_KIND:-}" in slurm|nohup) ;; *) die "$T_DIR/profile.sh: T_KIND must be slurm|nohup (got '${T_KIND:-}')" ;; esac
  [ -n "${T_HOST:-}" ] || die "$T_DIR/profile.sh: T_HOST is empty"
}
rs_init() {   # bin/* prologue: TARGET (CLUSTER= / STATION= are aliases) -> rs_load_target
  TARGET="${TARGET:-${CLUSTER:-${STATION:-}}}"; [ -n "$TARGET" ] || die "set TARGET=<name> (or CLUSTER=/STATION=); known: $(rs_targets | tr '\n' ' ')"
  rs_load_target "$TARGET"
}
rs_host() { [ "$T_KIND" = slurm ] && printf %s "${REMOTE_HOST:-$T_HOST}" || printf %s "$T_HOST"; }   # slurm honours REMOTE_HOST
rs_conf_file() { [ "$T_KIND" = slurm ] && echo .hpc.conf || echo .ws.conf; }
rs_load_conf() {   # rs_load_conf KEY... : unset KEY and ${T_TAG}_KEY, then source ./<conf> from the cwd
  local c k; c=$(rs_conf_file)
  for k in "$@"; do unset "$k" "${T_TAG}_$k"; done
  [ -f "./$c" ] || die "no $c in $(pwd). cd to the repo root (or scaffold one)."
  . "./$c" || die "failed sourcing $c (unquoted spaces?)"
}
ovr() {   # ovr KEY [DEFAULT] -> ${T_TAG}_KEY, else KEY, else DEFAULT
  local _v; eval "_v=\${${T_TAG}_$1:-}"; [ -n "$_v" ] || eval "_v=\${$1:-}"; printf %s "${_v:-${2:-}}"
}
rs_remote_dir() {
  local d t; eval "t=\${${T_TAG}_REMOTE_DIR:-}"
  if [ "$T_KIND" = slurm ]; then
    [ "${T_REMOTE_DIR_REQUIRED:-0}" = 1 ] && [ -z "$t" ] && \
      die "target '$T_NAME' does not share a filesystem with other targets — set ${T_TAG}_REMOTE_DIR in .hpc.conf"
    d=$(ovr REMOTE_DIR); [ -n "$d" ] || die "REMOTE_DIR (or ${T_TAG}_REMOTE_DIR) not set in .hpc.conf — never guess it"
  else
    d="${t:-${WS_REMOTE_DIR:-}}"; [ -n "$d" ] || die "WS_REMOTE_DIR (or ${T_TAG}_REMOTE_DIR) not set in .ws.conf — never guess it"
  fi
  printf %s "$d"
}
rs_deploy_dir() { [ "$T_KIND" = slurm ] && echo ".$T_NAME" || echo .ws; }
rs_deploy_files() {   # absolute paths, one per line (profile.sh is deployed separately with T_NAME appended)
  echo "$RS_HOME/remote/env.sh"; echo "$RS_HOME/remote/bootstrap.sh"; echo "$RS_HOME/remote/status.sh"
  [ "$T_KIND" = slurm ] || return 0
  echo "$RS_HOME/remote/submit.sh"; echo "$RS_HOME/remote/job.sbatch"
  [ -f "$T_DIR/policy.sh" ] && echo "$T_DIR/policy.sh"
  [ -n "$T_LOCAL_DIR" ] && [ -f "$T_LOCAL_DIR/policy.local.sh" ] && echo "$T_LOCAL_DIR/policy.local.sh"
  return 0
}
rs_lint_conf() {   # rs_lint_conf FILE: warn on <TAG>_KEY lines whose KEY no target honours (kind's list + every T_CONF_KEYS)
  local tags keys line n rest p k
  tags=" $(rs_targets | while read -r n; do rs_tag "$n"; echo; done | tr '\n' ' ') "
  [ "$T_KIND" = slurm ] && keys=" $RS_PREFIXABLE_SLURM " || keys=" $RS_PREFIXABLE_NOHUP "
  keys="$keys${T_CONF_KEYS:-} "   # + other targets' private keys: a multi-target conf is linted on every sync
  for n in $(rs_targets); do keys="$keys$( (rs_load_target "$n" 2>/dev/null; printf %s "${T_CONF_KEYS:-}") ) "; done
  grep -nE '^[[:space:]]*[A-Z0-9]+_[A-Z0-9_]+=' "$1" | while IFS= read -r line; do
    n=${line%%:*}; rest=${line#*:}; rest=${rest#"${rest%%[![:space:]]*}"}
    p=${rest%%_*}; k=${rest#*_}; k=${k%%=*}
    case "$tags" in *" $p "*) ;; *) continue ;; esac
    case "$keys" in *" $k "*) continue ;; esac
    echo "WARN: $1:$n: ${p}_$k is not honoured ($k not prefixable for $T_KIND)" >&2
  done
  return 0
}
rs_wandb_env_file() {
  local f
  for f in ./.wandb_env "$RS_USER_DIR/wandb_env" "$HOME/.config/hpc-run/wandb_env"; do [ -f "$f" ] && { echo "$f"; return 0; }; done
  return 0
}
rs_gen_index() {   # rs_gen_index slurm|nohup OUT [ROOT]: references/INDEX.md for the installed skill of that kind
  local kind=$1 out=$2 root=${3:-$HOME/.agents/run-skills} skill rows=0 ref t
  [ "$kind" = slurm ] && skill=hpc-run || skill=ws-run
  { echo "root: $root"; echo
    echo '| target | host | GPUs | default | max time | description | reference |'; echo '|---|---|---|---|---|---|---|'
    for t in $(rs_targets); do
      ( rs_load_target "$t"; [ "$T_KIND" = "$kind" ] || exit 1
        case "$T_DIR" in "$RS_HOME"/*) ref="$root/targets/$t/reference.md" ;; *) ref="$T_DIR/reference.md" ;; esac
        [ -n "$T_LOCAL_DIR" ] && [ -f "$T_LOCAL_DIR/reference.local.md" ] && ref="$ref + $T_LOCAL_DIR/reference.local.md"
        [ "$kind" = slurm ] && d="${T_DEFAULT_PARTITION:--} / ${T_DEFAULT_GPU_TYPE:--}" || d=-
        echo "| $t | $T_HOST | ${T_GPUS:--} | $d | ${T_MAXTIME:--} | ${T_DESC:--} | $ref |" ) && rows=$((rows+1))
    done
    [ "$rows" = 0 ] && echo && echo "no $([ "$kind" = slurm ] && echo cluster || echo workstation) registered yet: register one with" \
      "the user ($root/INSTALL.md, Steps 2-6: run-probe, then ~/.config/run-skills/targets/<name>/ from $root/targets/_template-$kind/) or install a target pack"
    echo; if [ -f "$RS_HOME/skills/$skill/references/INDEX.md" ]; then sed -n '/^## Routing/,$p' "$RS_HOME/skills/$skill/references/INDEX.md"; fi
    for ref in "$RS_PACKS_DIR"/*/routing/"$skill.md" "$RS_USER_DIR/routing/$skill.md"; do if [ -f "$ref" ]; then cat "$ref"; fi; done
  } > "$out"
}
