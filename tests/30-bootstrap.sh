#!/usr/bin/env bash
# tests/30-bootstrap.sh — phase A: remote/bootstrap.sh on the deployed fixtures (uv stub on PATH, never the
# network): inherited sentinel neutralised, venv containment (in-project / ENV_ROOT / VENV_DIR accepted, /tmp
# escape and a hook-moved root refused), BOOTSTRAP_HOOK instead of uv sync, no pyproject, owner-file mismatch,
# conda gates. Run by selftest.sh with RS_HOME set:  bash tests/30-bootstrap.sh
set -u
. "$RS_HOME/tests/lib.sh"
U=rstest$$
# boot PROJ DEPLOYDIR [env...] : run the deployed bootstrap.sh with the stub PATH, stderr merged
boot() { local p=$1 d=$2; shift 2; env "$@" USER="$U" PATH="$T/bin:$PATH" bash -c "export PROJ='$p'; bash '$d/bootstrap.sh' 2>&1"; }

echo "-- uv: guards --"
P=$(mk_proj fx-slurm 'REMOTE_DIR=/x
ENV_KIND=uv') || { bad "mk_proj fx-slurm"; exit 1; }
printf 'REMOTE_DIR=/x\nENV_KIND=uv\nENV_HOOK=nope.sh\n' > "$P/.hpc.conf"
O=$(boot "$P" "$P/.fx-slurm" TARGET=fx-slurm RUN_ENV_READY="$P" HPC_ENV_READY="$P") && bad "inherited sentinel trusted" \
  || has "$O" 'did not complete' "inherited RUN_ENV_READY cannot mask a broken env.sh"
hasnt "$O" 'uv sync' "nothing synced after a failed env.sh"
printf 'REMOTE_DIR=/x\nENV_KIND=uv\nENV_HOOK=hook.sh\n' > "$P/.hpc.conf"
printf 'export UV_PROJECT_ENVIRONMENT=/tmp/escaped-rs-venv\n' > "$P/hook.sh"
O=$(boot "$P" "$P/.fx-slurm" TARGET=fx-slurm) && bad "uncontained venv synced" || has "$O" 'outside' "ENV_HOOK cannot move the venv out of \$PROJ"
[ -e /tmp/escaped-rs-venv ] && bad "no venv created outside \$PROJ" || ok "no venv created outside \$PROJ"
printf 'export RS_ENV_ROOT=/tmp UV_PROJECT_ENVIRONMENT=/tmp/escaped-rs-venv\n' > "$P/hook.sh"
O=$(boot "$P" "$P/.fx-slurm" TARGET=fx-slurm) && bad "hook-moved RS_ENV_ROOT widened the guard" || has "$O" 'outside' "a hook that moves RS_ENV_ROOT cannot widen the guard"
printf 'REMOTE_DIR=/x\nENV_KIND=uv\n' > "$P/.hpc.conf"
O=$(boot "$P" "$P/.fx-slurm" TARGET=fx-slurm); RC=$?
[ "$RC" = 1 ] && has "$O" 'no pyproject.toml' "no pyproject.toml -> exit 1" || bad "no pyproject.toml -> exit 1 (rc=$RC)"
hasnt "$O" 'uv sync' "no sync without pyproject"

echo "-- uv: sane path --"
: > "$P/pyproject.toml"
O=$(boot "$P" "$P/.fx-slurm" TARGET=fx-slurm); RC=$?
[ "$RC" = 0 ] && ok "contained venv -> syncs (rc 0)" || { bad "contained venv -> syncs (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
has "$O" '\[stub\] uv sync' "uv sync ran (stub)"; has "$O" "venv=$P/.venv-fx" "syncs the venv env.sh will use"
has "$O" 'uv 0.0.0-stub' "reuses an on-PATH uv (no download)"; has "$O" 'bootstrap done (fx-slurm)' "final line names the target"
[ "$(cat "$P/.venv-fx/.run-skills-proj" 2>/dev/null)" = "$P" ] && ok "owner file written" || bad "owner file written"
printf 'REMOTE_DIR=/x\nENV_KIND=uv\nUV_SYNC_ARGS="--extra dev --frozen"\n' > "$P/.hpc.conf"
O=$(boot "$P" "$P/.fx-slurm" TARGET=fx-slurm); has "$O" '\[stub\] uv sync --extra dev --frozen' "UV_SYNC_ARGS word-split into uv sync"
printf '/somewhere/else\n' > "$P/.venv-fx/.run-skills-proj"
O=$(boot "$P" "$P/.fx-slurm" TARGET=fx-slurm) && bad "foreign venv synced" || has "$O" 'belongs to /somewhere/else' "owner-file mismatch refused"
hasnt "$O" '\[stub\] uv sync' "owner check happens before syncing"
mkdir -p "$T/home/shared"; printf '/somewhere/else\n' > "$T/home/shared/.run-skills-proj"
printf 'REMOTE_DIR=/x\nENV_KIND=uv\nVENV_DIR=$HOME/shared\n' > "$P/.hpc.conf"
O=$(boot "$P" "$P/.fx-slurm" TARGET=fx-slurm HOME="$T/home"); RC=$?
[ "$RC" = 0 ] && has "$O" "venv=$T/home/shared" "explicit VENV_DIR is accepted and shared on purpose" || bad "explicit VENV_DIR accepted (rc=$RC)"
printf 'REMOTE_DIR=/x\nENV_KIND=uv\nBOOTSTRAP_HOOK=boot.sh\n' > "$P/.hpc.conf"
printf 'echo HOOK_RAN venv=$UV_PROJECT_ENVIRONMENT target=$RS_TARGET\n' > "$P/boot.sh"
O=$(boot "$P" "$P/.fx-slurm" TARGET=fx-slurm); RC=$?
[ "$RC" = 0 ] && has "$O" "HOOK_RAN venv=$P/.venv-fx target=fx-slurm" "BOOTSTRAP_HOOK runs with env.sh exported" || bad "BOOTSTRAP_HOOK runs (rc=$RC)"
has "$O" 'running BOOTSTRAP_HOOK boot.sh' "announces the hook"; hasnt "$O" '\[stub\] uv sync' "no uv sync when BOOTSTRAP_HOOK is set"
printf 'exit 7\n' > "$P/boot.sh"
boot "$P" "$P/.fx-slurm" TARGET=fx-slurm >/dev/null && bad "failing BOOTSTRAP_HOOK aborts" || ok "failing BOOTSTRAP_HOOK aborts"
printf 'REMOTE_DIR=/x\nENV_KIND=uv\nBOOTSTRAP_HOOK=missing.sh\n' > "$P/.hpc.conf"
O=$(boot "$P" "$P/.fx-slurm" TARGET=fx-slurm) && bad "missing BOOTSTRAP_HOOK" || has "$O" "BOOTSTRAP_HOOK 'missing.sh' not found" "missing BOOTSTRAP_HOOK -> abort"

echo "-- uv: ENV_ROOT venv --"
H=$(mk_proj fx-home 'REMOTE_DIR=/x
ENV_KIND=uv') || { bad "mk_proj fx-home"; exit 1; }
: > "$H/pyproject.toml"; mkdir -p "$T/tmpx"
O=$(boot "$H" "$H/.fx-home" TARGET=fx-home HOME="$T/home" TMPDIR="$T/tmpx"); RC=$?
[ "$RC" = 0 ] && has "$O" "venv=$T/home/.rs-test/envs/$(basename "$H")-fx" "venv under T_ENV_ROOT accepted" || { bad "venv under T_ENV_ROOT accepted (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
[ -f "$T/home/.rs-test/envs/$(basename "$H")-fx/.run-skills-proj" ] && ok "owner file under ENV_ROOT" || bad "owner file under ENV_ROOT"

echo "-- conda --"
mkdir -p "$T/home/miniconda3/etc/profile.d"
cat > "$T/home/miniconda3/etc/profile.d/conda.sh" <<'EOF'
conda() { case "$1" in env) printf '# conda environments:\nbase  *  /x\ngood     /y\n' ;; activate) export CONDA_DEFAULT_ENV=$2 ;; *) return 1 ;; esac; }
EOF
W=$(mk_proj ws-box 'WS_REMOTE_DIR=projects/x
ENV_KIND=conda') || { bad "mk_proj ws-box"; exit 1; }
O=$(boot "$W" "$W/.ws" HOME="$T/home"); RC=$?
[ "$RC" = 1 ] && has "$O" 'ENV_NAME required' "conda without ENV_NAME -> abort" || bad "conda without ENV_NAME -> abort (rc=$RC)"
printf 'WS_REMOTE_DIR=projects/x\nENV_KIND=conda\nENV_NAME=nope\n' > "$W/.ws.conf"
O=$(boot "$W" "$W/.ws" HOME="$T/home"); RC=$?
[ "$RC" = 1 ] && has "$O" "conda env 'nope' MISSING on ws-box" "missing conda env -> abort, never created" || bad "missing conda env -> abort (rc=$RC)"
printf 'WS_REMOTE_DIR=projects/x\nENV_KIND=conda\nENV_NAME=nope\nWSBOX_ENV_NAME=good\n' > "$W/.ws.conf"
O=$(boot "$W" "$W/.ws" HOME="$T/home"); RC=$?
[ "$RC" = 0 ] && has "$O" "conda env 'good' present" "<TAG>_ENV_NAME present -> ok" || bad "conda env present (rc=$RC)"
has "$O" 'bootstrap done (ws-box)' "conda: final line"; hasnt "$O" 'uv' "conda branch never touches uv"

echo "-- resolver --"
rm "$W/.ws.conf"
O=$(boot "$W" "$W/.ws"); RC=$?
[ "$RC" = 2 ] && has "$O" 'MISSING .*\.ws\.conf' "missing conf -> exit 2" || bad "missing conf -> exit 2 (rc=$RC)"
printf 'WS_REMOTE_DIR=projects/x\nENV_KIND=bogus\n' > "$W/.ws.conf"
O=$(boot "$W" "$W/.ws"); RC=$?
[ "$RC" = 2 ] && has "$O" "invalid ENV_KIND='bogus'" "invalid ENV_KIND -> exit 2" || bad "invalid ENV_KIND -> exit 2 (rc=$RC)"
rm "$W/.ws/profile.sh"
O=$(boot "$W" "$W/.ws"); RC=$?
[ "$RC" = 2 ] && has "$O" 'MISSING .*profile\.sh' "missing profile -> exit 2" || bad "missing profile -> exit 2 (rc=$RC)"
O=$(boot "$P" "$P/.fx-slurm" -u TARGET -u CLUSTER); RC=$?
[ "$RC" = 2 ] && ok "slurm project without TARGET -> exit 2" || bad "slurm project without TARGET -> exit 2 (rc=$RC)"
rm -rf "/tmp/ray_$U-fx" "/tmp/ray_$U"
