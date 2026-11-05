#!/usr/bin/env bash
# tests/61-launch-remote.sh — phase A: the deployed .ws/launch.sh itself, run here as run-launch's ssh would run it
# (cwd = $HOME/projects/<p>, TARGET set; real setsid/sleep/kill, stub nvidia-smi with UUIDs). Covers: the attempt
# journal (claim, out/err replay, stage, result, receipt fields), a dead caller loses nothing, NONCE reuse (75), the env
# gate fail-closed paths, the duplicate guard by live triple, GPU ids (+ UUIDs in the receipt), NICE, group/wrapper TERM -> rc=143 term=1,
# no payload without a confirmed gate, the conf cannot steer launch.sh, RUN's plain conf/hook variables (named ones only,
# mode 600, deleted once read; the harness's CUDA env wins), nested launches, status.sh / rsk reading the run, api=3 (the
# plan block, --rs-expect, the P2 launch.sh given its flags), busy GPUs (--query-compute-apps, --gpu-busy-ok, the occupants
# bound), the plan's read-only env check (D10) and a full $TMPDIR under bash 4.2 heredocs (fulltmp).
# Run by selftest.sh with RS_HOME set:  bash tests/61-launch-remote.sh
set -u
. "$RS_HOME/tests/lib.sh"
if [ ! -r /proc/self/stat ] || ! command -v setsid >/dev/null 2>&1; then
  echo "  SKIP: 61-launch-remote — launch.sh is a Linux remote script (/proc, setsid); run selftest on Linux for it"; exit 0; fi
H=$T/home; mkdir -p "$H/projects" "$H/miniconda3/etc/profile.d"
printf 'conda() { case "$1" in activate) [ "$2" = broken ] && export CONDA_DEFAULT_ENV=other || export CONDA_DEFAULT_ENV=$2 ;; *) return 1 ;; esac; }\n' \
  > "$H/miniconda3/etc/profile.d/conda.sh"
cat > "$T/bin/nvidia-smi" <<EOS
#!/usr/bin/env bash
[ ! -f "$T/nvsmi.fail" ] || { echo "NVIDIA-SMI has failed" >&2; exit 9; }
case "\$*" in *index,uuid,memory.used*) [ ! -f "$T/gpus" ] || { cat "$T/gpus"; exit 0; }   # another table: \$T/gpus
    printf '0, GPU-aaaa0000-0000, 8000\n1, GPU-aaaa0000-0001, 2\n2, GPU-aaaa0000-0002, 5\n3, GPU-aaaa0000-0003, 9000\n' ;;
  "--query-compute-apps=gpu_uuid,pid --format=csv,noheader") [ ! -f "$T/apps.fail" ] || exit 9; cat "$T/apps" 2>/dev/null; exit 0 ;;   # the busy list: \$T/apps
  *) echo "nvidia-smi stub: unexpected \$*" >&2; exit 2 ;; esac
EOS
chmod +x "$T/bin/nvidia-smi"
mkp() { local d; d=$(mk_proj ws-box "$2") || return 1; ln -s "$d" "$H/projects/$1"; echo "$d"; }
L() { local p=$1; shift; ( cd "$H/projects/$p" && HOME="$H" PATH="$T/bin:$PATH" TARGET=ws-box bash .ws/launch.sh "$@" 2>&1 ); }   # stderr merged
kv() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }
pst() { awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null; }          # field 22, counted after the last ')'
latt() {   # the attempt the last `O=$(…)` printed (by name), else the newest dir — a live wrapper may touch an older one later
  local a; a=$(printf '%s\n' "${O:-}" | sed -n 's|^attempt: \.rs/attempts/||p' | tail -n 1)
  if [ -n "$a" ] && [ -d "$1/.rs/attempts/$a" ]; then printf '%s\n' "$1/.rs/attempts/$a"
  else ls -dt "$1"/.rs/attempts/*/ 2>/dev/null | head -n 1 | sed 's|/$||'; fi; }
waitfor() { local i=0; while [ "$i" -lt 100 ]; do for f in $1; do [ -e "$f" ] && return 0; done; sleep 0.1; i=$((i+1)); done; return 1; }   # glob, 10 s
ngrp() { ps -e -o pgid= | tr -d ' ' | grep -cx "$1"; }                                # processes left in a process group
reap() { local r p; for r in "$T"/proj_*/.rs/attempts/*/receipt; do [ -f "$r" ] || continue; p=$(kv pgid "$r")
  [ -n "$p" ] && [ "$(pst "$p")" = "$(kv start "$r")" ] && kill -KILL -- "-$p" 2>/dev/null; done; }
trap 'reap; [ -z "${SP:-}" ] || kill "$SP" 2>/dev/null; rm -rf "$T"' EXIT
BOOT=$(cat /proc/sys/kernel/random/boot_id)
N=$(mkp n 'WS_REMOTE_DIR=projects/n
ENV_KIND=none') || { bad "mk_proj"; exit 1; }

echo "-- journal + receipt --"
O=$(L n --rs-attempt r1 -N rcpt -d 1,3 -- sleep 30); RC=$?; A=$N/.rs/attempts/r1
[ "$RC" = 0 ] && ok "launches (rc 0)" || { bad "launches (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
R=$(cat "$A/receipt" 2>/dev/null); PID=$(kv pid "$A/receipt"); LG=$N/$(kv log "$A/receipt")
[ -n "$PID" ] && [ "$PID" = "$(cat "$LG.pid" 2>/dev/null)" ] && ok "receipt pid = <log>.pid (the wrapper)" || bad "receipt pid = <log>.pid ($PID)"
grep -qx '[0-9]*' "$LG.pid" && ok "<log>.pid holds digits only (status.sh / rsk / run-watch read it)" || bad "<log>.pid holds digits only"
[ "$(kv pgid "$A/receipt")" = "$PID" ] && ok "pgid = pid: the wrapper leads its process group" || bad "pgid = pid"
[ "$(ps -o sid= -p "$PID" | tr -d ' ')" = "$PID" ] && ok "setsid: the wrapper leads its own session" || bad "setsid: own session"
[ -n "$(kv start "$A/receipt")" ] && [ "$(kv start "$A/receipt")" = "$(pst "$PID")" ] && ok "start = field 22 of /proc/<pid>/stat" || bad "start = /proc field 22"
[ "$(kv boot_id "$A/receipt")" = "$BOOT" ] && ok "boot_id recorded" || bad "boot_id recorded"
has "$R" '^gpus=GPU-aaaa0000-0001,GPU-aaaa0000-0003$' "-d 1,3 -> their UUIDs, in that order"
has "$R" '^log=logs/rcpt-[0-9]\{8\}-[0-9]\{6\}\.log$' "log= is the project-relative log"; has "$R" '^name=rcpt$' "name="
has "$R" '^nonce=r1$' "nonce="; has "$R" '^at=[0-9]\{10\}$' "at= (epoch)"
has "$(cat "$A/result")" '^stage=done rc=0 verdict=launched at=[0-9]*$' "result: stage=done rc=0 verdict=launched"
[ "$(cat "$A/stage")" = done ] && [ "$(readlink "$A/gate")" = go ] && ok "stage=done, gate -> go" || bad "stage=done, gate -> go"
has "$(cat "$A/out")" '^attempt: \.rs/attempts/r1$' "out keeps the attempt line"; has "$(cat "$A/out")" '^\[ws-box\] started PID '"$PID"' on GPU(s) 1,3' "out keeps the PID line (ids shown)"
[ "$O" = "$(cat "$A/out" "$A/err")" ] && ok "the caller got exactly out then err (replayed at exit)" || bad "the caller got exactly out then err"
S=$( cd "$H/projects/n" && bash .ws/status.sh "$(kv log "$A/receipt")" )
has "$S" "^proc=alive pid=$PID " "status.sh: proc=alive for the wrapper pid"; has "$S" '^starts=1 restart=0 footer=none' "status.sh: the header opens a start"
if command -v python3 >/dev/null 2>&1 && PR=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from remote_run import observe; print(observe.NOHUP)' "$RS_HOME/src" 2>/dev/null); then
  has "$(RDIR="$N" bash -c "$PR" 2>&1)" "^logs/rcpt-.* alive:[0-9]*:$PID\$" "rsk status's nohup probe: alive, with the wrapper pid"
else echo "  SKIP: python3 / remote_run not importable: rsk's nohup probe not exercised"; fi

echo "-- duplicates: a receipt whose pid, /proc start and boot_id still match --"
O=$(L n -N rcpt -d 0 -- sleep 30); RC=$?; D=$(latt "$N")
[ "$RC" = 6 ] && has "$O" "'rcpt' is already running from this project: pid $PID (attempt \.rs/attempts/r1" "same name alive -> exit 6, names pid + attempt" || bad "same name alive -> exit 6 (rc=$RC)"
has "$(cat "$D/result")" '^stage=pre-policy rc=6 verdict=refused' "...journaled: verdict=refused"; [ "$(ls "$N"/logs/rcpt-*.log | wc -l)" = 1 ] && ok "...no second log" || bad "...no second log"
sleep 1   # a second launch of one name in the same second finds its log name taken (exit 2)
O=$(L n -N rcpt --same-name-ok -d 0 -- sleep 30); RC=$?; [ "$RC" = 0 ] && ok "--same-name-ok launches the second" || bad "--same-name-ok (rc=$RC)"
A2=$(latt "$N"); PID2=$(kv pid "$A2/receipt")
sleep 30 & SP=$!; SS=$(pst "$SP")   # a live process stands in for a run: only the receipt decides
fake() { local d=$N/.rs/attempts/$1; mkdir -p "$d"; printf 'pid=%s\npgid=%s\nstart=%s\nboot_id=%s\nname=%s\nlog=logs/x.log\n' "$SP" "$SP" "$2" "$3" "$4" > "$d/receipt"; ln -s "$5" "$d/gate"; }
fake f1 "$SS" "$BOOT" fk-a go;    O=$(L n -N fk-a -d 0 -- c); [ "$?" = 6 ] && ok "a live triple blocks" || bad "a live triple blocks"
fake f2 "$((SS+1))" "$BOOT" fk-b go; O=$(L n -N fk-b -d 0 -- c); [ "$?" = 0 ] && ok "same pid, other /proc start (a reused pid) does not block" || bad "reused pid blocks"
fake f3 "$SS" 00000000-0000-0000-0000-000000000000 fk-c go; O=$(L n -N fk-c -d 0 -- c); [ "$?" = 0 ] && ok "another boot's receipt does not block" || bad "another boot blocks"
fake f4 "$SS" "$BOOT" fk-d abort; O=$(L n -N fk-d -d 0 -- c); [ "$?" = 0 ] && ok "a run whose gate never opened does not block" || bad "gate abort blocks"
kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; SP=""
O=$(L n -N fk-a -d 0 -- c); [ "$?" = 0 ] && ok "the triple's process gone -> the name is free" || bad "dead triple blocks"

echo "-- TERM --"
PG=$(kv pgid "$A/receipt"); kill -TERM -- "-$PG"
waitfor "$LG.rc" && has "$(cat "$LG.rc")" '^rc=143 term=1 at=[0-9]*$' "group TERM -> <log>.rc rc=143 term=1" || bad "group TERM -> <log>.rc"
has "$(tail -n 1 "$LG")" '^\[.*\] EXIT rc=143 term=1 pid='"$PID"' attempt=r1$' "...and the log's EXIT footer"
S=$( cd "$H/projects/n" && bash .ws/status.sh "$(kv log "$A/receipt")" )
has "$S" '^starts=1 restart=0 footer=EXIT rc=143 term=1' "status.sh reads the footer"; has "$S" "^proc=gone pid=$PID" "status.sh: proc=gone"
has "$S" "^proc=gone pid=$PID exit=143 term=1 (<log>.rc)\$" "status.sh: a gone run's exit comes from <log>.rc (never 'unknown' when it is recorded)"
mv "$LG.rc" "$LG.rc.off"; S=$( cd "$H/projects/n" && bash .ws/status.sh "$(kv log "$A/receipt")" )
has "$S" "^proc=gone pid=$PID exit=143 term=1 (the log's EXIT footer)\$" "...without <log>.rc: from the log's EXIT footer naming that pid"
sed "s/ pid=$PID / pid=1$PID /" "$LG" > "$LG.x" && mv "$LG.x" "$LG"; S=$( cd "$H/projects/n" && bash .ws/status.sh "$(kv log "$A/receipt")" )
has "$S" "^proc=gone pid=$PID exit=unknown (no <log>.rc or EXIT footer of this pid" "...a footer of another pid is not this run's: unknown"
printf 'rc=abc term=1 at=1\n' > "$LG.rc"; S=$( cd "$H/projects/n" && bash .ws/status.sh "$(kv log "$A/receipt")" )
has "$S" "^proc=gone pid=$PID exit=unknown " "...nor is a malformed <log>.rc"; mv "$LG.rc.off" "$LG.rc"
LG2=$N/$(kv log "$A2/receipt"); kill -TERM "$PID2"   # the wrapper alone (`kill <pid>`): forwarded once to the run
waitfor "$LG2.rc" && has "$(cat "$LG2.rc")" '^rc=143 term=1 ' "TERM to the wrapper pid alone -> forwarded, rc=143 term=1" || bad "wrapper TERM -> <log>.rc"
i=0; while [ "$(ngrp "$PID2")" != 0 ] && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i+1)); done   # the wrapper exits just after .rc
[ "$(ngrp "$PID2")" = 0 ] && ok "...and nothing of the run is left in its group" || bad "...the run's group still has $(ngrp "$PID2") process(es)"
O=$(L n -N ex3 -d 0 -- "sh -c 'exit 3'"); LG3=$N/$(kv log "$(latt "$N")/receipt")
waitfor "$LG3.rc" && has "$(cat "$LG3.rc")" '^rc=3 term=0 ' "a run's own exit code -> rc=3 term=0" || bad "own exit code"
has "$(sed -n 1p "$LG3")" '^\[.*\] target=ws-box job=[0-9]* restart=0 attempt=.* gpus=0$' "the log opens with the harness header"

echo "-- no confirmed gate, no payload --"
K=$(mkp slow 'WS_REMOTE_DIR=projects/slow
ENV_KIND=none
ENV_HOOK=slow.sh'); printf 'sleep 1\n' > "$K/slow.sh"
( cd "$H/projects/slow" && HOME="$H" PATH="$T/bin:$PATH" TARGET=ws-box exec bash .ws/launch.sh --rs-attempt k1 -N k1 -d 0 -- touch "$T/ran" > "$T/k1.out" 2>&1 ) & KP=$!
i=0; until [ "$(cat "$K/.rs/attempts/k1/stage" 2>/dev/null)" = launch ] || [ "$i" -ge 100 ]; do sleep 0.05; i=$((i+1)); done
kill -TERM "$KP"; wait "$KP"; RC=$?
[ "$RC" = 143 ] && ok "launch.sh killed during env.sh -> exit 143" || bad "launch.sh killed during env.sh (rc=$RC)"
waitfor "$K/logs/k1-*.log.rc" && has "$(cat "$K"/logs/k1-*.log.rc)" '^rc=125 term=0 ' "...its wrapper never got go: rc=125" || bad "...its wrapper never got go"
[ ! -e "$T/ran" ] && ok "...and the payload never ran" || bad "...and the payload never ran"
has "$(cat "$K/.rs/attempts/k1/result")" '^stage=launch rc=143 verdict=failed' "...journaled: stage=launch verdict=failed"
[ "$(readlink "$K/.rs/attempts/k1/gate")" = abort ] && ok "...gate -> abort" || bad "...gate -> abort"
has "$(cat "$K"/logs/k1-*.log)" 'EXIT rc=125 .*(not started' "...the log says not started"

echo "-- the caller --"
( cd "$H/projects/n" && HOME="$H" PATH="$T/bin:$PATH" TARGET=ws-box bash .ws/launch.sh --rs-attempt disc -N disc -d 2 -- sleep 30 2>&1 | true
  echo "${PIPESTATUS[0]}" > "$T/disc.rc" )
A=$N/.rs/attempts/disc
[ "$(cat "$T/disc.rc")" = 0 ] && ok "a caller that is gone: launch.sh still exits 0 (the replay's EPIPE ignored)" || bad "dead caller: rc=$(cat "$T/disc.rc")"
has "$(cat "$A/result")" 'verdict=launched' "...result written"; [ -n "$(pst "$(kv pid "$A/receipt")")" ] && ok "...receipt written, the run alive" || bad "...receipt / run"
has "$(cat "$A/out")" '^\[ws-box\] started PID' "...and out still holds every line"
SECONDS=0; O=$(L n -N hold -d 2 -- sleep 30); RC=$?
[ "$RC" = 0 ] && [ "$SECONDS" -lt 10 ] && ok "the caller's pipe is released at once (the run holds none of its fds)" || bad "pipe released at once (rc=$RC, ${SECONDS}s)"
O=$(L n --rs-attempt j1 -N j1 -d 0 -- c); O=$(L n --rs-attempt j1 -N j2 -d 0 -- c); RC=$?
[ "$RC" = 75 ] && has "$O" 'already claimed' "a claimed NONCE -> exit 75" || bad "a claimed NONCE -> exit 75 (rc=$RC)"
ls "$N"/logs/j2-*.log >/dev/null 2>&1 && bad "...launched anyway" || ok "...nothing launched"; has "$(cat "$N/.rs/attempts/j1/out")" 'j1' "...the first attempt's journal untouched"
B=$(ls "$N/.rs/attempts" | wc -l)
for n in 'a b' '' . .. -y .x a/b 'é' "$(printf 'x%.0s' $(seq 65))"; do   # submit.sh's rule: [A-Za-z0-9][A-Za-z0-9._-]{0,63}
  O=$(L n --rs-attempt "$n" -N j3 -- c); RC=$?; [ "$RC" = 2 ] && ok "an invalid NONCE '${n:0:12}' -> exit 2" || bad "invalid NONCE '${n:0:12}' (rc=$RC)"; done
[ "$(ls "$N/.rs/attempts" | wc -l)" = "$B" ] && ok "...nothing claimed by any of them" || bad "...an invalid NONCE claimed a dir"
O=$(L n -N j4 -d 0 -- c); has "$(basename "$(latt "$N")")" '^[0-9]\{8\}T[0-9]\{6\}Z-[0-9]*-[0-9]*$' "no NONCE given -> a generated one"
O=$(L n -N j5 --bogus -- c); RC=$?; A5=$(printf '%s\n' "$O" | sed -n 's|^attempt: \.rs/attempts/||p' | head -n 1)   # by name: an earlier run's
[ "$RC" = 2 ] && [ -n "$A5" ] && has "$(cat "$N/.rs/attempts/$A5/result")" '^stage=pre-policy rc=2 verdict=refused' \
  "a usage error after the claim is journaled (exit 2)" || bad "usage error (rc=$RC attempt=$A5)"   # wrapper may touch its dir later (ls -t)
O=$(RS_ATTEMPT=parent RS_RUN=x RS_ACKS=y RS_CONF_FILE=z L n -N nest -d 0 -- "sh -c 'echo att=\${RS_ATTEMPT:-none}'"); RC=$?
[ "$RC" = 0 ] && [ ! -e "$N/.rs/attempts/parent" ] && ok "a launch from inside a run gets its own attempt, never the parent's" || bad "nested launch (rc=$RC)"
waitfor "$N/$(kv log "$(latt "$N")/receipt").rc"; has "$(cat "$N/$(kv log "$(latt "$N")/receipt")")" '^att=none$' "...and the payload sees no RS_ATTEMPT"

echo "-- GPUs (ids in PCI_BUS_ID order, UUIDs in the receipt), NICE, the payload's env --"
O=$(L n -N env1 -d 2,0 -- "sh -c 'echo CVD=\$CUDA_VISIBLE_DEVICES ORDER=\$CUDA_DEVICE_ORDER UNBUF=\$PYTHONUNBUFFERED READY=\$RUN_ENV_READY'")
has "$O" 'GPU(s) \[2,0\]' "the printed lines keep showing ids"; E1=$N/$(kv log "$(latt "$N")/receipt"); waitfor "$E1.rc"
has "$(cat "$E1")" "^CVD=2,0 ORDER=PCI_BUS_ID UNBUF=1 READY=$H/projects/n\$" "payload env: the ids in -d order, PCI_BUS_ID (= nvidia-smi index order), unbuffered, the contained env"
O=$(L n -N pick -n 2 -x 1 -- c); has "$O" 'GPU(s) \[2,0\]' "-n 2 -x 1: the two idlest outside the exclude"
has "$(cat "$(latt "$N")/receipt")" '^gpus=GPU-aaaa0000-0002,GPU-aaaa0000-0000$' "...pinned by UUID"
O=$(L n -N g7 -d 7 -- c); RC=$?; [ "$RC" = 2 ] && has "$O" 'GPU id 7 is not on this box (ids: 0,1,2,3)' "-d with an absent id -> exit 2" || bad "-d 7 (rc=$RC)"
O=$(L n -N g8 -d 1,01 -- c); RC=$?; [ "$RC" = 2 ] && has "$O" 'twice' "-d naming one GPU twice -> exit 2" || bad "-d 1,01 (rc=$RC)"
O=$(L n -N g9 -d 0 -n 1 -- c); RC=$?; [ "$RC" = 2 ] && has "$O" 'exclusive' "-d with -n -> exit 2" || bad "-d -n (rc=$RC)"
touch "$T/nvsmi.fail"; O=$(L n -N g10 -d 0 -- c); RC=$?; rm -f "$T/nvsmi.fail"
[ "$RC" = 1 ] && has "$O" 'nvidia-smi failed' "nvidia-smi failing -> exit 1, nothing launched" || bad "nvidia-smi failing (rc=$RC)"
ls "$N"/logs/g10-*.log >/dev/null 2>&1 && bad "...no log" || ok "...no log"; has "$(cat "$(latt "$N")/result")" 'verdict=failed' "...verdict=failed"
O=$(L n -N nice1 -d 0 --nice 5 -- "sh -c 'echo NI=\$(nice)'"); E2=$N/$(kv log "$(latt "$N")/receipt"); waitfor "$E2.rc"
w=$(( $(nice) + 5 )); [ "$w" -le 19 ] || w=19; has "$(cat "$E2")" "^NI=$w\$" "--nice 5 -> the payload runs at nice +5"

echo "-- the env gate fails closed --"
G=$(mkp gu 'WS_REMOTE_DIR=projects/gu
ENV_KIND=uv')
O=$(L gu -N g -d 0 -- c); RC=$?; [ "$RC" = 1 ] && has "$O" 'uv venv not active' "uv without the venv -> exit 1" || bad "uv without the venv (rc=$RC)"
has "$(cat "$(latt "$G")/result")" '^stage=launch rc=1 verdict=failed' "...verdict=failed"; ls "$G"/logs/g-*.log >/dev/null 2>&1 && bad "...no log" || ok "...no log, no run"
mkdir -p "$G/.venv/bin"; printf '#!/bin/sh\n' > "$G/.venv/bin/python"; chmod +x "$G/.venv/bin/python"
O=$(L gu -N g -d 0 -- c); [ "$?" = 0 ] && ok "...with the venv: launches" || bad "...with the venv: launches"
G=$(mkp gc 'WS_REMOTE_DIR=projects/gc
ENV_KIND=conda
ENV_NAME=broken')
O=$(L gc -N g -d 0 -- c); RC=$?; [ "$RC" = 1 ] && has "$O" "conda env 'broken' not active (got 'other')" "conda env not the active one -> exit 1" || bad "conda gate (rc=$RC)"
G=$(mkp gh 'WS_REMOTE_DIR=projects/gh
ENV_KIND=none
ENV_HOOK=nohook.sh')
O=$(L gh -N g -d 0 -- c); RC=$?; [ "$RC" = 1 ] && has "$O" 'containment env not loaded' "env.sh refusing -> exit 1" || bad "env.sh refusing (rc=$RC)"
has "$O" "ENV_HOOK 'nohook.sh' not found" "...with env.sh's own reason"
O=$(RUN_ENV_READY="$H/projects/gh" WS_ENV_READY="$H/projects/gh" L gh -N g -d 0 -- c); [ "$?" = 1 ] && ok "an inherited sentinel never passes the gate" || bad "an inherited sentinel passes the gate"
O=$(cd "$H/projects/gh" && HOME="$H" PATH="$T/bin:$PATH" TARGET=other-box bash .ws/launch.sh -N g -d 0 -- c 2>&1); RC=$?
[ "$RC" = 2 ] && has "$O" "deployed for target 'ws-box', not 'other-box'" "a .ws/ deployed for another box -> exit 2" || bad "other box's .ws (rc=$RC)"

echo "-- the conf cannot steer launch.sh; RUN expands as in a login shell --"
C=$(mkp cv "WS_REMOTE_DIR=projects/cv
ENV_KIND=none
NAME=evil LOG=logs/evil.log A=/nonexistent NONCE=evil UUIDS=GPU-evil TN=evil PROJ_X=1
DATA=hello
export EXPD=exp")
O=$(L cv -N cv1 -d 1 -- 'sh -c "echo data=$DATA inner=\${DATA:-unset} exp=\$EXPD cvd=\$CUDA_VISIBLE_DEVICES"'); RC=$?
[ "$RC" = 0 ] && has "$O" '^\[ws-box\] started PID' "a conf setting NAME/LOG/A/NONCE/UUIDS/TN launches as asked" || bad "conf clobber (rc=$RC)"
E3=$C/$(kv log "$(latt "$C")/receipt"); waitfor "$E3.rc"
has "$E3" '/logs/cv1-' "...the log is -N's"; [ ! -e "$C/logs/evil.log" ] && ok "...not the conf's LOG" || bad "...not the conf's LOG"
has "$(cat "$E3")" '^data=hello inner=unset exp=exp cvd=1$' "RUN sees the conf's plain variables (not exported to the run), exports, the picked ids"

echo "-- plain conf/hook variables: only those RUN names, never over the harness's CUDA env, never left on disk --"
mkdir -p "$T/ss"; printf '#!/usr/bin/env bash\nd=$(dirname "$2"); [ ! -f "$d/vars" ] || { ls -ln "$d/vars"; cat "$d/vars"; } > %q\nexec %q "$@"\n' \
  "$T/vars.seen" "$(command -v setsid)" > "$T/ss/setsid"; chmod +x "$T/ss/setsid"   # what the wrapper is handed, as it starts
V=$(mkp pv "WS_REMOTE_DIR=projects/pv
ENV_KIND=none
ENV_HOOK=hook.sh
CUDA_VISIBLE_DEVICES=0
TAG=v2 NAME=confname LOG=x DEV=9 i=7")
printf 'HF_TOKEN=hf_SECRET123\nMYV=from-hook\nPYTHONUNBUFFERED=0\nCUDA_DEVICE_ORDER=FASTEST_FIRST\n' > "$V/hook.sh"
printf 'WANDB_API_KEY=wandbSECRET\n' > "$V/.wandb_env"; chmod 600 "$V/.wandb_env"
RV='sh -c "echo cvd=\$CUDA_VISIBLE_DEVICES order=\$CUDA_DEVICE_ORDER unbuf=\$PYTHONUNBUFFERED outer=$CUDA_VISIBLE_DEVICES myv=$MYV tag=$TAG name=$NAME dev=$DEV i=$i"'
O=$( cd "$H/projects/pv" && HOME="$H" PATH="$T/ss:$T/bin:$PATH" TARGET=ws-box bash .ws/launch.sh -N pv1 -d 1 -- "$RV" 2>&1 ); RC=$?
A=$(latt "$V"); E4=$V/$(kv log "$A/receipt"); waitfor "$E4.rc"
[ "$RC" = 0 ] && has "$(cat "$E4")" '^cvd=1 order=PCI_BUS_ID unbuf=1 outer=1 ' \
  "a plain CUDA_VISIBLE_DEVICES (conf), CUDA_DEVICE_ORDER / PYTHONUNBUFFERED (hook): the harness's values reach the run" || bad "harness CUDA env wins (rc=$RC)"
has "$(cat "$E4")" ' myv=from-hook tag=v2 name=confname dev=9 i=7$' "RUN expands the conf's/hook's TAG NAME DEV i (names launch.sh uses itself) as a login shell would"
has "$(cat "$T/vars.seen" 2>/dev/null)" '^-rw-------' "the vars file handed to the wrapper is mode 600"
has "$(cat "$T/vars.seen" 2>/dev/null)" '^declare -- MYV="from-hook"$' "...and carries the plain variables RUN names"
hasnt "$(cat "$T/vars.seen" 2>/dev/null)" 'SECRET\|CUDA\|PYTHONUNBUFFERED' "...never one RUN does not name (a hook's token, .wandb_env's key) nor the harness's CUDA env"
[ ! -e "$A/vars" ] && [ -z "$(grep -rl SECRET "$V/.rs" "$V/logs" 2>/dev/null)" ] && ok "...and nothing of it stays on disk once the run started" || bad "vars left on disk"
printf 'WS_REMOTE_DIR=projects/pv\nENV_KIND=none\nENV_HOOK=hook.sh\n' > "$V/.ws.conf"; printf 'CUDA_VISIBLE_DEVICES=3\n' > "$V/hook.sh"
O=$(L pv -N pv2 -d 2 -- "$RV"); E5=$V/$(kv log "$(latt "$V")/receipt"); waitfor "$E5.rc"
has "$(cat "$E5")" '^cvd=2 order=PCI_BUS_ID unbuf=1 outer=2 ' "a plain CUDA_VISIBLE_DEVICES in the hook: the harness's ids still win"

echo "-- api=3: plan mode (every check, the env gate read-only; nothing starts or is created), --rs-expect, busy GPUs --"
blk() { printf '%s\n' "$1" | sed -n '/^@@plan v1$/,/^@@end$/p'; }   # the plan block
bnd() { printf '%s\n' "$1" | sed -n '/^kind=/,/^env_name=/p'; }   # its bound lines, which bound_hash covers
bh() { printf '%s\n' "$1" | sed -n 's/^bound_hash=//p'; }
nolog() { ! ls "$N"/logs/"$1"-*.log >/dev/null 2>&1; }
rm -f "$T/apps" "$T/apps.fail"
O=$(L n --rs-attempt pl1 --rs-mode plan -N pl1 -n 2 -x 1 --nice 3 -- "touch $T/plan-ran"); RC=$?; A=$N/.rs/attempts/pl1; B=$(blk "$O")
[ "$RC" = 0 ] && ok "plan mode exits 0" || { bad "plan mode exits 0 (rc=$RC)"; printf '%s\n' "$O" | head -8 | sed 's/^/    | /'; }
[ "$(printf '%s\n' "$B" | sed 's/=.*//' | tr '\n' ' ')" = "@@plan v1 api kind target name gpus_req exclude nice busy_ok payload env_kind env_hook venv_dir uv_sync_args env_name info_gpus info_uuids info_busy warnings warnings_avail warnings_id bound_hash @@end " ] \
  && ok "ONE block, exactly these keys in this order" || { bad "plan block keys"; printf '%s\n' "$B" | sed 's/^/    | /'; }
[ "$(printf '%s\n' "$O" | grep -c '^@@plan v1$')" = 1 ] && ok "...printed once" || bad "...printed once"
has "$B" "^api=$(sed -n 's/^api=//p' "$N/.ws/API")\$" "api= is the deployed .ws/API's"; has "$B" '^kind=nohup$' "kind=nohup"; has "$B" '^target=ws-box$' "target="
has "$B" '^name=pl1$' "name="; has "$B" '^gpus_req=n=2$' "gpus_req=n=N"; has "$B" '^exclude=1$' "exclude="; has "$B" '^nice=3$' "nice="
has "$B" "^payload=touch\\\\ $T/plan-ran\$" "payload = RUN, %q-quoted"; has "$B" '^env_kind=none$' "env_kind (the conf's)"; has "$B" "^env_name=''\$" "env_name (empty: %q '')"
has "$B" '^busy_ok=$' "busy_ok= (no --gpu-busy-ok: never a busy GPU)"; has "$B" "^env_hook=''\$" "env_hook='' (no ENV_HOOK)"; has "$B" "^venv_dir=''\$" "venv_dir"; has "$B" "^uv_sync_args=''\$" "uv_sync_args"
has "$B" '^info_gpus=2,0$' "info_gpus = the pick (envelope)"; has "$B" '^info_uuids=GPU-aaaa0000-0002,GPU-aaaa0000-0000$' "info_uuids"
has "$B" '^info_busy=$' "info_busy= (none busy)"; has "$B" '^warnings=0$' "warnings=0"
has "$B" '^warnings_avail=0$' "warnings_avail=0 (no availability -y gate on a box)"; has "$B" "^warnings_id=$(printf '' | sha256sum | cut -d' ' -f1)\$" "warnings_id = the digest of nothing"
[ "$(grep -cx '# rs-api=3' "$N/.ws/launch.sh")" = 1 ] && ok "C: the deployed launch.sh carries the '# rs-api=3' line" || bad "launch.sh: the '# rs-api=3' line"
H1=$(bh "$O"); [ "$(bnd "$O" | sha256sum | cut -d' ' -f1)" = "$H1" ] && ok "bound_hash = sha256 of the lines kind= … env_name= (each + newline)" || bad "bound_hash = sha256 of the bound lines"
has "$(cat "$A/result")" '^stage=plan rc=0 verdict=planned ' "journal: stage=plan rc=0 verdict=planned"
[ ! -e "$A/receipt" ] && [ ! -e "$A/gate" ] && [ ! -e "$A/run" ] && [ ! -e "$A/vars" ] && nolog pl1 && ok "...no receipt, gate, wrapper script or log" || bad "a plan creates nothing"
sleep 0.5; [ ! -e "$T/plan-ran" ] && ok "...and the payload never ran" || bad "plan: the payload never ran"
O=$(L n --rs-attempt pl2 --rs-mode plan --same-name-ok --gpu-busy-ok --log "logs/pl1-20260101-000000.log" -N pl1 -n 2 -x 1 --nice 3 -- "touch $T/plan-ran")
[ "$(bh "$O")" = "$H1" ] && ok "NONCE, --log, --same-name-ok, --gpu-busy-ok are not bound (same hash)" || bad "unbound flags keep the hash"
for v in "-n 3 -x 1 --nice 3" "-n 2 --nice 3" "-n 2 -x 1" "-d 2,0 -x 1 --nice 3"; do
  O=$(L n --rs-mode plan -N pl1 $v -- "touch $T/plan-ran"); [ -n "$(bh "$O")" ] && [ "$(bh "$O")" != "$H1" ] && ok "bound: '$v' changes the hash" || bad "bound: '$v' changes the hash"; done
O=$(L n --rs-mode plan -N pl1x -n 2 -x 1 --nice 3 -- "touch $T/plan-ran"); [ "$(bh "$O")" != "$H1" ] && ok "bound: the name" || bad "bound: the name"
O=$(L n --rs-mode plan -N pl1 -n 2 -x 1 --nice 3 -- "touch $T/plan-ran2"); [ "$(bh "$O")" != "$H1" ] && ok "bound: the payload" || bad "bound: the payload"
O=$(ENV_KIND=conda ENV_NAME=stale WSBOX_ENV_NAME=stale L n --rs-mode plan -N pl1 -n 2 -x 1 --nice 3 -- "touch $T/plan-ran")
[ "$(bh "$O")" = "$H1" ] && ok "exported ENV_KIND / ENV_NAME / WSBOX_ENV_NAME never reach the bound env (the conf alone)" || bad "stale exported env keys"
PC=$(mkp pc 'WS_REMOTE_DIR=projects/pc
ENV_KIND=conda
ENV_NAME=base
WSBOX_ENV_NAME=tagged
builtin() { command printf "conda\0forged\0"; }
sha256sum() { echo 0000; }
echo conf-says-hi')
O=$(L pc --rs-mode plan -N c1 -d 0 -- c); RC=$?
[ "$RC" = 0 ] && has "$(blk "$O")" '^env_kind=conda$' "conda conf: env_kind=conda (the env activates in a throwaway shell: the plan goes on)" || bad "conda plan (rc=$RC)"
has "$(blk "$O")" '^env_name=tagged$' "...env_name = WSBOX_ENV_NAME over ENV_NAME, as env.sh; a conf builtin() cannot forge it"
[ "$(bnd "$O" | sha256sum | cut -d' ' -f1)" = "$(bh "$O")" ] && ok "...and a conf sha256sum() never computes the hash" || bad "conf sha256sum() reached the hash"
hasnt "$(blk "$O")" 'conf-says-hi' "...the conf's own output stays out of the block"
PG=$(mkp pg 'WS_REMOTE_DIR=projects/pg
ENV_KIND=uv')
tree() { ( cd "$1" && find . -path ./.rs -prune -o -print | sort ); }   # the project, .rs/ left out
tree "$PG" > "$T/tree.before"
O=$(L pg --rs-attempt pg1 --rs-mode plan -N g -d 0 -- c); RC=$?
[ "$RC" = 1 ] && has "$O" '^ERROR: uv venv missing: no .*/projects/pg/\.venv/bin/python' "D10 (L4): a plan checks the env gate read-only: no venv -> exit 1, before any card" || bad "plan env check (rc=$RC)"
hasnt "$O" '^@@plan' "...no block (nothing to approve)"; has "$(cat "$PG/.rs/attempts/pg1/result")" '^stage=plan rc=1 verdict=failed ' "...journal: stage=plan rc=1"
tree "$PG" > "$T/tree.after"; cmp -s "$T/tree.before" "$T/tree.after" && ok "...and the project tree is unchanged outside .rs/ (no logs/, no cache dirs)" || { bad "a plan created project dirs"; comm -13 "$T/tree.before" "$T/tree.after" | head -5 | sed 's/^/    | /'; }
mkdir -p "$PG/.venv/bin"; printf '#!/bin/sh\n' > "$PG/.venv/bin/python"; chmod +x "$PG/.venv/bin/python"; tree "$PG" > "$T/tree.before"
O=$(L pg --rs-attempt pg2 --rs-mode plan -N g -d 0 -- c); RC=$?
[ "$RC" = 0 ] && has "$O" 'the env gate was checked read-only' "...with the venv: the plan goes on (exit 0)" || bad "plan with the venv (rc=$RC)"
has "$(blk "$O")" '^env_kind=uv$' "...a block (env_kind=uv)"; has "$(cat "$PG/.rs/attempts/pg2/result")" '^stage=plan rc=0 verdict=planned ' "...journal: planned"
tree "$PG" > "$T/tree.after"; cmp -s "$T/tree.before" "$T/tree.after" && ok "...a passing plan creates nothing outside .rs/ either" || { bad "a passing plan created project dirs"; comm -13 "$T/tree.before" "$T/tree.after" | head -5 | sed 's/^/    | /'; }
chmod -x "$PG/.venv/bin/python"; O=$(L pg --rs-mode plan -N g -d 0 -- c); [ "$?" = 1 ] && ok "...a venv python that is not executable: exit 1" || bad "non-executable venv python"
chmod +x "$PG/.venv/bin/python"
printf 'WS_REMOTE_DIR=projects/pg\nENV_KIND=uv\nVENV_DIR=$HOME/venvs/pg\n' > "$PG/.ws.conf"; O=$(L pg --rs-mode plan -N g -d 0 -- c); RC=$?
[ "$RC" = 1 ] && has "$O" "no $H/venvs/pg/bin/python" "...VENV_DIR resolved as env.sh does (\$HOME expanded): missing -> exit 1" || bad "VENV_DIR env check (rc=$RC)"
mkdir -p "$H/venvs/pg/bin"; cp "$PG/.venv/bin/python" "$H/venvs/pg/bin/"; O=$(L pg --rs-mode plan -N g -d 0 -- c); [ "$?" = 0 ] && ok "...present: exit 0" || bad "VENV_DIR present"
printf 'WS_REMOTE_DIR=projects/pg\nENV_KIND=uv\nENV_HOOK=nohook.sh\n' > "$PG/.ws.conf"; O=$(L pg --rs-mode plan -N g -d 0 -- c); RC=$?
[ "$RC" = 1 ] && has "$O" "ENV_HOOK 'nohook.sh' not found" "...an ENV_HOOK file that is missing: exit 1" || bad "missing ENV_HOOK (rc=$RC)"
printf 'WS_REMOTE_DIR=projects/pg\nENV_KIND=conda\nENV_NAME=broken\n' > "$PG/.ws.conf"; tree "$PG" > "$T/tree.before"
O=$(L pg --rs-mode plan -N g -d 0 -- c); RC=$?
[ "$RC" = 1 ] && has "$O" "conda env 'broken' does not activate here" "...a conda env that does not activate: exit 1" || bad "conda env check (rc=$RC)"
tree "$PG" > "$T/tree.after"; cmp -s "$T/tree.before" "$T/tree.after" && ok "...creating nothing" || bad "a conda env check created project dirs"
printf 'WS_REMOTE_DIR=projects/pg\nENV_KIND=uv\n' > "$PG/.ws.conf"; O=$(L pg --rs-mode plan -N g -d 0 -- c)
O=$(L pg --rs-attempt pg3 --rs-expect "$(bh "$O")" -N g -d 0 -- c); RC=$?
[ "$RC" = 0 ] && has "$O" 'started PID' "...the approved launch then passes the real gate" || bad "launch after a passing env check (rc=$RC)"
O=$(L pg --rs-mode plan -N gx -d 0 -- c); mv "$PG/.venv" "$PG/.venv-off"
O=$(L pg --rs-attempt pg4 --rs-expect "$(bh "$O")" -N gx -d 0 -- c); RC=$?; mv "$PG/.venv-off" "$PG/.venv"
[ "$RC" = 1 ] && has "$O" 'uv venv not active' "...and the real gate still runs at the launch (the venv gone since the plan: exit 1)" || bad "the env gate at the launch (rc=$RC)"
has "$(cat "$PG/.rs/attempts/pg4/result")" 'rc=1 verdict=failed' "...journal: failed, nothing started"
O=$(L n --rs-mode plan -N rcpt -d 0 -- c); RC=$?   # rcpt's first run was TERMed: the second (A2) is gone too; a live one:
O=$(L n --rs-attempt lv1 -N live1 -d 3 -- sleep 30); O=$(L n --rs-mode plan -N live1 -d 0 -- c); RC=$?
[ "$RC" = 6 ] && hasnt "$O" '^@@plan' "plan mode keeps the duplicate guard: a live same-name run -> exit 6, no block" || bad "plan + live duplicate (rc=$RC)"

O=$(L n --rs-attempt ex1 --rs-expect "$H1" -N pl1 -n 2 -x 1 --nice 3 -- "touch $T/plan-ran"); RC=$?; A=$N/.rs/attempts/ex1
[ "$RC" = 0 ] && has "$O" "^plan: bound_hash=$H1 = --rs-expect" "--rs-expect = the plan's hash: launches, saying so" || bad "--rs-expect match (rc=$RC)"
has "$(cat "$A/result")" 'verdict=launched' "...verdict=launched"; hasnt "$O" '^@@plan' "...no block on a match"
waitfor "$T/plan-ran" && ok "...the approved payload ran" || bad "...the approved payload ran"
printf 'GPU-aaaa0000-0002, %s\n' "$$" > "$T/apps"; sleep 1
O=$(L n --rs-attempt ex2 --rs-expect "$H1" --same-name-ok -N pl1 -n 2 -x 1 --nice 3 -- "touch $T/plan-ran"); RC=$?
[ "$RC" = 0 ] && has "$(cat "$N/.rs/attempts/ex2/receipt")" '^gpu_ids=0,3$' "GPU 2 busy since the plan: the pick moves (0,3), the request (bound) still matches" || bad "busy since the plan (rc=$RC)"
rm -f "$T/apps"; sleep 1   # (one name twice in one second: its log name is taken, exit 2)
O=$(L n --rs-attempt ex3 --rs-expect "$H1" -N pl1 -n 3 -x 1 --nice 3 -- "touch $T/plan-ran3"); RC=$?; A=$N/.rs/attempts/ex3
[ "$RC" = 6 ] && has "$O" '^ERROR: the resolved submission differs from the approved plan' "another -n than the plan's -> exit 6" || bad "--rs-expect mismatch (rc=$RC)"
has "$(blk "$O")" '^gpus_req=n=3$' "...printing the CURRENT block"; [ "$(bh "$O")" != "$H1" ] && ok "...with its own hash" || bad "...its own hash"
has "$(cat "$A/result")" '^stage=expect rc=6 verdict=refused ' "...journal: stage=expect rc=6 verdict=refused"
[ ! -e "$A/receipt" ] && [ ! -e "$A/run" ] && [ ! -e "$A/env.ok" ] && ok "...before the env gate and the wrapper (no run, no env.ok)" || bad "...before the wrapper"
sleep 0.5; [ ! -e "$T/plan-ran3" ] && ok "...nothing ran" || bad "...nothing ran"
printf 'WS_REMOTE_DIR=projects/n\nENV_KIND=none\nENV_NAME=drift\n' > "$N/.ws.conf"; sleep 1
O=$(L n --rs-expect "$H1" -N pl1 -n 2 -x 1 --nice 3 -- "touch $T/plan-ran"); RC=$?
[ "$RC" = 6 ] && has "$(blk "$O")" '^env_name=drift$' "a conf edited after the plan (ENV_NAME) -> exit 6" || bad "conf drift (rc=$RC)"
printf 'WS_REMOTE_DIR=projects/n\nENV_KIND=none\n' > "$N/.ws.conf"
for a in '--rs-mode apply' '--rs-mode plan --rs-mode plan' '--rs-expect abc' "--rs-expect $(printf %s "$H1" | tr a-f A-F)" '--rs-chain' '--rs-mode'; do
  O=$(L n $a -N bad1 -d 0 -- c); RC=$?; [ "$RC" = 2 ] && has "$(cat "$(latt "$N")/result")" '^stage=pre-policy rc=2 verdict=refused' "'$a' -> exit 2 (journaled)" || bad "'$a' -> exit 2 (rc=$RC)"; done
nolog bad1 && ok "...none of them launched" || bad "...none of them launched"

echo "-- busy GPUs: a compute process on it (nvidia-smi --query-compute-apps + ps) --"
( exit 0 ) & DP=$!; wait "$DP"; U=$(ps -o user= -p $$ | tr -d ' ')   # DP: a pid that is gone
printf 'GPU-aaaa0000-0001, %s\nGPU-aaaa0000-0002, %s\n' "$$" "$DP" > "$T/apps"
O=$(L n -N b1 -n 2 -- c); RC=$?
[ "$RC" = 0 ] && has "$O" 'GPU(s) \[0,3\]' "auto-pick skips busy GPUs 1, 2 (the idlest by memory are 1, 2): picks 0,3" || bad "auto-pick skips busy (rc=$RC)"
has "$O" "^\[ws-box\] GPU(s) in use (id:user:pid): 1:$U:$$,2:?:$DP\$" "names them id:user:pid (ps -o user=; a pid ps cannot see: ?)"
O=$(L n --rs-attempt b2 -N b2 -n 3 -- c); RC=$?
[ "$RC" = 1 ] && has "$O" 'only 2 GPU id(s) free' "fewer free than -n -> exit 1 (only K free)" || bad "busy shortfall (rc=$RC)"
has "$(cat "$N/.rs/attempts/b2/result")" 'rc=1 verdict=refused' "...verdict=refused"; nolog b2 && ok "...nothing launched" || bad "...nothing launched"
O=$(L n --rs-attempt b3 -N b3 -d 3,1 -- c); RC=$?
[ "$RC" = 6 ] && has "$O" '^ERROR: -d GPU(s) 1 already run a compute process' "-d onto a busy GPU -> exit 6" || bad "-d busy (rc=$RC)"
has "$(cat "$N/.rs/attempts/b3/result")" 'rc=6 verdict=refused' "...verdict=refused"; nolog b3 && ok "...nothing launched" || bad "...nothing launched"
O=$(L n --rs-attempt b4 -N b4 -d 3,1 --gpu-busy-ok -- c); RC=$?
[ "$RC" = 0 ] && has "$O" '^WARNING: -d GPU(s) 1 already run a compute process .*--gpu-busy-ok' "...with --gpu-busy-ok: launches, with a WARNING" || bad "-d busy + ok (rc=$RC)"
has "$(cat "$N/.rs/attempts/b4/receipt")" '^gpu_ids=3,1$' "...onto exactly -d"
O=$(L n -N b5 -n 3 --gpu-busy-ok -- c); RC=$?
[ "$RC" = 0 ] && has "$O" 'GPU(s) \[0,3,1\]' "auto-pick + --gpu-busy-ok: the free ones first, then the idlest busy one" || bad "auto-pick + ok (rc=$RC)"
has "$O" '^WARNING: the pick includes GPU(s) 1 ' "...saying which"
O=$(L n --rs-mode plan -N b6 -d 1 --gpu-busy-ok -- c); B=$(blk "$O")
has "$B" "^info_busy=1:$U:$$,2:?:$DP\$" "plan: info_busy=id:user:pid,…"; has "$B" '^warnings=1$' "plan: the busy WARNING is counted"
printf 'No running processes found\n' > "$T/apps"; O=$(L n -N b7 -d 1 -- c); [ "$?" = 0 ] && ok "'No running processes found' = none busy" || bad "'No running processes found'"
printf 'GPU-ffff0000-0009, 12\n' > "$T/apps"; O=$(L n -N b8 -d 0 -- c); RC=$?
[ "$RC" = 1 ] && has "$O" 'cannot tell which GPUs are busy' "a process on a GPU id the box does not list = unknown -> exit 1" || bad "unmapped uuid (rc=$RC)"
touch "$T/apps.fail"; O=$(L n --rs-attempt b9 -N b9 -d 0 -- c); RC=$?
[ "$RC" = 1 ] && has "$O" 'cannot tell which GPUs are busy' "the compute-apps query failing -> exit 1 (unknown, fail closed)" || bad "apps query fails (rc=$RC)"
nolog b9 && ok "...nothing launched" || bad "...nothing launched"
O=$(L n --rs-mode plan -N b10 -d 0 --gpu-busy-ok -- c); RC=$?
[ "$RC" = 0 ] && has "$(blk "$O")" '^info_busy=unknown$' "...--gpu-busy-ok: goes on (plan: info_busy=unknown, the WARNING counted)" || bad "unknown + ok (rc=$RC)"
has "$(blk "$O")" '^warnings=1$' "...warnings=1"; has "$(blk "$O")" '^busy_ok=unknown$' "...busy_ok=unknown (bound: a known state later is another plan)"; rm -f "$T/apps" "$T/apps.fail"

echo "-- H1: who the landing shares with is bound (busy_ok=<id>:<uuid>:<user>); another busy GPU, owner or GPU behind the id is exit 6 --"
wid() { printf '%s\n' "$1" | sed -n 's/^warnings_id=//p'; }
printf 'GPU-aaaa0000-0001, %s\n' "$$" > "$T/apps"
O=$(L n --rs-mode plan -N h1 -d 1,3 --gpu-busy-ok -- "touch $T/h1-ran"); HB=$(bh "$O"); WB=$(wid "$O")
has "$(blk "$O")" "^busy_ok=1:GPU-aaaa0000-0001:$U\$" "plan -d 1,3 --gpu-busy-ok, GPU 1 busy: busy_ok=1:<uuid>:<user> (bound)"
O=$(L n --rs-mode plan -N h1 -d 3,1 --gpu-busy-ok -- c); has "$(blk "$O")" "^busy_ok=1:GPU-aaaa0000-0001:$U\$" "...whatever the -d order"
O=$(L n --rs-mode plan -N h1 -d 3,01 --gpu-busy-ok -- c); has "$(blk "$O")" "^busy_ok=1:GPU-aaaa0000-0001:$U\$" "...-d 01 is GPU 1 (base 10)"
printf 'GPU-aaaa0000-0001, %s\nGPU-aaaa0000-0001, %s\n' "$$" "$DP" > "$T/apps"
O=$(L n --rs-mode plan -N h1 -d 1,3 --gpu-busy-ok -- c); has "$(blk "$O")" "^busy_ok=1:GPU-aaaa0000-0001:?,1:GPU-aaaa0000-0001:$U\$" "two owners on one GPU: one entry each, sorted (a pid ps cannot see: ?)"
printf 'GPU-aaaa0000-0001, %s\n' "$DP" > "$T/apps"; : > "$N/1:GPU-aaaa0000-0001:x"   # an entry ending in '?' is no glob over the project's files
O=$(L n --rs-mode plan -N h1 -d 1,3 --gpu-busy-ok -- c); has "$(blk "$O")" "^busy_ok=1:GPU-aaaa0000-0001:?\$" "...a '?' owner stays '?' next to a file it would glob to"; rm -f "$N/1:GPU-aaaa0000-0001:x"
printf 'GPU-aaaa0000-0001, %s\nGPU-aaaa0000-0003, %s\n' "$$" "$$" > "$T/apps"
O=$(L n --rs-attempt h1x --rs-expect "$HB" --rs-warnings "$WB" -N h1 -d 1,3 --gpu-busy-ok -- "touch $T/h1-ran"); RC=$?
[ "$RC" = 6 ] && has "$(blk "$O")" "^busy_ok=1:GPU-aaaa0000-0001:$U,3:GPU-aaaa0000-0003:$U\$" "GPU 3 busy too since the approval -> exit 6" || bad "a newly busy GPU in the landing (rc=$RC)"
has "$O" '^changed: busy_ok warnings$' "H1-msg: ...changed: busy_ok warnings (read from the approved plan's journal)"
has "$(cat "$N/.rs/attempts/h1x/result")" 'rc=6 verdict=refused' "...refused"; nolog h1 && ok "...nothing launched" || bad "...nothing launched (h1)"
U1=$(ps -o user= -p 1 2>/dev/null | tr -d ' ')
if [ -n "$U1" ] && [ "$U1" != "$U" ]; then   # H1-owner: the same GPU, another user's process (pid 1) since the approval
  printf 'GPU-aaaa0000-0001, 1\n' > "$T/apps"
  O=$(L n --rs-attempt h1o --rs-expect "$HB" --rs-warnings "$WB" -N h1 -d 1,3 --gpu-busy-ok -- "touch $T/h1-ran"); RC=$?
  [ "$RC" = 6 ] && has "$(blk "$O")" "^busy_ok=1:GPU-aaaa0000-0001:$U1\$" "H1-owner: GPU 1 now held by $U1, not $U: exit 6" || bad "owner swap on the approved GPU (rc=$RC)"
  has "$O" '^changed: busy_ok' "...changed: busy_ok"; nolog h1 && ok "...nothing launched (owner swap)" || bad "...launched onto another user's GPU"
else echo "  SKIP: pid 1 runs as $U here: the owner-swap check needs another user's process"; fi
printf '0, GPU-aaaa0000-0000, 8000\n1, GPU-aaaa0000-0009, 2\n2, GPU-aaaa0000-0002, 5\n3, GPU-aaaa0000-0003, 9000\n' > "$T/gpus"; printf 'GPU-aaaa0000-0009, %s\n' "$$" > "$T/apps"
O=$(L n --rs-attempt h1u --rs-expect "$HB" --rs-warnings "$WB" -N h1 -d 1,3 --gpu-busy-ok -- "touch $T/h1-ran"); RC=$?; rm -f "$T/gpus"
[ "$RC" = 6 ] && has "$(blk "$O")" "^busy_ok=1:GPU-aaaa0000-0009:$U\$" "H1-uuid: id 1 is another physical GPU since the approval: exit 6" || bad "GPU re-index under the approved id (rc=$RC)"
printf 'GPU-aaaa0000-0001, %s\n' "$$" > "$T/apps"
O=$(L n --rs-attempt h1w --rs-expect "$HB" -N h1 -d 1,3 --gpu-busy-ok -- "touch $T/h1-ran"); RC=$?
[ "$RC" = 6 ] && has "$O" "differs from the approved plan: its 1 warning(s) are not the approved card's" "the same landing, no --rs-warnings (= no warning): its WARNING is new -> exit 6" || bad "launch.sh warnings_id (rc=$RC)"
has "$O" '^changed: warnings$' "...changed: warnings"
O=$(L n --rs-attempt h1y --rs-expect "$HB" --rs-warnings "$WB" -N h1 -d 1,3 --gpu-busy-ok -- "touch $T/h1-ran"); RC=$?
[ "$RC" = 0 ] && has "$O" "its 1 warning(s) = the approved card's (warnings_id)" "the approved occupants and warnings, unchanged: launches" || bad "approved busy launch (rc=$RC)"
waitfor "$T/h1-ran" && ok "...the payload ran" || bad "...the payload ran (h1)"
for a in '--rs-warnings 1' '--rs-warnings x' "--rs-expect $HB --rs-warnings" "--rs-expect $HB --rs-warnings 1" "--rs-expect $HB --rs-warnings $(printf %s "$WB" | tr a-f A-F)"; do
  O=$(L n $a -N bad2 -d 0 -- c); RC=$?; [ "$RC" = 2 ] && ok "'${a:0:40}' -> exit 2" || bad "'$a' -> exit 2 (rc=$RC)"; done
for a in '-N --rs-chain' '-d --rs-mode' '--log --rs-x' '--nice --rs-expect'; do   # an --rs- word as an option's value
  O=$(L n $a -d 0 -- c); RC=$?; [ "$RC" = 2 ] && ok "--rs- value: '$a' -> exit 2" || bad "--rs- value: '$a' -> exit 2 (rc=$RC)"; done
rm -f "$T/apps"
O=$(L n --rs-mode plan -N ch1 -n 2 -- c); HC=$(bh "$O")
O=$(L n --rs-expect "$HC" -N ch1 -n 3 --nice 2 -- c); RC=$?
[ "$RC" = 6 ] && has "$O" '^changed: gpus_req nice$' "H1-msg: another -n and --nice than the plan's: changed: gpus_req nice" || bad "changed: line (rc=$RC)"
O=$(L n --rs-expect "$(printf %s "$HC" | tr 0-9a-f 1-9a-f0)" -N ch1 -n 2 -- c); RC=$?
[ "$RC" = 6 ] && hasnt "$O" '^changed:' "...no plan with that hash in the journal: no changed: line (rsk compares its stored card)" || bad "unknown expect (rc=$RC)"

echo "-- D: busy GPUs read without a temp file: a full \$TMPDIR under bash 4.2 heredocs never reads as 'none busy' --"
hasnt "$(sed -n '/^BUSY=""; BROWS/,/^else BUSY=unknown/p' "$RS_HOME/remote/launch.sh")" '<<' "the busy parse has no heredoc / here-string"
hasnt "$(grep -v '^ *#' "$RS_HOME/remote/launch.sh")" '<<' "launch.sh has no heredoc / here-string at all (the wrapper is a literal)"
if fulltmp_ok; then
  printf 'GPU-aaaa0000-0000, %s\nGPU-aaaa0000-0003, %s\n' "$$" "$$" > "$T/apps"
  O=$(cd "$H/projects/n" && fulltmp env HOME="$H" PATH="$T/bin:$PATH" TARGET=ws-box bash .ws/launch.sh --rs-mode plan -N ft -d 0 -- c 2>&1); RC=$?
  [ "$RC" = 6 ] && has "$O" '^ERROR: -d GPU(s) 0 already run a compute process' "TMPDIR full, BASH_COMPAT=42: -d onto busy GPU 0 is still exit 6" || bad "full TMPDIR: -d busy (rc=$RC)"
  O=$(cd "$H/projects/n" && fulltmp env HOME="$H" PATH="$T/bin:$PATH" TARGET=ws-box bash .ws/launch.sh --rs-mode plan -N ft -n 4 -- c 2>&1); RC=$?
  [ "$RC" = 1 ] && has "$O" 'only 2 GPU id(s) free' "...and -n 4 with 2 busy: exit 1, only 2 free" || bad "full TMPDIR: -n 4 (rc=$RC)"
  rm -f "$T/apps"   # the wrapper is written without a heredoc too: a launch on a full TMPDIR starts (2fd4991: cannot write …/run)
  O=$(cd "$H/projects/n" && fulltmp env HOME="$H" PATH="$T/bin:$PATH" TARGET=ws-box bash .ws/launch.sh -N ftl -d 2 -- sleep 30 2>&1); RC=$?; A=$(latt "$N")
  [ "$RC" = 0 ] && has "$O" '^\[ws-box\] started PID [0-9]* on GPU(s) 2 ' "TMPDIR full, BASH_COMPAT=42: a launch still writes its wrapper and starts" || { bad "full TMPDIR: launch (rc=$RC)"; printf '%s\n' "$O" | tail -3 | sed 's/^/    | /'; }
  [ -n "$A" ] && head -n 1 "$A/run" 2>/dev/null | grep -q '^_rw_a=' && tail -n 1 "$A/run" | grep -qx '_rw_fin "$_rw_rc" ""' && ok "...the wrapper file: its variables, then the whole literal" || bad "...the wrapper file"
  P=$(kv pid "$A/receipt"); [ -n "$P" ] && kill -TERM -- "-$P" 2>/dev/null; waitfor "$N/$(kv log "$A/receipt").rc" && has "$(cat "$N/$(kv log "$A/receipt").rc")" '^rc=143 term=1 at=[0-9]*$' "...and its TERM path writes <log>.rc as before" || bad "...<log>.rc after TERM"
else echo "  SKIP: no user namespace here (unshare -rm) or heredocs do not fail on a full TMPDIR: the full-TMPDIR check runs on Linux"; fi

echo "-- an OLD launch.sh (P2) given the api=3 flags exits 2 and starts nothing --"
if OLDL=$(git -C "$RS_HOME" show 8560838:remote/launch.sh 2>/dev/null) && [ -n "$OLDL" ]; then
  OL=$(mkp oldl 'WS_REMOTE_DIR=projects/oldl
ENV_KIND=none'); printf '%s\n' "$OLDL" > "$OL/.ws/launch.sh"
  for a in '--rs-mode plan' "--rs-expect $H1" '--gpu-busy-ok'; do
    O=$(L oldl $a -N o1 -d 0 -- "touch $T/old-ran"); RC=$?; [ "$RC" = 2 ] && has "$O" 'unknown arg' "P2 launch.sh + '${a:0:24}': exit 2 (unknown arg)" || bad "P2 launch.sh + '$a' (rc=$RC)"; done
  sleep 0.5; [ ! -e "$T/old-ran" ] && ! ls "$OL"/logs/o1-* >/dev/null 2>&1 && ok "...nothing launched" || bad "...nothing launched"
else echo "  SKIP: no git history (an installed copy): the old-launch.sh check runs in the clone"; fi
if OLDL=$(git -C "$RS_HOME" show e612ef6:remote/launch.sh 2>/dev/null) && [ -n "$OLDL" ]; then
  OL=$(mkp oldl3 'WS_REMOTE_DIR=projects/oldl3
ENV_KIND=none'); printf '%s\n' "$OLDL" > "$OL/.ws/launch.sh"
  O=$(L oldl3 --rs-expect "$H1" --rs-warnings 0 -N o3 -d 0 -- "touch $T/old3-ran"); RC=$?
  [ "$RC" = 2 ] && has "$O" "unknown arg '--rs-warnings'" "e612ef6 launch.sh (api=3 before --rs-warnings) + --rs-warnings: exit 2" || bad "e612ef6 launch.sh + --rs-warnings (rc=$RC)"
  sleep 0.5; [ ! -e "$T/old3-ran" ] && ok "...nothing launched" || bad "...nothing launched (e612ef6)"
else echo "  SKIP: no git history (e612ef6): the old-launch.sh check runs in the clone"; fi

echo "-- CUDA numbers GPUs as nvidia-smi does under PCI_BUS_ID (opt-in, needs a real GPU: RS_GPU_TEST=1 bash selftest.sh) --"
# libcuda via ctypes (stdlib only): with CUDA_DEVICE_ORDER=PCI_BUS_ID, CUDA_VISIBLE_DEVICES=<nvidia-smi ids> lists exactly
# those GPUs in that order (cuda:0 = the first id; checked by UUID) — launch.sh's ids mean what nvidia-smi showed.
CU='import ctypes
c = ctypes.CDLL("libcuda.so.1"); r = c.cuInit(0); n = ctypes.c_int(); out = []
if r == 0: c.cuDeviceGetCount(ctypes.byref(n))
for i in range(n.value):
    d = ctypes.c_int(); c.cuDeviceGet(ctypes.byref(d), i); u = (ctypes.c_ubyte * 16)(); c.cuDeviceGetUuid(u, d); h = bytes(u).hex()
    out.append("GPU-%s-%s-%s-%s-%s" % (h[:8], h[8:12], h[12:16], h[16:20], h[20:]))
print("init=%d n=%d %s" % (r, n.value, ",".join(out)))'
if [ "${RS_GPU_TEST:-0}" = 1 ] && U=$(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null) && [ -n "$U" ] && command -v python3 >/dev/null; then
  I=$(nvidia-smi --query-gpu=index --format=csv,noheader | tr -d ' ')   # nvidia-smi's own order: index i <-> UUID line i
  ALL=$(printf '%s\n' "$U" | tr -d ' ' | paste -sd, -); REV=$(printf '%s\n' "$U" | tr -d ' ' | tac | paste -sd, -)
  IALL=$(printf '%s\n' "$I" | paste -sd, -); IREV=$(printf '%s\n' "$I" | tac | paste -sd, -)
  has "$(CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES="$IREV" python3 -I -c "$CU")" "^init=0 n=$(printf '%s\n' "$U" | wc -l) $REV\$" "ids $IREV under PCI_BUS_ID = those nvidia-smi GPUs, in that order"
  has "$(CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES="$IALL" python3 -I -c "$CU")" " $ALL\$" "all ids in index order = nvidia-smi's UUID order"
else echo "  SKIP: CUDA id-order check (set RS_GPU_TEST=1 on a machine with a GPU)"; fi
