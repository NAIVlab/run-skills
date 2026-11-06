#!/usr/bin/env bash
# tests/61-launch-remote.sh — phase A: the deployed .ws/launch.sh itself, run here as run-launch's ssh would run it
# (cwd = $HOME/projects/<p>, TARGET set; real setsid/sleep/kill, stub nvidia-smi with UUIDs). Covers: the attempt
# journal (claim, out/err replay, stage, result, receipt fields), a dead caller loses nothing, NONCE reuse (75), the env
# gate fail-closed paths, the duplicate guard by live triple, GPU ids (+ UUIDs in the receipt), NICE, group/wrapper TERM -> rc=143 term=1,
# no payload without a confirmed gate, the conf cannot steer launch.sh, RUN's plain conf/hook variables (named ones only,
# mode 600, deleted once read; the harness's CUDA env wins), nested launches, status.sh / rsk reading the run, api=3 (the
# plan block, --rs-expect, the P2 launch.sh given its flags), busy GPUs (--query-compute-apps, --gpu-busy-ok, the occupants
# bound), the plan's read-only env check (D10), a full $TMPDIR under bash 4.2 heredocs (fulltmp), a RUN whose leading
# words set or clear a GPU variable (exit 2 before the claim; once expanded, the wrapper refuses to start it), a RUN whose TEXT
# does so anywhere (R5-3: exit 2 before the claim) or empties the whole environment anywhere (R6-6: env -i …), a launcher given
# GPU flags (R5-2: a counted WARNING), or GPUs by its config (R6-3: accelerate's gpu_ids, deepspeed's /job/hostfile) or a
# container runtime (R6-2: docker --gpus …, apptainer --cleanenv …; APPTAINERENV_NAME= refused), a tool that starts the
# command without this launch's environment or elsewhere (R7-3: docker exec, tmux new, sudo without -E, ssh …: a counted WARNING),
# accelerate's config unknown (R7-4: ENV_HOOK, a conf or RUN naming HF_HOME / ACCELERATE_…; R8-4: ENV_KIND=conda; NF7: a
# .wandb_env assigning them, or unreadable), those WARNINGs counted apart as warnings_gpu (NF8: never grant-covered), the configs /
# hostfile read bound as launch_cfg (R7-5: an edit after the card is exit 6; R8-5: deepspeed -H / --hostfile FILE too), tmux
# commands by any prefix tmux takes (R8-6: split, spl, run-, i …), info_prior (R5-4).
# Run by selftest.sh with RS_HOME set:  bash tests/61-launch-remote.sh
set -u
. "$RS_HOME/tests/lib.sh"
if [ ! -r /proc/self/stat ] || ! command -v setsid >/dev/null 2>&1; then
  echo "  SKIP: 61-launch-remote — launch.sh is a Linux remote script (/proc, setsid); run selftest on Linux for it"; exit 0; fi
H=$T/home; mkdir -p "$H/projects" "$H/miniconda3/etc/profile.d"
# conda stub: `conda activate ENV` sets CONDA_DEFAULT_ENV and, as conda's activator does with the env's own variables
# (`conda env config vars set HF_HOME=…`), exports HF_HOME when the env has one (here: <env>/hf_home; R8-4)
printf '%s\n' 'conda() { case "$1" in activate) [ "$2" = broken ] && export CONDA_DEFAULT_ENV=other || export CONDA_DEFAULT_ENV=$2' \
  '    [ ! -f "$HOME/miniconda3/envs/$2/hf_home" ] || export HF_HOME="$(cat "$HOME/miniconda3/envs/$2/hf_home")" ;; *) return 1 ;; esac; }' \
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
trap 'reap; [ -z "${SP:-}" ] || kill $SP 2>/dev/null; rm -rf "$T"' EXIT   # (SP: pids, unquoted)
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
# the wrapper's wait loop, as shipped, with `wait` / `kill` stubbed: after a trap interrupted the first wait (>128) and the
# run is gone, a second wait that cannot give the run's status (127: not a child; a status outside 0-255, which bash 5.2.37's
# wait returned under load: the integrator's stress run wrote rc=-1 term=1) keeps the first — <log>.rc stays rc=<0-255>
WL=$(sed -n '/^while :; do   # >128 = the status of the payload/,/^done$/p' "$RS_HOME/remote/launch.sh")
for c in "127:143" "0:0" "3:3" "143:143"; do   # the second wait's status : the rc the loop must keep
  O=$(bash -c 'w2=$1 n=0; wait() { n=$((n + 1)); [ "$n" = 1 ] && return 143; return "$w2"; }; kill() { return 1; }; _rw_c=1
    eval "$2"; echo "rc=$_rw_rc"' _ "${c%%:*}" "$WL" 2>&1)
  [ -n "$WL" ] && [ "$O" = "rc=${c#*:}" ] && ok "wrapper wait loop: trap-interrupted 143, then the run gone and a second wait of ${c%%:*} -> rc=${c#*:}" \
    || bad "wrapper wait loop: second wait ${c%%:*} -> want rc=${c#*:} (got: $O)"; done
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

echo "-- R4-5: RUN never picks the GPUs: leading words that set or clear a GPU variable (also after a leading env) --"
# the facts behind it (GNU env, as on the boxes: tests/vgate/local.sh env_facts=): env's argv = RUN's words; options end at the first
# non-option, `--` ends them and a `-` then = -i, every word holding '=' before the command is an assignment — quoted or not
if env --version 2>/dev/null | grep -q 'GNU coreutils'; then
  fx() { CUDA_VISIBLE_DEVICES=5 env "$@" 2>/dev/null; }
  [ "$(fx 'CUDA_VISIBLE_DEVICES=0' printenv CUDA_VISIBLE_DEVICES)" = 0 ] && ok "fact: a (quoted) NAME=VALUE word before env's command sets NAME" || bad "fact: NAME=VALUE word"
  [ "$(fx A=1 env CUDA_VISIBLE_DEVICES=0 printenv CUDA_VISIBLE_DEVICES)" = 0 ] && ok "fact: ...also after a nested env" || bad "fact: nested env"
  for o in '-u CUDA_VISIBLE_DEVICES' '--unset=CUDA_VISIBLE_DEVICES' '--uns CUDA_VISIBLE_DEVICES' '-' '-- -' '-i'; do
    [ -z "$(fx $o printenv CUDA_VISIBLE_DEVICES)" ] && ok "fact: env $o clears it" || bad "fact: env $o clears it"; done
  [ "$(fx -S 'CUDA_VISIBLE_DEVICES=0 printenv CUDA_VISIBLE_DEVICES')" = 0 ] && ok "fact: env -S splits a string into assignments too" || bad "fact: env -S"
  fx A=1 -i printenv CUDA_VISIBLE_DEVICES; [ "$?" = 127 ] && ok "fact: options end at the first non-option (-i after A=1 is the command)" || bad "fact: options end at the first non-option"
  [ "$(fx sh -c 'echo $CUDA_VISIBLE_DEVICES' CUDA_VISIBLE_DEVICES=0)" = 5 ] && ok "fact: after the command, NAME=VALUE is the payload's argument" || bad "fact: argument after the command"
else echo "  SKIP: no GNU env here: the env facts behind R4-5 not reproduced"; fi
printf 'GPU-aaaa0000-0001, 1\n' > "$T/apps"   # GPU 1: another user's process (the finding's setup)
GV=$(mkp gv 'WS_REMOTE_DIR=projects/gv
ENV_KIND=none
PRE=CUDA_VISIBLE_DEVICES=0,1,2,3
PRINT=printenv')
i=0
for r in 'CUDA_VISIBLE_DEVICES=0,1,2,3 printenv CUDA_VISIBLE_DEVICES' '"CUDA_VISIBLE_DEVICES=0,1" printenv CUDA_VISIBLE_DEVICES' \
         "'CUDA_VISIBLE_DEVICES'=0 python t.py" 'C\UDA_VISIBLE_DEVICES=0 python t.py' 'OMP_NUM_THREADS=4 CUDA_DEVICE_ORDER=FASTEST_FIRST python t.py' \
         'NVIDIA_VISIBLE_DEVICES=all python t.py' 'HIP_VISIBLE_DEVICES=1 python t.py' 'ROCR_VISIBLE_DEVICES=1 python t.py' \
         'env CUDA_VISIBLE_DEVICES=0 python t.py' '/usr/bin/env -v A=1 env CUDA_VISIBLE_DEVICES=0 python t.py' 'env -u CUDA_VISIBLE_DEVICES python t.py' \
         'env -uCUDA_DEVICE_ORDER python t.py' '-i python t.py' '- python t.py' 'env -- - python t.py' 'env -S "CUDA_VISIBLE_DEVICES=0 python t.py"' \
         'env --uns CUDA_VISIBLE_DEVICES python t.py' 'CUDA_VISIBLE_DEVICES=$X python t.py' 'CUDA_VISIBLE_DEVICES={0,1} python t.py'; do
  i=$((i + 1)); O=$(L gv --rs-attempt cv$i -N cv$i -n 1 -- "$r"); RC=$?
  [ "$RC" = 2 ] && has "$O" "^ERROR: RUN .* — the GPUs are launch.sh's choice" "R4-5: RUN $r -> exit 2" || { bad "R4-5: RUN $r -> exit 2 (rc=$RC)"; printf '%s\n' "$O" | head -3 | sed 's/^/    | /'; }
  [ ! -e "$GV/.rs/attempts/cv$i" ] && ! ls "$GV"/logs/cv$i-*.log >/dev/null 2>&1 && ok "...before the claim: no attempt dir, no log" || bad "...before the claim (cv$i)"
done
has "$O" "sets CUDA_VISIBLE_DEVICES before its command ('CUDA_VISIBLE_DEVICES=')" "...an assignment whose value expands is still one of that name"
O=$(LC_ALL=C.UTF-8 L gv -N cvm -n 1 -- 'TAG="ünï code" CUDA_VISIBLE_DEVICES=ü python t.py "é"'); RC=$?   # read as bytes: multibyte text kept whole
[ "$RC" = 2 ] && has "$O" "sets CUDA_VISIBLE_DEVICES before its command ('CUDA_VISIBLE_DEVICES=ü')" "R4-5: multibyte words around it: still found, quoted back intact" || bad "R4-5: multibyte RUN (rc=$RC)"
O=$(L gv --rs-attempt cvp -N cvp --rs-mode plan -n 1 -- 'CUDA_VISIBLE_DEVICES=0,1,2,3 python t.py'); RC=$?
[ "$RC" = 2 ] && hasnt "$O" '^@@plan' "R4-5: a plan of such a RUN: exit 2, no block (no card to approve)" || bad "R4-5: plan of such a RUN (rc=$RC)"
O=$(L gv -N cvok -d 2 -- 'OMP_NUM_THREADS=4 sh -c "echo cvd=\$CUDA_VISIBLE_DEVICES omp=\$OMP_NUM_THREADS \$0" GPU_NOTE=9'); RC=$?
E6=$GV/$(kv log "$(latt "$GV")/receipt"); waitfor "$E6.rc"
[ "$RC" = 0 ] && has "$(cat "$E6")" '^cvd=2 omp=4 GPU_NOTE=9$' "R4-5: another leading assignment, and a NAME=VALUE argument AFTER the command: launched, the harness's ids" || bad "R4-5: plain RUN launched (rc=$RC)"
O=$(L gv -N cvu -d 2 -- 'env -v -C . -u FOO printenv CUDA_VISIBLE_DEVICES'); E7=$GV/$(kv log "$(latt "$GV")/receipt"); waitfor "$E7.rc"
has "$(cat "$E7")" '^2$' "R4-5: env -v -C DIR -u OTHER pass (they leave the GPU variables alone)"
has "$(cat "$(latt "$GV")/run")" '^rs_gpuenv ()' "...the wrapper carries the same check (rs_gpuenv)"
i=0; for r in '$PRE printenv CUDA_VISIBLE_DEVICES' '"$PRE" printenv CUDA_VISIBLE_DEVICES' 'env $PRE printenv CUDA_VISIBLE_DEVICES > rt.out'; do
  i=$((i + 1)); O=$(L gv -N cvr$i -d 2 -- "$r"); RC=$?; A=$(latt "$GV"); E8=$GV/$(kv log "$A/receipt"); waitfor "$E8.rc"
  [ "$RC" = 0 ] && has "$(cat "$E8")" "ERROR: RUN sets CUDA_VISIBLE_DEVICES before its command ('CUDA_VISIBLE_DEVICES=0,1,2,3') — not started" \
    "R4-5: RUN $r (a conf variable: known only once expanded) — the wrapper refuses it" || bad "R4-5: runtime refusal of $r (rc=$RC)"
  has "$(cat "$E8.rc")" '^rc=2 term=0 ' "...rc=2"; hasnt "$(cat "$E8" "$GV/rt.out" 2>/dev/null)" '^0,1,2,3$' "...and the payload never ran"
done
O=$(L gv -N cvd -d 2 -- '$PRINT CUDA_VISIBLE_DEVICES'); E9=$GV/$(kv log "$(latt "$GV")/receipt"); waitfor "$E9.rc"
has "$(cat "$E9")" '^2$' "R4-5: an expanded word that sets nothing (the command): runs, with the harness's ids"
rm -f "$T/apps"

echo "-- R5-3: RUN's TEXT that assigns or clears a GPU variable ANYWHERE (a later pipeline element, a wrapper before env, bash -c, a container's --env) --"
# the facts (bash + coreutils here, as on the boxes): each of these reaches the process it starts, past the leading-word check
fy() { CUDA_VISIBLE_DEVICES=5 bash -c "$1" 2>/dev/null; }
[ "$(fy 'echo x | CUDA_VISIBLE_DEVICES=0,1 printenv CUDA_VISIBLE_DEVICES')" = 0,1 ] && ok "fact: a later pipeline element's NAME=VALUE sets it for that command" || bad "fact: pipeline element"
if command -v timeout >/dev/null 2>&1; then [ "$(fy 'timeout 5 env CUDA_VISIBLE_DEVICES=0,1 printenv CUDA_VISIBLE_DEVICES')" = 0,1 ] \
  && ok "fact: a wrapper (timeout) before env: env still sets it" || bad "fact: timeout env"; else echo "  SKIP: no timeout(1) here"; fi
[ "$(fy 'true; unset -v A CUDA_VISIBLE_DEVICES; printenv CUDA_VISIBLE_DEVICES')" = "" ] && ok "fact: a later 'unset … NAME' clears it" || bad "fact: unset"
[ "$(fy 'export -n CUDA_VISIBLE_DEVICES; printenv CUDA_VISIBLE_DEVICES')" = "" ] && ok "fact: 'export -n NAME' takes it from the commands' environment" || bad "fact: export -n"
[ "$(fy 'declare +x CUDA_VISIBLE_DEVICES; printenv CUDA_VISIBLE_DEVICES')" = "" ] && ok "fact: 'declare +x NAME' too" || bad "fact: declare +x"
[ "$(fy 'CUDA_VISIBLE_DEVICES+=,7; printenv CUDA_VISIBLE_DEVICES')" = 5,7 ] && ok "fact: NAME+=… appends to it" || bad "fact: +="
[ "$(fy 'x=$(CUDA_VISIBLE_DEVICES=0 printenv CUDA_VISIBLE_DEVICES); echo $x')" = 0 ] && ok "fact: inside \$( ) as well" || bad "fact: command substitution"
printf 'GPU-aaaa0000-0001, 1\n' > "$T/apps"   # GPU 1: another user's process (round 4's setup: a 1-GPU landing elsewhere)
i=0
for r in 'echo start | CUDA_VISIBLE_DEVICES=0,1,2,3 printenv CUDA_VISIBLE_DEVICES' 'timeout 1h env CUDA_VISIBLE_DEVICES=0,1,2,3 printenv CUDA_VISIBLE_DEVICES' \
         'nice -n 5 env CUDA_VISIBLE_DEVICES=0,1 python t.py' 'stdbuf -oL env NVIDIA_VISIBLE_DEVICES=all python t.py' 'bash -c "CUDA_VISIBLE_DEVICES=0 python t.py"' \
         "sh -c 'export CUDA_VISIBLE_DEVICES=0; python t.py'" 'docker run --env CUDA_VISIBLE_DEVICES=0 img' 'docker run --env=NVIDIA_VISIBLE_DEVICES=all img' \
         'docker run -e "NVIDIA_VISIBLE_DEVICES=all" img' 'python a.py && unset CUDA_VISIBLE_DEVICES && python b.py' 'cd x; unset -v A HIP_VISIBLE_DEVICES; y' \
         'x | env -u CUDA_VISIBLE_DEVICES y' 'x | env --unset=ROCR_VISIBLE_DEVICES y' 'x | env --uns CUDA_DEVICE_ORDER y' "x; 'CUDA_VISIBLE_DEVICES'=0 y" \
         'x; C\UDA_VISIBLE_DEVICES=0 y' 'bash -c "export CUDA_VISIBLE_DEVICES+=,1; y"' 'bash -c "export -n CUDA_VISIBLE_DEVICES; y"' 'x $(CUDA_VISIBLE_DEVICES=0 y)' \
         'sh -c "echo" CUDA_VISIBLE_DEVICES=9' "$(printf 'echo a\nCUDA_DEVICE_ORDER=FASTEST_FIRST y')" 'bash -c "declare +x CUDA_VISIBLE_DEVICES; y"'; do
  i=$((i + 1)); O=$(L gv --rs-attempt tx$i -N tx$i -n 1 -- "$r"); RC=$?
  [ "$RC" = 2 ] && has "$O" "^ERROR: RUN \(sets\|clears\) [A-Z_]* in its text .* — the GPUs are launch.sh's choice" "R5-3: RUN $(printf %s "$r" | tr '\n' ' ') -> exit 2" \
    || { bad "R5-3: RUN $r -> exit 2 (rc=$RC)"; printf '%s\n' "$O" | head -3 | sed 's/^/    | /'; }
  [ ! -e "$GV/.rs/attempts/tx$i" ] && ! ls "$GV"/logs/tx$i-*.log >/dev/null 2>&1 && ok "...before the claim: no attempt dir, no log" || bad "...before the claim (tx$i)"
done
O=$(L gv --rs-attempt txp --rs-mode plan -N txp -n 1 -- 'echo start | CUDA_VISIBLE_DEVICES=0,1,2,3 python t.py'); RC=$?
[ "$RC" = 2 ] && hasnt "$O" '^@@plan' "R5-3: a plan of such a RUN: exit 2, no block (no card to approve)" || bad "R5-3: plan of such a RUN (rc=$RC)"
O=$(L gv -N txok -d 2 -- 'printenv CUDA_VISIBLE_DEVICES | cat; echo "$CUDA_DEVICE_ORDER" | tr A-Z a-z; env -u FOO sh -c "echo \${CUDA_VISIBLE_DEVICES:-none}"'); RC=$?
E10=$GV/$(kv log "$(latt "$GV")/receipt"); waitfor "$E10.rc"
[ "$RC" = 0 ] && [ "$(grep -v '^\[' "$E10" | tr '\n' ' ')" = "2 pci_bus_id 2 " ] && ok "R5-3: a RUN that only READS them (pipelines, \$NAME, \${NAME:-…}, env -u OTHER) launches, with the harness's ids" \
  || { bad "R5-3: reads only (rc=$RC)"; sed 's/^/    | /' "$E10" | head -5; }

echo "-- R6-6: RUN's TEXT that empties the whole environment ANYWHERE (env -i / env - / --ignore-environment) --"
# the facts (GNU env, as on the boxes: tests/vgate/local.sh env_anywhere=): after a wrapper (timeout), and after env's other
# options, each empties the environment the harness's CUDA_VISIBLE_DEVICES is in; -S's string is read as options too
if env --version 2>/dev/null | grep -q 'GNU coreutils' && command -v timeout >/dev/null 2>&1; then
  for o in '-i' '-' '-v -i' '-vi' '-u FOO -i' '-C / -- -' '--ignore-environment' '--ignore-e' "-S '-i printenv CUDA_VISIBLE_DEVICES'"; do
    c="timeout 5 env $o printenv CUDA_VISIBLE_DEVICES"; case "$o" in -S*) c="timeout 5 env $o" ;; esac
    [ "$(fy "$c")" = "" ] && ok "fact: $c -> unset" || bad "fact: $c -> unset"; done
  [ "$(fy 'timeout 5 env --i printenv CUDA_VISIBLE_DEVICES; echo rc=$?')" = rc=125 ] || [ "$(fy 'timeout 5 env --i printenv CUDA_VISIBLE_DEVICES')" = "" ] \
    && ok "fact: env --i is ambiguous in a newer env (125, nothing runs) or --ignore-environment in an older one" || bad "fact: env --i"
  [ "$(fy 'timeout 5 env A=1 -i printenv CUDA_VISIBLE_DEVICES; echo rc=$?')" = rc=127 ] && ok "fact: -i after NAME=VALUE is the command (options ended)" || bad "fact: -i after an assignment"
else echo "  SKIP: no GNU env / timeout here: the env facts behind R6-6 not reproduced"; fi
i=0
for r in "timeout 1h env -i PATH=/usr/bin:/bin sh -c 'echo CVD=\${CUDA_VISIBLE_DEVICES-unset}'" "nice -n 5 env - PATH=/usr/bin:/bin sh -c 'echo x'" \
         "echo go | env --ignore-environment PATH=/usr/bin:/bin sh -c 'echo x'" 'x | env --ig y' 'x | env -v -i y' 'x | env -u FOO -i y' 'x; env -vi y' \
         'x | env -C /tmp -- - y' "x; env -S'-i y'" 'x | env -S "-i y"' 'x | env --split-string=-i y' 'x | /usr/bin/env -0i y' 'x | "env" "-i" y' 'x | e\nv -i y' \
         'x | env --uns=FOO -i y' 'x | env --chdir /tmp -i y' 'x | env --ignore-signal -i y'; do
  i=$((i + 1)); O=$(L gv --rs-attempt ei$i -N ei$i -n 1 -- "$r"); RC=$?
  [ "$RC" = 2 ] && has "$O" "^ERROR: RUN empties the whole environment in its text ('env .*': the harness's CUDA_VISIBLE_DEVICES and CUDA_DEVICE_ORDER would go .* — the GPUs are launch.sh's choice" "R6-6: RUN $r -> exit 2" \
    || { bad "R6-6: RUN $r -> exit 2 (rc=$RC)"; printf '%s\n' "$O" | head -3 | sed 's/^/    | /'; }
  [ ! -e "$GV/.rs/attempts/ei$i" ] && ! ls "$GV"/logs/ei$i-*.log >/dev/null 2>&1 && ok "...before the claim: no attempt dir, no log" || bad "...before the claim (ei$i)"
done
O=$(L gv --rs-attempt eip --rs-mode plan -N eip -n 1 -- 'timeout 1h env -i PATH=/bin sh -c true'); RC=$?
[ "$RC" = 2 ] && hasnt "$O" '^@@plan' "R6-6: a plan of such a RUN: exit 2, no block (no card to approve)" || bad "R6-6: plan of such a RUN (rc=$RC)"
for r in 'python t.py -i data' 'env FOO=1 python t.py -i data' 'env -u FOO python t.py -' 'x | env A=1 -i y' 'x | env -a -i y' 'x | env -u -i y' \
         'x | env -S "A=1 -i x"' 'docker exec -it c bash' 'apptainer exec -c --nv img p' 'x | env --debug y -i' 'x | env -- y -' 'printenv -0' 'x | env'; do
  O=$(L gv --rs-mode plan -N eok -n 1 -- "$r"); RC=$?
  [ "$RC" = 0 ] && ok "R6-6: no refusal for $r (env's options end at its command; a value word is a value)" || { bad "R6-6: $r refused (rc=$RC)"; printf '%s\n' "$O" | grep ERROR | head -2 | sed 's/^/    | /'; }
done
O=$(L gv -N eiok -d 2 -- 'env -u FOO bash -c "printenv CUDA_VISIBLE_DEVICES; env -C / printenv CUDA_DEVICE_ORDER" -i'); RC=$?
E11=$GV/$(kv log "$(latt "$GV")/receipt"); waitfor "$E11.rc"
[ "$RC" = 0 ] && [ "$(grep -v '^\[' "$E11" | tr '\n' ' ')" = "2 PCI_BUS_ID " ] && ok "R6-6: env -u OTHER … -i (an argument after its command) and env -C DIR launch, with the harness's ids" \
  || { bad "R6-6: env -u / env -C launch (rc=$RC)"; sed 's/^/    | /' "$E11" | head -5; }
# round-6 integration: bash's `exec -c` empties the environment as env -i does — refused where a command starts (the facts:
# this bash; -l / -a NAME may come first, `-ac` is -a with the name c), never as a subcommand (apptainer / kubectl exec -c)
for c in 'exec -c printenv CUDA_VISIBLE_DEVICES' 'exec -l -c printenv CUDA_VISIBLE_DEVICES' 'exec -a n -c printenv CUDA_VISIBLE_DEVICES' \
         'exec -cl printenv CUDA_VISIBLE_DEVICES' 'A=1 exec -c printenv CUDA_VISIBLE_DEVICES'; do
  [ "$(fy "$c")" = "" ] && ok "fact: bash $c -> unset" || bad "fact: bash $c -> unset"; done
for c in 'exec -ac printenv CUDA_VISIBLE_DEVICES' 'exec -a -c printenv CUDA_VISIBLE_DEVICES' 'exec printenv CUDA_VISIBLE_DEVICES'; do
  [ "$(fy "$c")" = 5 ] && ok "fact: bash $c -> kept (-a takes the rest of its cluster or the next word)" || bad "fact: bash $c -> kept"; done
i=0
for r in 'exec -c python t.py' 'cd /tmp && exec -c python t.py' 'x; exec -lc y' 'x | exec -l -c y' 'exec -a n -c y' "bash -c 'exec -c y'" 'bash -c "exec -c y"' \
         'x $(exec -c y)' '{ exec -c y; }' 'if x; then exec -c y; fi' 'A=1 B=2 exec -c y' 'command exec -c y' '"exec" -c y' 'ex\ec -c y' 'exec -cl y'; do
  i=$((i + 1)); O=$(L gv --rs-attempt xc$i -N xc$i -n 1 -- "$r"); RC=$?
  [ "$RC" = 2 ] && has "$O" "^ERROR: RUN empties the whole environment in its text ('exec -c': the harness's CUDA_VISIBLE_DEVICES and CUDA_DEVICE_ORDER would go .* — the GPUs are launch.sh's choice" "exec -c: RUN $r -> exit 2" \
    || { bad "exec -c: RUN $r -> exit 2 (rc=$RC)"; printf '%s\n' "$O" | head -3 | sed 's/^/    | /'; }
  [ ! -e "$GV/.rs/attempts/xc$i" ] && ! ls "$GV"/logs/xc$i-*.log >/dev/null 2>&1 && ok "...before the claim: no attempt dir, no log" || bad "...before the claim (xc$i)"
done
for r in 'apptainer exec -c --nv img p' 'singularity exec -c img p' 'kubectl exec -c ctr pod -- p' "bash -c 'apptainer exec -c img p'" 'exec -ac y' 'exec -a -c y' \
         'exec python t.py -c' 'exec -- -c' 'x --exec -c' 'myexec -c y' 'exec -l python t.py'; do
  O=$(L gv --rs-mode plan -N xok -n 1 -- "$r"); RC=$?
  [ "$RC" = 0 ] && ok "exec -c: no refusal for $r (a subcommand, or -c is not exec's option there)" || { bad "exec -c: $r refused (rc=$RC)"; printf '%s\n' "$O" | grep ERROR | head -2 | sed 's/^/    | /'; }
done
echo "-- R6-2: APPTAINERENV_NAME= / SINGULARITYENV_NAME= set NAME inside the container: an assignment, refused like one --"
i=0
for r in 'APPTAINERENV_CUDA_VISIBLE_DEVICES=0,1 apptainer exec --nv img p' 'x; export SINGULARITYENV_NVIDIA_VISIBLE_DEVICES=all; singularity exec img p' \
         'env APPTAINERENV_CUDA_DEVICE_ORDER=FASTEST_FIRST apptainer exec img p' "bash -c 'APPTAINERENV_HIP_VISIBLE_DEVICES=1 apptainer run img'"; do
  i=$((i + 1)); O=$(L gv --rs-attempt ae$i -N ae$i -n 1 -- "$r"); RC=$?
  [ "$RC" = 2 ] && has "$O" "^ERROR: RUN sets [A-Z_]* in its text ('\(APPTAINER\|SINGULARITY\)ENV_[A-Z_]*=' .* — the GPUs are launch.sh's choice" "R6-2: RUN $r -> exit 2" \
    || { bad "R6-2: RUN $r -> exit 2 (rc=$RC)"; printf '%s\n' "$O" | head -3 | sed 's/^/    | /'; }
  [ ! -e "$GV/.rs/attempts/ae$i" ] && ok "...before the claim" || bad "...before the claim (ae$i)"
done
O=$(L gv --rs-mode plan -N aeok -n 1 -- 'MY_APPTAINERENV_X=1 APPTAINERENV_OMP_NUM_THREADS=4 apptainer exec --nv img p'); RC=$?
[ "$RC" = 0 ] && ok "R6-2: APPTAINERENV_ of another name (and a longer name ending in it) passes" || bad "R6-2: other APPTAINERENV_ names (rc=$RC)"
rm -f "$T/apps"

echo "-- api=3: plan mode (every check, the env gate read-only; nothing starts or is created), --rs-expect, busy GPUs --"
blk() { printf '%s\n' "$1" | sed -n '/^@@plan v1$/,/^@@end$/p'; }   # the plan block
bnd() { printf '%s\n' "$1" | sed -n '/^kind=/,/^env_name=/p'; }   # its bound lines, which bound_hash covers
bh() { printf '%s\n' "$1" | sed -n 's/^bound_hash=//p'; }
nolog() { ! ls "$N"/logs/"$1"-*.log >/dev/null 2>&1; }
rm -f "$T/apps" "$T/apps.fail"
O=$(L n --rs-attempt pl1 --rs-mode plan -N pl1 -n 2 -x 1 --nice 3 -- "touch $T/plan-ran"); RC=$?; A=$N/.rs/attempts/pl1; B=$(blk "$O")
[ "$RC" = 0 ] && ok "plan mode exits 0" || { bad "plan mode exits 0 (rc=$RC)"; printf '%s\n' "$O" | head -8 | sed 's/^/    | /'; }
[ "$(printf '%s\n' "$B" | sed 's/=.*//' | tr '\n' ' ')" = "@@plan v1 api kind target name gpus_req exclude nice launch_cfg busy_ok payload env_kind env_hook venv_dir uv_sync_args env_name info_gpus info_uuids info_busy info_run_gpu info_prior info_launchers warnings warnings_avail warnings_gpu warnings_id bound_hash @@end " ] \
  && ok "ONE block, exactly these keys in this order" || { bad "plan block keys"; printf '%s\n' "$B" | sed 's/^/    | /'; }
[ "$(printf '%s\n' "$O" | grep -c '^@@plan v1$')" = 1 ] && ok "...printed once" || bad "...printed once"
has "$B" "^api=$(sed -n 's/^api=//p' "$N/.ws/API")\$" "api= is the deployed .ws/API's"; has "$B" '^kind=nohup$' "kind=nohup"; has "$B" '^target=ws-box$' "target="
has "$B" '^name=pl1$' "name="; has "$B" '^gpus_req=n=2$' "gpus_req=n=N"; has "$B" '^exclude=1$' "exclude="; has "$B" '^nice=3$' "nice="
has "$B" "^payload=touch\\\\ $T/plan-ran\$" "payload = RUN, %q-quoted"; has "$B" '^env_kind=none$' "env_kind (the conf's)"; has "$B" "^env_name=''\$" "env_name (empty: %q '')"
has "$B" '^launch_cfg=$' "launch_cfg= (R7-5: no launcher config or hostfile read)"; has "$B" '^busy_ok=$' "busy_ok= (no --gpu-busy-ok: never a busy GPU)"; has "$B" "^env_hook=''\$" "env_hook='' (no ENV_HOOK)"; has "$B" "^venv_dir=''\$" "venv_dir"; has "$B" "^uv_sync_args=''\$" "uv_sync_args"
has "$B" '^info_gpus=2,0$' "info_gpus = the pick (envelope)"; has "$B" '^info_uuids=GPU-aaaa0000-0002,GPU-aaaa0000-0000$' "info_uuids"
has "$B" '^info_busy=$' "info_busy= (none busy)"; has "$B" '^info_run_gpu=checked$' "info_run_gpu=checked (R4-5: this launch.sh refuses a RUN that sets a GPU variable)"; has "$B" '^warnings=0$' "warnings=0"
has "$B" '^info_prior=0$' "info_prior=0 (R5-4: no receipt of the run pl1 in this project's journal)"
has "$B" '^info_launchers=checked$' "info_launchers=checked (round 6: launcher configs, containers, env -i anywhere — rsk needs it: an older launch.sh's card lacks those WARNINGs)"
has "$B" '^warnings_avail=0$' "warnings_avail=0 (no availability -y gate on a box)"; has "$B" '^warnings_gpu=0$' "warnings_gpu=0 (NF8: no launcher / container WARNING)"; has "$B" "^warnings_id=$(printf '' | sha256sum | cut -d' ' -f1)\$" "warnings_id = the digest of nothing"
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

echo "-- R5-2: a launcher that picks the GPUs from its own flags (deepspeed --num_gpus …, accelerate launch --gpu_ids …): a counted WARNING --"
# the argparse facts behind the spellings (stdlib, as both launchers use it): deepspeed's runner takes unique prefixes
# (ArgumentParser's default allow_abbrev) and attached short values; accelerate launch sets allow_abbrev=False. That the runner
# then ignores CUDA_VISIBLE_DEVICES, and accelerate overwrites it from --gpu_ids: their source (tests/vgate/launchers.sh reads it
# back from an installed copy, with the user's OK) — emulated by the stubs below, as round 4 did
if command -v python3 >/dev/null 2>&1; then
  F=$(python3 -I -c 'import argparse
p = argparse.ArgumentParser(); p.add_argument("-i", "--include", default=""); p.add_argument("--num_nodes"); p.add_argument("--num_gpus", "--num_accelerators"); p.add_argument("--master_port"); p.add_argument("s")
a, b = p.parse_args(["--num_g", "2", "t.py"]), p.parse_args(["-ilocalhost:1", "t.py"])
q = argparse.ArgumentParser(allow_abbrev=False); q.add_argument("--gpu_ids"); q.add_argument("s")
try:
    q.parse_args(["--gpu_i", "0", "t.py"]); c = "taken"
except SystemExit:
    c = "refused"
print(a.num_gpus, b.include, c)' 2>/dev/null)
  [ "$F" = "2 localhost:1 refused" ] && ok "fact: argparse takes --num_g for --num_gpus and -ilocalhost:1 for -i; with allow_abbrev=False --gpu_i is refused" || bad "fact: argparse spellings (got '$F')"
else echo "  SKIP: no python3 here: the argparse facts not reproduced"; fi
LR=$(mkp lr 'WS_REMOTE_DIR=projects/lr
ENV_KIND=none')
cat > "$T/bin/deepspeed" <<'EOS'
#!/usr/bin/env bash
# stub of deepspeed/launcher/runner.py main(): with --num_gpus N it prints "…but ignoring it", drops VISIBLE_DEVICES, the workers see 0..N-1
n=""; while [ $# -gt 0 ]; do case "$1" in --num_gpus) n=$2; shift 2 ;; *) break ;; esac; done
[ -z "$n" ] || { echo "Detected VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES but ignoring it"; export CUDA_VISIBLE_DEVICES=$(seq -s, 0 $((n - 1))); }
echo "worker sees CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
EOS
chmod +x "$T/bin/deepspeed"; printf 'GPU-aaaa0000-0001, 1\n' > "$T/apps"
O=$(L lr --rs-attempt dp1 --rs-mode plan -N dp -n 1 -- 'deepspeed --num_gpus 2 train.py'); RC=$?; HD=$(bh "$O"); WD=$(printf '%s\n' "$O" | sed -n 's/^warnings_id=//p')
[ "$RC" = 0 ] && ok "R5-2: plan of 'deepspeed --num_gpus 2 train.py': goes on (a warning, never a refusal)" || { bad "R5-2: plan (rc=$RC)"; printf '%s\n' "$O" | head -5 | sed 's/^/    | /'; }
has "$O" "^WARNING: RUN runs deepspeed with --num_gpus — such a launcher may ignore CUDA_VISIBLE_DEVICES and pick GPUs itself (any on the box, another user's too), not only this launch's GPU(s) \[2\]: drop those flags" "...names the launcher, the flag and the landing"
has "$(blk "$O")" '^warnings=1$' "...counted (warnings=1)"; has "$(blk "$O")" '^warnings_avail=0$' "...not an availability warning"
has "$(blk "$O")" '^warnings_gpu=1$' "NF8: ...and counted apart as warnings_gpu=1 (no standing grant covers it, whatever its kind)"
[ -n "$WD" ] && [ "$WD" != "$(printf '' | sha256sum | cut -d' ' -f1)" ] && ok "...in warnings_id" || bad "...in warnings_id"
O=$(L lr --rs-attempt dp2 --rs-expect "$HD" -N dp -n 1 -- 'deepspeed --num_gpus 2 train.py'); RC=$?
[ "$RC" = 6 ] && has "$O" '^changed: warnings$' "...an approved launch without the card's warnings_id: exit 6, changed: warnings" || bad "R5-2: --rs-expect without --rs-warnings (rc=$RC)"
O=$(L lr --rs-attempt dp3 --rs-expect "$HD" --rs-warnings "$WD" -N dp -n 1 -- 'deepspeed --num_gpus 2 train.py'); RC=$?
LD=$LR/$(kv log "$LR/.rs/attempts/dp3/receipt"); waitfor "$LD.rc"
[ "$RC" = 0 ] && has "$(cat "$LR/.rs/attempts/dp3/err")" '^WARNING: RUN runs deepspeed with --num_gpus' "...with it: launched, the WARNING in its journal" || bad "R5-2: approved launch (rc=$RC)"
has "$(cat "$LD")" '^worker sees CUDA_VISIBLE_DEVICES=0,1$' "...why: the (stub) runner's workers see 0,1 — GPU 1 is another user's, the landing was 2"
sleep 1; O=$(L lr -N dp -n 1 -- 'deepspeed --num_gpus 2 train.py'); RC=$?
[ "$RC" = 0 ] && has "$O" '^WARNING: RUN runs deepspeed' "...a launch without a plan prints it too (exit 0)" || bad "R5-2: plain launch (rc=$RC)"
i=0
for r in 'accelerate launch --gpu_ids 0,1 train.py' 'accelerate launch --num-processes=2 t.py' 'accelerate-launch --gpu-ids=0 t.py' 'python -m accelerate.commands.launch --num_processes 2 t.py' \
         'python -m deepspeed.launcher.runner --include localhost:0,1 t.py' 'deepspeed -i localhost:1 t.py' 'deepspeed -ilocalhost:1 t.py' 'deepspeed --num_g 2 t.py' \
         '/v/bin/deepspeed -H hostfile t.py' 'timeout 1h deepspeed --num_nodes 1 t.py' 'deepspeed --master_addr 10.0.0.1 t.py' 'deepspeed --exclude localhost:1 t.py' \
         'ds --num_accelerators 2 t.py' 'OMP_NUM_THREADS=4 env A=1 deepspeed "--num_gpus" 2 t.py' 'bash -c "deepspeed --num_gpus 2 t.py"'; do
  i=$((i + 1)); O=$(L lr --rs-mode plan -N lw$i -n 1 -- "$r"); RC=$?
  [ "$RC" = 0 ] && has "$O" "^WARNING: RUN runs .* with .* — such a launcher may ignore CUDA_VISIBLE_DEVICES" "R5-2: $r -> WARNING" || bad "R5-2: $r (rc=$RC)"
  has "$(blk "$O")" '^warnings=1$' "...counted"; has "$(blk "$O")" '^warnings_gpu=1$' "...as warnings_gpu=1 (NF8)"
done
O=$(L lr --rs-mode plan -N lw0 -n 1 -- 'deepspeed --num_gpus 2 a.py; accelerate launch --gpu_ids 0 b.py')
[ "$(printf '%s\n' "$O" | grep -c '^WARNING: RUN runs ')" = 2 ] && has "$(blk "$O")" '^warnings=2$' "R5-2: two launchers, two warnings" || bad "R5-2: two launchers"
has "$(blk "$O")" '^warnings_gpu=2$' "...warnings_gpu=2 (NF8)"
for r in 'deepspeed train.py --deepspeed_config ds.json' 'accelerate launch train.py' 'python train.py --num_gpus 2' \
         'torchrun --nproc_per_node 2 t.py' 'deepspeed --master_port 29501 t.py' 'deepspeed --num_train_epochs 3 t.py'; do
  O=$(L lr --rs-mode plan -N ln -n 1 -- "$r"); hasnt "$O" '^WARNING:' "R5-2: no warning for $r (the landing is used; no config, no hostfile here)"; done
rm -f "$T/apps" "$T/bin/deepspeed"

echo "-- R6-3: accelerate's config (gpu_ids) and deepspeed's default hostfile (/job/hostfile), read here read-only: a counted WARNING --"
# the facts (accelerate: launch.py takes the config's gpu_ids when --gpu_ids is absent and utils/launch.py sets CUDA_VISIBLE_DEVICES
# from it unless it is all; the default config is $HF_HOME/accelerate/default_config.yaml, .json when only that is a file —
# env.sh's HF_HOME is $PROJ/.cache/huggingface; deepspeed's runner reads its default hostfile /job/hostfile when it exists and then
# leaves CUDA_VISIBLE_DEVICES aside): their source, read back from installed copies by tests/vgate/launchers.sh (acc_cfg_gpu_ids=
# acc_all= acc_cfg_default= acc_cfg_json_only= acc_cfg_hyphen= ds_hostfile= ds_pool_cvd=), whose plumbing tests/88 runs on fakes
wn() { printf '%s\n' "$1" | grep -c '^WARNING: '; }; wd() { printf '%s\n' "$1" | sed -n 's/^warnings_id=//p'; }
AC=$LR/.cache/huggingface/accelerate; mkdir -p "$AC"; NOW=$(printf '' | sha256sum | cut -d' ' -f1)
printf 'compute_environment: LOCAL_MACHINE\ngpu_ids: 0,1\nnum_processes: 2\n' > "$AC/default_config.yaml"
O=$(L lr --rs-mode plan -N ac -n 1 -- 'accelerate launch train.py'); RC=$?
[ "$RC" = 0 ] && has "$O" "^WARNING: RUN runs accelerate launch with gpu_ids: 0,1 in \.cache/huggingface/accelerate/default_config\.yaml — such a launcher may ignore CUDA_VISIBLE_DEVICES and pick GPUs itself (any on the box, another user's too), not only this launch's GPU(s) \[[0-9]\]: drop those flags and settings" \
  "R6-3: accelerate launch, no --gpu_ids, the project's default config says gpu_ids: 0,1 -> a WARNING naming the value and the file" || { bad "R6-3: default config (rc=$RC)"; printf '%s\n' "$O" | head -4 | sed 's/^/    | /'; }
has "$(blk "$O")" '^warnings=1$' "...counted (warnings=1)"; has "$(blk "$O")" '^warnings_gpu=1$' "...as warnings_gpu=1 (NF8: no grant covers it, whatever its kind)"
printf 'gpu_ids: all  # every GPU it is shown\n' > "$AC/default_config.yaml"
O=$(L lr --rs-mode plan -N ac -n 1 -- 'accelerate launch train.py'); HA=$(bh "$O")
[ "$(wd "$O")" = "$NOW" ] && hasnt "$O" '^WARNING:' "R6-3: gpu_ids: all (a comment after it): no warning — it uses the landing" || bad "R6-3: gpu_ids all"
printf 'gpu_ids: 0,1\n' > "$AC/default_config.yaml"
O=$(L lr --rs-attempt ac4 --rs-expect "$HA" -N ac -n 1 -- 'accelerate launch train.py'); RC=$?
[ "$RC" = 6 ] && has "$O" '^changed: launch_cfg warnings$' "...the config is read again at the approved launch: gpu_ids 0,1 since the plan -> exit 6, changed: launch_cfg warnings (R7-5: the file is bound too)" || bad "R6-3: config re-read at the launch (rc=$RC)"
has "$(cat "$LR/.rs/attempts/ac4/result" 2>/dev/null)" 'rc=6 verdict=refused' "...refused, nothing launched"
for c in "gpu_ids: '0'" '{"a": 1, "gpu_ids": "0,1"}' "$(printf 'gpu_ids:\n  - 0\n  - 1')" "$(printf '{\n  "gpu_ids": [0, 1]\n}')" 'gpu_ids: *ids' '  "gpu_ids" : "2",'; do
  printf '%s\n' "$c" > "$LR/c.yaml"; O=$(L lr --rs-mode plan -N ac -n 1 -- 'accelerate launch --config_file c.yaml t.py')
  [ "$(wn "$O")" = 1 ] && has "$O" '^WARNING: RUN runs accelerate launch with gpu_ids: .* in c\.yaml — such a launcher' "R6-3: --config_file c.yaml holding $(printf %s "$c" | tr '\n' ' ') -> a WARNING" || bad "R6-3: config $c"; done
for c in 'gpu_ids: all' "$(printf '# gpu_ids: 0,1\ngpu_ids: null')" "$(printf 'gpu_ids:\nnum_processes: 2')" 'num_processes: 2' '{"gpu_ids": null, "x": 1}' "$(printf '{\n  "gpu_ids": "all"\n}')" 'gpu_ids: ~' "gpu_ids: ''"; do
  printf '%s\n' "$c" > "$LR/c.yaml"; O=$(L lr --rs-mode plan -N ac -n 1 -- 'accelerate launch --config_file c.yaml t.py')
  hasnt "$O" '^WARNING:' "R6-3: --config_file c.yaml holding $(printf %s "$c" | tr '\n' ' ') -> no warning (all / null / empty / none: the landing)"; done
printf 'gpu_ids: 0\n' > "$LR/c.yaml"
for r in 'accelerate launch --config_file=c.yaml t.py' 'accelerate launch --config-file c.yaml t.py' 'accelerate-launch --config-file=c.yaml t.py' \
         'python -m accelerate.commands.launch --config_file c.yaml t.py' "accelerate launch --config_file $LR/c.yaml t.py"; do
  O=$(L lr --rs-mode plan -N ac -n 1 -- "$r"); has "$O" '^WARNING: RUN runs .* with gpu_ids: 0 in .*c\.yaml — such a launcher' "R6-3: $r -> read, a WARNING"; done
printf 'gpu_ids: all\n' > "$LR/c.yaml"; printf 'gpu_ids: 0,1\n' > "$AC/default_config.yaml"
O=$(L lr --rs-mode plan -N ac -n 1 -- 'accelerate launch --config_file c.yaml t.py'); hasnt "$O" '^WARNING:' "R6-3: --config_file wins over the default config (accelerate reads only the given one)"
for r in 'accelerate launch --config_file missing.yaml t.py' 'accelerate launch --config_file $CFG t.py' 'accelerate launch --config_file ~nobody/c.yaml t.py' \
         'accelerate launch --config_file /dev/null t.py' 'accelerate launch t.py --config_file'; do
  O=$(L lr --rs-mode plan -N ac -n 1 -- "$r"); [ "$(wn "$O")" = 1 ] && has "$O" '^WARNING: RUN runs accelerate launch with a config it cannot read here (--config_file .*) — such a launcher' "R6-3: $r -> cannot read it: a WARNING (fail closed)" || bad "R6-3: $r"; done
head -c 70000 /dev/zero | tr '\0' '#' > "$LR/big.yaml"; O=$(L lr --rs-mode plan -N ac -n 1 -- 'accelerate launch --config_file big.yaml t.py')
has "$O" '^WARNING: RUN runs accelerate launch with a config it cannot read here (big\.yaml: unreadable or over 64 KiB)' "R6-3: a config over 64 KiB is not read: a WARNING"
O=$(L lr --rs-mode plan -N ac -n 1 -- 'accelerate launch --gpu_ids 2 t.py')
[ "$(wn "$O")" = 1 ] && has "$O" '^WARNING: RUN runs accelerate launch with --gpu_ids — such a launcher .* drop those flags (it then uses these)' "R6-3: --gpu_ids given: its flag warning only (the config's gpu_ids is not used)" || bad "R6-3: --gpu_ids and a config"
O=$(L lr --rs-mode plan -N ac -n 1 -- 'accelerate launch --num_processes 2 t.py')
has "$O" '^WARNING: RUN runs accelerate launch with --num_processes gpu_ids: 0,1 in \.cache/huggingface/accelerate/default_config\.yaml — ' "R6-3: a flag and the config's gpu_ids: one line naming both"
O=$(L lr --rs-mode plan -N ac -n 1 -- 'HF_HOME=/data/hf accelerate launch t.py'); has "$O" '^WARNING: RUN runs accelerate launch with a default config it cannot read here (RUN sets HF_HOME)' "R6-3: RUN moves HF_HOME: its default config is not the one read here — a WARNING"
rm -f "$AC/default_config.yaml"; printf '{"gpu_ids": "1"}\n' > "$AC/default_config.json"
O=$(L lr --rs-mode plan -N ac -n 1 -- 'accelerate launch --cache_dir $HF_HOME/x t.py'); has "$O" '^WARNING: RUN runs accelerate launch with gpu_ids: "1" in \.cache/huggingface/accelerate/default_config\.json' "R6-3: only default_config.json is a file: it is the one read (\$HF_HOME read, not set)"
printf 'gpu_ids: all\n' > "$AC/default_config.yaml"; O=$(L lr --rs-mode plan -N ac -n 1 -- 'accelerate launch t.py'); hasnt "$O" '^WARNING:' "...a .yaml beside it is the one accelerate reads"
if [ "$(id -u)" != 0 ]; then chmod 000 "$AC/default_config.yaml"; O=$(L lr --rs-mode plan -N ac -n 1 -- 'accelerate launch t.py')
  has "$O" '^WARNING: RUN runs accelerate launch with a config it cannot read here (\.cache/huggingface/accelerate/default_config\.yaml)' "R6-3: a default config this cannot read: a WARNING (fail closed)"; chmod 644 "$AC/default_config.yaml"
else echo "  SKIP: root reads any file: the unreadable-config case is not testable"; fi
rm -rf "$LR/.cache" "$LR/c.yaml" "$LR/big.yaml"
DS=$(mkp dsh 'WS_REMOTE_DIR=projects/dsh
ENV_KIND=none')
[ "$(grep -c '^  local dsh=/job/hostfile ' "$RS_HOME/remote/launch.sh")" = 1 ] && ok "R6-3: launch.sh looks for deepspeed's default hostfile at /job/hostfile (its runner's DLTS_HOSTFILE; tests/vgate/launchers.sh ds_hostfile=)" || bad "R6-3: the /job/hostfile line"
sed "s|^  local dsh=/job/hostfile |  local dsh=$T/job/hostfile |" "$RS_HOME/remote/launch.sh" > "$DS/.ws/launch.sh"   # /job cannot be made here: that path moved under $T
[ "$(diff "$RS_HOME/remote/launch.sh" "$DS/.ws/launch.sh" | grep -c '^[<>]')" = 2 ] && ok "...the copy under test differs from the shipped launch.sh in that line only" || bad "...the hostfile copy differs elsewhere"
mkdir -p "$T/job"; : > "$T/job/hostfile"
O=$(L dsh --rs-mode plan -N ds -n 1 -- 'deepspeed train.py'); RC=$?
[ "$RC" = 0 ] && has "$O" "^WARNING: RUN runs deepspeed with $T/job/hostfile (present: its default hostfile, read without --hostfile) — such a launcher may ignore CUDA_VISIBLE_DEVICES" \
  "R6-3: deepspeed, no flags, its default hostfile exists -> a WARNING naming it" || { bad "R6-3: hostfile (rc=$RC)"; printf '%s\n' "$O" | head -4 | sed 's/^/    | /'; }
has "$(blk "$O")" '^warnings=1$' "...counted"
O=$(L dsh --rs-mode plan -N ds -n 1 -- 'deepspeed --hostfile my.hf train.py'); [ "$(wn "$O")" = 1 ] && has "$O" '^WARNING: RUN runs deepspeed with --hostfile — such a launcher' "...with --hostfile: that flag's warning only" || bad "R6-3: --hostfile"
O=$(L dsh --rs-mode plan -N ds -n 1 -- 'deepspeed -H my.hf t.py'); hasnt "$O" '(present: its default hostfile' "...with -H: the default file is not read"
O=$(L dsh --rs-mode plan -N ds -n 1 -- 'deepspeed --num_gpus 2 t.py'); has "$O" "^WARNING: RUN runs deepspeed with --num_gpus $T/job/hostfile (present" "...with another flag: one line naming both"
O=$(L dsh --rs-mode plan -N ds -n 1 -- 'accelerate launch t.py; torchrun t.py'); hasnt "$O" '^WARNING:' "...not for other launchers"
rm -f "$T/job/hostfile"; O=$(L dsh --rs-mode plan -N ds -n 1 -- 'deepspeed train.py'); hasnt "$O" '^WARNING:' "R6-3: no hostfile there: deepspeed with no flags uses the landing — no warning"

echo "-- R6-2: container runtimes give a container the GPUs THEY pick (docker / podman / nvidia-docker, apptainer / singularity): a counted WARNING --"
# the facts (docker / podman run pass no host environment in, only -e/--env; --gpus, --runtime nvidia, CDI --device nvidia.com/gpu…,
# --device /dev/nvidia… and --privileged hand it GPUs; apptainer / singularity pass the host environment in unless --cleanenv /
# --containall): tests/vgate/containers.sh reads them on a box (with the user's OK); tests/88 runs its plumbing on stubs
for r in 'docker run --rm --gpus all -v $PWD:/w myimg python /w/train.py' 'docker run --gpus=device=0 img' 'docker run --gpus "device=$CUDA_VISIBLE_DEVICES" img' \
         'podman run --device nvidia.com/gpu=all img' 'podman run --device=nvidia.com/gpu=0 img' 'docker run --device /dev/nvidia0 img' 'docker run --device=/dev/nvidia1:/dev/nvidia1 img' \
         'docker run --runtime=nvidia img' 'docker run --runtime nvidia img' 'docker run --privileged img' 'docker run -e NVIDIA_VISIBLE_DEVICES img' 'docker run --env=NVIDIA_VISIBLE_DEVICES img' \
         'nvidia-docker run img p' 'sudo -E /usr/bin/docker run --gpus all img' 'docker run --device $D img' 'bash -c "docker run --gpus all img"' 'docker create --gpus all img'; do
  O=$(L lr --rs-mode plan -N ct -n 1 -- "$r"); RC=$?
  [ "$RC" = 0 ] && has "$O" "^WARNING: RUN runs [a-z/-]* with .* — a container started so does not get this launch's CUDA_VISIBLE_DEVICES and may see GPUs its runtime picks (any on the box, another user's too), not only this launch's GPU(s) \[[0-9]\]: name the GPUs it will use to the user\$" \
    "R6-2: $r -> WARNING" || { bad "R6-2: $r (rc=$RC)"; printf '%s\n' "$O" | grep WARNING | head -2 | sed 's/^/    | /'; }
  has "$(blk "$O")" '^warnings=1$' "...counted"; has "$(blk "$O")" '^warnings_gpu=1$' "...as warnings_gpu=1 (NF8)"
done
for r in 'apptainer exec --nv --cleanenv img p' 'singularity exec -e --nv img p' 'apptainer exec -C --nv img p' 'apptainer run --containall img' 'apptainer exec -ce --nv img p' '/opt/bin/singularity run --cleanenv=true img'; do
  O=$(L lr --rs-mode plan -N ct -n 1 -- "$r"); RC=$?
  [ "$RC" = 0 ] && has "$O" "^WARNING: RUN runs [a-z/]* with .* — a container started so does not get this launch's CUDA_VISIBLE_DEVICES .*: drop those flags (it then keeps these), or name the GPUs it will use to the user\$" \
    "R6-2: $r -> WARNING (drop the flag: the landing then reaches it)" || bad "R6-2: $r (rc=$RC)"
  has "$(blk "$O")" '^warnings=1$' "...counted"
done
for r in 'docker run img python t.py' 'docker run -e CUDA_VISIBLE_DEVICES img' 'docker run --device /dev/fuse img' 'podman run --env-host img p' \
         'apptainer exec --nv img python t.py' 'singularity exec --nv -B /data:/data img p' 'apptainer exec --nv --bind /x img python -c x'; do
  O=$(L lr --rs-mode plan -N ct -n 1 -- "$r"); hasnt "$O" '^WARNING:' "R6-2: no warning for $r (no GPU flag; apptainer passes the landing in)"; done
O=$(L lr --rs-mode plan -N ct -n 1 -- 'docker run --gpus all img'); HK=$(bh "$O")
O=$(L lr --rs-attempt ct2 --rs-expect "$HK" -N ct -n 1 -- 'docker run --gpus all img'); RC=$?
[ "$RC" = 6 ] && has "$O" '^changed: warnings$' "R6-2: an approved launch without the card's warnings_id: exit 6, changed: warnings (nothing started)" || bad "R6-2: --rs-expect without --rs-warnings (rc=$RC)"

echo "-- R7-3: a tool that starts the command without this launch's environment, or elsewhere: a counted WARNING naming it and the landing --"
# the facts: tests/vgate/envdrop.sh reads them from the box's own tmux / screen / setpriv / systemd-run (tests/88 runs it, on the
# real tools when installed here: a running tmux server's session never gets the client's CUDA_VISIBLE_DEVICES, setpriv
# --reset-env clears it); containers.sh reads docker / podman exec (no host environment enters a container)
r7() {   # r7 RUN TOOL: a plan of RUN -> exit 0, ONE counted R7-3 WARNING naming TOOL and the landing's ids
  O=$(L lr --rs-mode plan -N r7 -n 1 -- "$1"); RC=$?
  [ "$RC" = 0 ] && [ "$(wn "$O")" = 1 ] && has "$O" "^WARNING: RUN starts its command through $2 — .* — so it may use GPUs other than this launch's GPU(s) \[[0-9]\] (any on the box, another user's too): run the command directly (launch.sh detaches it), or name the GPUs it will use to the user\$" \
    "R7-3: $1 -> a WARNING naming '$2' and the landing" || { bad "R7-3: $1 -> one WARNING naming '$2' (rc=$RC)"; printf '%s\n' "$O" | grep '^WARNING' | head -3 | sed 's/^/    | /'; }
  has "$(blk "$O")" '^warnings=1$' "...counted (warnings=1)"; has "$(blk "$O")" '^warnings_gpu=1$' "...as warnings_gpu=1 (NF8: no grant covers it, whatever its kind)"; }
r7 'docker exec dev python train.py' 'docker exec'; r7 'podman exec -it dev p' 'podman exec'; r7 'nerdctl exec dev p' 'nerdctl exec'
r7 'docker container exec dev p' 'docker exec'; r7 'docker start -a trainer' 'docker start'; r7 '/usr/bin/docker exec dev p' '/usr/bin/docker exec'
r7 'docker compose run --rm trainer python train.py' 'docker compose run'; r7 'docker compose up' 'docker compose up'; r7 'podman compose exec t p' 'podman compose exec'
r7 'docker-compose run t p' 'docker-compose run'; r7 'podman-compose up -d' 'podman-compose up'
r7 'kubectl exec pod -- p' 'kubectl exec'; r7 'kubectl -n ns run x --image=i -- p' 'kubectl run'; r7 'kubectl apply -f job.yaml' 'kubectl apply'
r7 'tmux new-session -d -s train "python train.py"' 'tmux new-session'; r7 'tmux -L s -f /dev/null new -d p' 'tmux new'; r7 'tmux neww p' 'tmux neww'
r7 'tmux new-w p' 'tmux new-w'; r7 'tmux send-keys -t s "python t.py" Enter' 'tmux send-keys'; r7 'tmux splitw p' 'tmux splitw'; r7 'tmux respawn-pane -k p' 'tmux respawn-pane'
r7 'tmux run-shell p' 'tmux run-shell'; r7 '/usr/bin/tmux display-popup p' '/usr/bin/tmux display-popup'
r7 'screen -dmS t p' 'screen -dmS'; r7 'screen -d -m p' 'screen -d -m'; r7 'screen -S t -X stuff p' 'screen -X'
r7 'setpriv --reset-env p' 'setpriv --reset-env'; r7 'setpriv --reuid 1000 --res p' 'setpriv --res'
r7 'systemd-run --user --wait p' 'systemd-run'; r7 'doas p' 'doas'; r7 'ssh gpu-host python t.py' 'ssh'; r7 'x; /usr/bin/ssh h p' '/usr/bin/ssh'
r7 'srun -n1 p' 'srun'; r7 'salloc -N1 p' 'salloc'; r7 'sbatch job.sh' 'sbatch'; r7 'bash -c "tmux new -d p"' 'tmux new'
r7 'sudo p' 'sudo'; r7 '/usr/bin/sudo -n p' '/usr/bin/sudo'; r7 'sudo -u root p' 'sudo'; r7 'sudo -uE p' 'sudo'; r7 'sudo -p -E p' 'sudo'; r7 'sudo -p E p' 'sudo'
r7 'sudo -i -E p' 'sudo'; r7 'sudo --login --preserve-env p' 'sudo'; r7 'sudo --preserve-env=CUDA_VISIBLE_DEVICES p' 'sudo'
r7 'sudo --preserve-env=CUDA_DEVICE_ORDER p' 'sudo'; r7 'sudo --preserve-e p' 'sudo'; r7 'sudo p -E' 'sudo'
# R8-6: tmux runs any unique prefix of a command name, an alias, or a default command-alias (splitp, split-pane) — the real
# tmux shows it (tests/vgate/envdrop.sh tmux_prefix= / tmux_alias=, run by tests/88 on this machine's tmux): `tmux split`
# / `spl` / `sp` is split-window, `run-` / `ru` run-shell, `i` / `if-` if-shell, `pi` pipe-pane. A word that is a prefix of a
# warned command at least as long as the shortest one only warned commands share warns (new- and resp: ambiguous among them)
for p in split spl sp split-w splitw splitp split-pane run- ru run run-s i if if- pi pipe pipe- pipep new new- new-s new-w neww \
         resp respawn respawn- respawn-p respawnw display-po popup send send-k; do r7 "tmux -L s $p -d x" "tmux $p"; done
r7 "/usr/bin/tmux spl -d -t base 'python t.py'" '/usr/bin/tmux spl'; r7 'bash -c "tmux ru x"' 'tmux ru'
for p in s r p n ne res display-p send- split-p spx new-sessionx ls list-s kill-ses attach has; do   # ambiguous with a command launch.sh does not warn about, unknown, or not one that starts a command
  O=$(L lr --rs-mode plan -N r7 -n 1 -- "tmux -L s $p x"); [ "$?" = 0 ] && hasnt "$O" '^WARNING:' "R8-6: no warning for tmux $p (tmux refuses it, or it starts nothing)" || bad "R8-6: tmux $p (plan not exit 0)"; done
O=$(L lr --rs-mode plan -N r7 -n 1 -- 'sudo -i p'); has "$O" "^WARNING: RUN starts its command through sudo — a login shell (sudo -i / --login) resets the environment" "R7-3: sudo -i: the reason is the login shell"
O=$(L lr --rs-mode plan -N r7 -n 1 -- 'sudo p'); has "$O" "^WARNING: RUN starts its command through sudo — sudo resets the environment (env_reset) unless -E, --preserve-env or --preserve-env=CUDA_VISIBLE_DEVICES,CUDA_DEVICE_ORDER — " "R7-3: sudo: the reason names what keeps the landing"
O=$(L lr --rs-mode plan -N r7 -n 1 -- 'tmux new -d p'); has "$O" "through tmux new — starts it in a tmux session: with a tmux server's environment (a running server's, not this launch's) and outside this run" "R7-3: tmux: the reason (a server's environment, outside the run)"
for r in 'sudo -E p' 'sudo -nE p' 'sudo -E -u root p' 'sudo -u root -E p' 'sudo -Eu root p' 'sudo --preserve-env p' 'sudo --preserve-env=CUDA_VISIBLE_DEVICES,CUDA_DEVICE_ORDER p' \
         'sudo --preserve-env=PATH --preserve-env=CUDA_DEVICE_ORDER,CUDA_VISIBLE_DEVICES p' 'sudo -E -- p' 'tmux ls' 'tmux kill-server' 'screen -ls' 'screen -wipe' \
         'setpriv --reuid 1000 p' 'docker run img p' 'docker ps' 'docker compose ps' 'git clone ssh://h/r x' 'python ssh_tool.py --screen' 'kubectl get pods' \
         'python train.py --run start' 'nohup python t.py' 'setsid p'; do
  O=$(L lr --rs-mode plan -N r7 -n 1 -- "$r"); [ "$?" = 0 ] && hasnt "$O" '^WARNING:' "R7-3: no warning for $r (the landing reaches it)" || bad "R7-3: $r (plan not exit 0)"; done
O=$(L lr --rs-mode plan -N r7 -n 1 -- 'sudo docker run --gpus all img'); RC=$?
[ "$RC" = 0 ] && [ "$(wn "$O")" = 2 ] && has "$(blk "$O")" '^warnings=2$' "R7-3: sudo (no -E) + docker --gpus: two warnings, both counted" || bad "R7-3: sudo + docker (rc=$RC)"
has "$(blk "$O")" '^warnings_gpu=2$' "...both as warnings_gpu (NF8)"
O=$(L lr --rs-mode plan -N r7 -n 1 -- 'nerdctl run --rm --gpus all img python train.py'); [ "$(wn "$O")" = 1 ] \
  && has "$O" "^WARNING: RUN runs nerdctl with --gpus — a container started so does not get this launch's CUDA_VISIBLE_DEVICES" "R6-2 for nerdctl: run --gpus is a container WARNING" || bad "nerdctl run --gpus"
O=$(L lr --rs-mode plan -N r7 -n 1 -- 'python -m accelerate.commands.accelerate_cli launch --gpu_ids 0,1 train.py'); [ "$(wn "$O")" = 1 ] \
  && has "$O" "^WARNING: RUN runs accelerate.commands.accelerate_cli launch with --gpu_ids — such a launcher" "R5-2 for python -m accelerate.commands.accelerate_cli launch: the launcher WARNING" || bad "accelerate_cli launch"
O=$(L lr --rs-mode plan -N r7 -n 1 -- 'docker exec --privileged dev p'); [ "$(wn "$O")" = 2 ] && ok "R7-3: docker exec --privileged: the container line and the exec line" || bad "docker exec --privileged ($(wn "$O"))"
O=$(L lr --rs-attempt r7p -N r7x --rs-mode plan -n 1 -- 'srun -n1 true'); H7=$(bh "$O"); W7=$(wd "$O")
O=$(L lr --rs-attempt r7a -N r7x --rs-expect "$H7" -n 1 -- 'srun -n1 true'); RC=$?
[ "$RC" = 6 ] && has "$O" '^changed: warnings$' "R7-3: an approved launch without the card's warnings_id: exit 6, changed: warnings (nothing started)" || bad "R7-3: --rs-expect without --rs-warnings (rc=$RC)"
[ ! -e "$LR/.rs/attempts/r7a/receipt" ] && ok "...no receipt" || bad "...no receipt"
O=$(L lr --rs-attempt r7b -N r7x --rs-expect "$H7" --rs-warnings "$W7" -n 1 -- 'srun -n1 true'); RC=$?
[ "$RC" = 0 ] && has "$(cat "$LR/.rs/attempts/r7b/err")" '^WARNING: RUN starts its command through srun' "...with it: launched, the WARNING in its journal" || bad "R7-3: approved launch (rc=$RC)"

echo "-- R7-4: accelerate launch without --config_file when the config it reads may be elsewhere (ENV_HOOK, a conf or RUN naming HF_HOME / ACCELERATE_…): a counted WARNING --"
# the facts: accelerate reads $HF_HOME/accelerate/default_config.yaml (tests/vgate/launchers.sh acc_cfg_default=); env.sh exports
# HF_HOME, then sources ENV_HOOK last (remote/env.sh; tests/30-env.sh) — so a hook moves the config accelerate reads (shown below)
cat > "$T/bin/accelerate" <<'EOS'
#!/usr/bin/env bash
# stub: accelerate launch reads --config_file, else $HF_HOME/accelerate/default_config.yaml, and sets CUDA_VISIBLE_DEVICES from its gpu_ids
shift; c=${HF_HOME:-$HOME/.cache/huggingface}/accelerate/default_config.yaml; g=""
while [ $# -gt 0 ]; do case "$1" in --gpu_ids) g=$2; shift 2 ;; --config_file) c=$2; shift 2 ;; *) break ;; esac; done
[ -n "$g" ] || g=$(sed -n 's/^gpu_ids: *//p' "$c" 2>/dev/null); [ -z "$g" ] || [ "$g" = all ] || export CUDA_VISIBLE_DEVICES=$g
echo "accelerate-stub: config=$c worker sees CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
EOS
chmod +x "$T/bin/accelerate"
SH=$T/shared-hf; mkdir -p "$SH/accelerate"; printf 'distributed_type: MULTI_GPU\ngpu_ids: 0,1\n' > "$SH/accelerate/default_config.yaml"
HK=$(mkp hk 'WS_REMOTE_DIR=projects/hk
ENV_KIND=none
ENV_HOOK=hook.sh'); printf 'export HF_HOME=%s   # a shared model cache\n' "$SH" > "$HK/hook.sh"
printf 'GPU-aaaa0000-0001, 1\n' > "$T/apps"
O=$(L hk --rs-attempt hk1 --rs-mode plan -N hk -n 1 -- 'accelerate launch train.py'); RC=$?; H4=$(bh "$O"); W4=$(wd "$O")
[ "$RC" = 0 ] && [ "$(wn "$O")" = 1 ] && has "$O" "^WARNING: RUN runs accelerate launch with no --config_file: the config accelerate reads is unknown (ENV_HOOK 'hook.sh' may move it) — such a launcher may ignore CUDA_VISIBLE_DEVICES and pick GPUs itself (any on the box, another user's too), not only this launch's GPU(s) \[2\]: give it --config_file FILE (read here, bound in the plan)" \
  "R7-4: ENV_HOOK set, accelerate launch without --config_file: a WARNING (the hook may move HF_HOME)" || { bad "R7-4: ENV_HOOK (rc=$RC)"; printf '%s\n' "$O" | head -4 | sed 's/^/    | /'; }
has "$(blk "$O")" '^warnings=1$' "...counted"; has "$(blk "$O")" '^launch_cfg=$' "...nothing read here: launch_cfg= (the project has no default config)"
O=$(L hk --rs-attempt hk2 --rs-expect "$H4" --rs-warnings "$W4" -N hk -n 1 -- 'accelerate launch train.py'); RC=$?
LK=$HK/$(kv log "$HK/.rs/attempts/hk2/receipt"); waitfor "$LK.rc"
[ "$RC" = 0 ] && has "$(cat "$LK")" "^accelerate-stub: config=$SH/accelerate/default_config.yaml worker sees CUDA_VISIBLE_DEVICES=0,1\$" \
  "...why: approved, the (stub) accelerate reads the hook's HF_HOME config and lands on 0,1 (GPU 1 is another user's; the landing was 2)" || bad "R7-4: the hook's config (rc=$RC)"
for r in 'accelerate launch --config_file c.yaml t.py' 'accelerate launch --gpu_ids 2 t.py' 'deepspeed t.py' 'python t.py'; do
  printf 'gpu_ids: all\n' > "$HK/c.yaml"; O=$(L hk --rs-mode plan -N hkp -n 1 -- "$r")
  [ "$?" = 0 ] && hasnt "$O" 'the config accelerate reads is unknown' "R7-4: not for $r (the config is named, the ids are flags, or no accelerate)" || bad "R7-4: $r (plan not exit 0)"; done
O=$(L hk --rs-mode plan -N hkp -n 1 -- 'accelerate launch --num_processes 2 t.py')
has "$O" "^WARNING: RUN runs accelerate launch with --num_processes no --config_file: the config accelerate reads is unknown (ENV_HOOK 'hook.sh' may move it) — " "R7-4: with a GPU flag: one line naming both"
mkdir -p "$HK/.cache/huggingface/accelerate"; printf 'gpu_ids: 0\n' > "$HK/.cache/huggingface/accelerate/default_config.yaml"
O=$(L hk --rs-mode plan -N hkp -n 1 -- 'accelerate launch t.py'); [ "$(wn "$O")" = 1 ] \
  && has "$O" "with gpu_ids: 0 in \.cache/huggingface/accelerate/default_config\.yaml no --config_file: the config accelerate reads is unknown (ENV_HOOK 'hook.sh' may move it) — " "R7-4: the project's default config is still read (and bound): one line naming both" || bad "R7-4: hook + default config"
has "$(blk "$O")" "^launch_cfg=\.cache/huggingface/accelerate/default_config\.yaml:[0-9a-f]\{64\}\$" "...launch_cfg binds that default config"
rm -rf "$HK/.cache"
printf 'WS_REMOTE_DIR=projects/hk\nENV_KIND=none\nexport HF_HOME=/data/hf\n' > "$HK/.ws.conf"
O=$(L hk --rs-mode plan -N hkp -n 1 -- 'accelerate launch t.py'); has "$O" "^WARNING: RUN runs accelerate launch with no --config_file: the config accelerate reads is unknown (\.ws\.conf names HF_HOME, which may move it) — " "R7-4: a conf naming HF_HOME (no hook): a WARNING"
printf 'WS_REMOTE_DIR=projects/hk\nENV_KIND=none\nACCELERATE_CONFIG_DIR=/data/acc\n' > "$HK/.ws.conf"
O=$(L hk --rs-mode plan -N hkp -n 1 -- 'accelerate launch t.py'); has "$O" "unknown (\.ws\.conf names ACCELERATE_CONFIG_DIR, which may move it)" "R7-4: a conf naming ACCELERATE_…: a WARNING"
printf 'WS_REMOTE_DIR=projects/hk\nENV_KIND=none\n  # HF_HOME and ACCELERATE_X are env.sh'"'"'s business\nRUN="accelerate launch --cache $HF_HOME/x t.py"\n' > "$HK/.ws.conf"
O=$(L hk --rs-mode plan -N hkp -n 1 -- 'accelerate launch t.py'); [ "$?" = 0 ] && hasnt "$O" '^WARNING:' "R7-4: a conf naming them only in a comment line or as an expansion (\$HF_HOME): no warning" || bad "R7-4: comment-line conf (plan not exit 0)"
O=$(L hk --rs-mode plan -N hkp -n 1 -- 'ACCELERATE_USE_CPU=0 accelerate launch t.py'); has "$O" "unknown (RUN names ACCELERATE_USE_CPU, which may move it)" "R7-4: RUN naming ACCELERATE_…: a WARNING"
O=$(L hk --rs-mode plan -N hkp -n 1 -- 'accelerate launch t.py --dir ${ACCELERATE_DIR:-x}'); [ "$?" = 0 ] && hasnt "$O" '^WARNING:' "R7-4: RUN expanding \${ACCELERATE_…} only: no warning" || bad "R7-4: \${ACCELERATE_…} (plan not exit 0)"
O=$(L hk --rs-mode plan -N hkp -n 1 -- 'HF_HOME=/data/hf accelerate launch t.py'); has "$O" '^WARNING: RUN runs accelerate launch with a default config it cannot read here (RUN sets HF_HOME) — ' "R6-3's RUN-sets-HF_HOME line is unchanged (an approved card's warnings_id stays)"
# R8-4: ENV_KIND=conda — env.sh runs `conda activate` after exporting HF_HOME, and conda applies the env's own variables
# (`conda env config vars set HF_HOME=…`, activate.d): the config accelerate reads is unknown too (the stub above does that)
CE=$(mkp ce 'WS_REMOTE_DIR=projects/ce
ENV_KIND=conda
ENV_NAME=train'); mkdir -p "$H/miniconda3/envs/train"; printf '%s\n' "$SH" > "$H/miniconda3/envs/train/hf_home"
O=$(L ce --rs-attempt ce1 --rs-mode plan -N ce -n 1 -- 'accelerate launch train.py'); RC=$?; H8=$(bh "$O"); W8=$(wd "$O")
[ "$RC" = 0 ] && [ "$(wn "$O")" = 1 ] && has "$O" "^WARNING: RUN runs accelerate launch with no --config_file: the config accelerate reads is unknown (ENV_KIND=conda: conda activate 'train' applies the env's own variables (HF_HOME / ACCELERATE_… among them), which may move it) — such a launcher may ignore CUDA_VISIBLE_DEVICES and pick GPUs itself (any on the box, another user's too), not only this launch's GPU(s) \[2\]: give it --config_file FILE (read here, bound in the plan)" \
  "R8-4: ENV_KIND=conda, accelerate launch without --config_file: a WARNING (conda activate may move HF_HOME)" || { bad "R8-4: conda (rc=$RC)"; printf '%s\n' "$O" | grep -v '^[a-z_]*=' | head -4 | sed 's/^/    | /'; }
has "$(blk "$O")" '^warnings=1$' "...counted"; has "$(blk "$O")" '^warnings_gpu=1$' "...as warnings_gpu=1 (NF8: no grant covers it)"; has "$(blk "$O")" '^env_kind=conda$' "...env_kind=conda"
O=$(L ce --rs-attempt ce2 --rs-expect "$H8" --rs-warnings "$W8" -N ce -n 1 -- 'accelerate launch train.py'); RC=$?
LK=$CE/$(kv log "$CE/.rs/attempts/ce2/receipt"); waitfor "$LK.rc"
[ "$RC" = 0 ] && has "$(cat "$LK")" "^accelerate-stub: config=$SH/accelerate/default_config.yaml worker sees CUDA_VISIBLE_DEVICES=0,1\$" \
  "...why: approved, conda activate set the env's HF_HOME, the (stub) accelerate reads that config and lands on 0,1 (GPU 1 is another user's; the landing was 2)" || bad "R8-4: the conda env's config (rc=$RC)"
for r in 'accelerate launch --config_file c.yaml t.py' 'accelerate launch --gpu_ids 2 t.py' 'python t.py'; do
  printf 'gpu_ids: all\n' > "$CE/c.yaml"; O=$(L ce --rs-mode plan -N cep -n 1 -- "$r")
  [ "$?" = 0 ] && hasnt "$O" 'the config accelerate reads is unknown' "R8-4: conda, not for $r (the config is named, the ids are flags, or no accelerate)" || bad "R8-4: conda, $r (plan not exit 0)"; done
# NF7 (R7-4's reasons, the .wandb_env part): env.sh sources $PROJ/.wandb_env (the user's wandb key) after it exports HF_HOME
# (remote/env.sh step 8), so a .wandb_env assigning HF_HOME or ACCELERATE_… moves the config accelerate reads as a conf does:
# read here read-only (never printed: it holds the key — the reason names only which kind of name), unreadable = unknown
WE=$(mkp we 'WS_REMOTE_DIR=projects/we
ENV_KIND=none'); printf 'WANDB_API_KEY=wandbSECRETkey0\nexport HF_HOME=%s\n' "$SH" > "$WE/.wandb_env"; chmod 600 "$WE/.wandb_env"
O=$(L we --rs-attempt we1 --rs-mode plan -N we -n 1 -- 'accelerate launch train.py'); RC=$?; H9=$(bh "$O"); W9=$(wd "$O")
[ "$RC" = 0 ] && [ "$(wn "$O")" = 1 ] && has "$O" "^WARNING: RUN runs accelerate launch with no --config_file: the config accelerate reads is unknown (\.wandb_env names HF_HOME, which may move it) — such a launcher may ignore CUDA_VISIBLE_DEVICES" \
  "NF7: a .wandb_env assigning HF_HOME, accelerate launch without --config_file: a WARNING (env.sh sources it after HF_HOME)" || { bad "NF7: .wandb_env HF_HOME (rc=$RC)"; printf '%s\n' "$O" | grep -v '^[a-z_]*=' | head -4 | sed 's/^/    | /'; }
has "$(blk "$O")" '^warnings_gpu=1$' "...counted as warnings_gpu=1 (no grant covers it)"; hasnt "$O" 'SECRET' "...nothing of the .wandb_env is printed (its key)"
O=$(L we --rs-attempt we2 --rs-expect "$H9" --rs-warnings "$W9" -N we -n 1 -- 'accelerate launch train.py'); RC=$?
LK=$WE/$(kv log "$WE/.rs/attempts/we2/receipt"); waitfor "$LK.rc"
[ "$RC" = 0 ] && has "$(cat "$LK")" "^accelerate-stub: config=$SH/accelerate/default_config.yaml worker sees CUDA_VISIBLE_DEVICES=0,1\$" \
  "...why: approved, env.sh sourced the .wandb_env's HF_HOME, the (stub) accelerate reads that config and lands on 0,1 (GPU 1 is another user's; the landing was 2)" || bad "NF7: the .wandb_env's config (rc=$RC)"
hasnt "$(cat "$WE/.rs/attempts/we2/out" "$WE/.rs/attempts/we2/err" 2>/dev/null)" 'SECRET' "...nor in the attempt's journal"
printf 'WANDB_API_KEY=wandbSECRETkey0\nACCELERATE_CONFIG_DIR=/data/acc\n' > "$WE/.wandb_env"
O=$(L we --rs-mode plan -N wep -n 1 -- 'accelerate launch t.py'); has "$O" "unknown (\.wandb_env names an ACCELERATE_… variable, which may move it)" "NF7: a .wandb_env naming ACCELERATE_…: a WARNING (the name itself not echoed)"
printf 'WANDB_API_KEY=wandbSECRETkey0\n  # HF_HOME and ACCELERATE_X are env.sh'"'"'s business\nWANDB_DIR=$HF_HOME/w\n' > "$WE/.wandb_env"
O=$(L we --rs-mode plan -N wep -n 1 -- 'accelerate launch t.py'); [ "$?" = 0 ] && hasnt "$O" '^WARNING:' "NF7: a .wandb_env naming them only in a comment line or as an expansion (\$HF_HOME): no warning" || bad "NF7: comment-line .wandb_env (plan not exit 0)"
printf 'WANDB_API_KEY=wandbSECRETkey0\nexport HF_HOME=/data/hf\n' > "$WE/.wandb_env"
for r in 'accelerate launch --config_file c.yaml t.py' 'accelerate launch --gpu_ids 2 t.py' 'python t.py'; do
  printf 'gpu_ids: all\n' > "$WE/c.yaml"; O=$(L we --rs-mode plan -N wep -n 1 -- "$r")
  [ "$?" = 0 ] && hasnt "$O" 'the config accelerate reads is unknown' "NF7: .wandb_env HF_HOME, not for $r (the config is named, the ids are flags, or no accelerate)" || bad "NF7: $r (plan not exit 0)"; done
chmod 000 "$WE/.wandb_env"
if [ -r "$WE/.wandb_env" ]; then echo "  SKIP: NF7 unreadable .wandb_env (this user reads a mode-000 file: root?)"
else O=$(L we --rs-mode plan -N wep -n 1 -- 'accelerate launch t.py'); RC=$?
  [ "$RC" = 0 ] && has "$O" "unknown (\.wandb_env could not be read here)" "NF7: an unreadable .wandb_env: the config is unknown — a WARNING (fail closed)" || bad "NF7: unreadable .wandb_env (rc=$RC)"; fi
chmod 600 "$WE/.wandb_env"; rm -f "$WE/.wandb_env"
O=$(L we --rs-mode plan -N wep -n 1 -- 'accelerate launch t.py'); [ "$?" = 0 ] && hasnt "$O" '^WARNING:' "NF7: no .wandb_env (and nothing else moving it): no warning" || bad "NF7: no .wandb_env (plan not exit 0)"
printf 'WS_REMOTE_DIR=projects/hk\nENV_KIND=none\n( sleep 6 ) >/dev/null 2>&1 &\n' > "$HK/.ws.conf"   # a conf that leaves a process behind
SECONDS=0; O=$(L hk --rs-mode plan -N hkp -n 1 -- 'python t.py'); RC=$?
[ "$RC" = 0 ] && [ "$SECONDS" -lt 4 ] && ok "the conf is read without the caller's channel (fds 3/4) or the launch lock (9): a process it leaves behind never holds the plan's reply (${SECONDS}s)" \
  || bad "a conf's background process held the caller (rc=$RC, ${SECONDS}s)"
printf 'WS_REMOTE_DIR=projects/hk\nENV_KIND=none\nX="a b\n' > "$HK/.ws.conf"
O=$(L hk --rs-mode plan -N hkp -n 1 -- 'accelerate launch t.py'); [ "$?" = 2 ] && has "$O" 'sourcing .*/\.ws\.conf (after profile\.sh) failed' "a conf that does not source: a plan is still exit 2 (read before the launcher check now)" || bad "broken conf, plan"
printf 'WS_REMOTE_DIR=projects/hk\nENV_KIND=none\n' > "$HK/.ws.conf"; rm -f "$T/apps"

echo "-- R7-5: the configs / hostfile the launcher check read are bound (launch_cfg=<file>:<sha256>, sorted): an edit after the card is exit 6 --"
sha() { sha256sum < "$1" | cut -d' ' -f1; }
printf 'gpu_ids: 0\n' > "$LR/ddp.yaml"
O=$(L lr --rs-attempt cf1 --rs-mode plan -N cf -n 1 -- 'accelerate launch --config_file ddp.yaml t.py'); HC=$(bh "$O"); WC=$(wd "$O")
has "$(blk "$O")" "^launch_cfg=ddp\.yaml:$(sha "$LR/ddp.yaml")\$" "R7-5: launch_cfg=ddp.yaml:<its sha256>, right before busy_ok (the key order check above)"
[ "$(bnd "$O" | sha256sum | cut -d' ' -f1)" = "$HC" ] && ok "...one of the hashed bound lines" || bad "...bound"
printf 'gpu_ids: 1\n' > "$LR/ddp.yaml"   # the same WARNING once its digits are masked: the warnings_id cannot tell
O=$(L lr --rs-attempt cf2 --rs-mode plan -N cf -n 1 -- 'accelerate launch --config_file ddp.yaml t.py'); [ "$(wd "$O")" = "$WC" ] && [ "$(bh "$O")" != "$HC" ] \
  && ok "R7-5: gpu_ids 0 -> 1: the same warnings_id (digits masked), another bound_hash" || bad "R7-5: gpu_ids 0 -> 1 hashes"
O=$(L lr --rs-attempt cf3 --rs-expect "$HC" --rs-warnings "$WC" -N cf -n 1 -- 'accelerate launch --config_file ddp.yaml t.py'); RC=$?
[ "$RC" = 6 ] && has "$O" '^changed: launch_cfg$' "R7-5: the config edited after the card (gpu_ids 0 -> 1) -> exit 6, changed: launch_cfg" || { bad "R7-5: config drift (rc=$RC)"; printf '%s\n' "$O" | grep -v '^[a-z_]*=' | head -4 | sed 's/^/    | /'; }
has "$(cat "$LR/.rs/attempts/cf3/result")" '^stage=expect rc=6 verdict=refused ' "...refused before the env gate"; [ ! -e "$LR/.rs/attempts/cf3/receipt" ] && ok "...nothing launched" || bad "...nothing launched"
printf 'gpu_ids: 0\n' > "$LR/ddp.yaml"
O=$(L lr --rs-attempt cf4 --rs-expect "$HC" --rs-warnings "$WC" -N cf -n 1 -- 'accelerate launch --config_file ddp.yaml t.py'); RC=$?
[ "$RC" = 0 ] && has "$O" "^plan: bound_hash=$HC = --rs-expect" "...the approved bytes back: launches" || bad "R7-5: same config launches (rc=$RC)"
O=$(L lr --rs-mode plan -N cfp -n 1 -- 'accelerate launch --config_file b.yaml x; accelerate launch --config_file a.yaml y; accelerate launch --config_file b.yaml z')
has "$(blk "$O")" '^launch_cfg=a\.yaml:unreadable,b\.yaml:unreadable$' "R7-5: two configs it cannot read: <file>:unreadable each, sorted, once"
O=$(L lr --rs-mode plan -N cfp -n 1 -- 'accelerate launch --config_file $CFG t.py'); has "$(blk "$O")" '^launch_cfg=\\$CFG:unreadable$' "R7-5: a config named by an expansion: unreadable (%q-quoted)"
mkdir -p "$LR/src"; printf 'gpu_ids: all\n' > "$LR/c.yaml"; printf 'gpu_ids: 0,1\n' > "$LR/src/c.yaml"   # the one read after the cd
for r in 'cd src && accelerate launch --config_file c.yaml t.py' 'pushd src; accelerate launch --config_file=c.yaml t.py' 'env -C src accelerate launch --config_file c.yaml t.py' 'env -v -Csrc accelerate launch --config_file c.yaml t.py' \
         'bash -c "cd src; accelerate launch --config_file c.yaml t.py"'; do
  O=$(L lr --rs-mode plan -N cfp -n 1 -- "$r"); [ "$(wn "$O")" = 1 ] && has "$O" "^WARNING: RUN runs accelerate launch with a config it cannot read here (--config_file c\.yaml: relative, after a cd in RUN) — " \
    "R7-5: $r -> a relative config after a cd is not the project's c.yaml: unknown, a WARNING" || bad "R7-5: $r"
  has "$(blk "$O")" '^launch_cfg=c\.yaml:unreadable$' "...bound as c.yaml:unreadable"; done
O=$(L lr --rs-mode plan -N cfp -n 1 -- "cd src && accelerate launch --config_file $LR/src/c.yaml t.py"); has "$O" '^WARNING: RUN runs accelerate launch with gpu_ids: 0,1 in .*src/c\.yaml — ' "...an absolute one is read wherever RUN goes"
O=$(L lr --rs-mode plan -N cfp -n 1 -- 'accelerate launch --config_file c.yaml t.py'); [ "$?" = 0 ] && hasnt "$O" '^WARNING:' "...no cd: the project's c.yaml (gpu_ids: all) is read — no warning" || bad "...no cd (plan not exit 0)"; rm -rf "$LR/src" "$LR/c.yaml"
O=$(L lr --rs-attempt cf5 --rs-mode plan -N cfm -n 1 -- 'accelerate launch --config_file new.yaml t.py'); HM=$(bh "$O")
printf 'gpu_ids: all\n' > "$LR/new.yaml"   # appears after the card: no warning now, and another launch_cfg
O=$(L lr --rs-expect "$HM" --rs-warnings "$(wd "$O")" -N cfm -n 1 -- 'accelerate launch --config_file new.yaml t.py'); RC=$?
[ "$RC" = 6 ] && has "$O" '^changed: launch_cfg warnings$' "R7-5: a config missing at the card, there at the launch -> exit 6, changed: launch_cfg warnings" || bad "R7-5: config appeared (rc=$RC)"
AC=$LR/.cache/huggingface/accelerate; O=$(L lr --rs-attempt cf6 --rs-mode plan -N cfd -n 1 -- 'accelerate launch t.py'); HD=$(bh "$O")
has "$(blk "$O")" '^launch_cfg=$' "R7-5: no default config: launch_cfg="
mkdir -p "$AC"; printf 'gpu_ids: all\n' > "$AC/default_config.yaml"
O=$(L lr --rs-expect "$HD" -N cfd -n 1 -- 'accelerate launch t.py'); RC=$?
[ "$RC" = 6 ] && has "$O" '^changed: launch_cfg$' "R7-5: a default config created after the card (gpu_ids: all, no warning) -> exit 6, changed: launch_cfg" || bad "R7-5: default config appeared (rc=$RC)"
head -c 70000 /dev/zero | tr '\0' '#' > "$AC/default_config.yaml"; O=$(L lr --rs-mode plan -N cfd -n 1 -- 'accelerate launch t.py')
has "$(blk "$O")" '^launch_cfg=\.cache/huggingface/accelerate/default_config\.yaml:unreadable$' "R7-5: a config over 64 KiB: unreadable"; rm -rf "$LR/.cache" "$LR/ddp.yaml" "$LR/new.yaml"
mkdir -p "$T/job"; printf 'localhost slots=1\n' > "$T/job/hostfile"
O=$(L dsh --rs-attempt hf1 --rs-mode plan -N dh -n 1 -- 'deepspeed train.py'); HH=$(bh "$O"); WH=$(wd "$O")
has "$(blk "$O")" "^launch_cfg=$T/job/hostfile:$(sha "$T/job/hostfile")\$" "R7-5: deepspeed's default hostfile, read without --hostfile: bound by its sha256"
printf 'localhost slots=4\n' > "$T/job/hostfile"
O=$(L dsh --rs-expect "$HH" --rs-warnings "$WH" -N dh -n 1 -- 'deepspeed train.py'); RC=$?
[ "$RC" = 6 ] && has "$O" '^changed: launch_cfg$' "R7-5: the hostfile edited after the card -> exit 6, changed: launch_cfg" || bad "R7-5: hostfile drift (rc=$RC)"
O=$(L dsh --rs-mode plan -N dh -n 1 -- 'deepspeed -H my.hf train.py'); has "$(blk "$O")" '^launch_cfg=my\.hf:unreadable$' "...with -H my.hf: the default hostfile is not read, nor bound — the named one is (R8-5; missing here: unreadable)"
echo "-- R8-5: a hostfile named explicitly (deepspeed -H FILE / --hostfile FILE, argparse spellings) is read and bound too --"
# the facts: deepspeed's runner takes -H / --hostfile (argparse: -HFILE, -H=FILE, --hostfile=FILE, a unique prefix --hostf; the
# last one given wins) — tests/vgate/launchers.sh ds_hostfile_flag= reads it from an installed runner (tests/88: a fake one, the
# real argparse); the stdlib part here, on a parser shaped as the runner's (-h/--help too: --h is ambiguous, refused)
if command -v python3 >/dev/null 2>&1; then
  F=$(python3 -I -c 'import argparse
p = argparse.ArgumentParser(); p.add_argument("-H", "--hostfile", default="/job/hostfile"); p.add_argument("-i", "--include", default="")
p.add_argument("-e", "--exclude", default=""); p.add_argument("--num_gpus", type=int, default=-1); p.add_argument("s"); p.add_argument("a", nargs=argparse.REMAINDER)
def h(a):
    try:
        return p.parse_args(a).hostfile
    except SystemExit:
        return "refused"
print(" ".join(h(a) for a in (["-H", "h1", "t.py"], ["-Hh2", "t.py"], ["-H=h3", "t.py"], ["--hostf", "h4", "t.py"], ["--hostfile=h5", "t.py"],
      ["--ho=h6", "t.py"], ["-H", "h7", "-H", "h8", "t.py"], ["--h", "h9", "t.py"])))' 2>/dev/null)
  [ "$F" = "h1 h2 h3 h4 h5 h6 h8 refused" ] && ok "fact: argparse (as deepspeed's runner) takes -H h, -Hh, -H=h, --hostf h, --hostfile=h, --ho=h; the last -H wins; --h is ambiguous with --help" \
    || bad "fact: argparse hostfile spellings (got '$F')"
else echo "  SKIP: no python3 here: the argparse hostfile facts not reproduced"; fi
printf 'localhost slots=1\n' > "$DS/hosts"; HS=$(sha "$DS/hosts")
O=$(L dsh --rs-attempt hx1 --rs-mode plan -N dx -n 1 -- 'deepspeed --hostfile hosts train.py'); RC=$?; HX=$(bh "$O"); WX=$(wd "$O")
[ "$RC" = 0 ] && has "$(blk "$O")" "^launch_cfg=hosts:$HS\$" "R8-5: deepspeed --hostfile hosts: read and bound (launch_cfg=hosts:<its sha256>)" || bad "R8-5: --hostfile bound (rc=$RC)"
[ "$(wn "$O")" = 1 ] && has "$O" '^WARNING: RUN runs deepspeed with --hostfile — such a launcher' "...its R5-2 WARNING unchanged (one line: an approved card's warnings_id stays)" || bad "R8-5: the --hostfile WARNING"
printf 'localhost slots=4\n' > "$DS/hosts"
O=$(L dsh --rs-attempt hx2 --rs-expect "$HX" --rs-warnings "$WX" -N dx -n 1 -- 'deepspeed --hostfile hosts train.py'); RC=$?
[ "$RC" = 6 ] && has "$O" '^changed: launch_cfg$' "R8-5: the --hostfile edited after the card (slots=1 -> 4) -> exit 6, changed: launch_cfg" || { bad "R8-5: hostfile drift (rc=$RC)"; printf '%s\n' "$O" | grep -v '^[a-z_]*=' | head -4 | sed 's/^/    | /'; }
[ ! -e "$DS/.rs/attempts/hx2/receipt" ] && ok "...nothing launched" || bad "...nothing launched"
printf 'localhost slots=1\n' > "$DS/hosts"
O=$(L dsh --rs-attempt hx3 --rs-expect "$HX" --rs-warnings "$WX" -N dx -n 1 -- 'deepspeed --hostfile hosts train.py'); RC=$?
[ "$RC" = 0 ] && has "$O" "^plan: bound_hash=$HX = --rs-expect" "...the approved bytes back: launches" || bad "R8-5: same hostfile launches (rc=$RC)"
for r in 'deepspeed -H hosts t.py' 'deepspeed -Hhosts t.py' 'deepspeed -H=hosts t.py' 'deepspeed --hostfile=hosts t.py' 'deepspeed --hostf hosts t.py' \
         'deepspeed --ho=hosts t.py' 'python -m deepspeed.launcher.runner -H hosts t.py' "deepspeed -H $H/projects/dsh/hosts t.py" 'ds --num_gpus 1 -H hosts t.py'; do
  O=$(L dsh --rs-mode plan -N dz -n 1 -- "$r"); has "$(blk "$O")" "^launch_cfg=hosts:$HS\$" "R8-5: $r -> hosts bound"; done
O=$(L dsh --rs-mode plan -N dz -n 1 -- 'deepspeed -H a.hf -H hosts t.py'); has "$(blk "$O")" "^launch_cfg=a\.hf:unreadable,hosts:$HS\$" "R8-5: two -H: both bound (sorted; argparse takes the last)"
for r in 'cd src && deepspeed -H hosts t.py' 'env -C src deepspeed --hostfile hosts t.py'; do
  O=$(L dsh --rs-mode plan -N dz -n 1 -- "$r"); has "$(blk "$O")" '^launch_cfg=hosts:unreadable$' "R8-5: $r -> a relative hostfile after a cd: unreadable (not the project's hosts)"; done
O=$(L dsh --rs-mode plan -N dz -n 1 -- 'deepspeed -H $HF t.py'); has "$(blk "$O")" '^launch_cfg=\\$HF:unreadable$' "R8-5: a hostfile named by an expansion: unreadable (%q-quoted)"
O=$(L dsh --rs-mode plan -N dz -n 1 -- 'deepspeed t.py --hostfile'); [ "$(blk "$O" | sed -n 's/^launch_cfg=//p')" = "\\'\\':unreadable" ] && ok "R8-5: a dangling --hostfile: '':unreadable (%q-quoted)" || bad "R8-5: a dangling --hostfile ($(blk "$O" | grep '^launch_cfg='))"
head -c 70000 /dev/zero | tr '\0' '#' > "$DS/big.hf"; O=$(L dsh --rs-mode plan -N dz -n 1 -- 'deepspeed -H big.hf t.py')
has "$(blk "$O")" '^launch_cfg=big\.hf:unreadable$' "R8-5: a hostfile over 64 KiB: unreadable"; rm -f "$DS/big.hf"
O=$(L dsh --rs-attempt hx4 --rs-mode plan -N dy -n 1 -- 'deepspeed -H new.hf t.py'); HN=$(bh "$O"); has "$(blk "$O")" '^launch_cfg=new\.hf:unreadable$' "R8-5: a hostfile missing at the card: new.hf:unreadable"
printf 'localhost slots=1\n' > "$DS/new.hf"
O=$(L dsh --rs-expect "$HN" --rs-warnings "$(wd "$O")" -N dy -n 1 -- 'deepspeed -H new.hf t.py'); RC=$?
[ "$RC" = 6 ] && has "$O" '^changed: launch_cfg$' "R8-5: ...there at the launch -> exit 6, changed: launch_cfg" || bad "R8-5: hostfile appeared (rc=$RC)"
rm -f "$DS/hosts" "$DS/new.hf"
rm -f "$T/job/hostfile" "$T/bin/accelerate"

echo "-- R5-4: info_prior = this project's journal receipts of the run (<run id> or <run id>--aNN) --"
IPN=$(mkp ipn 'WS_REMOTE_DIR=projects/ipn
ENV_KIND=none')
pri() { printf '%s\n' "$1" | sed -n 's/^info_prior=//p'; }
O=$(L ipn --rs-mode plan -N ip -d 0 -- true); [ "$(pri "$O")" = 0 ] && ok "R5-4: no history: info_prior=0" || bad "R5-4: no history (got '$(pri "$O")')"; HP0=$(bh "$O")
O=$(L ipn --rs-mode plan -N ip -d 0 -- true); [ "$(pri "$O")" = 0 ] && ok "...a plan's own attempt (no receipt) never counts" || bad "...plans count (got '$(pri "$O")')"
O=$(L ipn --rs-attempt ip1 -N ip -d 0 -- true); RC=$?; waitfor "$IPN/$(kv log "$IPN/.rs/attempts/ip1/receipt").rc"
[ "$RC" = 0 ] && ok "(a launch of ip: its receipt)" || bad "(a launch of ip, rc=$RC)"
sleep 1   # (a log name is per second: a plan of ip in the launch's second would find it taken)
O=$(L ipn --rs-mode plan -N ip -d 0 -- true); [ "$(pri "$O")" = 1 ] && ok "R5-4: after a launch of ip: info_prior=1" || bad "R5-4: after a launch (got '$(pri "$O")')"
[ "$(bh "$O")" = "$HP0" ] && ok "...envelope only: the bound_hash is unchanged" || bad "...info_prior changed the bound_hash"
O=$(L ipn --rs-mode plan -N ip--a02 -d 0 -- true); [ "$(pri "$O")" = 1 ] && ok "...a plan named ip--a02 counts the run id ip's receipts" || bad "...ip--a02 (got '$(pri "$O")')"
fr() { mkdir -p "$IPN/.rs/attempts/$1"; printf 'pid=1\npgid=1\nstart=1\nboot_id=x\nname=%s\nlog=logs/x.log\n' "$2" > "$IPN/.rs/attempts/$1/receipt"; }
fr f1 ip--a03; fr f2 ip--a3; fr f3 ipx; fr f4 ip--a03x; fr f5 other
O=$(L ipn --rs-mode plan -N ip -d 0 -- true); [ "$(pri "$O")" = 2 ] && ok "R5-4: ip--a03 counts; ip--a3, ipx, ip--a03x, other do not: 2" || bad "R5-4: names (got '$(pri "$O")')"
if [ "$(id -u)" != 0 ]; then chmod 000 "$IPN/.rs/attempts/f5/receipt"
  O=$(L ipn --rs-mode plan -N ip -d 0 -- true); [ "$(pri "$O")" = unknown ] && ok "R5-4: a receipt that cannot be read: info_prior=unknown (rsk: a relaunch)" || bad "R5-4: unreadable receipt (got '$(pri "$O")')"
  chmod 644 "$IPN/.rs/attempts/f5/receipt"; else echo "  SKIP: root reads any receipt: the unreadable-receipt case is not testable"; fi

echo "-- busy GPUs: a compute process on it (nvidia-smi --query-compute-apps + ps) --"
( exit 0 ) & DP=$!; wait "$DP"; U=$(ps -o user= -p $$ | tr -d ' ')   # DP: a pid that is gone
printf 'GPU-aaaa0000-0001, %s\nGPU-aaaa0000-0002, %s\n' "$$" "$DP" > "$T/apps"
O=$(L n -N b1 -n 2 -- c); RC=$?
[ "$RC" = 0 ] && has "$O" 'GPU(s) \[0,3\]' "auto-pick skips busy GPUs 1, 2 (the idlest by memory are 1, 2): picks 0,3" || bad "auto-pick skips busy (rc=$RC)"
has "$O" "^\[ws-box\] GPU(s) in use (id:user:pid): 1:$U:$$,2:?:$DP\$" "names them id:user:pid (ps -o user=; a pid ps cannot see: ?)"
O=$(L n --rs-attempt b2 -N b2 -n 3 -- c); RC=$?
[ "$RC" = 1 ] && has "$O" 'only 2 GPU id(s) free' "fewer free than -n -> exit 1 (only K free)" || bad "busy shortfall (rc=$RC)"
has "$O" 'Use -n 2, -d <ids>, or' "...and suggests -n K, the free count"
has "$(cat "$N/.rs/attempts/b2/result")" 'rc=1 verdict=refused' "...verdict=refused"; nolog b2 && ok "...nothing launched" || bad "...nothing launched"
O=$(L n --rs-attempt b2z -N b2z -n 1 -x 0,3 -- c); RC=$?   # busy 1,2 + the free 0,3 excluded: none left
[ "$RC" = 1 ] && has "$O" 'only 0 GPU id(s) free' "none free (1,2 busy, 0,3 excluded) -> exit 1" || bad "none free (rc=$RC)"
hasnt "$O" ' -n 0' "...never suggests -n 0 (no GPU count: exit 2)"
has "$O" 'None is free: wait for one, or (only with the user.s OK naming them) -d <ids> --gpu-busy-ok' "...says none is free"
nolog b2z && ok "...nothing launched" || bad "...nothing launched (none free)"
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
has "$B" '^warnings_gpu=0$' "...not as warnings_gpu (NF8: a busy landing is rsk's own never-a-grant check)"
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

echo "-- the wrapper's exit record under load (opt-in, every core busy for about a minute: RS_STRESS_TEST=1 bash selftest.sh) --"
# a group TERM right after the start, 40 times, with every core busy: each <log>.rc must read rc=143 term=1 — the reproduction
# behind the wait-loop guard above (without it, bash 5.2.37 here wrote rc=-1 term=1 in 3 of 60 such runs: unreadable to status.sh)
if [ "${RS_STRESS_TEST:-0}" = 1 ]; then
  BP=""; for k in $(seq 1 "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"); do timeout 300 sh -c 'while :; do :; done' & BP="$BP $!"; done
  SP=$BP; bads=""
  for i in $(seq 1 40); do
    O=$(L n -N st$i -d 2 -- sleep 30); A=$(latt "$N"); P=$(kv pid "$A/receipt"); [ -n "$P" ] && kill -TERM -- "-$P" 2>/dev/null
    f=$N/$(kv log "$A/receipt").rc; { waitfor "$f" && grep -qx 'rc=143 term=1 at=[0-9]*' "$f"; } || bads="$bads $i:$(cut -d' ' -f1 "$f" 2>/dev/null)"
  done; kill $BP 2>/dev/null; SP=""
  [ -z "$bads" ] && ok "40 group TERMs under load: every <log>.rc reads rc=143 term=1" || bad "40 group TERMs under load: not rc=143 term=1:$bads"
else echo "  SKIP: the wrapper's exit record under load (set RS_STRESS_TEST=1)"; fi
