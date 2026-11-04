#!/usr/bin/env bash
# tests/60-launch.sh — phase A: bin/run-launch on the ws-box fixture. Part 1 (any OS): the ssh stub only logs the launch
# command (the GPU table is canned): flag validation, what reaches .ws/launch.sh (one quoted argv: NICE, pick, exclude,
# log name, RUN as ONE word, JOB_NAME, REMOTE_DIR, --rs-attempt / --same-name-ok), refusals before any ssh, the ssh 255
# note, the OLD run-launch rejecting the new flags, slurm refused. Part 2 (Linux: /proc + setsid): the stub EXECUTES the
# remote side here (HOME=$T/home, remote cwd = $HOME, projects/x -> the fixture) with an nvidia-smi stub (4 GPUs + UUIDs),
# so the deployed launch.sh really runs: the pick it prints, exit codes 1/6/75, receipts, the uv gate, an old deploy.
# launch.sh's own guarantees (journal, gate, receipt, TERM, duplicates): tests/61-launch-remote.sh.
# Run by selftest.sh with RS_HOME set:  bash tests/60-launch.sh
set -u
. "$RS_HOME/tests/lib.sh"
export TARGET=ws-box
H=$T/home; mkdir -p "$H/projects" "$H/miniconda3/etc/profile.d"
printf 'conda() { case "$1" in activate) export CONDA_DEFAULT_ENV=$2 ;; *) return 1 ;; esac; }\n' > "$H/miniconda3/etc/profile.d/conda.sh"
cat > "$T/bin/ssh" <<EOS
#!/usr/bin/env bash
# logs the host and every non-table command; with $T/ssh.exec runs it here as the remote login shell would
echo "\$1" >> "$T/ssh-host.log"; shift; cmd="\$*"
case "\$cmd" in *query-gpu=index,name*) ;; *) echo "\$cmd" >> "$T/launch.log" ;; esac
[ ! -f "$T/ssh.255" ] || case "\$cmd" in *launch.sh*) exit 255 ;; esac
[ -f "$T/ssh.exec" ] || case "\$cmd" in *launch.sh*) echo "[fake] started PID 4242"; exit 0 ;; esac
cd "$H" && HOME="$H" exec bash -c "\$cmd"
EOS
cat > "$T/bin/nvidia-smi" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *index,name,*) printf '0, F, 0 %%, 8000 MiB, 49140 MiB\n1, F, 0 %%, 2 MiB, 49140 MiB\n2, F, 0 %%, 5 MiB, 49140 MiB\n3, F, 0 %%, 9000 MiB, 49140 MiB\n' ;;
  *index,uuid,memory.used*) printf '0, GPU-aaaa0000-0000, 8000\n1, GPU-aaaa0000-0001, 2\n2, GPU-aaaa0000-0002, 5\n3, GPU-aaaa0000-0003, 9000\n' ;;
  *) echo "nvidia-smi stub: unexpected $*" >&2; exit 2 ;;
esac
EOS
chmod +x "$T/bin/ssh" "$T/bin/nvidia-smi"
# launch PROJ ARGS... : run-launch from PROJ with the stub PATH, stderr merged; launch.log / ssh-host.log truncated first
launch() { local p=$1; shift; : > "$T/launch.log"; : > "$T/ssh-host.log"; ( cd "$p" && PATH="$T/bin:$PATH" bash "$RS_HOME/bin/run-launch" "$@" 2>&1 ); }
conf() { printf '%s\n' "$2" > "$1/.ws.conf"; }
latt() { ls -dt "$1"/.rs/attempts/*/ 2>/dev/null | head -n 1 | sed 's|/$||'; }   # newest attempt dir
noss() { [ ! -s "$T/ssh-host.log" ]; }                                           # nothing was sent
# every run a test started is killed at exit (only while its receipt's start time still matches: never a reused pid)
reap() { local r p; for r in "$T"/proj_*/.rs/attempts/*/receipt; do [ -f "$r" ] || continue; p=$(sed -n 's/^pgid=//p' "$r")
  [ -n "$p" ] && [ "$(awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$p/stat" 2>/dev/null)" = "$(sed -n 's/^start=//p' "$r")" ] && kill -KILL -- "-$p" 2>/dev/null; done; }
trap 'reap; rm -rf "$T"' EXIT
W0='ENV_KIND=conda
ENV_NAME=e
WS_REMOTE_DIR=projects/x
GPU_EXCLUDE="0, 1"
DEFAULT_NGPU=2
WSBOX_NICE=7
WSBOX_RUN="tagcmd --flag"
WSBOX_JOB_NAME=jobx'
W=$(mk_proj ws-box "$W0") || { bad "mk_proj ws-box"; exit 1; }
ln -s "$W" "$H/projects/x"; ln -s "$W" "$H/projects/y"; mkdir -p "$W/.venv/bin"; printf '#!/bin/sh\n' > "$W/.venv/bin/python"; chmod +x "$W/.venv/bin/python"

echo "-- part 1: what run-launch sends (logging stub) --"
O=$(launch "$W" -N t); RC=$?
[ "$RC" = 0 ] && ok "launches (rc 0)" || { bad "launches (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
has "$O" '^\[ws-box\] current GPUs on wsbox:' "prints the GPU table header"; has "$O" '^  1, F, 0 %, 2 MiB' "prints the GPU table"
has "$O" '^\[ws-box\] auto-pick excludes GPU(s) \[0,1\] (GPU_EXCLUDE)' "names the exclude (spaces normalised)"
has "$O" '^\[ws-box\] reference: /.*/ws-box/reference\.md — the target rules' "launch re-prints the reference path"
has "$O" "verify:.*\.ws/status\.sh' 'logs/t-[0-9-]*\.log'\"" "prints the verify line: status.sh + the PROJECT-relative log, both quoted (never tail -f)"
[ "$(wc -l < "$T/ssh-host.log")" = 2 ] && ok "two ssh in all: the GPU table + ONE for the launch" || bad "two ssh in all (got $(wc -l < "$T/ssh-host.log"))"
L=$(cat "$T/launch.log")
has "$L" "^cd 'projects/x' || exit 1; " "the launch cds into the \$HOME-relative dir (or stops)"; has "$L" "TARGET='ws-box' bash \.ws/launch\.sh " "the launch runs the deployed .ws/launch.sh with TARGET"
has "$L" "test -f \.ws/launch\.sh || .*deploy predates it" "an old deploy (no launch.sh) is named, never run around"
has "$L" "--rs-attempt '[0-9]\{8\}T[0-9]\{6\}Z-[0-9]*-[0-9]*' " "a generated NONCE goes along"
has "$L" "--nice '7'" "per-station NICE passed to launch.sh"; has "$L" " -n '2' -x '0,1'" "auto-pick: count + GPU_EXCLUDE go to launch.sh"
has "$L" "--log 'logs/t-[0-9]\{8\}-[0-9]\{6\}\.log'" "-N names the log (local timestamp, as before)"; has "$L" " -- 'tagcmd --flag'\$" "<TAG>_RUN fallback, as ONE quoted word"
hasnt "$L" 'same-name-ok' "no --same-name-ok unless asked"
O=$(launch "$W"); has "$(cat "$T/launch.log")" "-N 'jobx'" "per-station JOB_NAME honoured"
O=$(launch "$W" -d 1 -N t -- c); L=$(cat "$T/launch.log")
has "$L" " -d '1' " "-d goes to launch.sh"; has "$L" " -- 'c'\$" "payload after -- overrides RUN"; hasnt "$L" " -x '" "-d sends no exclude"; hasnt "$L" " -n '" "-d sends no count"
O=$(launch "$W" -d '0, 1' -N t -- c); has "$(cat "$T/launch.log")" " -d '0,1' " "-d '0, 1' whitespace-normalised"
O=$(launch "$W" -N t -- python t.py --msg "it's" '$HOME'); has "$(cat "$T/launch.log")" " -- 'python t.py --msg it'\\\\''s \$HOME'\$" "RUN with a quote: one single-quoted word, \$ left for the remote"
O=$(launch "$W" -N t --same-name-ok --rs-attempt my.id-1 -- c); L=$(cat "$T/launch.log")
has "$L" "--rs-attempt 'my.id-1' " "--rs-attempt passes through"; has "$L" ' --same-name-ok ' "--same-name-ok passes through"
O=$(launch "$W" -d '0;rm' -N t -- c) && bad "-d garbage rejected" || { has "$O" 'comma-separated' "-d garbage rejected"; noss && ok "...before any ssh" || bad "...before any ssh"; }
for badn in 0 -1 abc; do O=$(launch "$W" -n "$badn" -N t -- c) && bad "-n $badn accepted" || has "$O" 'positive integer' "-n $badn rejected"; done
O=$(launch "$W" -d 1 -n 2 -N t -- c) && bad "-d 1 -n 2 hard-fails" || has "$O" 'only 1 GPU' "-d with fewer ids than -n hard-fails"
O=$(launch "$W" -z -N t -- c); RC=$?; [ "$RC" = 2 ] && noss && ok "unknown flag exits 2 (no ssh)" || bad "unknown flag exits 2 (got $RC)"
for n in 'a/b' 'a b' "it's" '-x' '.hidden'; do
  O=$(launch "$W" -N "$n" -- c); RC=$?; [ "$RC" = 2 ] && noss && ok "-N '$n' refused locally (exit 2, no ssh)" || bad "-N '$n' refused locally (rc=$RC)"; done
for bn in 'a/b' '..' .x -y 'é' "$(printf 'x%.0s' $(seq 65))"; do
  O=$(launch "$W" -N t --rs-attempt "$bn" -- c); RC=$?; [ "$RC" = 2 ] && noss && ok "--rs-attempt '${bn:0:12}' refused locally" || bad "--rs-attempt '${bn:0:12}' refused locally (rc=$RC)"; done
touch "$T/ssh.255"; O=$(launch "$W" -N t --rs-attempt cut-1 -- c); RC=$?; rm -f "$T/ssh.255"
[ "$RC" = 255 ] && has "$O" "NOTE: ssh failed.*cat 'projects/x/\.rs/attempts/cut-1/result'" "ssh 255 -> exit 255 + where the attempt's verdict is" || bad "ssh 255 note (rc=$RC)"
has "$O" 'can never launch twice' "...and that a retry with the same NONCE is safe"; hasnt "$O" 'verify:' "...and no verify line"
conf "$W" 'ENV_KIND=conda
ENV_NAME=e
WS_REMOTE_DIR=projects/x
DEFAULT_NGPU=2
WSBOX_DEFAULT_NGPU=1
WSBOX_GPU_EXCLUDE=1'
O=$(launch "$W" -N t -- c); has "$(cat "$T/launch.log")" " -n '1' -x '1' " "WSBOX_DEFAULT_NGPU beats DEFAULT_NGPU; WSBOX_GPU_EXCLUDE goes along"
conf "$W" 'ENV_KIND=conda
ENV_NAME=e
WS_REMOTE_DIR=projects/x'
O=$(launch "$W" -N t); RC=$?; [ "$RC" = 2 ] && has "$O" 'no run command' "no RUN and no -- -> exit 2" || bad "no run command (rc=$RC)"
O=$(launch "$W" -N t -- c); L=$(cat "$T/launch.log"); has "$L" " -n '1' " "default -n 1"; hasnt "$L" " -x '" "no GPU_EXCLUDE, no -x"; hasnt "$L" '--nice' "no NICE, no --nice"
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
conf "$W" 'ENV_KIND=conda
WS_REMOTE_DIR=projects/x'
O=$(launch "$W" -N t -- c) && bad "conda without ENV_NAME accepted" || has "$O" 'ENV_NAME required' "local: conda needs ENV_NAME"
conf "$W" 'WS_REMOTE_DIR=projects/x
WSBOX_REMOTE_DIR=projects/y
RUN=c'
O=$(launch "$W" -N t); has "$(cat "$T/launch.log")" "cd 'projects/y'" "WSBOX_REMOTE_DIR beats WS_REMOTE_DIR"
O=$(TARGET= STATION=ws-box launch "$W" -N t); has "$O" 'started PID' "STATION= is accepted as TARGET"
# the OLD run-launch never reaches a launch with the new flags: unknown arg, exit 2, before any ssh
OLD=""; for c in $(git -C "$RS_HOME" rev-list -n 20 HEAD -- bin/run-launch 2>/dev/null); do   # the newest run-launch without the flags
  OLD=$(git -C "$RS_HOME" show "$c:bin/run-launch" 2>/dev/null) && ! printf '%s\n' "$OLD" | grep -q 'rs-attempt' && break; OLD=""; done
if [ -n "$OLD" ]; then
  mkdir -p "$T/old/bin"; ln -s "$RS_HOME/lib" "$T/old/lib"; printf '%s\n' "$OLD" > "$T/old/bin/run-launch"
  for f in '--rs-attempt X' --same-name-ok; do
    : > "$T/ssh-host.log"; O=$( cd "$W" && PATH="$T/bin:$PATH" bash "$T/old/bin/run-launch" -N t $f -- c 2>&1 ); RC=$?
    [ "$RC" = 2 ] && noss && ok "the OLD run-launch rejects $f (exit 2, no ssh)" || bad "the OLD run-launch rejects $f (rc=$RC)"; done
else echo "  SKIP: no git history with the pre-attempt run-launch (an installed copy)"; fi
P=$(mk_proj fx-slurm 'REMOTE_DIR=/x')
O=$(TARGET=fx-slurm launch "$P" -N t -- c); RC=$?
[ "$RC" = 2 ] && has "$O" 'run-launch is for nohup targets' "slurm target refused" || bad "slurm target refused (rc=$RC)"
has "$O" 'submit\.sh' "refusal points at submit.sh"
O=$(TARGET= launch "$W" -N t); RC=$?; [ "$RC" = 2 ] && has "$O" 'set TARGET=' "no TARGET -> exit 2" || bad "no TARGET -> exit 2 (rc=$RC)"

echo "-- part 2: the deployed launch.sh runs (executing stub) --"
if [ ! -r /proc/self/stat ] || ! command -v setsid >/dev/null 2>&1; then
  echo "  SKIP: part 2 — launch.sh is a Linux remote script (/proc, setsid); run selftest on Linux for it"
else
  touch "$T/ssh.exec"; conf "$W" "$W0"   # each successful launch below gets its own -N: one name twice in one second = exit 2
  O=$(launch "$W" -N t1); RC=$?
  [ "$RC" = 0 ] && ok "launches (rc 0)" || { bad "launches (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
  has "$O" 'GPU(s) \[2,3\]' "spaced exclude + DEFAULT_NGPU=2 -> picks 2,3"; has "$O" '^\[ws-box\] started PID [0-9]* on GPU(s) 2,3 ; log ' "prints the PID line"
  has "$O" '^attempt: \.rs/attempts/[0-9]\{8\}T[0-9]\{6\}Z-[0-9]*-[0-9]*$' "prints the attempt dir"; has "$O" 'RUN: tagcmd --flag' "prints the RUN line"
  has "$O" "pid file $H/projects/x/logs/t1-.*\.log\.pid" "the launch line names the pid file"
  LG=$(ls "$W"/logs/t1-*.log 2>/dev/null | head -n 1); [ -n "$LG" ] && [ -f "$LG.pid" ] && ok "writes the pid file beside the log" || bad "writes the pid file beside the log"
  has "$(cat "$(latt "$W")/receipt" 2>/dev/null)" '^gpus=GPU-aaaa0000-0002,GPU-aaaa0000-0003$' "the receipt pins the picked GPUs by UUID"
  has "$(cat "$(latt "$W")/result" 2>/dev/null)" 'verdict=launched' "the attempt's result says launched"
  O=$(launch "$W" -d 1 -N t2 -- c); has "$O" 'GPU(s) \[1\]' "-d bypasses exclude"
  O=$(launch "$W" -n 3 -N t3 -- c) && bad "-n 3 with 2 excluded hard-fails" || has "$O" 'only 2 GPU' "-n 3 with 2 excluded hard-fails"
  O=$(launch "$W" -n 5 -d 0,1,2,3,4 -N t4 -- c) && bad "-d with an absent id" || has "$O" 'GPU id 4 is not on this box' "-d with an absent id -> refused"
  conf "$W" 'ENV_KIND=conda
ENV_NAME=e
WS_REMOTE_DIR=projects/x
DEFAULT_NGPU=2
WSBOX_DEFAULT_NGPU=1
WSBOX_GPU_EXCLUDE=1'
  O=$(launch "$W" -N t5 -- c); has "$O" 'GPU(s) \[2\]' "WSBOX_GPU_EXCLUDE skips the idlest"
  O=$(launch "$W" -n 5 -N t6 -- c) && bad "-n 5 of 4 GPUs hard-fails" || has "$O" 'only 3 GPU' "-n 5 of 4 GPUs (1 excluded) hard-fails"
  has "$(cat "$(latt "$W")/result")" 'verdict=refused' "...and its attempt records verdict=refused"
  conf "$W" 'WS_REMOTE_DIR=projects/x
RUN=c'
  O=$(launch "$W" -N t7); has "$O" 'started PID' "no ENV_KIND -> uv: launches with the venv"
  mv "$W/.venv" "$W/.venv-off"
  O=$(launch "$W" -N t8); RC=$?; [ "$RC" = 1 ] && has "$O" 'uv venv not active' "no ENV_KIND, no venv -> the uv gate refuses (never conda)" || bad "uv gate without a venv (rc=$RC)"
  conf "$W" 'WS_REMOTE_DIR=projects/x
ENV_KIND=none
RUN=c'
  O=$(launch "$W" -N t9); RC=$?; [ "$RC" = 0 ] && has "$O" 'started PID' "ENV_KIND=none: launches without ENV_NAME or a venv" || bad "ENV_KIND=none launches (rc=$RC)"
  mv "$W/.venv-off" "$W/.venv"
  O=$(launch "$W" -N n1 --rs-attempt fixed-1 -- c); [ -f "$W/.rs/attempts/fixed-1/receipt" ] && ok "the given NONCE names the attempt dir" || bad "the given NONCE names the attempt dir"
  n=$(ls "$W"/logs/n1-*.log | wc -l); O=$(launch "$W" -N n1 --rs-attempt fixed-1 -- c); RC=$?
  [ "$RC" = 75 ] && has "$O" 'already claimed' "the same NONCE again -> exit 75" || bad "the same NONCE again -> exit 75 (rc=$RC)"
  [ "$(ls "$W"/logs/n1-*.log | wc -l)" = "$n" ] && ok "...and launches nothing" || bad "...and launches nothing"
  O=$(launch "$W" -N live -- sleep 30); RC=$?; [ "$RC" = 0 ] || bad "live launch (rc=$RC)"
  O=$(launch "$W" -N live -- sleep 30); RC=$?
  [ "$RC" = 6 ] && has "$O" "'live' is already running" "a second live run of one name -> exit 6" || bad "a second live run of one name -> exit 6 (rc=$RC)"
  hasnt "$O" 'verify:' "...and prints no verify line"
  sleep 1   # one name twice in one second would find its log name taken (exit 2, never truncated)
  O=$(launch "$W" -N live --same-name-ok -- sleep 30); RC=$?; [ "$RC" = 0 ] && ok "--same-name-ok launches the second" || bad "--same-name-ok (rc=$RC)"
  reap
  mv "$W/.ws/launch.sh" "$W/.ws/launch.sh.off"
  O=$(launch "$W" -N t10 -- c); RC=$?; [ "$RC" = 2 ] && has "$O" 'deploy predates it' "a deploy without .ws/launch.sh -> exit 2, re-sync" || bad "old deploy (rc=$RC)"
  mv "$W/.ws/launch.sh.off" "$W/.ws/launch.sh"
fi
stub_fail ssh
O=$(launch "$W" -N t) && bad "ssh failure propagates" || hasnt "$O" 'started PID' "ssh failure propagates, no bogus PID line"
