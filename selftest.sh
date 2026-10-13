#!/usr/bin/env bash
# run-skills selftest.sh — the test runner (local). Phase A runs tests/NN-*.sh against fixture targets written
# here under a scratch RS_USER_DIR (never the real ~/.config/run-skills); phase B runs targets/<t>/tests.sh and
# tests.local.sh from the shipped tree, every installed target pack and the real overlay. Every section is a subshell; its "  PASS:"/"  FAIL:"
# lines are aggregated from a results file.   Usage: bash selftest.sh   (exit code = number of failures)
set -u
RS_HOME=$(cd "$(dirname "$0")" && pwd); export RS_HOME
RS_USER_DIR_REAL=${RS_USER_DIR:-$HOME/.config/run-skills}; export RS_USER_DIR_REAL   # 70-docs reads the real overlay in phase A
RS_PACKS_DIR_REAL=${RS_PACKS_DIR:-$RS_USER_DIR_REAL/packs}
T_A=$(mktemp -d); trap 'rm -rf "$T_A"' EXIT
R=$T_A/results; : > "$R"
run_section() {   # run_section LABEL CMD... : stream + record the output; a crashed section counts as a FAIL
  echo "== $1 =="; shift
  "$@" 2>&1 | tee -a "$R"; rc=${PIPESTATUS[0]}
  [ "$rc" = 0 ] || echo "  FAIL: section exited $rc" | tee -a "$R"
}

# ---------- phase A: fixture targets (spec §9) ----------
FX=$T_A/user/targets; mkdir -p "$FX/fx-slurm" "$FX/fx-home" "$FX/ws-box"
cat > "$FX/fx-slurm/profile.sh" <<'EOF'
T_KIND=slurm; T_HOST=fx; T_DESC='fixture slurm cluster'; T_TRIGGERS='fx'; T_GPUS='4x fake'; T_CUDA_ARCH='9.0'
T_SUFFIX='-fx'; T_CONDA_INIT='source $HOME/miniconda3/etc/profile.d/conda.sh'; T_CUDA_HOME=''; T_ENV_ROOT=''
T_TMPDIR=project; T_COMPILE_CACHE=project; T_REMOTE_DIR_REQUIRED=0; T_CONF_KEYS=''
T_DEFAULT_PARTITION=gpu; T_DEFAULT_GPU_TYPE=any; T_MAXTIME=1-00:00:00; T_FORBIDDEN_QOS='vip'; T_PARTITIONS='gpu forbidden'
EOF
cat > "$FX/fx-slurm/policy.sh" <<'EOF'
t_partition() { case "$1" in gpu) P_GPUS=1-4 P_CPU_PER_GPU=8 P_MEM_PER_GPU=40 ;; *) return 1 ;; esac; }
t_policy() {
  [ "$PART" = vip ] && { echo "REFUSED: vip is policy-gated" >&2; exit 3; }
  [ "$PART" = gpu ] && [ "${ACK:-0}" = 1 ] && SB_ARGS+=(--comment=acked); return 0
}
EOF
cat > "$FX/fx-home/profile.sh" <<'EOF'
T_KIND=slurm; T_HOST=fx; T_DESC='fixture slurm cluster with a home env root'; T_SUFFIX='-fx'
T_CONDA_INIT='source $HOME/miniconda3/etc/profile.d/conda.sh'; T_ENV_ROOT='$HOME/.rs-test'; T_TMPDIR=inherit
T_COMPILE_CACHE=tmp; T_DEFAULT_PARTITION=gpu; T_DEFAULT_GPU_TYPE=any; T_MAXTIME=1-00:00:00
EOF
cat > "$FX/ws-box/profile.sh" <<'EOF'
T_KIND=nohup; T_HOST=wsbox; T_DESC='fixture workstation'; T_GPUS='4x fake'; T_SUFFIX=''; T_ENV_ROOT=''
T_TMPDIR=project; T_COMPILE_CACHE=project; T_CONDA_INIT='source $HOME/miniconda3/etc/profile.d/conda.sh'
EOF
PK=$T_A/user/packs/fx-pack; mkdir -p "$PK/targets/fx-packed" "$PK/routing"   # a target pack: one target + routing
cat > "$PK/targets/fx-packed/profile.sh" <<'EOF'
T_KIND=slurm; T_HOST=fxp; T_DESC='fixture pack cluster'; T_TRIGGERS='fxpacked'; T_DEFAULT_PARTITION=gpu
T_DEFAULT_GPU_TYPE=any; T_MAXTIME=1-00:00:00; T_TMPDIR=project; T_COMPILE_CACHE=project
EOF
printf -- '- fixture pack routing rule\n' > "$PK/routing/hpc-run.md"
export RS_USER_DIR=$T_A/user RS_PACKS_DIR=$T_A/user/packs
for f in "$RS_HOME"/tests/[0-9]*.sh; do run_section "A: $(basename "$f")" bash "$f"; done

# ---------- phase B: per-target tests with the REAL overlay ----------
for d in "$RS_HOME"/targets/*/ "$RS_PACKS_DIR_REAL"/*/targets/*/ "$RS_USER_DIR_REAL"/targets/*/; do
  [ -d "$d" ] || continue; d=${d%/}; case "$(basename "$d")" in _*) continue ;; esac
  for f in "$d/tests.sh" "$d/tests.local.sh"; do
    [ -f "$f" ] || continue
    run_section "B: ${f#"$HOME"/}" env RS_USER_DIR="$RS_USER_DIR_REAL" RS_PACKS_DIR="$RS_PACKS_DIR_REAL" bash -c '. "$RS_HOME/tests/lib.sh"; . "$1"' _ "$f"
  done
done
P=$(grep -c '^  PASS: ' "$R"); F=$(grep -c '^  FAIL: ' "$R")
echo; echo "===== RESULT: $P pass, $F fail ====="
exit "$F"
