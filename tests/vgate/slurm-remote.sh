#!/usr/bin/env bash
# tests/vgate/slurm-remote.sh — reproductions behind the v3 submit protocol, run ON a Slurm login node, only with the
# user's OK:  ssh <alias> bash -s -- <scratch-dir> <partition> [VENV=<venv>] [sbatch args...] < tests/vgate/slurm-remote.sh
# Submits 8 tiny CPU jobs (1 cpu, 1G, <= 5 min): five held and cancelled unrun (duplicate options, SBATCH_* vs CLI,
# Comment storage; a time limit of 0 — or sbatch's refusal of it; a value word `-t1` after --comment; a bare word, which
# sbatch runs as the batch script); two of one name with --dependency=singleton (submit.sh --rs-chain), held, the second released: it
# stays PENDING (Dependency) while the first is pending, both cancelled (the second as soon as the first is gone, before
# it can run more than `true`); one --requeue job that this script requeues once (env and stored script after a
# requeue; a login-node dir seen from the compute node; torch arch flags without a GPU when VENV= is given), then
# cancelled. Also the identity reads rsk cancel and run-watch's fail-stop / --adopt rely on (squeue -O / sacct -o of
# its own jobs).
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
# 1a. a time limit of 0 is NO limit (sbatch(1) --time; slurm_opt.c arg_set_time_limit: 0 -> INFINITE): submit.sh refuses
#     it; what this cluster does with one (held: never runs)
j4=$(sb --hold --time=0 -J rs-vgate-t0 --wrap true 2> t0.err) || j4=""
if [ -n "$j4" ]; then J="$J $j4"; echo "time0=$(tl "$j4") reason=$(squeue -h -j "$j4" -O Reason:0 2>&1) (want TimeLimit=UNLIMITED or a partition-limit pend: 0 = none)"; scancel "$j4"
else echo "time0=rejected err=$(head -c 200 t0.err | tr '\n' ' ') (sbatch itself refused a limit of none here)"; fi
# 1b'. getopt: a required-argument option takes the NEXT word as its value even when it starts with '-' (--comment -t1)
j5=$(sb --hold --time=00:02:00 --comment -t1 -J rs-vgate-cv --wrap true); got "$j5" commentval
echo "comment_value=$(tl "$j5") comment=$(squeue -h -j "$j5" -O Comment:0 2>&1) (want TimeLimit=00:02:00 comment=-t1: -t1 is the comment, never a --time)"
# 1b''. sbatch's getopt string starts with '+' (slurm_opt.c): the first word that is no option and no option's value
#      (--requeue takes none as a separate word) is the batch script, every option after it that script's argument
printf '#!/bin/sh\ntrue\n' > bare.sh
j6=$(sb --hold --time=00:01:00 --requeue bare.sh -J rs-vgate-bare --comment=rs=vgate-bare); got "$j6" bare
echo "bare_word=$(squeue -h -j "$j6" -O 'Name:0|,Comment:0|' 2>&1) (want bare.sh|<no rs=vgate-bare>|: -J and --comment after the bare word went to bare.sh)"
scancel "$j" "$j2" "$j5" "$j6"; sleep 8
echo "comment_sacct=$(sacct -X -n -P -j "$j" -o Comment 2>&1 | head -n 1)"
# identity of an ended job (run-watch --adopt, rsk cancel's "gone"): JobID|JobName|User|WorkDir, -P (no trailing '|')
echo "id_sacct=$(sacct -X -n -j "$j" -o JobID,JobName,User,WorkDir -P 2>&1 | head -n 1) (want $j|rs-vgate-dup|$U|$D)"

# 1b. --rs-chain = --dependency=singleton: a second job of the same name and user waits while the first has not ended
s1=$(sb --hold -t 00:01:00 -J rs-vgate-single --dependency=singleton --wrap true); got "$s1" single1
s2=$(sb --hold -t 00:01:00 -J rs-vgate-single --dependency=singleton --wrap true); got "$s2" single2
scontrol release "$s2"; sleep 5   # the second is no longer held: only the first (held, same name) can keep it pending
echo "singleton_second=$(squeue -h -j "$s2" -O 'State:0|,Reason:0|' 2>&1) (want PENDING|Dependency| while $s1 is held)"
scancel "$s1"; sleep 5
echo "singleton_second_after=$(squeue -h -j "$s2" -O 'State:0|,Reason:0|' 2>&1) (want no Dependency: the first is gone)"
scancel "$s2"

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
# identity of a live job, read-only, this user's own: every -O field ends with '|' (Name may hold one: parsed from the right)
echo "id_squeue=$(squeue -h -u "$U" -O 'JobID:0|,UserName:0|,Name:0|,WorkDir:0|' 2>&1 | grep -a "^$j3|" | head -n 1) (want $j3|$U|rs-vgate-rq|$D|)"
echo "id_squeue_state=$(squeue -h -u "$U" --states=all -O 'JobID:0|,Name:0|,UserName:0|,WorkDir:0|,State:0|' 2>&1 | grep -a "^$j3|" | head -n 1) (want $j3|rs-vgate-rq|$U|$D|<state>|)"
echo "id_squeue_j=$(squeue -h -j "$j3" -O 'JobID:0|,UserName:0|' 2>&1 | head -n 1) (want $j3|$U|; rsk cancel: another user's job by id)"
sed -i 's/script=v1/script=v2/' job.sh   # a requeue must still run the copy stored at submit
for _ in $(seq 60); do [ -s requeue.out ] && break; sleep 5; done
if [ ! -s requeue.out ]; then echo "requeue=not-started-in-5min $(squeue -h -j "$j3" -O State:0,Reason:0)"; exit 0; fi
sleep 10; scontrol requeue "$j3" 2> rq.err; echo "requeue_rc=$? err=$(head -c 200 rq.err | tr '\n' ' ')"
for _ in $(seq 60); do grep -q 'restart=1' requeue.out && break; sleep 5; done
echo "after_requeue=$(squeue -h -j "$j3" -O State:0,Reason:0,RestartCnt:0 2>&1)"
sed 's/^/requeue_out: /' requeue.out; echo "compute_made=$(ls -d compute-made-* 2>/dev/null | tr '\n' ' ')"
