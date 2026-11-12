#!/usr/bin/env bash
# tests/51-gate-exclude.sh — phase A: remote/submit.sh's availability gate on the fx-slurm fixture (stub sinfo / sbatch,
# nothing submitted for real) counts no GPU on a node the job's own --exclude forbids, given ONCE among the words sbatch
# gets (the harness's, the policy's, SBATCH_EXTRA's); given more than once, none is subtracted and a NOTE says so (which
# one sbatch keeps has no reproduction: tests/vgate dup_time= is --time's); an option's separate value is never one
# (tests/vgate comment_value=), a value that is no plain host list (a hostlist range, a path) is not subtracted and ONE
# NOTE says so; no --exclude = the count as before; the plan block's fields and
# bound_hash are untouched (the gate's numbers are envelope, never bound).  Run by selftest.sh:  bash tests/51-gate-exclude.sh
set -u
. "$RS_HOME/tests/lib.sh"
subo() { local p=$1; shift; : > "$T/sbatch.log"; PATH="$T/bin:$PATH" bash "$p/.fx-slurm/submit.sh" "$@" 2>&1; }
rc_is() { [ "$2" = "$1" ] && ok "$3 (exit $1)" || { bad "$3 (exit $1, got $2)"; printf '%s\n' "${4:-}" | head -8 | sed 's/^/    | /'; }; }
xp() { mk_proj fx-slurm "REMOTE_DIR=/x
SBATCH_EXTRA=\"$1\""; }   # xp WORDS: a project whose conf's SBATCH_EXTRA is WORDS
blk() { printf '%s\n' "$1" | sed -n '/^@@plan v1$/,/^@@end$/p'; }
# three nodes in partition gpu: n1 4 free (idle), n2 2 of 4 free (mixed), n3 4 free (idle) = 10 free, 4 on one node
NODES3=$(printf '%s\n' 'n1   gpu:a100:4   gpu:a100:0   idle' 'n2   gpu:a100:4   gpu:a100:2(IDX:0-1)   mixed' 'n3   gpu:a100:4   gpu:a100:0   idle')
stub_sinfo gpu "$NODES3"

echo "-- no --exclude: the count as before --"
P0=$(mk_proj fx-slurm 'REMOTE_DIR=/x') || { bad "mk_proj fx-slurm"; exit 1; }
O=$(subo "$P0" -g 4 -- echo hi); RC=$?
rc_is 0 "$RC" "4 free on one node, -g 4: submits" "$O"; has "$O" '^  -> 10 free now; up to 4 on one node' "...10 free, 4 on one node"
has "$O" "^gpu nodes carrying 'any' (free/cfg, state):\$" "...the table's header unchanged"
hasnt "$O" 'excluded' "...no node marked [excluded]"; hasnt "$O" '^NOTE: this job.s --exclude' "...no NOTE"

echo "-- the job's --exclude nodes are listed [excluded] and never counted --"
P=$(xp '--exclude=n1,n3'); O=$(subo "$P" -g 4 -- echo hi); RC=$?
rc_is 1 "$RC" "--exclude=n1,n3: 2 free (n2) < -g 4: the gate's warning" "$O"; nosub "...nothing submitted"
has "$O" "^WARNING: only 2 free of 'any' (2 on one node)\. Re-run -y" "...the WARNING counts n2 alone"
has "$O" '^  n1 .*4/4  \[idle\] \[excluded\]$' "...n1 listed, marked [excluded]"; has "$O" '^  n3 .*\[excluded\]$' "...n3 too"
hasnt "$O" '^  n2 .*excluded' "...n2 not marked"; has "$O" "^gpu nodes carrying 'any' (free/cfg, state; \[excluded\] = named by its --exclude, not counted):\$" "...the header says what [excluded] means"
O=$(subo "$P" -g 2 -- echo hi); RC=$?
rc_is 0 "$RC" "...-g 2 fits n2: submits" "$O"; has "$O" 'ARG:--exclude=n1,n3$' "...sbatch still gets the --exclude word"
P=$(xp '--exclude n1'); O=$(subo "$P" -g 4 -- echo hi); RC=$?
rc_is 0 "$RC" "--exclude n1 (a separate value): n3 still has 4" "$O"; has "$O" '^  -> 6 free now; up to 4 on one node' "...6 free (n2 + n3)"
P=$(xp '-x n1,n3'); rc_is 1 "$(subo "$P" -g 4 -- echo hi >/dev/null; echo $?)" "-x n1,n3 (short, separate value): 2 free < 4"
P=$(xp '-xn1,n3'); rc_is 1 "$(subo "$P" -g 4 -- echo hi >/dev/null; echo $?)" "-xn1,n3 (short, attached value): 2 free < 4"

echo "-- given more than once: none subtracted, a NOTE --"
P=$(xp '--exclude=n1,n3 -x n2'); O=$(subo "$P" -g 4 -- echo hi); RC=$?
rc_is 0 "$RC" "--exclude=n1,n3 then -x n2: nothing subtracted" "$O"; has "$O" '^  -> 10 free now; up to 4 on one node' "...10 free (all counted)"
has "$O" '^NOTE: this job gives --exclude/-x 2 times' "...the NOTE"; hasnt "$O" 'excluded\]' "...no node marked"
P=$(xp '-x n2 --exclude=n1,n3'); has "$(subo "$P" -g 4 -- echo hi)" '^  -> 10 free now' "-x n2 then --exclude=n1,n3: nothing subtracted"
P=$(xp '--exclude=n1 -xn2'); has "$(subo "$P" -g 4 -- echo hi)" '^  -> 10 free now' "--exclude=n1 then -xn2: nothing subtracted"
echo "-- an option's separate value is never an option: --comment -xn3 is a comment --"
P=$(xp '--exclude=n1 --comment -xn3'); O=$(subo "$P" -g 4 -- echo hi); RC=$?
rc_is 0 "$RC" "--exclude=n1 --comment -xn3: n1 excluded, n3 counted" "$O"; has "$O" '^  -> 6 free now; up to 4 on one node' "...6 free"
hasnt "$O" '^  n3 .*excluded' "...n3 not marked"

echo "-- the policy's words come before SBATCH_EXTRA's --"
cp -R "$RS_USER_DIR" "$T/user-x"; printf 't_policy() { SB_ARGS+=(--exclude=n2); return 0; }\n' > "$T/user-x/targets/fx-slurm/policy.local.sh"
PP=$(RS_USER_DIR=$T/user-x mk_proj fx-slurm 'REMOTE_DIR=/x'); O=$(subo "$PP" -g 4 -- echo hi)
has "$O" '^  -> 8 free now' "the policy's --exclude=n2 alone: n2 not counted"; has "$O" '^  n2 .*\[excluded\]$' "...n2 marked"
printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="--exclude=n1"\n' > "$PP/.hpc.conf"; O=$(subo "$PP" -g 4 -- echo hi)
has "$O" '^  -> 10 free now' "...plus SBATCH_EXTRA's --exclude=n1: two of them, none subtracted"; has "$O" '^NOTE: this job gives --exclude/-x 2 times' "...the NOTE"

echo "-- a value that is no plain host list: not subtracted, one NOTE --"
P=$(xp '--exclude=n[1-3]'); O=$(subo "$P" -g 4 -- echo hi); RC=$?
rc_is 0 "$RC" "--exclude=n[1-3]: nothing subtracted, 4 on one node: submits" "$O"; has "$O" '^  -> 10 free now' "...10 free (all counted)"
[ "$(printf '%s\n' "$O" | grep -c '^NOTE: this job.s --exclude .n\[1-3\]. is not a plain comma-separated host list')" = 1 ] \
  && ok "...ONE NOTE naming the value" || { bad "...ONE NOTE naming the value"; printf '%s\n' "$O" | grep NOTE | sed 's/^/    | /'; }
hasnt "$O" 'excluded\]' "...no node marked"; has "$O" 'ARG:--exclude=n\[1-3\]$' "...sbatch gets the word as written"
P=$(xp '-x n1 --exclude=n[1-3]'); O=$(subo "$P" -g 4 -- echo hi)
has "$O" '^  -> 10 free now' "-x n1 then --exclude=n[1-3]: two of them, not even n1 is subtracted"; has "$O" '^NOTE: this job gives --exclude/-x 2 times' "...the NOTE"
P=$(xp '--exclude=/x/bad-nodes'); O=$(subo "$P" -g 4 -- echo hi)
has "$O" '^  -> 10 free now' "--exclude=/x/bad-nodes (a path): nothing subtracted"; has "$O" "^NOTE: this job.s --exclude ./x/bad-nodes. is not a plain" "...the NOTE"

echo "-- plan mode: the gate's numbers are envelope (info_avail), the bound fields as before --"
P=$(xp '--exclude=n1,n3'); O=$(subo "$P" --rs-mode plan -g 4 -- echo hi); RC=$?; B=$(blk "$O")
rc_is 0 "$RC" "plan: the gate's warning is acknowledged" "$O"; nosub "...nothing submitted"
has "$B" '^info_avail=free:2/max_node:2/gpu_type:any$' "...info_avail counts n2 alone"; has "$B" '^warnings_avail=1$' "...the availability WARNING counted"
has "$B" '^conf_extra=--exclude=n1[\\]*,n3$' "...conf_extra lists the word, as before"
H1=$(printf '%s\n' "$B" | sed -n 's/^bound_hash=//p')
stub_sinfo gpu "$(printf '%s\n' 'n1   gpu:a100:4   gpu:a100:4   mixed' 'n2   gpu:a100:4   gpu:a100:0   idle' 'n3   gpu:a100:4   gpu:a100:4   mixed')"
O=$(subo "$P" --rs-mode plan -g 4 -- echo hi); B=$(blk "$O"); H2=$(printf '%s\n' "$B" | sed -n 's/^bound_hash=//p')
has "$B" '^info_avail=free:4/max_node:4/gpu_type:any$' "...another sinfo: n2 has 4 now"; has "$B" '^warnings_avail=0$' "...no availability WARNING"
[ -n "$H1" ] && [ "$H1" = "$H2" ] && ok "...the bound_hash does not move with the gate's numbers" || bad "...bound_hash $H1 vs $H2"
stub_sinfo gpu "$NODES3"

echo "-- a full \$TMPDIR under bash 4.2 here-strings changes nothing (no temp file in the gate) --"
if fulltmp_ok; then
  P=$(xp '--exclude=n1,n3'); : > "$T/sbatch.log"
  O=$(fulltmp env PATH="$T/bin:$PATH" bash "$P/.fx-slurm/submit.sh" -g 4 -- echo hi 2>&1); RC=$?
  rc_is 1 "$RC" "TMPDIR full, BASH_COMPAT=42: n1 and n3 still excluded" "$O"; has "$O" "^WARNING: only 2 free of 'any'" "...the same WARNING"; nosub "...nothing submitted"
else echo "  SKIP: no user namespace here (unshare -rm) or here-strings do not fail on a full TMPDIR: the full-TMPDIR check runs on Linux"; fi
