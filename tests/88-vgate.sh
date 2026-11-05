#!/usr/bin/env bash
# tests/88-vgate.sh — phase A: tests/vgate/slurm-remote.sh (the V-gate reproductions, never run against a target here)
# under stub sbatch/scontrol/squeue/sacct/scancel and an instant sleep: a scratch dir given relative to the remote home
# reaches sbatch as an absolute --chdir and job.sh writes absolute paths; a failed sbatch stops the gate (exit 1).
set -u
. "$RS_HOME/tests/lib.sh"
G=$RS_HOME/tests/vgate/slurm-remote.sh; V=$T/vg; mkdir -p "$V/bin" "$V/home"
cat > "$V/bin/sbatch" <<EOS
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && { echo "slurm 0.0-stub"; exit 0; }
[ -f "$V/sbatch-fails" ] && { echo "sbatch: error: stub" >&2; exit 1; }
printf '%s\n' "\$*" >> "$V/sbatch.log"; echo \$(( 100 + \$(wc -l < "$V/sbatch.log") ))
EOS
for c in scontrol squeue sacct scancel sleep; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$c" "$V" > "$V/bin/$c"; done
chmod +x "$V/bin/"*
vg() { ( cd "$V/home" && PATH="$V/bin:$PATH" bash "$G" "$@" 2>&1 ); }

echo "-- slurm-remote.sh: a relative scratch dir --"
O=$(vg scratch/vg gpu); RC=$?; D=$(cd "$V/home/scratch/vg" 2>/dev/null && pwd -P)
[ "$RC" = 0 ] && [ -n "$D" ] && ok "gate runs to the end on stubs (exit 0)" || { bad "gate runs to the end on stubs (rc=$RC)"; echo "$O" | head -5 | sed 's/^/    | /'; }
has "$O" "dir=$D\$" "dir= is the physical scratch dir"
has "$(cat "$V/sbatch.log" 2>/dev/null)" "rs-vgate-rq --chdir $D job.sh\$" "requeue job: --chdir is absolute (not resolved again inside the scratch dir)"
has "$(cat "$D/job.sh" 2>/dev/null)" ">> \"$D/requeue.out\"" "job.sh appends to an absolute requeue.out"
has "$(cat "$V/sbatch.log" 2>/dev/null)" '^--parsable -p gpu -c 1 ' "no extra sbatch args: none passed"
hasnt "$(grep -v '^ *#' "$G")" '[^+]"\${X\[@\]}"' "extra sbatch args expand as \${X[@]+...} (bash < 4.4 + set -u)"
C=$(cat "$V/calls.log" 2>/dev/null)   # the identity reads rsk cancel / run-watch rely on, each of the script's own jobs
has "$C" '^squeue -h -u [^ ]* -O JobID:0|,UserName:0|,Name:0|,WorkDir:0|$' "identity read: squeue -u -O JobID,UserName,Name,WorkDir"
has "$C" '^squeue -h -u [^ ]* --states=all -O JobID:0|,Name:0|,UserName:0|,WorkDir:0|,State:0|$' "identity read: run-watch's / rsk cancel's squeue format"
has "$C" '^squeue -h -j 10[0-9] -O JobID:0|,UserName:0|$' "identity read: squeue -j (another user's job by id)"
has "$C" '^sacct -X -n -j 10[0-9] -o JobID,JobName,User,WorkDir -P$' "identity read: sacct -j -o JobID,JobName,User,WorkDir -P"
S=$(cat "$V/sbatch.log" 2>/dev/null)   # --rs-chain's singleton: two held jobs of one name, the second released, both cancelled
[ "$(printf '%s\n' "$S" | grep -c -- '--hold -t 00:01:00 -J rs-vgate-single --dependency=singleton --wrap true$')" = 2 ] \
  && ok "singleton repro: two held 1-min jobs of one name with --dependency=singleton" || bad "singleton repro: the two submits"
has "$C" '^scontrol release 10[0-9]$' "...the second is released (the first stays held)"
has "$C" '^squeue -h -j 10[0-9] -O State:0|,Reason:0|$' "...its State|Reason read (PENDING|Dependency| wanted)"
has "$O" '^singleton_second=.*(want PENDING|Dependency| while 10[0-9] is held)$' "...printed as singleton_second="
[ "$(printf '%s\n' "$C" | grep -c '^scancel 10[0-9]$')" -ge 2 ] && ok "...both cancelled" || bad "singleton repro: both cancelled"

echo "-- slurm-remote.sh: sbatch fails --"
touch "$V/sbatch-fails"; : > "$V/calls.log"
O=$(vg scratch/vg2 gpu); RC=$?
[ "$RC" = 1 ] && has "$O" '^vgate=fail sbatch (dup)' "a failed sbatch stops the gate (exit 1)" || bad "a failed sbatch stops the gate (rc=$RC)"
hasnt "$O" 'dup_time=\|requeue=' "nothing measured on an empty job id"
hasnt "$(cat "$V/calls.log")" 'scancel *$' "no scancel of an empty job id"
