#!/usr/bin/env bash
# tests/55-job.sh — phase A: remote/job.sbatch run directly (bash, SLURM_JOB_ID faked) on the fx-slurm fixture:
# the uv gate blocks a missing venv and runs once it exists, TARGET is accepted as an alias of CLUSTER,
# inherited sentinels cannot certify a broken env.sh, conda gate. Run by selftest.sh:  bash tests/55-job.sh
set -u
. "$RS_HOME/tests/lib.sh"
U=rstest$$
# job PROJ [env...] : run the deployed job.sbatch with payload `echo hi`, stderr merged
job() { local p=$1; shift; ( cd "$p" && env "$@" USER="$U" PATH="$T/bin:$PATH" SLURM_JOB_ID=t1 bash "$p/.fx-slurm/job.sbatch" echo hi 2>&1 ); }

J=$(mk_proj fx-slurm 'REMOTE_DIR=/x
ENV_KIND=uv') || { bad "mk_proj fx-slurm"; exit 1; }
O=$(job "$J" PROJ="$J" CLUSTER=fx-slurm) && bad "uv gate: missing venv blocked" || has "$O" 'uv venv missing' "uv gate: missing venv blocked"
hasnt "$O" '^hi$' "payload not run without the venv"
mkdir -p "$J/.venv-fx/bin"; printf '#!/bin/sh\n' > "$J/.venv-fx/bin/python"; chmod +x "$J/.venv-fx/bin/python"
O=$(job "$J" PROJ="$J" CLUSTER=fx-slurm) && has "$O" '^hi$' "uv gate: venv present -> runs" || { bad "uv gate: venv present -> runs"; echo "$O" | sed 's/^/    | /'; }
has "$O" 'RUN: echo hi' "announces the run command"; has "$O" 'EXIT rc=0' "EXIT footer closes the log"
O=$(cd "$J" && PROJ="$J" CLUSTER=fx-slurm SLURM_JOB_ID=t1 USER="$U" PATH="$T/bin:$PATH" bash .fx-slurm/job.sbatch sh -c 'exit 3' 2>&1); RC=$?
[ "$RC" = 3 ] && has "$O" 'EXIT rc=3 usr1=0' "payload exit code propagates + EXIT footer" || bad "payload exit code propagates (rc=$RC)"
# USR1 (preempt/timeout) forwarded to a trainer that saves and exits 0 — it would exit 9 on its own, so a pass proves the
# forwarding; the footer carries the trainer's rc, not 138. A second USR1 while draining must not change that.
usr1_job() {   # usr1_job N : N signals, 0.3 s apart; prints the wrapper's exit status, log in $T/usr1.out
  ( cd "$J" && exec env PROJ="$J" CLUSTER=fx-slurm SLURM_JOB_ID=t1 USER="$U" PATH="$T/bin:$PATH" bash .fx-slurm/job.sbatch \
      sh -c 'trap "sleep 1; exit 0" USR1; echo READY; sleep 30 & wait; exit 9' ) > "$T/usr1.out" 2>&1 &
  local jp=$! i; for i in $(seq 1 100); do grep -q "^READY" "$T/usr1.out" 2>/dev/null && break; sleep 0.1; done   # trainer's trap is installed
  for i in $(seq 1 "$1"); do kill -USR1 "$jp" 2>/dev/null || true; sleep 0.3; done; wait "$jp"; echo $?
}
RC=$(usr1_job 1); [ "$RC" = 0 ] && has "$(cat "$T/usr1.out")" 'EXIT rc=0 usr1=1' "USR1 forwarded: trainer's own rc 0 + usr1=1" || { bad "USR1 forwarded (rc=$RC)"; sed 's/^/    | /' "$T/usr1.out"; }
RC=$(usr1_job 2); [ "$RC" = 0 ] && has "$(cat "$T/usr1.out")" 'EXIT rc=0 usr1=1' "a second USR1 while draining is ignored (still rc 0)" || { bad "second USR1 ignored (rc=$RC)"; sed 's/^/    | /' "$T/usr1.out"; }
# a trainer that catches USR1 and just keeps going, two signals back-to-back: bash may return a spurious 138 from the
# next `wait` — the wrapper must still wait for the real status instead of exiting while the trainer runs
( cd "$J" && exec env PROJ="$J" CLUSTER=fx-slurm SLURM_JOB_ID=t1 USER="$U" PATH="$T/bin:$PATH" bash .fx-slurm/job.sbatch \
    sh -c 'trap "" USR1; echo READY; sleep 0.3; echo DONE; exit 0' ) > "$T/usr1b.out" 2>&1 &
JP=$!; for _i in $(seq 1 100); do grep -q "^READY" "$T/usr1b.out" 2>/dev/null && break; sleep 0.05; done
kill -USR1 "$JP" 2>/dev/null; kill -USR1 "$JP" 2>/dev/null; wait "$JP"; RC=$?
[ "$RC" = 0 ] && has "$(cat "$T/usr1b.out")" 'EXIT rc=0 usr1=1' "catch-and-continue trainer + 2 rapid USR1: wrapper waits for the real rc 0" || { bad "spurious 138 (rc=$RC)"; sed 's/^/    | /' "$T/usr1b.out"; }
[ "$(grep -n '^DONE' "$T/usr1b.out" | cut -d: -f1)" -lt "$(grep -n 'EXIT rc=' "$T/usr1b.out" | cut -d: -f1)" ] && ok "wrapper footer comes after the trainer's last line" || bad "wrapper exited before the trainer finished"
# a trainer with NO USR1 handler is killed by the forwarded signal: the footer reports the real 138 (bash keeps returning
# a collected child's saved status, so the kill -0 branch must take it — no spin, no fake 0)
( cd "$J" && exec env PROJ="$J" CLUSTER=fx-slurm SLURM_JOB_ID=t1 USER="$U" PATH="$T/bin:$PATH" bash .fx-slurm/job.sbatch \
    sh -c 'echo READY; sleep 5 & wait' ) > "$T/usr1c.out" 2>&1 &
JP=$!; for _i in $(seq 1 100); do grep -q "^READY" "$T/usr1c.out" 2>/dev/null && break; sleep 0.05; done
kill -USR1 "$JP"; wait "$JP"; RC=$?
[ "$RC" = 138 ] && has "$(cat "$T/usr1c.out")" 'EXIT rc=138 usr1=1' "no-handler trainer: forwarded USR1 kills it, footer says rc=138 usr1=1" || { bad "no-handler trainer (rc=$RC)"; sed 's/^/    | /' "$T/usr1c.out"; }
# SIGTERM (cancel / preempt / final kill) delivered to the WRAPPER ONLY (proctrack/cgroup sites do not signal children):
# the wrapper forwards it once, keeps waiting, and the footer carries the trainer's own rc (0 after its handler saved)
( cd "$J" && exec env PROJ="$J" CLUSTER=fx-slurm SLURM_JOB_ID=t1 USER="$U" PATH="$T/bin:$PATH" bash .fx-slurm/job.sbatch \
    sh -c 'trap "echo SAVED; exit 0" TERM; echo READY; sleep 30 & wait; exit 9' ) > "$T/term.out" 2>&1 &
JP=$!; for _i in $(seq 1 100); do grep -q "^READY" "$T/term.out" 2>/dev/null && break; sleep 0.05; done
kill -TERM "$JP"; wait "$JP"; RC=$?
[ "$RC" = 0 ] && has "$(cat "$T/term.out")" 'EXIT rc=0 usr1=0 term=1' "TERM to the wrapper only: forwarded, trainer's rc 0 kept" || { bad "TERM path (rc=$RC)"; sed 's/^/    | /' "$T/term.out"; }
has "$(cat "$T/term.out")" '^SAVED$' "the trainer's TERM handler ran (forwarded, not assumed)"
# a TERM during startup (here: while nvidia-smi -L runs) must not be followed by launching the trainer
printf '#!/bin/sh\nsleep 1\n' > "$T/bin/nvidia-smi"; chmod +x "$T/bin/nvidia-smi"
( cd "$J" && exec env PROJ="$J" CLUSTER=fx-slurm SLURM_JOB_ID=t1 USER="$U" PATH="$T/bin:$PATH" bash .fx-slurm/job.sbatch sh -c 'echo LAUNCHED' ) > "$T/term0.out" 2>&1 &
JP=$!; for _i in $(seq 1 100); do grep -q "target=" "$T/term0.out" 2>/dev/null && break; sleep 0.05; done; sleep 0.2
kill -TERM "$JP"; wait "$JP"; RC=$?; rm -f "$T/bin/nvidia-smi"
[ "$RC" = 143 ] && has "$(cat "$T/term0.out")" 'EXIT rc=143 usr1=0 term=pending' "TERM before launch: aborts with 143 + footer" || { bad "startup TERM (rc=$RC)"; sed 's/^/    | /' "$T/term0.out"; }
hasnt "$(cat "$T/term0.out")" 'LAUNCHED\|RUN:' "TERM before launch: the trainer is never started"
O=$(cd "$J" && PROJ="$J" CLUSTER=fx-slurm SLURM_JOB_ID=t1 USER="$U" PATH="$T/bin:$PATH" bash .fx-slurm/job.sbatch no-such-cmd-xyz 2>&1); RC=$?
[ "$RC" = 127 ] && has "$O" 'EXIT rc=127 usr1=0' "a trainer that does not exist reports its real 127, not a reaped-guess" || bad "exit 127 preserved (rc=$RC)"
O=$(job "$J" PROJ="$J" TARGET=fx-slurm) && has "$O" '^hi$' "TARGET accepted as alias of CLUSTER" || bad "TARGET accepted as alias of CLUSTER"
O=$(job "$J" PROJ="$J" CLUSTER=fx-slurm RUN_ENV_READY="$J" HPC_ENV_READY="$J" WS_ENV_READY="$J" CONDA_DEFAULT_ENV=stale) \
  && has "$O" '^hi$' "stale sentinels + good env.sh -> runs" || bad "stale sentinels + good env.sh -> runs"
printf 'REMOTE_DIR=/x\nENV_KIND=uv\nENV_HOOK=nope.sh\n' > "$J/.hpc.conf"
O=$(job "$J" PROJ="$J" CLUSTER=fx-slurm RUN_ENV_READY="$J" HPC_ENV_READY="$J") && bad "stale HPC_ENV_READY export neutralised" \
  || { hasnt "$O" '^hi$' "stale HPC_ENV_READY export neutralised (broken env.sh never runs the payload)"; }
has "$O" 'refusing to continue' "env.sh's own message surfaces in the job log"
printf 'REMOTE_DIR=/x\nENV_KIND=uv\n' > "$J/.hpc.conf"
(cd "$J" && PROJ="$J" CLUSTER=fx-slurm SLURM_JOB_ID=t1 USER="$U" bash .fx-slurm/job.sbatch >/dev/null 2>&1) && bad "no run command -> error" || ok "no run command -> error"
(cd "$J" && env -u PROJ CLUSTER=fx-slurm SLURM_JOB_ID=t1 bash .fx-slurm/job.sbatch echo hi >/dev/null 2>&1) && bad "missing PROJ -> error" || ok "missing PROJ -> error"
R=$(bash -c 'set -uo pipefail; PROJ=/p; RUN_ENV_READY=/p; export RUN_ENV_READY; unset RUN_ENV_READY HPC_ENV_READY WS_ENV_READY CONDA_DEFAULT_ENV 2>/dev/null||true; . /nonexistent 2>/dev/null; [ "${RUN_ENV_READY:-}" = "$PROJ" ] && echo GATE_PASS || echo GATE_BLOCKED')
has "$R" 'GATE_BLOCKED' "gate idiom: inherited sentinel neutralised by the unset"
S=$(grep -v '^[[:space:]]*#' "$RS_HOME/remote/job.sbatch")
has "$S" 'unset RUN_ENV_READY HPC_ENV_READY WS_ENV_READY CONDA_DEFAULT_ENV' "job.sbatch unsets all sentinels before env.sh"
has "$S" 'RUN_ENV_READY' "job.sbatch gates on RUN_ENV_READY"

echo "-- conda gate --"
mkdir -p "$T/home/miniconda3/etc/profile.d"
printf 'conda() { case "$1" in activate) export CONDA_DEFAULT_ENV=$2 ;; *) return 1 ;; esac; }\n' > "$T/home/miniconda3/etc/profile.d/conda.sh"
printf 'REMOTE_DIR=/x\nENV_KIND=conda\nENV_NAME=good\n' > "$J/.hpc.conf"
O=$(job "$J" PROJ="$J" CLUSTER=fx-slurm HOME="$T/home") && has "$O" '^hi$' "conda: active env -> runs" || { bad "conda: active env -> runs"; echo "$O" | sed 's/^/    | /'; }
printf 'conda() { case "$1" in activate) export CONDA_DEFAULT_ENV=other ;; *) return 1 ;; esac; }\n' > "$T/home/miniconda3/etc/profile.d/conda.sh"
O=$(job "$J" PROJ="$J" CLUSTER=fx-slurm HOME="$T/home") && bad "conda: wrong env active -> blocked" || has "$O" 'not active' "conda: wrong env active -> blocked"
echo "-- bootstrap payload, ENV_KIND=none, source stamp --"
B=$(mk_proj fx-slurm 'REMOTE_DIR=/x
ENV_KIND=uv') || { bad "mk_proj boot"; exit 1; }
: > "$B/pyproject.toml"
O=$(cd "$B" && PROJ="$B" CLUSTER=fx-slurm SLURM_JOB_ID=t1 USER="$U" PATH="$T/bin:$PATH" bash .fx-slurm/job.sbatch bash "$B/.fx-slurm/bootstrap.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && has "$O" '\[stub\] uv sync' "the deployed bootstrap runs as a job without a venv (it builds it)" || { bad "bootstrap job (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
has "$O" 'bootstrap done (fx-slurm)' "bootstrap job log ends with its done line"
O=$(cd "$B" && PROJ="$B" CLUSTER=fx-slurm SLURM_JOB_ID=t1 USER="$U" PATH="$T/bin:$PATH" bash .fx-slurm/job.sbatch bash "$B/.fx-slurm/bootstrap.sh" extra 2>&1)
has "$O" 'uv venv missing' "any other payload (even bootstrap.sh + args) still needs the venv"
rm -rf "$B/.venv-fx"
O=$(cd "$B" && PROJ="$B" CLUSTER=fx-slurm SLURM_JOB_ID=t1 USER="$U" PATH="$T/bin:$PATH" bash .fx-slurm/job.sbatch bash ./.fx-slurm/bootstrap.sh 2>&1)
has "$O" 'uv venv missing' "a relative spelling is not the bootstrap payload"
printf 'REMOTE_DIR=/x\nENV_KIND=none\n' > "$B/.hpc.conf"
O=$(job "$B" PROJ="$B" CLUSTER=fx-slurm) && has "$O" '^hi$' "ENV_KIND=none: runs without a venv" || { bad "ENV_KIND=none runs"; echo "$O" | sed 's/^/    | /'; }
hasnt "$O" 'source:' "no stamp -> no source line"
printf 'path=/l\nhost=h\nbranch=main\ncommit=abc123\ndirty=2\nsynced=2026-01-01T00:00:00+0000\n' > "$B/.run-source"
O=$(job "$B" PROJ="$B" CLUSTER=fx-slurm); has "$O" 'source: branch=main commit=abc123 dirty=2 synced=2026-01-01T00:00:00+0000 (run-sync stamp)' "header logs the sync stamp"
printf 'REMOTE_DIR=/x\nENV_KIND=pip\n' > "$B/.hpc.conf"
O=$(job "$B" PROJ="$B" CLUSTER=fx-slurm) && bad "invalid ENV_KIND blocked" || hasnt "$O" '^hi$' "invalid ENV_KIND blocked"
rm -rf "/tmp/ray_$U-fx" "/tmp/ray_$U"
