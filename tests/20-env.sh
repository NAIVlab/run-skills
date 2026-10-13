#!/usr/bin/env bash
# tests/20-env.sh — phase A: remote/env.sh policy matrix on the deployed fixtures. fx-slurm (everything
# in-project, suffix -fx), fx-home (T_ENV_ROOT=$HOME/.rs-test, TMPDIR inherit, compile caches in tmp),
# ws-box (nohup, uv default, conda via a fake conda.sh); VENV_DIR overrides; every fail-closed path
# withholds RUN_ENV_READY. Run by selftest.sh with RS_HOME set:  bash tests/20-env.sh
set -u
. "$RS_HOME/tests/lib.sh"
U=rstest$$   # RS_USER for every sourcing below, so the /tmp fallbacks env.sh creates are ours to remove
# envq PROJ DEPLOYDIR SNIPPET [env args...] : source the deployed env.sh in a fresh bash, then print SNIPPET
envq() { local p=$1 d=$2 q=$3; shift 3; env "$@" USER="$U" bash -c "export PROJ='$p'; . '$d/env.sh' 2>&1; $q"; }   # env -u X first
# NODE_LOCAL is "TMPDIR starts with /tmp/"; a scratch $T under /tmp flips it, so derive the expected RAY_TMPDIR
ray_for() { case "$1" in /tmp/*) echo "$1/ray" ;; *) echo "/tmp/ray_$U$2" ;; esac; }   # ray_for TMPDIR SUFFIX
Q='echo ready=${RUN_ENV_READY:-unset} hpc=${HPC_ENV_READY:-unset} ws=${WS_ENV_READY:-unset} cl=${CLUSTER:-unset} wstag=${WS_TAG:-unset} venv=${UV_PROJECT_ENVIRONMENT:-unset} rsvenv=${RS_VENV:-unset} uvcache=${UV_CACHE_DIR:-unset} tmp=${TMPDIR:-unset} nv=${CUDA_CACHE_PATH:-unset} triton=${TRITON_CACHE_DIR:-unset} ray=${RAY_TMPDIR:-unset} xdg=${XDG_CACHE_HOME:-unset} hf=${HF_HOME:-unset} root=${RS_ENV_ROOT:-unset} kind=${RS_KIND:-unset} tgt=${RS_TARGET:-unset} arch=${RS_CUDA_ARCH:-unset} wmode=${WANDB_MODE:-unset} wkey=${WANDB_API_KEY:-unset} cuda=${CUDA_HOME:-unset} path0=${PATH%%:*} conda=${CONDA_DEFAULT_ENV:-unset} envname=${ENV_NAME:-unset}'

echo "-- fx-slurm: in-project policy --"
P=$(mk_proj fx-slurm 'REMOTE_DIR=/x
ENV_KIND=uv') || { bad "mk_proj fx-slurm"; exit 1; }
R=$(envq "$P" "$P/.fx-slurm" "$Q" TARGET=fx-slurm CUDA_HOME=/inherited WANDB_API_KEY=sys)
has "$R" "ready=$P " "RUN_ENV_READY=\$PROJ"; has "$R" "hpc=$P " "HPC_ENV_READY set (slurm)"; has "$R" 'ws=unset' "no WS_ENV_READY on slurm"
has "$R" 'cl=fx-slurm ' "exports CLUSTER=fx-slurm"; has "$R" 'wstag=unset' "no WS_TAG on slurm"
has "$R" "venv=$P/.venv-fx " "venv \$PROJ/.venv-fx"; has "$R" "rsvenv=$P/.venv-fx " "RS_VENV exported"
has "$R" "uvcache=$P/.cache/uv-fx " "UV_CACHE_DIR in-project, suffixed"; has "$R" "tmp=$P/tmp " "TMPDIR=\$PROJ/tmp"
has "$R" "nv=$P/.cache/nv " "nv cache never suffixed"; has "$R" "triton=$P/.cache/triton-fx " "triton cache suffixed"
has "$R" "ray=$(ray_for "$P/tmp" -fx) " "RAY_TMPDIR follows the node-local rule (suffixed)"
has "$R" "xdg=$P/.cache " "XDG in-project when ENV_ROOT=\$PROJ"; has "$R" "hf=$P/.cache/huggingface " "HF_HOME in-project"
has "$R" "root=$P " "RS_ENV_ROOT=\$PROJ"; has "$R" 'kind=slurm tgt=fx-slurm arch=9.0 ' "RS_KIND / RS_TARGET / RS_CUDA_ARCH"
has "$R" 'wmode=offline wkey=unset' "no .wandb_env -> system WANDB_API_KEY dropped, mode offline"
has "$R" 'refusing system creds' "offline fallback is announced"
has "$R" 'cuda=unset' "inherited CUDA_HOME unset when T_CUDA_HOME empty"; has "$R" "path0=$P/.venv-fx/bin " "venv bin first on PATH"
R2=$(envq "$P" "$P/.fx-slurm" 'echo cc=${CC:-unset} leak=${D:-}${CONF:-}${TAG:-}${VENV:-}${ENV_ROOT:-}${STATE:-}${_rs_d:-}${_rs_venv:-}' TARGET=fx-slurm CC=gcc)
has "$R2" 'cc=gcc leak=$' "scratch names (D CONF TAG VENV ENV_ROOT ...) do not leak; an exported CC survives"
miss=""; for d in logs ckpts tmp .cache/triton-fx .cache/nv .cache/huggingface/hub wandb bin; do [ -d "$P/$d" ] || miss="$miss $d"; done
[ -z "$miss" ] && ok "project dirs materialised" || bad "project dirs materialised (missing:$miss)"
R=$(envq "$P" "$P/.fx-slurm" "$Q" CLUSTER=fx-slurm)
has "$R" "ready=$P .*cl=fx-slurm " "CLUSTER= alone resolves the target"
printf 'export WANDB_API_KEY=ours\n' > "$P/.wandb_env"
R=$(envq "$P" "$P/.fx-slurm" "$Q" TARGET=fx-slurm WANDB_API_KEY=sys)
has "$R" 'wmode=online wkey=ours' ".wandb_env key used, mode online"
printf 'REMOTE_DIR=/x\nENV_KIND=uv\nVENV_DIR=$HOME/shared-venv\n' > "$P/.hpc.conf"
R=$(envq "$P" "$P/.fx-slurm" "$Q" TARGET=fx-slurm HOME="$T/home")
has "$R" "venv=$T/home/shared-venv " "VENV_DIR honoured (\$HOME expanded)"
printf 'REMOTE_DIR=/x\nENV_KIND=uv\nVENV_DIR=/generic\nFXSLURM_VENV_DIR=$HOME/tagged-venv\n' > "$P/.hpc.conf"
R=$(envq "$P" "$P/.fx-slurm" "$Q" TARGET=fx-slurm HOME="$T/home")
has "$R" "venv=$T/home/tagged-venv .*path0=$T/home/tagged-venv/bin " "<TAG>_VENV_DIR beats VENV_DIR and leads PATH"
if command -v zsh >/dev/null 2>&1; then
  R=$(env USER="$U" TARGET=fx-slurm zsh -c "export PROJ='$P'; . '$P/.fx-slurm/env.sh' 2>&1; echo ready=\${RUN_ENV_READY:-unset}")
  has "$R" "ready=$P" "env.sh sources under zsh"
fi

echo "-- fx-home: env root under \$HOME, TMPDIR inherit, compile caches in tmp --"
H=$(mk_proj fx-home 'REMOTE_DIR=/x
ENV_KIND=uv') || { bad "mk_proj fx-home"; exit 1; }
N=$(basename "$H"); mkdir -p "$T/home" "$T/tmpx" "$T/ro"; chmod 555 "$T/ro"
R=$(envq "$H" "$H/.fx-home" "$Q" TARGET=fx-home HOME="$T/home" TMPDIR="$T/tmpx")
has "$R" "venv=$T/home/.rs-test/envs/$N-fx " "venv under ENV_ROOT/envs/<proj><suffix>"
has "$R" "uvcache=$T/home/.rs-test/.cache/uv-fx " "UV_CACHE_DIR under ENV_ROOT"
has "$R" "xdg=$T/home/.rs-test/state/$N-fx/.cache " "XDG under ENV_ROOT/state/<proj><suffix>"
has "$R" "hf=$H/.cache/huggingface " "blob caches stay in-project"
has "$R" "tmp=$T/tmpx " "preset writable TMPDIR kept (inherit)"; has "$R" "triton=$T/tmpx/triton-fx " "compile caches under \$TMPDIR"
has "$R" "nv=$T/tmpx/nv " "nv under \$TMPDIR, unsuffixed"; has "$R" "ray=$(ray_for "$T/tmpx" -fx) " "RAY_TMPDIR follows the node-local rule"
[ -d "$T/tmpx/triton-fx" ] && bad "compile-cache dirs not created inside a per-job TMPDIR" || ok "compile-cache dirs not created inside a per-job TMPDIR"
[ -d "$T/home/.rs-test/bin" ] && ok "ENV_ROOT/bin created" || bad "ENV_ROOT/bin created"
has "$R" "root=$T/home/.rs-test " "RS_ENV_ROOT expanded"
R=$(envq "$H" "$H/.fx-home" "$Q" -u TMPDIR TARGET=fx-home HOME="$T/home")
has "$R" "tmp=/tmp/$U/run-skills-fx " "TMPDIR unset -> /tmp/<user>/run-skills-fx"
has "$R" "ray=/tmp/$U/run-skills-fx/ray " "node-local TMPDIR -> RAY_TMPDIR=\$TMPDIR/ray"
has "$R" "triton=/tmp/$U/run-skills-fx/triton-fx " "compile caches follow the fallback TMPDIR"
[ -d "/tmp/$U/run-skills-fx/ray" ] && ok "fallback TMPDIR + ray dir created" || bad "fallback TMPDIR + ray dir created"
R=$(envq "$H" "$H/.fx-home" "$Q" TARGET=fx-home HOME="$T/home" TMPDIR="$T/ro")
has "$R" "tmp=/tmp/$U/run-skills-fx " "preset but unwritable TMPDIR -> fallback"
R=$(envq "$H" "$H/.fx-home" "$Q" TARGET=fx-home HOME="$T/home" TMPDIR="$T/nonexistent-tmp")
has "$R" "tmp=/tmp/$U/run-skills-fx " "preset but missing TMPDIR -> fallback"
chmod 755 "$T/ro"; rm -rf "/tmp/$U" "/tmp/ray_$U-fx" "/tmp/ray_$U"

echo "-- ws-box: nohup --"
W=$(mk_proj ws-box 'WS_REMOTE_DIR=projects/x
ENV_KIND=uv') || { bad "mk_proj ws-box"; exit 1; }
R=$(envq "$W" "$W/.ws" "$Q")
has "$R" "ready=$W " "nohup: READY without TARGET (T_NAME from .ws/profile.sh)"; has "$R" "ws=$W " "WS_ENV_READY set"
has "$R" 'hpc=unset' "no HPC_ENV_READY on nohup"; has "$R" 'wstag=wsbox ' "WS_TAG=wsbox"; has "$R" 'cl=unset' "no CLUSTER on nohup"
has "$R" "venv=$W/.venv " "unsuffixed in-project venv"; has "$R" "path0=$W/.venv/bin " "venv first on PATH"
has "$R" 'kind=nohup tgt=ws-box ' "RS_KIND=nohup"
R=$(envq "$W" "$W/.ws" "$Q" TARGET=ws-box CLUSTER=stale)
has "$R" "ready=$W .*cl=unset wstag=wsbox " "explicit TARGET works; stale CLUSTER cleared"
printf 'WS_REMOTE_DIR=projects/x\n' > "$W/.ws.conf"
R=$(envq "$W" "$W/.ws" "$Q")
has "$R" "ready=$W .*venv=$W/.venv " "no ENV_KIND -> uv default"
# conda via the fixture's T_CONDA_INIT (fake conda.sh under HOME)
mkdir -p "$T/home/miniconda3/etc/profile.d"
printf 'conda() { case "$1" in activate) export CONDA_DEFAULT_ENV=$2 ;; *) return 1 ;; esac; }\n' > "$T/home/miniconda3/etc/profile.d/conda.sh"
printf 'WS_REMOTE_DIR=projects/x\nENV_KIND=conda\nENV_NAME=gen\nWSBOX_ENV_NAME=tagged\n' > "$W/.ws.conf"
R=$(envq "$W" "$W/.ws" "$Q" HOME="$T/home")
has "$R" "ready=$W .*conda=tagged envname=tagged" "conda: <TAG>_ENV_NAME activated, ENV_NAME exported"
has "$R" "path0=$W/bin " "conda: ENV_ROOT/bin leads PATH"
printf 'WS_REMOTE_DIR=projects/x\nENV_KIND=conda\n' > "$W/.ws.conf"
R=$(envq "$W" "$W/.ws" "$Q" HOME="$T/home")
has "$R" 'ready=unset' "conda without ENV_NAME -> no READY"; has "$R" 'ENV_NAME required' "conda without ENV_NAME says so"
R=$(envq "$W" "$W/.ws" "$Q" HOME="$T/nohome")
has "$R" 'ready=unset' "conda init failure -> no READY"

echo "-- fail-closed --"
F=$(mk_proj fx-slurm 'REMOTE_DIR=/x
ENV_KIND=uv') || { bad "mk_proj"; exit 1; }
refuse() {   # refuse LABEL MSG-REGEX [env...] : source must withhold READY and say why
  local l=$1 m=$2; shift 2; local r; r=$(envq "$F" "$F/.fx-slurm" 'echo ready=${RUN_ENV_READY:-unset}' "$@")
  has "$r" 'ready=unset' "$l -> no READY"; has "$r" "env.sh: .*$m.*refusing to continue" "$l message"
}
refuse "slurm project without TARGET/CLUSTER" 'MISSING .*/\.ws/profile\.sh (partial sync?)' -u TARGET -u CLUSTER
refuse "TARGET typo (no such deploy dir)" 'MISSING .*/\.ws/profile\.sh (no .*/\.g22/ either) (partial sync?)' TARGET=g22
mkdir -p "$F/.ws"; grep -v '^T_NAME=' "$F/.fx-slurm/profile.sh" > "$F/.ws/profile.sh"
refuse "no target and no T_NAME in .ws/profile.sh" 'no target: export TARGET=<name>' -u TARGET -u CLUSTER
mkdir -p "$F/.other"; cp "$F/.fx-slurm/"* "$F/.other/"
refuse "profile for another target" "is for target 'fx-slurm', not 'other'" TARGET=other
printf 'REMOTE_DIR=/x\nENV_KIND=bogus\n' > "$F/.hpc.conf"; refuse "invalid ENV_KIND" "invalid ENV_KIND='bogus'" TARGET=fx-slurm
printf 'REMOTE_DIR=/x\nENV_HOOK=nope.sh\n' > "$F/.hpc.conf"; refuse "missing ENV_HOOK" "ENV_HOOK 'nope.sh' not found" TARGET=fx-slurm
printf 'REMOTE_DIR=/x\nENV_HOOK=hook.sh\n' > "$F/.hpc.conf"; printf 'false\n' > "$F/hook.sh"
refuse "failing ENV_HOOK" "FAILED sourcing ENV_HOOK" TARGET=fx-slurm
printf 'export HOOK_MARK=yes HF_HOME=/custom/hf\n' > "$F/hook.sh"
R=$(envq "$F" "$F/.fx-slurm" 'echo mark=${HOOK_MARK:-} hf=$HF_HOME ready=${RUN_ENV_READY:-unset}' TARGET=fx-slurm)
has "$R" "mark=yes hf=/custom/hf ready=$F" "ENV_HOOK sourced last and may override HF_HOME"
printf 'REMOTE_DIR=/x\nfalse\n' > "$F/.hpc.conf"; refuse "conf whose sourcing fails" 'FAILED sourcing .*\.hpc\.conf' TARGET=fx-slurm
rm "$F/.hpc.conf"; refuse "missing conf" 'MISSING .*\.hpc\.conf (partial sync?)' TARGET=fx-slurm
printf 'REMOTE_DIR=/x\n' > "$F/.hpc.conf"
printf 'T_KIND=other\nT_NAME=fx-slurm\n' > "$F/.fx-slurm/profile.sh"; refuse "bad T_KIND in profile" "T_KIND='other'" TARGET=fx-slurm
rm "$F/.fx-slurm/profile.sh"; refuse "missing profile" 'MISSING .*profile.sh (partial sync?)' TARGET=fx-slurm
rm -rf "/tmp/ray_$U-fx" "/tmp/ray_$U"
