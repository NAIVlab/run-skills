#!/usr/bin/env bash
# tests/52-attempt.sh — phase A: remote/submit.sh's attempt journal and the P2 guards on the fx-slurm fixture (stub
# sbatch / squeue / sinfo, nothing submitted for real): the claim (.rs/attempts/<NONCE>/, --rs-attempt, exit 75, invalid
# NONCEs), out / err / stage / result / receipt and the submit-time snapshots, output discipline (stdout to stdout, stderr
# to stderr, a caller whose channel died loses nothing), sbatch-failure verdicts (refused, or unknown when the job may
# exist), an OLD parser given --rs-attempt, conf isolation (a conf's sbatch() / printf() / PATH never reach the submit; it
# sees the profile's T_*), nested submissions, the duplicate guard (exit 6, symlinked WorkDirs), the SBATCH_EXTRA lint, the
# --comment merge, and policy code (its own EXIT trap, fd 3) kept in the submit's subshell.  bash tests/52-attempt.sh
set -u
. "$RS_HOME/tests/lib.sh"
subo() { local p=$1; shift; : > "$T/sbatch.log"; PATH="$T/bin:$PATH" bash "$p/.fx-slurm/submit.sh" "$@" 2>&1; }
att() { printf '%s\n' "$1" | sed -n 's|^attempt: \.rs/attempts/||p' | head -n 1; }   # att OUTPUT -> NONCE
lastc() { printf '%s\n' "$1" | grep '^ARG:--comment' | tail -n 1; }                   # the --comment sbatch keeps (the last)
natt() { ls -d "$1"/.rs/attempts/*/ 2>/dev/null | wc -l | tr -d ' '; }
rc_is() { [ "$2" = "$1" ] && ok "$3 (exit $1)" || { bad "$3 (exit $1, got $2)"; printf '%s\n' "${4:-}" | head -8 | sed 's/^/    | /'; }; }
P=$(mk_proj fx-slurm 'REMOTE_DIR=/x
ENV_KIND=uv') || { bad "mk_proj fx-slurm"; exit 1; }

echo "-- the journal of a call without --rs-attempt (every caller today) --"
O=$(subo "$P" -n jn -- echo hi); RC=$?; N=$(att "$O"); A=$P/.rs/attempts/$N
rc_is 0 "$RC" "submits" "$O"
[ -n "$N" ] && [ -d "$A" ] && ok "claims a generated attempt dir and names it: attempt: .rs/attempts/$N" || bad "attempt dir claimed and printed"
[ "$(printf '%s\n' "$O" | grep -c '^attempt: ')" = 1 ] && ok "the attempt line is printed once" || bad "the attempt line is printed once"
case "$N" in [0-9]*T[0-9]*Z-[0-9]*-[0-9]*) ok "generated NONCE = <UTC time>-<pid>-<random>" ;; *) bad "generated NONCE shape ($N)" ;; esac
has "$(cat "$A/result" 2>/dev/null)" '^stage=done rc=0 verdict=submitted at=[0-9][0-9]*$' "result: stage=done rc=0 verdict=submitted"
has "$(cat "$A/stage" 2>/dev/null)" '^done$' "stage file: done"
R=$(cat "$A/receipt" 2>/dev/null)
has "$R" '^job=1$' "receipt: job id"; has "$R" '^name=jn$' "receipt: name"; has "$R" '^partition=gpu$' "receipt: partition"
has "$R" "^proj=$P\$" "receipt: proj"; has "$R" "^nonce=$N\$" "receipt: nonce"; has "$R" '^at=[0-9][0-9]*$' "receipt: at (epoch)"
has "$R" "^argv=sbatch --job-name=jn .*--comment=rs=$N $P/\.fx-slurm/job\.sbatch echo hi\$" "receipt: argv = the sbatch argv (printf %q, one line)"
[ "$(wc -l < "$A/receipt")" = 7 ] && ok "receipt: exactly 7 key=value lines" || bad "receipt: 7 lines (got $(wc -l < "$A/receipt"))"
has "$(cat "$A/out")" '^log: .*/logs/jn_1\.out' "out = what went to stdout (the log: line)"
has "$(cat "$A/err")" '^+ sbatch ' "err = what went to stderr (the + sbatch line)"
cmp -s "$A/conf" "$P/.hpc.conf" && ok "snapshot: conf = .hpc.conf at submit time" || bad "snapshot: conf"
cmp -s "$A/profile.sh" "$P/.fx-slurm/profile.sh" && ok "snapshot: the deployed profile.sh" || bad "snapshot: profile.sh"
cmp -s "$A/env.sh" "$P/.fx-slurm/env.sh" && ok "snapshot: the deployed env.sh" || bad "snapshot: env.sh"
[ ! -e "$A/hook" ] && ok "no ENV_HOOK: no hook snapshot" || bad "no ENV_HOOK: no hook snapshot"
has "$O" "^ENV:RS_ATTEMPT=$N\$" "sbatch runs with RS_ATTEMPT=<NONCE> in its environment (--export=ALL carries it into the job)"
has "$O" "^ARG:--export=ALL,PROJ=$P,CLUSTER=fx-slurm,TARGET=fx-slurm\$" "the --export argument itself is unchanged"
has "$(lastc "$O")" "^ARG:--comment=rs=$N\$" "no comment given: --comment=rs=<NONCE>"
[ "$(printf '%s\n' "$O" | grep -n '^ARG:--comment' | tail -n 1 | cut -d: -f1)" -gt "$(printf '%s\n' "$O" | grep -n '^ARG:--error=' | cut -d: -f1)" ] \
  && ok "the comment is among the LAST options (nothing earlier can override it)" || bad "the comment comes last"
printf 'echo hooked\n' > "$P/hook.sh"; printf 'REMOTE_DIR=/x\nENV_KIND=uv\nENV_HOOK=hook.sh\n' > "$P/.hpc.conf"
O=$(subo "$P" -- echo hi); A=$P/.rs/attempts/$(att "$O")
cmp -s "$A/hook" "$P/hook.sh" && ok "ENV_HOOK names a file: hook snapshot" || bad "hook snapshot"
printf 'REMOTE_DIR=/x\nENV_KIND=uv\n' > "$P/.hpc.conf"

echo "-- output discipline: stdout to stdout, stderr to stderr, exit status unchanged --"
O=$(PATH="$T/bin:$PATH" bash "$P/.fx-slurm/submit.sh" -- echo hi 2>/dev/null)
has "$O" '^attempt: ' "stdout: attempt line"; has "$O" '^log: ' "stdout: log line"; hasnt "$O" '^+ sbatch' "stdout: no + sbatch line"
O=$(PATH="$T/bin:$PATH" bash "$P/.fx-slurm/submit.sh" -- echo hi 2>&1 >/dev/null)
has "$O" '^+ sbatch ' "stderr: + sbatch line"; hasnt "$O" '^log: ' "stderr: no log line"
O=$(subo "$P" -p vip -- echo hi); RC=$?; A=$P/.rs/attempts/$(att "$O")
rc_is 3 "$RC" "policy refusal keeps its exit code"; has "$(cat "$A/result")" '^stage=policy rc=3 verdict=refused ' "result: stage=policy rc=3 verdict=refused"
O=$(subo "$P" -Z -- echo hi); RC=$?; A=$P/.rs/attempts/$(att "$O")
rc_is 2 "$RC" "usage error"; has "$(cat "$A/result")" '^stage=pre-policy rc=2 verdict=refused ' "result: stage=pre-policy rc=2 verdict=refused"
stub_sinfo gpu 'nodeA   gpu:h100:4   gpu:h100:3(IDX:0-2)   mixed'
O=$(subo "$P" -G h100 -g 2 -- echo hi); RC=$?; A=$P/.rs/attempts/$(att "$O")
rc_is 1 "$RC" "availability warning"; has "$(cat "$A/result")" '^stage=avail rc=1 verdict=refused ' "result: stage=avail rc=1 verdict=refused"
rm -f "$T/sinfo.d/gpu"

echo "-- a caller that is gone: the remote side completes, records, and only then fails to print --"
mkdir -p "$T/slow"; printf '#!/usr/bin/env bash\nsleep 0.5\nexec %q "$@"\n' "$T/bin/sbatch" > "$T/slow/sbatch"; chmod +x "$T/slow/sbatch"
B=$(natt "$P"); : > "$T/sbatch.log"
( PATH="$T/slow:$T/bin:$PATH" bash "$P/.fx-slurm/submit.sh" -n gone -- echo hi 2>&1; echo "rc=$?" > "$T/gone.rc" ) | { sleep 0.1; }
A=$(last_attempt "$P")
[ "$(natt "$P")" = $((B + 1)) ] && [ -s "$T/sbatch.log" ] && ok "reader gone before sbatch returned: the job was still submitted" || bad "submitted with a dead reader"
has "$(cat "$T/gone.rc")" '^rc=0$' "...and submit.sh's exit status is still 0 (a failed replay changes nothing)"
has "$(cat "$A/result" 2>/dev/null)" '^stage=done rc=0 verdict=submitted ' "...result written"; has "$(cat "$A/receipt" 2>/dev/null)" '^job=1$' "...receipt written"
has "$(cat "$A/out" 2>/dev/null)" '^log: .*/logs/gone_1\.out' "...out holds what the caller never saw"; has "$(cat "$A/err" 2>/dev/null)" '^+ sbatch' "...err too"
( PATH="$T/slow:$T/bin:$PATH" exec bash "$P/.fx-slurm/submit.sh" -n hup -- echo hi > "$T/hup.out" 2>&1 ) & HP=$!
sleep 0.2; kill -HUP "$HP" 2>/dev/null; wait "$HP"; RC=$?; A=$(last_attempt "$P")
rc_is 0 "$RC" "a SIGHUP mid-submit (a pty session hanging up) does not stop it"; has "$(cat "$A/receipt" 2>/dev/null)" '^name=hup$' "...the receipt is written"
PATH="$T/bin:$PATH" bash "$P/.fx-slurm/submit.sh" -n closed -- echo hi >&- 2>&-; RC=$?; A=$(last_attempt "$P")
rc_is 0 "$RC" "stdout and stderr closed outright: still submits"; has "$(cat "$A/receipt" 2>/dev/null)" '^name=closed$' "...with its receipt"

echo "-- sbatch failures: refused vs unknown (it may have created the job) --"
mkdir -p "$T/sb"; sbx() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$T/sb/sbatch"; chmod +x "$T/sb/sbatch"; }
sbx 'echo "Submitted batch job 77"; echo "sbatch: error: Socket timed out on send/recv operation" >&2; exit 1'
O=$(PATH="$T/sb:$T/bin:$PATH" bash "$P/.fx-slurm/submit.sh" -n u -- echo hi 2>&1); RC=$?; A=$P/.rs/attempts/$(att "$O")
rc_is 1 "$RC" "created-then-rc-1: sbatch's rc"; has "$(cat "$A/result")" '^stage=sbatch rc=1 verdict=unknown ' "...verdict unknown (stage sbatch)"
[ ! -e "$A/receipt" ] && ok "...no receipt" || bad "...no receipt"; has "$O" 'Socket timed out' "...sbatch's stderr re-emitted"
hasnt "$O" '^log: ' "...no log line (as before: nothing claims a job id)"; has "$(cat "$A/out")" 'Submitted batch job 77' "...sbatch's stdout kept in the journal"
for e in 'Batch job submission failed: Invalid partition name specified' 'Batch job submission failed: Job violates accounting/QOS policy (job submit limit, user'"'"'s size and/or time limits)' \
         'Batch job submission failed: Invalid account or account/partition combination specified' 'QOSMaxSubmitJobPerUserLimit'; do
  sbx "echo \"sbatch: error: $e\" >&2; exit 1"
  O=$(PATH="$T/sb:$T/bin:$PATH" bash "$P/.fx-slurm/submit.sh" -- echo hi 2>&1); RC=$?; A=$P/.rs/attempts/$(att "$O")
  [ "$RC" = 1 ] && has "$(cat "$A/result")" '^stage=sbatch rc=1 verdict=refused ' "explicit rejection -> refused: ${e:0:60}" || bad "explicit rejection -> refused (rc=$RC): $e"
done
sbx 'echo "sbatch: error: something else" >&2; exit 3'
O=$(PATH="$T/sb:$T/bin:$PATH" bash "$P/.fx-slurm/submit.sh" -- echo hi 2>&1); RC=$?; A=$P/.rs/attempts/$(att "$O")
rc_is 3 "$RC" "another sbatch rc propagates verbatim"; has "$(cat "$A/result")" ' rc=3 verdict=unknown ' "...verdict unknown"
sbx 'echo "queued, somehow"; exit 0'
O=$(PATH="$T/sb:$T/bin:$PATH" bash "$P/.fx-slurm/submit.sh" -- echo hi 2>&1); RC=$?; A=$P/.rs/attempts/$(att "$O")
rc_is 0 "$RC" "rc 0 without a job id"; has "$(cat "$A/result")" ' rc=0 verdict=unknown ' "...verdict unknown, no receipt"; [ ! -e "$A/receipt" ] && ok "...no receipt" || bad "...no receipt"

echo "-- --rs-attempt NONCE --"
O=$(subo "$P" --rs-attempt n-1.a_B -n x -- echo hi); RC=$?
rc_is 0 "$RC" "--rs-attempt NONCE submits" "$O"; [ -d "$P/.rs/attempts/n-1.a_B" ] && has "$O" '^attempt: \.rs/attempts/n-1\.a_B$' "...into exactly that dir" || bad "...into exactly that dir"
has "$O" '^ENV:RS_ATTEMPT=n-1\.a_B$' "...and that NONCE reaches the job"; hasnt "$O" 'ARG:--rs-attempt\|ARG:n-1' "...the flag never reaches sbatch"
cp "$P/.rs/attempts/n-1.a_B/result" "$T/r1"; cp "$P/.rs/attempts/n-1.a_B/out" "$T/o1"; B=$(natt "$P")
O=$(subo "$P" --rs-attempt n-1.a_B -n x -- echo hi); RC=$?
rc_is 75 "$RC" "the same NONCE again: already claimed" "$O"; has "$O" 'already claimed' "...says so"; nosub "...nothing submitted"
cmp -s "$T/r1" "$P/.rs/attempts/n-1.a_B/result" && cmp -s "$T/o1" "$P/.rs/attempts/n-1.a_B/out" && [ "$(natt "$P")" = "$B" ] \
  && ok "...the existing attempt is left exactly as it was" || bad "...the existing attempt untouched"
L64=$(printf 'a%.0s' $(seq 1 64)); O=$(subo "$P" --rs-attempt "$L64" -n x -- echo hi); rc_is 0 $? "a 64-character NONCE is accepted"
O=$(subo "$P" -n x -- echo --rs-attempt zz); has "$O" '^ARG:--rs-attempt$' "after --, --rs-attempt is the payload's"; [ ! -d "$P/.rs/attempts/zz" ] && ok "...and claims nothing" || bad "...claims nothing"
B=$(natt "$P")
for n in '' . .. -y -p a/b 'a b' "${L64}b" .hidden _x 'a*' 'é'; do
  O=$(subo "$P" --rs-attempt "$n" -- echo hi); RC=$?
  [ "$RC" = 2 ] && ok "invalid NONCE '$n' refused (exit 2)" || bad "invalid NONCE '$n' refused (exit 2, got $RC)"
done
for a in '--rs-attempt=n2' '--rs-attempt n3 --rs-attempt n4' '--rs-attempt'; do
  O=$(subo "$P" $a -- echo hi); RC=$?; [ "$RC" = 2 ] && ok "'$a' refused (exit 2)" || bad "'$a' refused (exit 2, got $RC)"
done
O=$(subo "$P" -n x --rs-attempt); RC=$?; [ "$RC" = 2 ] && ok "a trailing --rs-attempt refused (exit 2)" || bad "a trailing --rs-attempt refused (got $RC)"
[ "$(natt "$P")" = "$B" ] && ok "no attempt dir created by any refused NONCE" || bad "no attempt dir created by a refused NONCE"
nosub "invalid NONCEs submit nothing"

echo "-- an OLD submit.sh (before --rs-attempt) given --rs-attempt NONCE exits 2 before sbatch --"
OLDC=""
if git -C "$RS_HOME" rev-parse --git-dir >/dev/null 2>&1; then
  for c in $(git -C "$RS_HOME" log --format=%H -n 50 -- remote/submit.sh 2>/dev/null); do   # the newest committed parser without it
    git -C "$RS_HOME" show "$c:remote/submit.sh" 2>/dev/null | grep -q 'rs-attempt' || { OLDC=$c; break; }; done
fi
if [ -n "$OLDC" ]; then
  OP=$(mk_proj fx-slurm 'REMOTE_DIR=/x'); git -C "$RS_HOME" show "$OLDC:remote/submit.sh" > "$OP/.fx-slurm/submit.sh"
  for a in '--rs-attempt n1 -- echo hi' '-p gpu -y --rs-attempt n1 -- echo hi' '--rs-attempt 20261104T000000Z-1-2 -g 1 -- echo hi'; do
    O=$(subo "$OP" $a); RC=$?
    [ "$RC" = 2 ] && has "$O" "unknown arg" "old parser ($(printf %s "$OLDC" | cut -c1-9)) + '$a': exit 2" || bad "old parser + '$a': exit 2 (got $RC)"
    nosub "old parser + '$a': sbatch never reached"
  done
else echo "  (no git history here — an installed copy: the old-parser check runs in the clone)"; fi

echo "-- conf isolation: the conf runs in a child shell; only the keys submit.sh reads come back --"
mkdir -p "$T/evil"; printf '#!/bin/sh\necho EVIL-PATH-SBATCH\n' > "$T/evil/sbatch"; cp "$T/evil/sbatch" "$T/evil/sinfo"; cp "$T/evil/sbatch" "$T/evil/squeue"; chmod +x "$T/evil/"*
PI=$(mk_proj fx-slurm "REMOTE_DIR=/x
sbatch() { echo HIJACKED-FUNCTION; }
sinfo() { echo HIJACKED-SINFO; }
alias sbatch='echo HIJACKED-ALIAS'
export PATH=\"$T/evil:\$PATH\"
echo conf-says-hello
FXSLURM_DEFAULT_CPUS=12
FXSLURM_JOB_NAME=\"it's a name\"
MY_OWN=1")
O=$(subo "$PI" -- echo hi); RC=$?; A=$PI/.rs/attempts/$(att "$O")
rc_is 0 "$RC" "a conf defining sbatch()/sinfo(), an alias and PATH still submits" "$O"
[ -s "$T/sbatch.log" ] && hasnt "$O" 'HIJACKED\|EVIL' "...through the real sbatch/sinfo (no function, alias or PATH from the conf)" || bad "...through the real sbatch"
has "$O" '^ARG:--cpus-per-task=12$' "...while the keys it reads still come through"; has "$O" "^ARG:--job-name=it's a name\$" "...quoted values round-trip (%q)"
has "$(cat "$A/err")" '^conf-says-hello$' "the conf's own stdout goes to stderr"; hasnt "$(cat "$A/out")" 'conf-says-hello' "...never to stdout"
PF=$(mk_proj fx-slurm 'REMOTE_DIR=/x
false')
O=$(subo "$PF" -- echo hi); RC=$?; rc_is 2 "$RC" "a conf whose sourcing fails"; has "$O" 'sourcing .*\.hpc\.conf failed' "...says so"; nosub "...submits nothing"
O=$(PATH="$T/bin:$PATH" SBATCH_EXTRA=--exclude=stale FXSLURM_ACCOUNT=stale bash "$PI/.fx-slurm/submit.sh" -- echo hi 2>&1)
hasnt "$O" 'stale' "stale exported conf keys still never reach the submit"
PP=$(mk_proj fx-slurm 'REMOTE_DIR=/x
DEFAULT_CPUS=6
printf() { builtin printf "%s\n" "DEFAULT_GPUS=1;sbatch() { echo HIJACKED-SBATCH; echo Submitted batch job 999; }"; }')
O=$(subo "$PP" -- echo hi); RC=$?
rc_is 0 "$RC" "a conf defining printf() (to forge the lines the child hands back) still submits" "$O"
[ -s "$T/sbatch.log" ] && hasnt "$O" 'HIJACKED\|job 999' "...through the real sbatch: the keys come back as data, never eval'd" || bad "...through the real sbatch (nothing the child prints is eval'd)"
has "$O" '^ARG:--cpus-per-task=6$' "...and its keys still come through"
PS=$(mk_proj fx-slurm 'REMOTE_DIR=/x
VENV_DIR=$HOME/venvs/p$T_SUFFIX
JOB_NAME=j$T_SUFFIX-$TAG')
O=$(subo "$PS" -- echo hi); RC=$?
rc_is 0 "$RC" "a conf using the profile's T_* and TAG submits (the child sources profile.sh first, as env.sh does)" "$O"
has "$O" '^ARG:--job-name=j-fx-FXSLURM$' "...with T_SUFFIX and TAG expanded"

echo "-- a nested submit (RS_* inherited from a job's --export=ALL) gets its own attempt --"
mkdir -p "$P/.rs/attempts/parent-1" "$T/envbin"; : > "$P/.rs/attempts/parent-1/marker"
printf '#!/usr/bin/env bash\nenv | grep "^RS_" | sed "s/^/RSENV:/"\nexec %q "$@"\n' "$T/bin/sbatch" > "$T/envbin/sbatch"; chmod +x "$T/envbin/sbatch"
O=$(PATH="$T/envbin:$T/bin:$PATH" RS_ATTEMPT=parent-1 RS_CONF_FILE=/elsewhere RS_RUN=x RS_ACKS=y bash "$P/.fx-slurm/submit.sh" -n nest -- echo hi 2>&1); N=$(att "$O")
[ -n "$N" ] && [ "$N" != parent-1 ] && ok "a fresh NONCE, not the parent's" || bad "a fresh NONCE, not the parent's ($N)"
has "$O" "^RSENV:RS_ATTEMPT=$N\$" "...and that one reaches the nested job"; hasnt "$O" 'RSENV:RS_CONF_FILE\|RSENV:RS_RUN\|RSENV:RS_ACKS' "RS_CONF_FILE / RS_RUN / RS_ACKS dropped"
[ "$(ls "$P/.rs/attempts/parent-1")" = marker ] && ok "the parent's attempt dir is untouched" || bad "the parent's attempt dir is untouched"

echo "-- duplicate guard: a live job of this name from this project -> exit 6 --"
mkdir -p "$T/sq"; cat > "$T/sq/squeue" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$T/squeue.args"
[ ! -f "$T/squeue.fail" ] || { echo "squeue: error: Unable to contact slurm controller" >&2; exit 1; }
cat "$T/squeue.rows" 2>/dev/null; exit 0
EOS
chmod +x "$T/sq/squeue"
D=$(mk_proj fx-slurm 'REMOTE_DIR=/x'); ln -s "$D" "$T/dlink"
sq() { local p=$1; shift; : > "$T/sbatch.log"; PATH="$T/sq:$T/bin:$PATH" bash "$p/.fx-slurm/submit.sh" "$@" 2>&1; }
rows() { printf '%s\n' "$@" > "$T/squeue.rows"; }
rows "9|other|RUNNING|None|0|N/A|$D|" "5|dup|RUNNING|None|0|N/A|$D|"
O=$(sq "$D" -n dup -- echo hi); RC=$?; A=$D/.rs/attempts/$(att "$O")
rc_is 6 "$RC" "RUNNING 'dup' from this project" "$O"; has "$O" "ERROR: 'dup' is already RUNNING from this project (job 5; live: 5) —" "...names the state and the job"
nosub "...nothing submitted"; has "$(cat "$A/result")" '^stage=avail rc=6 verdict=refused ' "...result: stage=avail rc=6 verdict=refused"
has "$(cat "$T/squeue.args")" '^-h -u [^ ]* --states=all -O JobID:0|,Name:0|,State:0|,Reason:0|,RestartCnt:0|,StartTime:0|,WorkDir:0|$' "the same squeue view as run-watch"
rc_is 6 "$(sq "$D" -n dup -y -- echo hi >/dev/null; echo $?)" "-y does not clear a duplicate"
rows "5|dup|PENDING|Priority|0|N/A|$D|"; rc_is 6 "$(sq "$D" -n dup -- echo hi >/dev/null; echo $?)" "PENDING counts as live"
rows "5|dup|REQUEUED|None|1|N/A|$D|"; rc_is 6 "$(sq "$D" -n dup -- echo hi >/dev/null; echo $?)" "REQUEUED counts as live"
O=$(sq "$T/dlink" -n dup -- echo hi); rc_is 6 $? "submitted through a symlinked path: the physical WorkDir still matches"
ln -s "$D" "$T/dlink2"; rows "5|dup|RUNNING|None|0|N/A|$T/dlink|" "6|dup|PENDING|Priority|0|N/A|$T/dlink2|"
O=$(sq "$D" -n dup -- echo hi); rc_is 6 $? "a live job submitted through a symlink (WorkDir = the link), this one via the physical path"
has "$O" '(job 5; live: 5,6) —' "...every live copy listed"; O=$(sq "$T/dlink2" -n dup -- echo hi); rc_is 6 $? "...or via another symlink"
rows "5|dup|RUNNING|None|0|N/A|$T/no-such-dir|"; O=$(sq "$D" -n dup -- echo hi); RC=$?
[ "$RC" = 0 ] && [ -s "$T/sbatch.log" ] && ok "a WorkDir that resolves nowhere is not this project" || bad "unresolvable WorkDir (rc=$RC)"
for r in "5|dup|COMPLETED|None|0|N/A|$D|" "5|dup|CANCELLED|None|0|N/A|$D|" "5|dup|RUNNING|None|0|N/A|/elsewhere|" "5|dupx|RUNNING|None|0|N/A|$D|"; do
  rows "$r"; O=$(sq "$D" -n dup -- echo hi); RC=$?; [ "$RC" = 0 ] && [ -s "$T/sbatch.log" ] && ok "not a duplicate: $r" || bad "not a duplicate: $r (rc=$RC)"
done
rows "5|dup|RUNNING|None|0|N/A|$D|"
O=$(sq "$D" -n dup --same-name-ok -- echo hi); RC=$?; [ "$RC" = 0 ] && [ -s "$T/sbatch.log" ] && ok "--same-name-ok submits next to a live one" || bad "--same-name-ok (rc=$RC)"
hasnt "$O" 'ARG:--same-name-ok\|passing .--same-name-ok' "--same-name-ok is submit.sh's own flag (never sbatch's, never policy's)"
for x in '--dependency=singleton' '-d singleton' '--dependency singleton' '-dsingleton' '--dependency=afterok:3?singleton'; do
  printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="%s"\n' "$x" > "$D/.hpc.conf"
  O=$(sq "$D" -n dup -- echo hi); RC=$?; [ "$RC" = 0 ] && [ -s "$T/sbatch.log" ] && ok "a singleton chain ($x) skips the guard" || bad "chain $x skips the guard (rc=$RC)"
done
printf 'REMOTE_DIR=/x\n' > "$D/.hpc.conf"; touch "$T/squeue.fail"
O=$(sq "$D" -n dup -- echo hi); RC=$?; rc_is 1 "$RC" "squeue fails: a warning" "$O"
has "$O" 'WARNING: squeue failed .*Re-run -y' "...that teaches -y"; nosub "...nothing submitted"
O=$(sq "$D" -n dup -y -- echo hi); RC=$?; [ "$RC" = 0 ] && [ -s "$T/sbatch.log" ] && has "$O" 'WARNING: squeue failed' "-y submits past a failed squeue, saying so" || bad "-y past a failed squeue (rc=$RC)"
rm -f "$T/squeue.fail" "$T/squeue.rows"

echo "-- SBATCH_EXTRA lint (warnings only) and the --comment merge --"
L=$(mk_proj fx-slurm 'REMOTE_DIR=/x
SBATCH_EXTRA="--wait-all-nodes=0 --time=2:00:00 -c 4 --qos=high --exclude=n1 --mem 9G --export=NONE"')
O=$(subo "$L" -- echo hi); RC=$?; rc_is 0 "$RC" "lint never refuses" "$O"
has "$O" "^WARNING (lint): SBATCH_EXTRA option '--wait-all-nodes' is outside the allowed set" "an option outside the allowlist: refused in a later version"
has "$O" "WARNING (lint): SBATCH_EXTRA repeats --time, .*SBATCH_EXTRA's '--time=2:00:00' (the harness's --time=1-00:00:00 comes earlier) wins" "--time repeated: SBATCH_EXTRA's wins (it comes later)"
has "$O" "WARNING (lint): SBATCH_EXTRA repeats -c, .*the harness's --cpus-per-task=8 (it comes later) wins" "-c repeated: the harness's wins"
has "$O" "repeats --mem, .*the harness's --mem=40G (it comes later) wins" "--mem (separate value) repeated: the harness's wins"
has "$O" "repeats --export, .*SBATCH_EXTRA's '--export=NONE'" "--export repeated: SBATCH_EXTRA's wins, said"
hasnt "$O" "lint.*'--qos'\|lint.*'--exclude'\|lint.*'2:00:00'\|lint.*'9G'" "allowlisted options and value words are not linted"
O=$(subo "$P" -G h100 -g 9 -- echo hi); RC=$?   # any refusal: no lint line at all, so its own message comes first
printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="--wait-all-nodes=0"\n' > "$L/.hpc.conf"; stub_sinfo gpu 'nodeA   gpu:h100:4   gpu:h100:3(IDX:0-2)   mixed'
O=$(subo "$L" -G h100 -g 2 -- echo hi); RC=$?; rm -f "$T/sinfo.d/gpu"
rc_is 1 "$RC" "a refused submit with a lint-worthy SBATCH_EXTRA"; hasnt "$O" 'lint' "...prints no lint (its first WARNING is the refusal's own)"
printf 'REMOTE_DIR=/x\nACCOUNT=acct\nSBATCH_EXTRA="--account=other"\n' > "$L/.hpc.conf"
has "$(subo "$L" -- echo hi)" "repeats --account, .*ACCOUNT's --account=acct comes earlier" "ACCOUNT + SBATCH_EXTRA --account: repeat named"
printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="--account=other"\n' > "$L/.hpc.conf"; hasnt "$(subo "$L" -- echo hi)" 'lint' "SBATCH_EXTRA --account alone: allowlisted, no lint"
printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="--exclude=n1 --comment"\n' > "$L/.hpc.conf"
has "$(subo "$L" -- echo hi)" "ends with '--comment' and no value" "a dangling value flag is named"
cp -R "$RS_USER_DIR" "$T/user-allow"; printf "\nT_SBATCH_EXTRA_ALLOW='--wait-all-nodes --open-mode'\n" >> "$T/user-allow/targets/fx-slurm/profile.sh"
LA=$(RS_USER_DIR=$T/user-allow mk_proj fx-slurm 'REMOTE_DIR=/x
SBATCH_EXTRA="--wait-all-nodes=0 --open-mode=append"')
hasnt "$(subo "$LA" -- echo hi)" 'lint' "the profile's T_SBATCH_EXTRA_ALLOW extends the allowlist"
for x in '--comment=bench --exclude=n1' '--comment bench --exclude=n1'; do
  printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="%s"\n' "$x" > "$L/.hpc.conf"; O=$(subo "$L" -- echo hi); N=$(att "$O")
  has "$(lastc "$O")" "^ARG:--comment=bench rs=$N\$" "SBATCH_EXTRA '$x': rs=<NONCE> merged into its comment"
done
O=$(subo "$P" --gpu-user-asked -- echo hi); N=$(att "$O")
has "$O" '^ARG:--comment=acked$' "the policy's own --comment stays where it was"; has "$(lastc "$O")" "^ARG:--comment=acked rs=$N\$" "...and the last one carries it + rs=<NONCE>"

echo "-- a policy file that sets its own EXIT trap cannot take the journal's --"
cp -R "$RS_USER_DIR" "$T/user-trap"; printf "trap 'echo POLICY-TRAP' EXIT\n" > "$T/user-trap/targets/fx-slurm/policy.local.sh"
PT=$(RS_USER_DIR=$T/user-trap mk_proj fx-slurm 'REMOTE_DIR=/x')
O=$(subo "$PT" -n trapped -- echo hi); RC=$?; A=$PT/.rs/attempts/$(att "$O")
rc_is 0 "$RC" "submits"; has "$O" '^log: .*/logs/trapped_1\.out' "...its output still reaches the caller"
has "$(cat "$A/result" 2>/dev/null)" '^stage=done rc=0 verdict=submitted ' "...and its result is written (the policy runs in the submit's subshell)"
cp -R "$RS_USER_DIR" "$T/user-trap2"; cat > "$T/user-trap2/targets/fx-slurm/policy.local.sh" <<'EOP'
t_policy() { local f; f=$(mktemp); trap 'rm -f "$f"' EXIT; echo "REFUSED: needs --gpu-user-asked" >&2; exit 3; }
EOP
PT=$(RS_USER_DIR=$T/user-trap2 mk_proj fx-slurm 'REMOTE_DIR=/x'); O=$(subo "$PT" -- echo hi); RC=$?; A=$(last_attempt "$PT")
rc_is 3 "$RC" "a t_policy that sets an EXIT trap, then refuses" "$O"; has "$O" '^REFUSED: needs --gpu-user-asked$' "...the caller still sees the refusal"
has "$O" '^reference: ' "...and the reference line"; has "$(cat "$A/result" 2>/dev/null)" '^stage=policy rc=3 verdict=refused ' "...and the result is written"
cp -R "$RS_USER_DIR" "$T/user-fd"; cat > "$T/user-fd/targets/fx-slurm/policy.local.sh" <<'EOP'
eval "$(declare -f t_partition | sed '1s/^t_partition/t_partition_shipped/')"
t_partition() { local l; exec 3</dev/null; while read -r -u 3 l; do :; done; exec 3<&-; t_partition_shipped "$@"; }
EOP
PT=$(RS_USER_DIR=$T/user-fd mk_proj fx-slurm 'REMOTE_DIR=/x'); O=$(PATH="$T/bin:$PATH" bash "$PT/.fx-slurm/submit.sh" -n fd3 -- echo hi 2>/dev/null); RC=$?
rc_is 0 "$RC" "a policy that opens and closes its own fd 3 (exec 3<file … exec 3<&-)"; has "$O" '^log: .*/logs/fd3_1\.out' "...the caller's stdout still gets every line"
printf '[ "$0" != rs-conf ] || { echo CHILD-READ-BASH-ENV >&2; echo DEFAULT_GPUS=3; }\n' > "$T/bashenv.sh"   # $0 = the child's name
O=$(PATH="$T/bin:$PATH" BASH_ENV="$T/bashenv.sh" bash "$P/.fx-slurm/submit.sh" -- echo hi 2>&1)
hasnt "$O" 'CHILD-READ-BASH-ENV' "the conf's child shell skips BASH_ENV (a module system's init runs once, in submit.sh)"
has "$O" '^ARG:--gres=gpu:1$' "...so nothing but the conf feeds it a key"
