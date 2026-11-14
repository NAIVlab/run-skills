#!/usr/bin/env bash
# tests/vgate/multinode.sh — reproductions behind multi-node jobs (submit.sh --nodes K, job.sbatch's srun), run ON a Slurm
# login node, only with the user's OK:  ssh <alias> 'bash -s <scratch-dir> <partition> [GRES=gpu:N] [sbatch args...]' < tests/vgate/multinode.sh
# Submits ONE tiny 2-node job (--nodes=2 --ntasks-per-node=1 -c 2 --mem=1G, <= 5 min; GRES= adds --gres to the job and to
# each step, for a GPU partition) whose batch script runs three steps the way job.sbatch does:
#   a) `srun --nodes=2 --ntasks-per-node=1 --export=ALL [--gres=G] bash -c 'NODE_RANK=$SLURM_NODEID; export NODE_RANK;
#      exec "$@"' rs-node CMD ARGS` — one task per node, SLURM_NODEID 0..1, the batch env carried, the GPUs and cpus a
#      task sees (also with --cpus-per-task=$SLURM_CPUS_PER_TASK, as job.sbatch passes it), its memory, the argument words intact;
#      and `scontrol show hostnames "$SLURM_JOB_NODELIST"` (MASTER_ADDR = line 1);
#   b) the same srun in the background: USR1 sent to srun (does srun relay it to every task?), then TERM sent the way job.sbatch's
#      multi-node path forwards it, `scancel --signal=TERM $SLURM_JOB_ID` (does every task get it, srun left running?);
#   b2) TERM sent to srun itself: srun_job.c answers it with SIGKILL to the tasks — does no task's TERM handler run?
#   c) `--kill-on-bad-exit=1`: the task on node 1 exits 3, the one on node 0 sleeps 90 s — does the step end early, non-zero?
#   d) last: the batch shell traps TERM as job.sbatch does (scancel --signal=TERM), the tasks trap TERM and take 10 s to "save";
#      this script then cancels the whole job (`scancel <job>`, as a user's cancel): do the tasks finish the save within KillWait,
#      or does srun — signalled with the batch step on a job's end — KILL them first?
# Prints key=value lines (each with its `want`). Writes only under <scratch-dir>; cancels only the job it submitted. NOT part
# of selftest.
set -u
D=$1; P=$2; shift 2; GRES=""
case "${1:-}" in GRES=*) GRES=${1#GRES=}; shift ;; esac
X=("$@"); J=""
trap '[ -z "$J" ] || scancel "$J" 2>/dev/null' EXIT
mkdir -p "$D" && cd "$D" || { echo "vgate=fail cd $D"; exit 1; }
D=$(pwd -P)
echo "host=$(hostname) slurm=$(sbatch --version 2>&1) dir=$D gres=${GRES:-none} $(scontrol show config 2>/dev/null | grep -i '^KillWait' | tr -d ' ')"
rm -f mn.out mn.slurm
cat > mn.sh <<'EOF'
#!/bin/bash
o=$RS_VG_D/mn.out; G=()
[ -z "${RS_VG_GRES:-}" ] || G=(--gres="$RS_VG_GRES")
S=(srun --nodes=2 --ntasks-per-node=1 --export=ALL ${G[@]+"${G[@]}"})
echo "batch nnodes=${SLURM_NNODES:-unset} nodelist=${SLURM_JOB_NODELIST:-unset} cpt=${SLURM_CPUS_PER_TASK:-unset} host=$(hostname -s)" >> "$o"
h=$(scontrol show hostnames "$SLURM_JOB_NODELIST" 2>&1); r=$?
echo "hostnames rc=$r first=$(printf '%s\n' "$h" | head -n 1) all=$(printf '%s' "$h" | tr '\n' ',')" >> "$o"
export RS_VG_BATCH=carried
"${S[@]}" bash -c 'NODE_RANK=$SLURM_NODEID; export NODE_RANK; exec "$@"' rs-node \
  bash -c 'echo "task nodeid=$SLURM_NODEID rank=$NODE_RANK host=$(hostname -s) var=${RS_VG_BATCH:-unset} cvd=${CUDA_VISIBLE_DEVICES:-unset} nproc=$(nproc) smem=${SLURM_MEM_PER_NODE:-unset} cgmem=$(c=$(sed -n "s/^0:://p" /proc/self/cgroup 2>/dev/null); cat "/sys/fs/cgroup$c/memory.max" 2>/dev/null || echo unreadable) args=$0$(printf "[%s]" "$@")"' \
  a0 'two words' x >> "$o" 2>&1
echo "step_a rc=$?" >> "$o"
"${S[@]}" --cpus-per-task="${SLURM_CPUS_PER_TASK:-1}" bash -c 'echo "taskc nodeid=$SLURM_NODEID nproc=$(nproc)"' >> "$o" 2>&1   # job.sbatch's explicit form
"${S[@]}" bash -c 'trap "echo sig=USR1 nodeid=\$SLURM_NODEID" USR1; trap "echo sig=TERM nodeid=\$SLURM_NODEID; exit 0" TERM
  echo "ready nodeid=$SLURM_NODEID"; for _ in $(seq 120); do sleep 1; done; echo "nosignal nodeid=$SLURM_NODEID"' >> "$o" 2>&1 &
c=$!; sleep 20; kill -USR1 "$c"; sleep 5; scancel --signal=TERM "$SLURM_JOB_ID"; echo "scancel_sig rc=$?" >> "$o"; wait "$c"; echo "step_b rc=$?" >> "$o"
"${S[@]}" bash -c 'trap "echo sig2=TERM nodeid=\$SLURM_NODEID; exit 0" TERM
  echo "ready2 nodeid=$SLURM_NODEID"; for _ in $(seq 60); do sleep 1; done; echo "nosignal2 nodeid=$SLURM_NODEID"' >> "$o" 2>&1 &
c=$!; sleep 15; kill -TERM "$c"; wait "$c"; echo "step_b2 rc=$?" >> "$o"
t0=$(date +%s)
"${S[@]}" --kill-on-bad-exit=1 bash -c '[ "$SLURM_NODEID" = 1 ] && exit 3; sleep 90; echo "survived nodeid=$SLURM_NODEID"' >> "$o" 2>&1
echo "step_c rc=$? secs=$(( $(date +%s) - t0 ))" >> "$o"
echo "d_start" >> "$o"
trap 'scancel --signal=TERM "$SLURM_JOB_ID"; echo "batch_term" >> "$o"' TERM
"${S[@]}" bash -c 'f=$RS_VG_D/mn.out; trap "echo dterm nodeid=\$SLURM_NODEID >> \$f; sleep 10; echo dsaved nodeid=\$SLURM_NODEID >> \$f; exit 0" TERM
  echo "dready nodeid=$SLURM_NODEID" >> "$f"; for _ in $(seq 240); do sleep 1; done' &
c=$!; while :; do wait "$c"; r=$?; [ "$r" -gt 128 ] && kill -0 "$c" 2>/dev/null && continue; break; done; echo "step_d rc=$r" >> "$o"
EOF
G=(); [ -z "$GRES" ] || G=(--gres="$GRES")
j=$(sbatch --parsable -p "$P" ${X[@]+"${X[@]}"} --nodes=2 --ntasks-per-node=1 -c 2 --mem=1G -t 00:05:00 ${G[@]+"${G[@]}"} \
      -J rs-vgate-mn -o "$D/mn.slurm" --chdir "$D" --export=ALL,RS_VG_D="$D",RS_VG_GRES="$GRES" mn.sh)
[ -n "$j" ] || { echo "vgate=fail sbatch: no job id"; exit 1; }; J=$j
for _ in $(seq 60); do [ "$(grep -c '^dready' mn.out 2>/dev/null)" -ge 2 ] && break; [ -z "$(squeue -h -j "$j" -O JobID:0 2>/dev/null)" ] && break; sleep 10; done
if [ ! -s mn.out ]; then echo "multinode=not-started-in-10min $(squeue -h -j "$j" -O State:0,Reason:0 2>&1)"; exit 0; fi
if [ "$(grep -c '^dready' mn.out)" -ge 2 ]; then sleep 3; scancel "$j"; echo "job_cancel sent at $(date +%s)"   # step d: the whole job, as a user would
  for _ in $(seq 24); do [ -z "$(squeue -h -j "$j" -O JobID:0 2>/dev/null)" ] && break; sleep 5; done; sleep 5; fi
J=""   # ended (or never reached step d: let it finish on its own)
o=$(cat mn.out); q() { printf '%s\n' "$o" | grep -a "$1"; }
first=$(q '^hostnames ' | sed -n 's/.* first=\([^ ]*\).*/\1/p'); hosts=$(q '^task ' | sed -n 's/.* host=\([^ ]*\).*/\1/p' | sort -u | tr '\n' ' ')
echo "batch_env=$(q '^batch ' | head -n 1) (want nnodes=2, cpt=2)"
echo "one_task_per_node=$(q '^task ' | wc -l) tasks on $(printf '%s' "$hosts" | wc -w) hosts: $hosts(want 2 tasks on 2 hosts)"
echo "nodeid=$(q '^task ' | sed -n 's/^task nodeid=\([^ ]*\) rank=\([^ ]*\).*/\1:\2/p' | sort | tr '\n' ' ')(want 0:0 1:1 — NODE_RANK = SLURM_NODEID)"
echo "hostnames_first=$(q '^hostnames ' | head -n 1) (want rc=0, first=$first one of: $hosts)"
echo "export_all=$(q '^task ' | sed -n 's/.* var=\([^ ]*\).*/\1/p' | tr '\n' ' ')(want carried carried)"
echo "args_kept=$(q '^task ' | sed -n 's/.* args=//p' | sort -u | tr '\n' ' ')(want a0[two words][x])"
echo "step_gres=$(q '^task ' | sed -n 's/.* cvd=\([^ ]*\).*/\1/p' | tr '\n' ' ')(GRES=${GRES:-none}: want N devices per task with gpu:N, unset or every GPU without)"
echo "step_cpus=$(q '^task ' | sed -n 's/.* nproc=\([^ ]*\).*/\1/p' | tr '\n' ' ')(the job asked -c 2: 2 = srun inherits --cpus-per-task; 1 = job.sbatch's srun must pass -c \$SLURM_CPUS_PER_TASK)"
echo "step_cpus_explicit=$(q '^taskc ' | sed -n 's/.* nproc=\([^ ]*\).*/\1/p' | tr '\n' ' ')(srun --cpus-per-task=\$SLURM_CPUS_PER_TASK, as job.sbatch passes it: want 2 2)"
echo "step_mem=$(q '^task ' | sed -n 's/.* smem=\([^ ]*\) cgmem=\([^ ]*\).*/\1:\2/p' | tr '\n' ' ')(SLURM_MEM_PER_NODE:cgroup v2 memory.max per task; the job asked --mem=1G: want 1024:1073741824 — a step without --mem gets the job's per-node memory)"
echo "signal_usr1=$(q '^sig=USR1' | tr '\n' ' ')(want sig=USR1 on nodeid=0 and 1: srun relays USR1)"
echo "signal_term=$(q '^sig=TERM' | tr '\n' ' ')$(q '^scancel_sig ') $(q '^step_b ') (scancel --signal=TERM <job>, job.sbatch's forward: want sig=TERM on nodeid=0 and 1, scancel_sig rc=0, step_b rc=0, no nosignal)"
echo "srun_term_kills=$(q '^sig2=TERM' | tr '\n' ' ')$(q '^step_b2 ') (TERM to srun itself: want no sig2=TERM line and step_b2 rc!=0 — srun KILLs the tasks, so job.sbatch never sends it TERM)"
echo "job_cancel_grace=$(q '^dterm\|^dsaved\|^batch_term\|^step_d' | tr '\n' ' ')(a whole-job scancel: dsaved on nodeid=0 and 1 = the tasks get KillWait to save; dterm without dsaved = srun, signalled with the batch step, KILLed them first)"
echo "kill_on_bad_exit=$(q '^step_c ') survived=$(q '^survived' | wc -l) (want rc!=0, secs well under 90, survived=0)"
q '^nosignal' | sed 's/^/unexpected: /'
printf '%s\n' "$o" | sed 's/^/mn_out: /'
