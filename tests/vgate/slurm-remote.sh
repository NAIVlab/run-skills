#!/usr/bin/env bash
# tests/vgate/slurm-remote.sh — reproductions behind the v3 submit protocol, run ON a Slurm login node, only with the
# user's OK:  ssh <alias> bash -s -- <scratch-dir> <partition> [VENV=<venv>] [sbatch args...] < tests/vgate/slurm-remote.sh
# Submits 3 tiny CPU jobs (1 cpu, 1G, <= 5 min): two held and cancelled unrun (duplicate options, SBATCH_* vs CLI,
# Comment storage), one --requeue job that this script requeues once (env and stored script after a requeue; a
# login-node dir seen from the compute node; torch arch flags without a GPU when VENV= is given), then cancelled.
# Prints key=value lines. Writes only under <scratch-dir>; cancels only the jobs it submitted. NOT part of selftest.
set -u
D=$1; P=$2; shift 2; VENV=""
case "${1:-}" in VENV=*) VENV=${1#VENV=}; shift ;; esac
X=("$@"); U=${USER:-$(id -un)}; J=""
trap 'for j in $J; do scancel "$j" 2>/dev/null; done' EXIT
mkdir -p "$D" && cd "$D" || { echo "vgate=fail cd $D"; exit 1; }
D=$(pwd -P)   # absolute from here on: sbatch(1) takes a relative --chdir from the dir it runs in, i.e. inside $D
echo "host=$(hostname) slurm=$(sbatch --version 2>&1) dir=$D"
sb() { sbatch --parsable -p "$P" ${X[@]+"${X[@]}"} -c 1 --mem=1G -o /dev/null "$@"; }   # bash < 4.4: an empty array is unbound under set -u (bash CHANGES, 4.4-rc2 a.)
got() { [ -n "$1" ] || { echo "vgate=fail sbatch ($2): no job id"; exit 1; }; J="$J $1"; }   # got JOBID LABEL: keep it for the trap, or stop
tl() { scontrol show job "$1" 2>&1 | grep -o 'TimeLimit=[^ ]*'; }

# 1. a repeated option: which one wins? an SBATCH_* input variable vs the command line?
j=$(sb --hold --time=00:02:00 --time=00:03:00 -J rs-vgate-dup --comment=rs=vgate-c1 --wrap true); got "$j" dup
echo "dup_time=$(tl "$j") (given 00:02:00 then 00:03:00)"
echo "comment_squeue=$(squeue -h -j "$j" -O Comment:0 2>&1)"
j2=$(SBATCH_TIMELIMIT=00:04:00 sb --hold --time=00:02:00 -J rs-vgate-env --wrap true); got "$j2" env
echo "env_vs_cli_time=$(tl "$j2") (SBATCH_TIMELIMIT=00:04:00, --time=00:02:00)"
scancel "$j" "$j2"; sleep 8
echo "comment_sacct=$(sacct -X -n -P -j "$j" -o Comment 2>&1 | head -n 1)"

# 2. how far back sacct may look (MaxQueryTimeRange)
sacct -X -n -P -u "$U" -S now-30days -o JobID > /dev/null 2> sacct.err; echo "sacct_30d_rc=$? err=$(head -c 200 sacct.err | tr '\n' ' ')"

# 3. a requeued job: same env? same (stored) script? sees a dir made on the login node?
mkdir -p login-made; rm -f requeue.out
cat > job.sh <<EOF
#!/bin/bash
echo "start restart=\${SLURM_RESTART_COUNT:-0} var=\${RS_VG:-unset} script=v1 node=\$(hostname) t=\$(date +%s)" >> "$D/requeue.out"
[ -d "$D/login-made" ] && echo "sees_login_dir=yes" >> "$D/requeue.out" || echo "sees_login_dir=no" >> "$D/requeue.out"
mkdir -p "$D/compute-made-\${SLURM_RESTART_COUNT:-0}"
[ -z "$VENV" ] || "$VENV/bin/python" -c "import torch; print('torch', torch.__version__, torch.version.cuda, torch.cuda.is_available(), torch._C._cuda_getArchFlags())" >> "$D/requeue.out" 2>&1
sleep 120
EOF
j3=$(RS_VG=one sb --requeue -t 00:05:00 -J rs-vgate-rq --chdir "$D" job.sh); got "$j3" requeue
sed -i 's/script=v1/script=v2/' job.sh   # a requeue must still run the copy stored at submit
for _ in $(seq 60); do [ -s requeue.out ] && break; sleep 5; done
if [ ! -s requeue.out ]; then echo "requeue=not-started-in-5min $(squeue -h -j "$j3" -O State:0,Reason:0)"; exit 0; fi
sleep 10; scontrol requeue "$j3" 2> rq.err; echo "requeue_rc=$? err=$(head -c 200 rq.err | tr '\n' ' ')"
for _ in $(seq 60); do grep -q 'restart=1' requeue.out && break; sleep 5; done
echo "after_requeue=$(squeue -h -j "$j3" -O State:0,Reason:0,RestartCnt:0 2>&1)"
sed 's/^/requeue_out: /' requeue.out; echo "compute_made=$(ls -d compute-made-* 2>/dev/null | tr '\n' ' ')"
