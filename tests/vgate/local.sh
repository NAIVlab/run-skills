#!/usr/bin/env bash
# tests/vgate/local.sh — reproductions run FROM this machine against one target, only with the user's OK:
#   bash tests/vgate/local.sh <alias> <scratch-dir> [slurm|nohup] [addr-a addr-b]
# <scratch-dir> is absolute or relative to the remote home — never with '~' (it is quoted, so it would not expand).
# (1) mkdir as a claim: two concurrent ssh sessions race for the same 300 names (each must be won exactly once); with
# addr-a/addr-b (two addresses behind the alias' round-robin name) each session is a fresh connection to its own login
# node, else both use the alias as configured; the hostnames printed show where they landed. (2) a non-pty ssh whose
# client dies: does the remote command survive when it stays silent, and when it writes to the dead stdout? (3) nohup
# targets: boot_id and the /proc/<pid>/stat start time are readable. Writes only under <scratch-dir>. NOT in selftest.
set -u
H=$1; D=$2; K=${3:-slurm}; A=${4:-}; B=${5:-}
case "$D" in *'~'*) echo "vgate=fail: <scratch-dir> without '~' (a relative path starts at the remote home)"; exit 2 ;; esac
S=(ssh -o BatchMode=yes -o ConnectTimeout=20 "$H")
NAME=$(ssh -G "$H" 2>/dev/null | awk '$1 == "hostname" { print $2 }')
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
on() {   # on ADDR CMD: a fresh (unmultiplexed) connection, to ADDR when given
  if [ -n "$1" ]; then ssh -o BatchMode=yes -o ConnectTimeout=20 -o ControlMaster=no -o ControlPath=none \
    -o HostName="$1" -o HostKeyAlias="$NAME" "$H" "$2"; else "${S[@]}" "$2"; fi
}
"${S[@]}" "rm -rf '$D/race' '$D/nopty-silent' '$D/nopty-writer' && mkdir -p '$D/race'" || { echo "vgate=fail mkdir $D"; exit 1; }
T0=$(( $(date +%s) + 8 ))   # both sessions start at the same second (login nodes keep NTP time)
race="cd '$D' && h=\$(hostname) && echo \"host \$h\" && while [ \$(date +%s) -lt $T0 ]; do sleep 0.05; done; for i in \$(seq 1 300); do mkdir race/c\$i 2>/dev/null && echo \"\$i \$h\"; done"
on "$A" "$race" > "$W/race.a" 2> "$W/err.a" & on "$B" "$race" > "$W/race.b" 2> "$W/err.b" & wait
wins() { grep -cv '^host ' "$1"; }
echo "race_wins=$(cat "$W"/race.* | grep -cv '^host ') (want 300)" \
  "distinct=$(cat "$W"/race.* | grep -v '^host ' | cut -d' ' -f1 | sort -u | wc -l)" \
  "a=$(sed -n 's/^host //p' "$W/race.a"):$(wins "$W/race.a") b=$(sed -n 's/^host //p' "$W/race.b"):$(wins "$W/race.b")" \
  "err=$(cat "$W"/err.* | grep -v '^Pseudo-terminal' | head -c 200 | tr '\n' ' ')"
"${S[@]}" "sleep 6; echo survived > '$D/nopty-silent'" & p1=$!
"${S[@]}" "echo hi; sleep 6; echo after; echo survived > '$D/nopty-writer'" > /dev/null & p2=$!
sleep 2; kill "$p1" "$p2" 2>/dev/null; wait 2>/dev/null; sleep 10
echo "nopty_after_client_death=$("${S[@]}" "cd '$D' && for f in nopty-silent nopty-writer; do [ -e \$f ] && echo \${f}:survived || echo \${f}:killed; done" | tr '\n' ' ')"
if [ "$K" = nohup ]; then
  echo "proc=$("${S[@]}" 'echo boot_id=$(cat /proc/sys/kernel/random/boot_id) self_start=$(sed "s/.*) //" /proc/self/stat | cut -d" " -f20) clk_tck=$(getconf CLK_TCK) shell=$0')"
fi
