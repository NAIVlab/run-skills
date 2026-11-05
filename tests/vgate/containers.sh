#!/usr/bin/env bash
# tests/vgate/containers.sh — the container facts behind launch.sh's container WARNING (R6-2) and its APPTAINERENV_ /
# SINGULARITYENV_ refusal, read on a box from its INSTALLED docker / podman / apptainer / singularity, only with the user's OK:
#   ssh <alias> 'bash -s <docker-image|-> <apptainer-image|->' < tests/vgate/containers.sh
# Each check starts a throwaway container that runs `printenv CUDA_VISIBLE_DEVICES` with the caller's set to 5 — no --gpus,
# --nv, --runtime or --device: no GPU is asked for; '-' (or no image) skips a kind's container checks. One line per runtime
# (or `<rt>=absent`); NOT in selftest (tests/88-vgate.sh runs it on stubs). `unset` = not set inside the container.
#   docker / podman: <rt>_version= <rt>_gpus_flag=<yes: `run --help` lists --gpus> <rt>_env=<inside> (want unset: the
#     host environment is not passed in, only -e/--env) <rt>_env_e=<with -e CUDA_VISIBLE_DEVICES> (want 5: a bare -e passes
#     the caller's value) [docker_default_runtime=<docker info's DefaultRuntime> (nvidia: an image's own NVIDIA_VISIBLE_DEVICES
#     then hands it GPUs with no flag at all — a residual launch.sh cannot see)]
#   apptainer / singularity: <rt>_version= <rt>_env=<inside> (want 5: the host environment is passed in) <rt>_cleanenv=<with
#     --cleanenv> (want unset) <rt>_containall=<with --containall> (want unset) <rt>_prefix=<APPTAINERENV_ / SINGULARITYENV_
#     CUDA_VISIBLE_DEVICES=7, with --cleanenv> (want 7: the prefix sets it inside — why launch.sh refuses it like an assignment)
set -u
DI=${1:--}; AI=${2:--}
W=$(mktemp -d) || exit 1; trap 'rm -rf "$W"' EXIT
cd "$W" || exit 1
pe() {   # pe CMD…: CMD printenv CUDA_VISIBLE_DEVICES, the caller's = 5 -> the value, unset (printenv's 1), or fail(rc=N)
  local v r; v=$(CUDA_VISIBLE_DEVICES=5 timeout 600 "$@" printenv CUDA_VISIBLE_DEVICES 2>/dev/null </dev/null); r=$?
  case "$r" in 0) echo "$v" ;; 1) echo unset ;; *) echo "fail(rc=$r)" ;; esac; }
for rt in docker podman; do
  command -v "$rt" >/dev/null 2>&1 || { echo "$rt=absent"; continue; }
  o="${rt}_version=$("$rt" --version 2>/dev/null | head -n 1 | tr ' ' '_') ${rt}_gpus_flag=$("$rt" run --help 2>/dev/null | grep -q -e '--gpus' && echo yes || echo no)"
  if [ "$DI" != - ]; then
    o="$o ${rt}_env=$(pe "$rt" run --rm "$DI") (want unset) ${rt}_env_e=$(pe "$rt" run --rm -e CUDA_VISIBLE_DEVICES "$DI") (want 5)"
  else o="$o ${rt}_env=skipped (no image)"; fi
  [ "$rt" != docker ] || o="$o docker_default_runtime=$(docker info --format '{{.DefaultRuntime}}' 2>/dev/null || echo unknown)"
  echo "$o"
done
for rt in apptainer singularity; do
  command -v "$rt" >/dev/null 2>&1 || { echo "$rt=absent"; continue; }
  P=APPTAINERENV_; [ "$rt" = apptainer ] || P=SINGULARITYENV_
  o="${rt}_version=$("$rt" --version 2>/dev/null | head -n 1 | tr ' ' '_')"
  if [ "$AI" != - ]; then
    o="$o ${rt}_env=$(pe "$rt" exec "$AI") (want 5) ${rt}_cleanenv=$(pe "$rt" exec --cleanenv "$AI") (want unset)"
    o="$o ${rt}_containall=$(pe "$rt" exec --containall "$AI") (want unset) ${rt}_prefix=$(pe env "${P}CUDA_VISIBLE_DEVICES=7" "$rt" exec --cleanenv "$AI") (want 7)"
  else o="$o ${rt}_env=skipped (no image)"; fi
  echo "$o"
done
