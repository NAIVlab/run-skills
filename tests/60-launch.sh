#!/usr/bin/env bash
# tests/60-launch.sh — phase A: bin/run-launch on the ws-box fixture with the ssh stub (fixed 4-GPU table, the
# launch command is logged instead of run): GPU pick/exclude, NICE, RUN fallback, per-station JOB_NAME, flag
# validation, the remote launch chain (sentinel unset, RS_VENV / conda gates), slurm target refused.
# Run by selftest.sh with RS_HOME set:  bash tests/60-launch.sh
set -u
. "$RS_HOME/tests/lib.sh"
export TARGET=ws-box
# launch PROJ ARGS... : run-launch from PROJ with the stub PATH, stderr merged; launch.log truncated first
launch() { local p=$1; shift; : > "$T/launch.log"; ( cd "$p" && PATH="$T/bin:$PATH" bash "$RS_HOME/bin/run-launch" "$@" 2>&1 ); }
conf() { printf '%s\n' "$2" > "$1/.ws.conf"; }

W=$(mk_proj ws-box 'ENV_KIND=conda
ENV_NAME=e
WS_REMOTE_DIR=projects/x
GPU_EXCLUDE="0, 1"
DEFAULT_NGPU=2
WSBOX_NICE=7
WSBOX_RUN="tagcmd --flag"
WSBOX_JOB_NAME=jobx') || { bad "mk_proj ws-box"; exit 1; }
O=$(launch "$W" -N t); RC=$?
[ "$RC" = 0 ] && ok "launches (rc 0)" || { bad "launches (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
has "$O" 'GPU(s) \[2,3\]' "spaced exclude + DEFAULT_NGPU=2 -> picks 2,3"; has "$O" 'started PID' "prints the PID line"
has "$O" "verify:.*\.ws/status\.sh' 'logs/t-[0-9-]*\.log'\"" "prints the verify line: status.sh + the PROJECT-relative log, both quoted (never tail -f)"
L=$(cat "$T/launch.log")
has "$L" 'nice -n 7 env' "per-station NICE injected"; has "$L" 'tagcmd --flag' "<TAG>_RUN fallback used"
has "$L" "CUDA_VISIBLE_DEVICES='2,3'" "CUDA_VISIBLE_DEVICES pinned"; has "$L" 'PYTHONUNBUFFERED=1' "unbuffered"
has "$L" "cd 'projects/x'" "chain cds into the \$HOME-relative dir"; has "$L" "TARGET='ws-box'" "chain exports TARGET"
has "$L" 'unset RUN_ENV_READY' "chain unsets the sentinel before env.sh"; has "$L" '\.ws/env\.sh' "chain sources .ws/env.sh"
has "$L" 'RUN_ENV_READY' "chain gates on RUN_ENV_READY"; has "$L" 'CONDA_DEFAULT_ENV' "conda gate in the chain"
has "$L" 'logs/t-' "-N names the log"; has "$L" 'nohup' "nohup launch"
has "$L" "echo \$! > 'logs/t-.*\.log\.pid'" "writes the pid file beside the log"; has "$L" 'pid file' "the launch line names the pid file"
O=$(launch "$W"); has "$(cat "$T/launch.log")" 'logs/jobx-' "per-station JOB_NAME honoured"
O=$(launch "$W" -d 1 -N t -- c); has "$O" 'GPU(s) \[1\]' "-d bypasses exclude"
L=$(cat "$T/launch.log"); has "$L" "CUDA_VISIBLE_DEVICES='1' PYTHONUNBUFFERED=1 c >" "payload after -- overrides RUN"
O=$(launch "$W" -d '0, 1' -N t -- c); has "$(cat "$T/launch.log")" "CUDA_VISIBLE_DEVICES='0,1'" "-d '0, 1' whitespace-normalised"
O=$(launch "$W" -d '0;rm' -N t -- c) && bad "-d garbage rejected" || has "$O" 'comma-separated' "-d garbage rejected"
for badn in 0 -1 abc; do O=$(launch "$W" -n "$badn" -N t -- c) && bad "-n $badn accepted" || has "$O" 'positive integer' "-n $badn rejected"; done
O=$(launch "$W" -n 3 -N t -- c) && bad "-n 3 with 2 excluded hard-fails" || has "$O" 'only 2 GPU' "-n 3 with 2 excluded hard-fails"
O=$(launch "$W" -z -N t -- c); RC=$?; [ "$RC" = 2 ] && ok "unknown flag exits 2" || bad "unknown flag exits 2 (got $RC)"
conf "$W" 'ENV_KIND=conda
ENV_NAME=e
WS_REMOTE_DIR=projects/x
DEFAULT_NGPU=2
WSBOX_DEFAULT_NGPU=1
WSBOX_GPU_EXCLUDE=1'
O=$(launch "$W" -N t -- c); has "$O" 'GPU(s) \[2\]' "WSBOX_DEFAULT_NGPU beats DEFAULT_NGPU; WSBOX_GPU_EXCLUDE skips the idlest"
conf "$W" 'ENV_KIND=conda
ENV_NAME=e
WS_REMOTE_DIR=projects/x'
O=$(launch "$W" -N t); RC=$?; [ "$RC" = 2 ] && has "$O" 'no run command' "no RUN and no -- -> exit 2" || bad "no run command (rc=$RC)"
O=$(launch "$W" -N t -- c); has "$O" 'GPU(s) \[1\]' "default -n 1 picks the idlest GPU"
O=$(launch "$W" -n 5 -N t -- c) && bad "-n 5 of 4 GPUs hard-fails" || has "$O" 'only 4 GPU' "-n 5 of 4 GPUs hard-fails"
conf "$W" 'ENV_KIND=conda
ENV_NAME=e
WS_REMOTE_DIR=projects/x
NICE=-5'
O=$(launch "$W" -N t -- c) && bad "negative NICE rejected" || has "$O" 'non-negative' "negative NICE rejected"
conf "$W" 'ENV_KIND=conda
ENV_NAME=e
WS_REMOTE_DIR=projects/x
GPU_EXCLUDE=a,b'
O=$(launch "$W" -N t -- c) && bad "GPU_EXCLUDE garbage rejected" || has "$O" 'comma-separated' "GPU_EXCLUDE garbage rejected"
conf "$W" 'ENV_KIND=bogus
WS_REMOTE_DIR=projects/x'
O=$(launch "$W" -N t -- c) && bad "bad ENV_KIND accepted" || has "$O" 'ENV_KIND' "local ENV_KIND validation"
conf "$W" 'ENV_KIND=uv
WS_REMOTE_DIR=projects/x
RUN=c'
O=$(launch "$W" -N t); has "$O" 'started PID' "uv: launches"
L=$(cat "$T/launch.log"); has "$L" 'RS_VENV' "uv gate compares against RS_VENV"; has "$L" 'uv venv not active' "uv gate message"
has "$L" 'run-bootstrap' "uv gate names run-bootstrap"; hasnt "$L" 'ln -s' "no ln -s in the chain"
conf "$W" 'WS_REMOTE_DIR=projects/x
RUN=c'
O=$(launch "$W" -N t); has "$(cat "$T/launch.log")" 'RS_VENV' "no ENV_KIND -> uv gate (never conda)"
conf "$W" 'WS_REMOTE_DIR=projects/x
WSBOX_REMOTE_DIR=projects/y
RUN=c'
O=$(launch "$W" -N t); has "$(cat "$T/launch.log")" "cd 'projects/y'" "WSBOX_REMOTE_DIR beats WS_REMOTE_DIR"
O=$(TARGET= STATION=ws-box launch "$W" -N t); has "$O" 'started PID' "STATION= is accepted as TARGET"
P=$(mk_proj fx-slurm 'REMOTE_DIR=/x')
O=$(TARGET=fx-slurm launch "$P" -N t -- c); RC=$?
[ "$RC" = 2 ] && has "$O" 'run-launch is for nohup targets' "slurm target refused" || bad "slurm target refused (rc=$RC)"
has "$O" 'submit\.sh' "refusal points at submit.sh"
O=$(TARGET= launch "$W" -N t); RC=$?; [ "$RC" = 2 ] && has "$O" 'set TARGET=' "no TARGET -> exit 2" || bad "no TARGET -> exit 2 (rc=$RC)"
stub_fail ssh
O=$(launch "$W" -N t) && bad "ssh failure propagates" || hasnt "$O" 'started PID' "ssh failure propagates, no bogus PID line"
