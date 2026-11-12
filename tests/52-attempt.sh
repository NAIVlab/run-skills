#!/usr/bin/env bash
# tests/52-attempt.sh — phase A: remote/submit.sh's attempt journal and the P2 guards on the fx-slurm fixture (stub
# sbatch / squeue / sinfo, nothing submitted for real): the claim (.rs/attempts/<NONCE>/, --rs-attempt, exit 75, invalid
# NONCEs), out / err / stage / result / receipt and the submit-time snapshots, output discipline (stdout to stdout, stderr
# to stderr, a caller whose channel died loses nothing), sbatch-failure verdicts (refused, or unknown when the job may
# exist), an OLD parser given --rs-attempt, conf isolation (a conf's sbatch() / printf() / PATH never reach the submit; it
# sees the profile's T_*), nested submissions, the duplicate guard (exit 6, symlinked WorkDirs), the SBATCH_EXTRA lint, the
# --comment merge, policy code (its own EXIT trap, fd 3) kept in the submit's subshell, and api=3: the --rs-mode plan block
# (keys, bound fields — flags= the policy flags too — bound_hash, -y gates acknowledged), --rs-expect, --rs-chain, old parsers
# given them; the FORCE=0 probes of t_policy and t_partition, a silent gate's output in warnings_id, a lint that reads
# SBATCH_EXTRA as the scan does (an option's value is never an option), info_prior (R5-4: receipts + squeue rows of the run),
# the policy template's gate idiom (R5-10).  bash tests/52-attempt.sh
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
has "$R" '^target=fx-slurm$' "receipt: target (a project dir two targets share: whose receipt it is, info_prior_here)"
has "$R" "^proj=$P\$" "receipt: proj"; has "$R" "^nonce=$N\$" "receipt: nonce"; has "$R" '^at=[0-9][0-9]*$' "receipt: at (epoch)"
has "$R" "^argv=sbatch --job-name=jn .*--comment=rs=$N $P/\.fx-slurm/job\.sbatch echo hi\$" "receipt: argv = the sbatch argv (printf %q, one line)"
[ "$(wc -l < "$A/receipt")" = 8 ] && ok "receipt: exactly 8 key=value lines" || bad "receipt: 8 lines (got $(wc -l < "$A/receipt"))"
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
# R4-9: the lint reads SBATCH_EXTRA as the scan (and sbatch's getopt, tests/vgate comment_value=) does: -t1 is --comment's value
printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="--time=23:00:00 --comment -t1"\n' > "$L/.hpc.conf"; O=$(subo "$L" -- echo hi); rc_is 0 $? "R4-9: SBATCH_EXTRA --time=23:00:00 --comment -t1 submits (both times within MaxTime)" "$O"
has "$O" "repeats --time, .*SBATCH_EXTRA's '--time=23:00:00' (the harness's --time=1-00:00:00 comes earlier) wins" "R4-9: the lint names --time=23:00:00 as the time sbatch keeps"
hasnt "$O" "lint.*'-t1'" "R4-9: ...never the comment's value -t1 (getopt gives it to --comment)"; hasnt "$O" "lint.*repeats -t," "...no 'repeats -t' line at all"
printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="--comment -c --exclude n1 -c 4"\n' > "$L/.hpc.conf"; O=$(subo "$L" -- echo hi)
[ "$(printf '%s\n' "$O" | grep -c 'lint.*repeats -c,')" = 1 ] && ok "R4-9: '--comment -c': that -c is a value (no lint); the later '-c 4' is linted once" || { bad "R4-9: value -c not linted"; printf '%s\n' "$O" | grep lint | sed 's/^/    | /'; }
hasnt "$O" "lint.*'n1'" "R4-9: --exclude n1: n1 is --exclude's value"
printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="--exclude=n1 --comment"\n' > "$L/.hpc.conf"
O=$(subo "$L" -- echo hi); rc_is 2 $? "a dangling value flag is refused (sbatch would take the harness's --partition as its value)" "$O"
has "$O" "^ERROR: SBATCH_EXTRA ends with a dangling '--comment'" "...and named"; nosub "...nothing submitted"
echo "-- a word that is no option and no option's value: sbatch ('+' getopt) would run it as the batch script --"
for x in '--requeue train.sh' '--comment x y' '--exclude=n1 bare' '-- x' '-' '--acc a1' '-v n1' '--nice 5' '--qos=high --hold x'; do
  printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="%s"\n' "$x" > "$L/.hpc.conf"; O=$(subo "$L" -- echo hi); RC=$?
  rc_is 2 "$RC" "SBATCH_EXTRA '$x': refused" "$O"; has "$O" "^ERROR: SBATCH_EXTRA word '[^']*' is no option and no option's value: sbatch would run it as the batch script" "...named ($x)"
  rc_is 2 "$(subo "$L" --rs-mode plan -- echo hi >/dev/null; echo $?)" "...a plan stops there too ($x)"; done
nosub "...nothing submitted"
for x in '--exclude=n1 --acc' '--qos=high -A' '--mem' '--nodelist' '--ntasks-per' '--exclude=n1 --dependency'; do
  printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="%s"\n' "$x" > "$L/.hpc.conf"; O=$(subo "$L" --rs-chain -- echo hi); RC=$?
  rc_is 2 "$RC" "SBATCH_EXTRA '$x' (a value option, or an abbreviation of one, at the end): refused" "$O"; has "$O" "^ERROR: SBATCH_EXTRA ends with a dangling '" "...named ($x)"; done
nosub "...nothing submitted"
for x in '--qos high --account a1 -A a2 --exclude n1 -x n2 --constraint c -C c --reservation r --signal B:USR1@60 --mail-type END --mail-user u --comment c' \
         '--dependency singleton -d singleton --gres-flags enforce-binding --nodes 1 -N 1 --mem 9G -c 4 --hint nomultithread --requeue' \
         '--exclude=n1 --nice' '--no-requeue' '--hold' '-v' '--exclusive' '--comment -t1 --qos=high' '--comment --requeue --qos=high'; do
  printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="%s"\n' "$x" > "$L/.hpc.conf"; O=$(subo "$L" -- echo hi); RC=$?
  rc_is 0 "$RC" "SBATCH_EXTRA '$x': every word an option or an option's value: submitted" "$O"; done
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

echo "-- api=3: --rs-mode plan runs every check, prints ONE block, snapshots nothing but the conf, submits nothing --"
blk() { printf '%s\n' "$1" | sed -n '/^@@plan v1$/,/^@@end$/p'; }   # the plan block
bnd() { printf '%s\n' "$1" | sed -n '/^kind=/,/^chain=/p'; }        # its bound lines, which bound_hash covers
bh() { printf '%s\n' "$1" | sed -n 's/^bound_hash=//p'; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
PC='REMOTE_DIR=/x
ENV_KIND=conda
ENV_NAME=e
FXSLURM_ENV_NAME=tagged
WANDB_MODE=disabled
ACCOUNT=acct
SBATCH_EXTRA="--mail-type=END,FAIL --exclude=n1"'
PP=$(mk_proj fx-slurm "$PC"); printf 'path=/l\ncommit=0123abc\ndirty=2\n' > "$PP/.run-source"
PA=(-g 2 -t 2:00:00 -m 64G -c 4 -n pj -- python t.py --msg "a b")
O=$(subo "$PP" --rs-attempt pl1 --rs-mode plan "${PA[@]}"); RC=$?; A=$PP/.rs/attempts/pl1; B=$(blk "$O")
rc_is 0 "$RC" "plan mode" "$O"; nosub "...sbatch never runs"
[ "$(printf '%s\n' "$B" | sed 's/=.*//' | tr '\n' ' ')" = "@@plan v1 api kind target partition gres cpus mem time account name extra payload env_kind env_name wandb_mode env_hook venv_dir uv_sync_args conf_extra flags chain info_avail info_conf_sha256 info_profile_sha256 info_policy_sha256 info_policy_local_sha256 info_source_commit info_source_dirty info_prior info_prior_here info_wandb_env warnings warnings_avail warnings_id bound_hash @@end " ] \
  && ok "ONE block, exactly these keys in this order" || { bad "plan block keys"; printf '%s\n' "$B" | sed 's/^/    | /'; }
[ "$(printf '%s\n' "$O" | grep -c '^@@plan v1$')" = 1 ] && ok "...printed once, on stdout" || bad "...printed once"
has "$(PATH="$T/bin:$PATH" bash "$PP/.fx-slurm/submit.sh" --rs-mode plan "${PA[@]}" 2>/dev/null)" '^@@end$' "...(stdout alone carries it)"
has "$B" "^api=$(sed -n 's/^api=//p' "$PP/.fx-slurm/API")\$" "api= is the deployed .<t>/API's"; has "$B" '^kind=slurm$' "kind=slurm"; has "$B" '^target=fx-slurm$' "target="
for kv in partition=gpu gres=gpu:2 cpus=4 mem=64G time=2:00:00 account=acct name=pj 'payload=python t\.py --msg a\\ b' env_kind=conda env_name=tagged wandb_mode=disabled "env_hook=''" "venv_dir=''" "uv_sync_args=''" chain=0; do
  has "$B" "^$kv\$" "bound: $kv"; done
has "$B" '^extra=--mail-type=END[\\]*,FAIL --exclude=n1$' "bound: extra = the SB_ARGS words after the harness's own (SBATCH_EXTRA here), %q each"
hasnt "$B" '^extra=.*--job-name\|^extra=.*--chdir\|^extra=.*--export\|^extra=.*--account\|^extra=.*--requeue' "...never the harness's --job-name/--chdir/--time/--requeue/--export/--account"
has "$B" '^info_avail=free:4/max_node:4/gpu_type:any$' "info_avail (envelope)"
has "$B" "^info_conf_sha256=$(sha < "$PP/.hpc.conf")\$" "info_conf_sha256 = the conf's"; has "$B" "^info_profile_sha256=$(sha < "$PP/.fx-slurm/profile.sh")\$" "info_profile_sha256"
has "$B" "^info_policy_sha256=$(sha < "$PP/.fx-slurm/policy.sh")\$" "info_policy_sha256"; has "$B" '^info_policy_local_sha256=none$' "info_policy_local_sha256=none (no overlay)"
has "$B" '^info_source_commit=0123abc$' "info_source_commit (.run-source)"; has "$B" '^info_source_dirty=2$' "info_source_dirty"; has "$B" '^warnings=0$' "warnings=0"
has "$B" '^info_prior=0$' "info_prior=0 (no earlier attempt of the run here: R5-4)"
has "$B" '^conf_extra=--mail-type=END[\\]*,FAIL --exclude=n1$' "bound: conf_extra = the conf's SBATCH_EXTRA words alone, %q each (just before flags=)"
has "$B" '^flags=$' "bound: flags= (no policy flag given: empty, just before chain=)"
has "$B" '^warnings_avail=0$' "warnings_avail=0"; has "$B" "^warnings_id=$(printf '' | sha)\$" "warnings_id = the digest of no warning at all (sha256 of nothing)"
H1=$(bh "$O"); [ "${#H1}" = 64 ] && [ "$(bnd "$O" | sha)" = "$H1" ] && ok "bound_hash = sha256 of the lines kind= … chain= (each + newline)" || bad "bound_hash = sha256 of the bound lines"
has "$(cat "$A/result")" '^stage=plan rc=0 verdict=planned at=' "journal: stage=plan rc=0 verdict=planned"
cmp -s "$A/conf" "$PP/.hpc.conf" && ok "...the conf is snapshotted (as for every call)" || bad "...conf snapshot"
[ ! -e "$A/profile.sh" ] && [ ! -e "$A/env.sh" ] && [ ! -e "$A/hook" ] && [ ! -e "$A/receipt" ] && [ ! -d "$PP/logs" ] && ok "...nothing else: no profile/env/hook snapshot, receipt or logs/" || bad "a plan snapshots only the conf"
O=$(subo "$PP" --rs-attempt pl2 --rs-mode plan -y --same-name-ok "${PA[@]}"); [ "$(bh "$O")" = "$H1" ] && ok "NONCE, -y, --same-name-ok are not bound (same hash)" || bad "unbound flags keep the hash"
for v in "-g 3" "-G h100" "-c 5" "-m 65G" "-t 3:00:00" "-n pk" "--gpu-user-asked" "--rs-chain"; do   # each against the same PA
  O=$(subo "$PP" --rs-mode plan "${PA[@]:0:10}" $v -- python t.py --msg "a b"); [ -n "$(bh "$O")" ] && [ "$(bh "$O")" != "$H1" ] && ok "bound: '$v' changes the hash" || bad "bound: '$v' changes the hash"; done
O=$(subo "$PP" --rs-mode plan "${PA[@]:0:10}" -- python t.py --msg "a  b"); [ "$(bh "$O")" != "$H1" ] && ok "bound: the payload argv (word boundaries count)" || bad "bound: the payload"
for c in 'ACCOUNT=other' 'ENV_KIND=uv' 'FXSLURM_ENV_NAME=t2' 'WANDB_MODE=online' 'SBATCH_EXTRA="--exclude=n1"' 'DEFAULT_TIME=5:00' \
         'ENV_HOOK=hook.sh' 'VENV_DIR=/elsewhere/venv' 'FXSLURM_VENV_DIR=/other' 'UV_SYNC_ARGS="--extra gpu"'; do
  printf '%s\n%s\n' "$PC" "$c" > "$PP/.hpc.conf"; O=$(subo "$PP" --rs-mode plan -g 2 -m 64G -c 4 -n pj -- python t.py --msg "a b")
  printf '%s\n' "$PC" > "$PP/.hpc.conf"; O2=$(subo "$PP" --rs-mode plan -g 2 -m 64G -c 4 -n pj -- python t.py --msg "a b")
  [ -n "$(bh "$O")" ] && [ "$(bh "$O")" != "$(bh "$O2")" ] && ok "bound: the conf's $c" || bad "bound: the conf's $c"; done
O=$(subo "$PP" --rs-mode plan --gpu-user-asked "${PA[@]}"); has "$(blk "$O")" '^extra=--comment=acked --mail-type=END[\\]*,FAIL --exclude=n1$' "the policy's SB_ARGS words are in extra too (t_policy runs before SBATCH_EXTRA is added)"
has "$(blk "$O")" '^conf_extra=--mail-type=END[\\]*,FAIL --exclude=n1$' "...never in conf_extra (the conf's words alone)"
has "$(blk "$O")" '^flags=--gpu-user-asked$' "R4-6: the policy flag itself is bound (flags=, %q list)"
O=$(subo "$PP" --rs-mode plan --whole-node "${PA[@]}"); B=$(blk "$O")   # a flag this policy ignores: extra unchanged, the flag bound
has "$B" '^extra=--mail-type=END[\\]*,FAIL --exclude=n1$' "R4-6: a policy flag the policy ignores leaves extra as it was"
has "$B" '^flags=--whole-node$' "...but is bound: flags=--whole-node"; [ -n "$(bh "$O")" ] && [ "$(bh "$O")" != "$H1" ] && ok "...so it changes the hash (a policy may turn it into any sbatch option)" || bad "R4-6: an ignored policy flag changes the hash"
[ "$(printf '%s\n' "$B" | sed -n '/^conf_extra=/{n;p;}' | cut -d= -f1)" = flags ] && [ "$(printf '%s\n' "$B" | sed -n '/^flags=/{n;p;}' | cut -d= -f1)" = chain ] \
  && ok "...flags= sits between conf_extra= and chain= (the last bound key)" || bad "R4-6: flags= position"
O=$(subo "$PP" --rs-mode plan --b-flag "--note=a b" --a-flag "${PA[@]}"); has "$(blk "$O")" '^flags=--b-flag --note=a\\ b --a-flag$' "...in the order given, each word %q-quoted"
H3=$(bh "$O"); O=$(subo "$PP" --rs-mode plan --a-flag "--note=a b" --b-flag "${PA[@]}"); [ "$(bh "$O")" != "$H3" ] && ok "...and that order is bound" || bad "R4-6: flag order bound"
O=$(subo "$PP" --rs-attempt fl1 --rs-mode plan --whole-node "${PA[@]}"); HW=$(bh "$O")
O=$(subo "$PP" --rs-expect "$HW" "${PA[@]}"); rc_is 6 $? "R4-6: an approved card with --whole-node, submitted without it: exit 6" "$O"; nosub "...nothing submitted"
has "$O" '^changed: flags$' "...changed: flags"
O=$(subo "$PP" --rs-expect "$HW" --whole-node "${PA[@]}"); rc_is 0 $? "...with it: submits" "$O"
wid() { printf '%s\n' "$1" | sed -n 's/^warnings_id=//p'; }   # the block's warnings_id
wdig() { printf '%s\n' "$@" | sed -E 's/[0-9]+/#/g' | LC_ALL=C sort -u | sha; }   # the digest of these WARNING: lines (digits masked)

echo "-- plan mode: -y gates count as acknowledged (WARNING, go on); refusals and usage errors still end it --"
stub_sinfo gpu 'nodeA   gpu:h100:4   gpu:h100:3(IDX:0-2)   mixed'
O=$(subo "$P" --rs-mode plan -G h100 -g 2 -n av -- echo hi); RC=$?
rc_is 0 "$RC" "too few free GPUs, no -y: the plan goes on" "$O"; has "$O" "^WARNING: only 1 free of 'h100' (1 on one node) — the submit needs -y" "...printing the WARNING"
has "$(blk "$O")" '^warnings=1$' "...counted: warnings=1"; has "$(blk "$O")" '^warnings_avail=1$' "...warnings_avail=1 (the harness's own availability gate)"
has "$(blk "$O")" '^info_avail=free:1/max_node:1/gpu_type:h100$' "...info_avail says it"; nosub "...nothing submitted"
WA=$(wid "$O"); [ "$WA" = "$(wdig "WARNING: only 1 free of 'h100' (1 on one node) — the submit needs -y to queue anyway.")" ] \
  && ok "warnings_id = sha256 of the distinct WARNING: lines, every digit run -> #, sorted" || bad "warnings_id digest ($WA)"
H2=$(bh "$O")
O=$(subo "$P" --rs-expect "$H2" -G h100 -g 2 -n av -- echo hi); rc_is 1 "$(sub "$P" fx-slurm --rs-expect "$H2" -G h100 -g 2 -n av -- echo hi >/dev/null; echo $?)" "the approved submit without -y still stops at that WARNING"
O=$(subo "$P" --rs-expect "$H2" --rs-warnings "$WA" -y -G h100 -g 2 -n av -- echo hi); RC=$?
rc_is 0 "$RC" "...with -y and --rs-warnings <the card's warnings_id>: submits — -y is not bound" "$O"; has "$O" '^ARG:--gres=gpu:h100:2$' "...as planned"
has "$O" "^plan: bound_hash=$H2 = --rs-expect (the approved plan); its 1 warning(s) = the approved card's (warnings_id)\$" "...the warnings recomputed: the card's"
has "$O" "^WARNING: only 1 free of 'h100' (1 on one node) — the submit needs -y to queue anyway\.\$" "...under --rs-expect the gate prints the card's line word for word (the digest compares them)"
has "$O" '^NOTE: -y: queuing anyway if the approved card showed this warning' "...and says what -y does"
O=$(subo "$P" --rs-expect "$H2" --rs-warnings "$WA" -y -G h100 -g 3 -n av -- echo hi); rc_is 6 $? "(another -g: another hash, exit 6)"
stub_sinfo gpu 'nodeA   gpu:h100:4   gpu:h100:4(IDX:0-3)   mixed'
O=$(subo "$P" --rs-mode plan -G h100 -g 2 -n av -- echo hi); [ "$(bh "$O")" = "$H2" ] && [ "$(wid "$O")" = "$WA" ] \
  && ok "0 free now, 1 then: digits masked — the same warnings_id" || bad "digit-masked warnings_id"
stub_sinfo gpu 'nodeA   gpu:h100:4   gpu:h100:3(IDX:0-2)   mixed'
O=$(subo "$P" --rs-attempt w0 --rs-expect "$H2" -y -G h100 -g 2 -n av -- echo hi); RC=$?
rc_is 6 "$RC" "--rs-expect + -y without --rs-warnings (= no warning at all): the WARNING is new to it — exit 6" "$O"; nosub "...nothing submitted"
has "$O" '^ERROR: the resolved submission differs from the approved plan: its 1 warning(s) are not the approved card' "...saying so"
has "$O" '^changed: warnings$' "...changed: warnings (the bound fields are the plan's)"
has "$(cat "$P/.rs/attempts/w0/result")" '^stage=expect rc=6 verdict=refused ' "...journal: stage=expect, refused"
O=$(subo "$P" --rs-expect "$H2" --rs-warnings "$(printf '%s\n' "$WA" | tr 0-9a-f 1-9a-f0)" -y -G h100 -g 2 -n av -- echo hi); rc_is 6 $? "...and another card's warnings_id: exit 6"
O=$(subo "$P" -G h100 -g 2 -n av -- echo hi); rc_is 1 $? "outside plan mode the gate is unchanged (exit 1)"; hasnt "$O" 'needs -y to queue anyway' "...with its old WARNING"
O=$(subo "$P" -G h100 -g 2 -y -n av -- echo hi); hasnt "$O" '^WARNING: only' "...and -y outside plan mode stays silent, as before (a policy may set FORCE=1 itself)"
rm -f "$T/sinfo.d/gpu"
touch "$T/squeue.fail"; O=$(sq "$D" --rs-mode plan -n dup -- echo hi); RC=$?; rm -f "$T/squeue.fail"
rc_is 0 "$RC" "squeue failing (the duplicate check's -y gate): the plan goes on" "$O"; has "$(blk "$O")" '^warnings=1$' "...counted"
has "$(blk "$O")" '^warnings_avail=0$' "...but not as an availability warning (warnings_avail=0)"; hasnt "$O" 'submitting anyway' "...a plan never says 'submitting anyway'"
LP=$(mk_proj fx-slurm 'REMOTE_DIR=/x
SBATCH_EXTRA="--wait-all-nodes=0"'); O=$(subo "$LP" --rs-mode plan -- echo hi)
has "$O" '^WARNING (lint):' "a lint line is printed"; has "$(blk "$O")" '^warnings=0$' "...but WARNING (lint) is not counted"
rc_is 3 "$(sub "$P" fx-slurm --rs-mode plan -p vip -- echo hi >/dev/null; echo $?)" "a policy refusal ends a plan"; hasnt "$(subo "$P" --rs-mode plan -p vip -- echo hi)" '^@@plan' "...no block"
rc_is 2 "$(sub "$P" fx-slurm --rs-mode plan -Z -- echo hi >/dev/null; echo $?)" "a usage error ends a plan"; rc_is 2 "$(sub "$P" fx-slurm --rs-mode plan -- sbatch x >/dev/null; echo $?)" "...so does the payload guard"
rc_is 2 "$(sub "$P" fx-slurm --rs-mode plan -t 2-00:00:00 -- echo hi >/dev/null; echo $?)" "...and MaxTime"
rows "5|dup|RUNNING|None|0|N/A|$D|"; O=$(sq "$D" --rs-mode plan -n dup -- echo hi); rc_is 6 $? "a live same-name job ends a plan (exit 6)"; hasnt "$O" '^@@plan' "...no block"; rm -f "$T/squeue.rows"
cp -R "$RS_USER_DIR" "$T/user-gate"; cat > "$T/user-gate/targets/fx-slurm/policy.local.sh" <<'EOP'
eval "$(declare -f t_policy | sed '1s/^t_policy/t_policy_shipped/')"
t_policy() { echo "policy sees PLAN=$PLAN FORCE=$FORCE" >&2
  [ "$GTYPE" != slow ] || { echo "WARNING: slow GPUs. Re-run -y to take them." >&2; [ "$FORCE" = 1 ] || exit 1; }; t_policy_shipped; }
EOP
PG=$(RS_USER_DIR=$T/user-gate mk_proj fx-slurm 'REMOTE_DIR=/x'); stub_sinfo gpu 'nodeA   gpu:slow:4   gpu:slow:0   idle'
O=$(subo "$PG" --rs-mode plan -G slow -- echo hi); RC=$?
rc_is 0 "$RC" "a policy -y gate (WARNING, then FORCE) in plan mode: goes on" "$O"; has "$O" '^policy sees PLAN=1 FORCE=1$' "...the policy sees PLAN=1 FORCE=1"
has "$O" '^policy sees PLAN=1 FORCE=0$' "D3: ...after a probe as a submit without -y (FORCE=0)"
[ "$(printf '%s\n' "$O" | grep -c '^WARNING: slow GPUs')" = 2 ] && has "$(blk "$O")" '^warnings=1$' "...its WARNING printed twice, counted once (distinct lines)" || bad "probe + real: one distinct warning"
has "$(blk "$O")" '^warnings_avail=0$' "...a policy gate is not an availability warning"
has "$(blk "$O")" "^info_policy_local_sha256=$(sha < "$PG/.fx-slurm/policy.local.sh")\$" "...info_policy_local_sha256"
rc_is 1 "$(sub "$PG" fx-slurm -G slow -- echo hi >/dev/null; echo $?)" "...outside plan mode, no -y: exit 1 (unchanged)"; has "$(subo "$PG" -- echo hi)" '^policy sees PLAN=0 FORCE=0$' "...PLAN=0 there"
[ "$(subo "$PG" -- echo hi | grep -c '^policy sees')" = 1 ] && ok "...and no probe outside plan / --rs-expect (t_policy runs once)" || bad "a plain submit probes t_policy"
rm -f "$T/sinfo.d/gpu"

echo "-- D3 (A-p2): a -y gate in the P2 idiom (silent under FORCE=1) is on the card and in its digest --"
cp -R "$RS_USER_DIR" "$T/user-p2"; cat > "$T/user-p2/targets/fx-slurm/policy.local.sh" <<'EOP'
eval "$(declare -f t_policy | sed '1s/^t_policy/t_policy_shipped/')"
t_policy() { if [ "$PART" = gpu ] && [ -f "$PROJ/.paid" ] && [ "$FORCE" -ne 1 ]; then
    echo "WARNING: partition '$PART' bills the group account. Re-run -y to accept the charge." >&2; exit 1; fi
  if [ -f "$PROJ/.quiet-gate" ] && [ "$FORCE" -ne 1 ]; then echo "NOTE: busy" >&2; exit 1; fi; t_policy_shipped; }
EOP
P2=$(RS_USER_DIR=$T/user-p2 mk_proj fx-slurm 'REMOTE_DIR=/x'); touch "$P2/.paid"
O=$(subo "$P2" --rs-mode plan -n pd -- echo hi); RC=$?; HP=$(bh "$O"); WP=$(wid "$O")
rc_is 0 "$RC" "plan: the gate (P2 idiom) does not end the plan" "$O"; has "$O" "^WARNING: partition 'gpu' bills the group account" "...its WARNING is printed (the FORCE=0 probe)"
has "$(blk "$O")" '^warnings=1$' "...and counted (before: warnings=0, no -y gate)"; has "$(blk "$O")" '^warnings_avail=0$' "...as a policy warning (warnings_avail=0)"
O=$(subo "$P2" --rs-expect "$HP" --rs-warnings "$WP" -y -n pd -- echo hi); RC=$?
rc_is 0 "$RC" "the approved submit (-y, the card's warnings_id): submits" "$O"; has "$O" "^WARNING: partition 'gpu' bills" "...the gate printed again (the probe), compared"
stub_sinfo gpu 'nodeA   gpu:any:4   gpu:any:4   idle'; rm -f "$P2/.paid"
O=$(subo "$P2" --rs-mode plan -n pd -- echo hi); HA=$(bh "$O"); WAV=$(wid "$O")
has "$(blk "$O")" '^warnings_avail=1$' "M4-swap: a card with the availability warning only (warnings_avail=1)"
rm -f "$T/sinfo.d/gpu"; touch "$P2/.paid"
O=$(subo "$P2" --rs-attempt sw1 --rs-expect "$HA" --rs-warnings "$WAV" -y -n pd -- echo hi); RC=$?
rc_is 6 "$RC" "...then GPUs free up and the charge gate appears (one warning gone, one new: the same count): exit 6" "$O"; nosub "...nothing submitted"
has "$O" '^changed: warnings$' "...changed: warnings"; has "$(cat "$P2/.rs/attempts/sw1/result")" 'verdict=refused' "...refused"
rm -f "$P2/.paid"; touch "$P2/.quiet-gate"
O=$(subo "$P2" --rs-mode plan -n pd -- echo hi); RC=$?
rc_is 0 "$RC" "a gate that exits 1 without -y but prints no WARNING line: the plan goes on" "$O"
has "$O" "^WARNING: the target's policy stops this submit without -y (t_policy exit 1, no WARNING line of its own)" "...a WARNING is printed for it"; has "$(blk "$O")" '^warnings=1$' "...and counted"
rm -f "$P2/.quiet-gate"
cp -R "$RS_USER_DIR" "$T/user-p3"; printf 't_policy() { [ "$FORCE" = 1 ] || { echo "REFUSED: needs -y" >&2; exit 3; }; return 0; }\n' > "$T/user-p3/targets/fx-slurm/policy.local.sh"
P3=$(RS_USER_DIR=$T/user-p3 mk_proj fx-slurm 'REMOTE_DIR=/x'); O=$(subo "$P3" --rs-mode plan -- echo hi); RC=$?
rc_is 3 "$RC" "a policy that refuses (3) without -y: the plan ends with 3 (-y never lifts a refusal)" "$O"; hasnt "$O" '^@@plan' "...no block"
echo "-- R4-11: a -y gate in t_partition (P2 idiom, silent under FORCE=1) is probed too: on the card and in its digest --"
cp -R "$RS_USER_DIR" "$T/user-pg"; cat > "$T/user-pg/targets/fx-slurm/policy.local.sh" <<'EOP'
eval "$(declare -f t_partition | sed '1s/^t_partition/t_partition_shipped/')"
t_partition() { case "$1" in
  paid) P_GPUS=1-4 P_CPU_PER_GPU=8 P_MEM_PER_GPU=40; echo "t_partition sees PLAN=$PLAN FORCE=$FORCE" >&2
        if [ -f "$PROJ/.charge" ] && [ "$FORCE" -ne 1 ]; then echo "WARNING: partition 'paid' bills the group account. Re-run -y to accept the charge." >&2; exit 1; fi ;;
  *) t_partition_shipped "$1" ;; esac; }
eval "$(declare -f t_policy | sed '1s/^t_policy/t_policy_shipped/')"
t_policy() { if [ -f "$PROJ/.maint" ] && [ "$FORCE" -ne 1 ]; then echo "WARNING: maintenance window: the job may be requeued once. Re-run -y." >&2; exit 1; fi; t_policy_shipped; }
EOP
PQ=$(RS_USER_DIR=$T/user-pg mk_proj fx-slurm 'REMOTE_DIR=/x'); touch "$PQ/.charge"
O=$(subo "$PQ" --rs-mode plan -p paid -n pg -- echo hi); RC=$?; HQ=$(bh "$O"); WQ=$(wid "$O")
rc_is 0 "$RC" "R4-11: plan -p paid (a t_partition -y gate): the plan goes on" "$O"; has "$O" "^WARNING: partition 'paid' bills the group account" "...the gate's WARNING is printed (t_partition probed with FORCE=0)"
[ "$(printf '%s\n' "$O" | grep '^t_partition sees' | tr '\n' ' ')" = "t_partition sees PLAN=1 FORCE=0 t_partition sees PLAN=1 FORCE=1 " ] \
  && ok "...the probe (FORCE=0) first, then the real call (plan: FORCE=1)" || bad "R4-11: t_partition probe then real call"
has "$(blk "$O")" '^warnings=1$' "...and counted (before: warnings=0 — the plan ran t_partition with FORCE=1 only)"; has "$(blk "$O")" '^warnings_avail=0$' "...as a policy warning"
O=$(subo "$PQ" --rs-expect "$HQ" --rs-warnings "$WQ" -y -p paid -n pg -- echo hi); rc_is 0 $? "...the approved submit (-y, that card's warnings_id): submits" "$O"; has "$O" '^ARG:--partition=paid$' "...to paid"
stub_sinfo '-p paid' 'nodeA   gpu:a100:4   gpu:a100:4   mixed'   # nothing free on paid: the availability gate too
O=$(subo "$PQ" --rs-mode plan -p paid -n pg -- echo hi); B=$(blk "$O")
has "$B" '^warnings=2$' "R4-11 (N2): availability + the charge gate: warnings=2"; has "$B" '^warnings_avail=1$' "...warnings_avail=1 (warnings != warnings_avail: never an availability-only card)"
rm -f "$PQ/.charge"; O=$(subo "$PQ" --rs-mode plan -p paid -n pg -- echo hi); HQ2=$(bh "$O"); WQ2=$(wid "$O")
has "$(blk "$O")" '^warnings=1$' "...a card with the availability warning alone (no charge then)"; touch "$PQ/.charge"
O=$(subo "$PQ" --rs-attempt pq1 --rs-expect "$HQ2" --rs-warnings "$WQ2" -y -p paid -n pg -- echo hi); RC=$?
rc_is 6 "$RC" "R4-11: the charge gate appears after that card; the -y sent for the availability warning never passes it: exit 6" "$O"; nosub "...nothing submitted"
has "$O" '^changed: warnings$' "...changed: warnings"; has "$(cat "$PQ/.rs/attempts/pq1/result")" 'verdict=refused' "...refused"
rm -f "$T/sinfo.d/-p paid"; touch "$PQ/.maint"
O=$(subo "$PQ" --rs-mode plan -p paid -n pg -- echo hi); RC=$?
rc_is 0 "$RC" "R4-11: a t_policy gate AND a t_partition gate" "$O"; has "$O" '^WARNING: maintenance window' "...the t_policy gate's WARNING"
has "$O" "^WARNING: partition 'paid' bills" "...and the t_partition gate's: the t_policy gate stopping its own probe hides nothing (t_partition is probed on its own)"
has "$(blk "$O")" '^warnings=2$' "...warnings=2"; rm -f "$PQ/.maint" "$PQ/.charge"
O=$(subo "$PQ" --rs-mode plan -p nope -n pg -- echo hi); rc_is 2 $? "R4-11: an unknown partition (t_partition returns 1) still ends a plan with exit 2" "$O"
has "$O" "^ERROR: unknown fx-slurm partition 'nope'" "...saying so"; hasnt "$O" 'policy stops this submit' "...never read as a -y gate"
O=$(subo "$PQ" -p paid -n pg -- echo hi); has "$O" '^ARG:--partition=paid$' "a plain submit (no plan, no --rs-expect): submits as before"
[ "$(printf '%s\n' "$O" | grep -c '^t_partition sees')" = 1 ] && ok "...t_partition runs once there (no probe)" || bad "R4-11: a plain submit probes t_partition"

echo "-- R4-12: a gate that prints no WARNING: line — what it printed is in warnings_id: one silent gate never passes for another --"
cp -R "$RS_USER_DIR" "$T/user-sg"; cat > "$T/user-sg/targets/fx-slurm/policy.local.sh" <<'EOP'
eval "$(declare -f t_policy | sed '1s/^t_policy/t_policy_shipped/')"
t_policy() {
  if [ -f "$PROJ/.gateA" ] && [ "$FORCE" -ne 1 ]; then
    echo "NOTE: the gpu partition is in its maintenance window: $(cat "$PROJ/.gateA") job(s) may be requeued. Re-run -y to accept." >&2; exit 1; fi
  if [ -f "$PROJ/.gateB" ] && [ "$FORCE" -ne 1 ]; then
    echo "NOTE: the group's allocation is overdrawn: this job is billed at the overage rate. Re-run -y to accept the charge." >&2; exit 1; fi
  t_policy_shipped; }
eval "$(declare -f t_partition | sed '1s/^t_partition/t_partition_shipped/')"
t_partition() { if [ -f "$PROJ/.gateC" ] && [ "$FORCE" -ne 1 ]; then echo "the queue is long"; exit 1; fi; t_partition_shipped "$1"; }
EOP
PS=$(RS_USER_DIR=$T/user-sg mk_proj fx-slurm 'REMOTE_DIR=/x'); echo 1 > "$PS/.gateA"
O=$(subo "$PS" --rs-mode plan -n sg -- echo hi); RC=$?; HS=$(bh "$O"); WS=$(wid "$O")
rc_is 0 "$RC" "R4-12: plan with silent gate A" "$O"; has "$O" '^NOTE: the gpu partition is in its maintenance window' "...its NOTE is printed"
has "$O" "^WARNING: the target's policy stops this submit without -y (t_policy exit 1, no WARNING line of its own)" "...the generic WARNING line stays"
has "$(blk "$O")" '^warnings=1$' "...warnings=1 (the generic line)"
[ "$WS" != "$(wdig "WARNING: the target's policy stops this submit without -y (t_policy exit 1, no WARNING line of its own) — its lines are above.")" ] \
  && ok "...warnings_id is not the generic line's alone: the probe's output is in it" || bad "R4-12: warnings_id = the generic line's digest"
rm -f "$PS/.gateA"; touch "$PS/.gateB"
O=$(subo "$PS" --rs-attempt sg1 --rs-expect "$HS" --rs-warnings "$WS" -y -n sg -- echo hi); RC=$?
rc_is 6 "$RC" "R4-12 (N3): gate A on the card, gate B at the submit (both silent): exit 6" "$O"; nosub "...nothing submitted"
has "$O" '^changed: warnings$' "...changed: warnings"; has "$(cat "$PS/.rs/attempts/sg1/result")" '^stage=expect rc=6 verdict=refused' "...journal: refused at stage=expect"
rm -f "$PS/.gateB"; echo 7 > "$PS/.gateA"
O=$(subo "$PS" --rs-expect "$HS" --rs-warnings "$WS" -y -n sg -- echo hi); rc_is 0 $? "...gate A again (another number in its text: digit runs masked): submits" "$O"
rm -f "$PS/.gateA"; touch "$PS/.gateB"; O=$(subo "$PS" --rs-mode plan -n sg -- echo hi); WB=$(wid "$O")
[ -n "$WB" ] && [ "$WB" != "$WS" ] && ok "...gate B's own card: another warnings_id" || bad "R4-12: gate B's warnings_id differs from A's"
rm -f "$PS/.gateB"; touch "$PS/.gateC"; O=$(subo "$PS" --rs-mode plan -n sg -- echo hi); RC=$?; WC=$(wid "$O")
rc_is 0 "$RC" "R4-12: a silent t_partition gate (plain stdout text)" "$O"; has "$O" "^WARNING: the target's policy stops this submit without -y (t_partition 'gpu' exit 1, no WARNING line of its own)" "...gets the generic line, naming t_partition"
[ "$WC" != "$WS" ] && [ "$WC" != "$WB" ] && ok "...and its own warnings_id" || bad "R4-12: t_partition's silent gate warnings_id"
rm -f "$PS/.gateC"; O=$(subo "$PS" --rs-mode plan -n sg -- echo hi); has "$(blk "$O")" "^warnings_id=$(printf '' | sha)\$" "no gate: the digest of nothing, as before"
echo "-- the probe passes each -y gate (exit 1) as plan mode does: a function's first gate hides none after it (tests/vgate bash_exit_fn=) --"
cp -R "$RS_USER_DIR" "$T/user-mg"; cat > "$T/user-mg/targets/fx-slurm/policy.local.sh" <<'EOP'
eval "$(declare -f t_policy | sed '1s/^t_policy/t_policy_shipped/')"
t_policy() {
  if [ -f "$PROJ/.gx" ] && [ "$FORCE" -ne 1 ]; then echo "WARNING: the gpu partition is busy. Re-run -y." >&2; exit 1; fi
  if [ -f "$PROJ/.gy" ] && [ "$FORCE" -ne 1 ]; then echo "WARNING: this job is billed to the group account. Re-run -y." >&2; exit 1; fi
  if [ -f "$PROJ/.gz" ] && [ "$FORCE" -ne 1 ]; then echo "NOTE: the job runs at a reduced priority. Re-run -y." >&2; exit 1; fi
  [ ! -f "$PROJ/.no" ] || { echo "REFUSED: the account is closed" >&2; exit 3; }
  t_policy_shipped; }
EOP
PM=$(RS_USER_DIR=$T/user-mg mk_proj fx-slurm 'REMOTE_DIR=/x'); touch "$PM/.gx" "$PM/.gy"
O=$(subo "$PM" --rs-mode plan -n mg -- echo hi); RC=$?; rc_is 0 "$RC" "two -y gates in one t_policy (P2 idiom): the plan goes on" "$O"
has "$O" '^WARNING: the gpu partition is busy' "...the first gate's WARNING"; has "$O" '^WARNING: this job is billed to the group account' "...and the second's: the first gate's exit no longer ends the probe"
has "$(blk "$O")" '^warnings=2$' "...warnings=2"
rm -f "$PM/.gy"; O=$(subo "$PM" --rs-mode plan -n mg -- echo hi); H1=$(bh "$O"); W1=$(wid "$O"); has "$(blk "$O")" '^warnings=1$' "a card with the first gate alone"
touch "$PM/.gy"; O=$(subo "$PM" --rs-attempt mg1 --rs-expect "$H1" --rs-warnings "$W1" -y -n mg -- echo hi); RC=$?
rc_is 6 "$RC" "...the second gate fires after that card: the -y for the first never passes it" "$O"; nosub "...nothing submitted"; has "$O" '^changed: warnings$' "...changed: warnings"
rm -f "$PM/.gy"; touch "$PM/.gz"; O=$(subo "$PM" --rs-attempt mg2 --rs-expect "$H1" --rs-warnings "$W1" -y -n mg -- echo hi); RC=$?
rc_is 6 "$RC" "...a silent gate after a WARNING gate: its output is in warnings_id too" "$O"; nosub "...nothing submitted"
has "$O" "^WARNING: the target's policy stops this submit without -y (t_policy exit 1, no WARNING line of its own)" "...with the generic line"
rm -f "$PM/.gz"; O=$(subo "$PM" --rs-expect "$H1" --rs-warnings "$W1" -y -n mg -- echo hi); rc_is 0 $? "...the first gate alone again: submits" "$O"
touch "$PM/.no"; O=$(subo "$PM" --rs-mode plan -n mg -- echo hi); rc_is 3 $? "a refusal after a gate: exit 3, as a -y submit meets it" "$O"
has "$O" '^REFUSED: the account is closed' "...its line"; rm -f "$PM/.no" "$PM/.gx"
echo "-- --rs-expect HASH: right before the snapshots and sbatch, the same rs_bound hash --"
printf '%s\n' "$PC" > "$PP/.hpc.conf"; O=$(subo "$PP" --rs-mode plan "${PA[@]}"); H1=$(bh "$O")
O=$(subo "$PP" --rs-attempt ex1 --rs-expect "$H1" "${PA[@]}"); RC=$?; A=$PP/.rs/attempts/ex1
rc_is 0 "$RC" "the plan's hash: submits" "$O"; has "$O" "^plan: bound_hash=$H1 = --rs-expect (the approved plan); its 0 warning(s) = the approved card's (warnings_id)\$" "...saying so"; hasnt "$O" '^@@plan' "...no block on a match"
has "$(cat "$A/result")" 'verdict=submitted' "...verdict=submitted"; [ -f "$A/profile.sh" ] && [ -f "$A/env.sh" ] && ok "...with its snapshots" || bad "...with its snapshots"
has "$O" '^ARG:--mail-type=END,FAIL$' "...the planned sbatch words (unescaped) reach sbatch"
O=$(subo "$PP" --rs-attempt ex2 --rs-expect "$H1" -g 1 -t 2:00:00 -m 64G -c 4 -n pj -- python t.py --msg "a b"); RC=$?; A=$PP/.rs/attempts/ex2
rc_is 6 "$RC" "another -g than the plan's: exit 6" "$O"; has "$O" '^ERROR: the resolved submission differs from the approved plan' "...the ERROR line"
has "$O" '^changed: gres$' "H1-msg: ...changed: gres (the approved plan's block, read from its journal here)"
has "$(blk "$O")" '^gres=gpu:1$' "...after the CURRENT block"; [ "$(bh "$O")" != "$H1" ] && [ "$(bnd "$O" | sha)" = "$(bh "$O")" ] && ok "...with its own hash" || bad "...its own hash"
nosub "...nothing submitted"; has "$(cat "$A/result")" '^stage=expect rc=6 verdict=refused ' "...journal: stage=expect rc=6 verdict=refused"
[ ! -e "$A/profile.sh" ] && [ ! -e "$A/env.sh" ] && [ ! -e "$A/receipt" ] && ok "...before the snapshots" || bad "...before the snapshots"
O=$(subo "$PP" --rs-mode plan -g 2 -c 4 -n pj -- python t.py); H3=$(bh "$O"); has "$(blk "$O")" '^mem=80G$' "(no -m: mem from the partition heuristic)"
printf '%s\nDEFAULT_MEM=99G\n' "$PC" > "$PP/.hpc.conf"; O=$(subo "$PP" --rs-expect "$H3" -g 2 -c 4 -n pj -- python t.py); RC=$?
rc_is 6 "$RC" "a conf default added after the approval (DEFAULT_MEM, the same CLI): exit 6" "$O"; has "$(blk "$O")" '^mem=99G$' "...the block shows mem=99G"
printf '%s\nACCOUNT=moved\n' "$PC" > "$PP/.hpc.conf"; O=$(subo "$PP" --rs-expect "$H1" "${PA[@]}"); RC=$?
rc_is 6 "$RC" "the conf edited after the approval (ACCOUNT): exit 6" "$O"; has "$(blk "$O")" '^account=moved$' "...the block shows the drift"; nosub "...nothing submitted"
has "$O" '^changed: account$' "...changed: account"
printf '%s\n' "$PC" > "$PP/.hpc.conf"
O=$(subo "$PP" --rs-expect "$H1" --rs-mode plan "${PA[@]}"); RC=$?; rc_is 0 "$RC" "--rs-mode plan --rs-expect <same>: a plan that matches (exit 0, block)"; has "$O" '^@@end$' "...block printed"
O=$(subo "$PP" --rs-expect "$H1" --rs-mode plan -n other "${PA[@]:2}"); rc_is 6 $? "--rs-mode plan --rs-expect <other>: exit 6"

echo "-- M7: ENV_HOOK (path + the file's sha256), VENV_DIR and UV_SYNC_ARGS are bound: a hook edited after the card -> exit 6 --"
printf '%s\nENV_HOOK=hook.sh\n' "$PC" > "$PP/.hpc.conf"; echo 'export A=1' > "$PP/hook.sh"
O=$(subo "$PP" --rs-mode plan "${PA[@]}"); HK=$(bh "$O")
has "$(blk "$O")" "^env_hook=hook.sh:$(sha < "$PP/hook.sh")\$" "bound: env_hook=<ENV_HOOK>:<sha256 of the file>"
echo 'alias python=/bin/true' >> "$PP/hook.sh"; O=$(subo "$PP" --rs-expect "$HK" "${PA[@]}"); RC=$?
rc_is 6 "$RC" "the hook's content changed after the approval: exit 6" "$O"; nosub "...nothing submitted"
has "$(blk "$O")" "^env_hook=hook.sh:$(sha < "$PP/hook.sh")\$" "...the block shows the new sha256"
rm -f "$PP/hook.sh"; has "$(blk "$(subo "$PP" --rs-mode plan "${PA[@]}")")" '^env_hook=hook\.sh:missing$' "...a missing hook file: env_hook=<path>:missing"
printf '%s\n' "$PC" > "$PP/.hpc.conf"

echo "-- B: --rs-warnings ID = the approved card's warnings_id (separate word, 64 hex, with --rs-expect only); older parsers reject it --"
B0=$(natt "$P"); WX=$(printf '' | sha)
for a in '--rs-warnings' '--rs-warnings x' '--rs-warnings -1' "--rs-warnings $WX" "--rs-expect $H1 --rs-warnings 1" "--rs-expect $H1 --rs-warnings $WX --rs-warnings $WX" \
         "--rs-expect $H1 --rs-warnings=$WX" "--rs-expect $H1 --rs-warnings $(printf %s "$WX" | tr a-f A-F)" "--rs-expect $H1 --rs-warnings ${WX}0"; do
  O=$(subo "$P" $a -- echo hi); RC=$?; [ "$RC" = 2 ] && ok "'${a:0:50}' refused (exit 2)" || bad "'${a:0:50}' refused (exit 2, got $RC)"; done
[ "$(natt "$P")" = "$B0" ] && ok "...none of them claimed an attempt dir" || bad "...an invalid --rs-warnings claimed a dir"; nosub "...nor submitted"
O=$(subo "$PP" --rs-expect "$H1" --rs-warnings "$WX" "${PA[@]}"); rc_is 0 $? "--rs-warnings <the digest of nothing> = no warning: as without it" "$O"
for c in b746431 dbd3255; do   # api=3 with a COUNT: the hex digest is not a count (exit 2); P2 and older: not a flag at all
  if OS=$(git -C "$RS_HOME" show "$c:remote/submit.sh" 2>/dev/null) && [ -n "$OS" ]; then
    OP=$(mk_proj fx-slurm 'REMOTE_DIR=/x'); printf '%s\n' "$OS" > "$OP/.fx-slurm/submit.sh"
    O=$(subo "$OP" --rs-expect "$H1" --rs-warnings "$WX" -- echo hi); RC=$?
    [ "$RC" = 2 ] && ok "$c submit.sh + --rs-warnings <warnings_id>: exit 2" || bad "$c + --rs-warnings <warnings_id> (rc=$RC)"; nosub "...sbatch never reached ($c)"
    hasnt "$OS" '^# rs-api=3$' "$c has no '# rs-api=3' line (rsk reads that line, not the API file)"
  else echo "  SKIP: no git history ($c): an installed copy — the old-parser check runs in the clone"; fi; done
[ "$(grep -cx '# rs-api=3' "$RS_HOME/remote/submit.sh")" = 1 ] && ok "C: submit.sh carries the '# rs-api=3' line, once" || bad "submit.sh: the '# rs-api=3' line"

echo "-- M4: under --rs-expect a failed squeue is exit 1 — never a -y gate --"
printf 'REMOTE_DIR=/x\n' > "$D/.hpc.conf"; O=$(sq "$D" --rs-mode plan -n dup2 -- echo hi); HD=$(bh "$O")
touch "$T/squeue.fail"; O=$(sq "$D" --rs-mode plan -n dup2 -- echo hi); HDW=$(bh "$O"); WDW=$(wid "$O")
O=$(sq "$D" --rs-attempt sqf --rs-expect "$HDW" --rs-warnings "$WDW" -y -n dup2 -- echo hi); RC=$?
rc_is 1 "$RC" "squeue fails, --rs-expect + -y + the card's warnings_id: exit 1" "$O"; nosub "...nothing submitted"
has "$O" "^ERROR: squeue failed .*never submitted without that check" "...saying why"; hasnt "$O" 'submitting anyway' "...never 'submitting anyway'"
has "$(cat "$D/.rs/attempts/sqf/result")" 'verdict=refused' "...journal: refused"
O=$(sq "$D" -n dup2 -y -- echo hi); RC=$?; [ "$RC" = 0 ] && has "$O" 'submitting anyway' "(without --rs-expect, -y still submits past it, as before)" || bad "-y past a failed squeue without --rs-expect (rc=$RC)"
rm -f "$T/squeue.fail"
O=$(sq "$D" --rs-expect "$HD" -n dup2 -- echo hi); RC=$?; rc_is 0 "$RC" "(squeue answering again: the clean card's submit goes out)" "$O"

echo "-- H2: an SBATCH_EXTRA --time / -t is held to MaxTime like -t (sbatch takes the last --time) --"
for x in '--time=2-00:00:00' '-t 2-00:00:00' '-t2-00:00:00' '--time 2-00:00:00'; do
  XP=$(mk_proj fx-slurm "REMOTE_DIR=/x
SBATCH_EXTRA=\"$x\""); O=$(subo "$XP" -t 30 -- echo hi); RC=$?
  rc_is 2 "$RC" "SBATCH_EXTRA '$x' over MaxTime 1-00:00:00, -t 30: refused" "$O"; nosub "...nothing submitted ($x)"
  has "$O" "^ERROR: SBATCH_EXTRA's --time 2-00:00:00 exceeds 'gpu' MaxTime" "...naming SBATCH_EXTRA's --time"
  rc_is 2 "$(subo "$XP" --rs-mode plan -t 30 -- echo hi >/dev/null; echo $?)" "...and a plan stops there too ($x)"; done
XP=$(mk_proj fx-slurm 'REMOTE_DIR=/x
SBATCH_EXTRA="--time=12:00:00"'); O=$(subo "$XP" -t 30 -- echo hi); rc_is 0 $? "SBATCH_EXTRA --time within MaxTime: submitted" "$O"
echo "-- a time hidden behind another option's value (sbatch: getopt gives -t1 to --comment) never passes for the real one --"
for x in '--time=7-00:00:00 --comment -t1' '--time=7-00:00:00 --mail-user -t5' '-t 7-00:00:00 --comment --time=1' '--time 7-00:00:00 --comment -t1'; do
  printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="%s"\n' "$x" > "$XP/.hpc.conf"; O=$(subo "$XP" -t 30 -- echo hi); RC=$?
  rc_is 2 "$RC" "SBATCH_EXTRA '$x': the real --time 7-00:00:00 is checked too" "$O"; has "$O" "^ERROR: SBATCH_EXTRA's --time 7-00:00:00 exceeds 'gpu' MaxTime" "...named"; done
nosub "...nothing submitted"
printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="--time=23:00:00 --comment -t1"\n' > "$XP/.hpc.conf"; O=$(subo "$XP" -t 30 -- echo hi); RC=$?
rc_is 0 "$RC" "every candidate within MaxTime (23:00:00, the comment's -t1): submitted" "$O"
printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="--exclude=n1 --time"\n' > "$XP/.hpc.conf"; O=$(subo "$XP" -t 30 -- echo hi); RC=$?
rc_is 2 "$RC" "SBATCH_EXTRA ending with a dangling --time: refused (sbatch would take the harness's next word as the time)" "$O"; has "$O" "dangling '--time'" "...named"
echo "-- D2: a time of 0 (any spelling), UNLIMITED, INFINITE or -1 is no limit at all in sbatch: refused from every source --"
for v in 0 0:0 00:00:00 0-0 0-00:00:00 UNLIMITED unlimited INFINITE Infinite -1; do
  O=$(subo "$P" -t "$v" -- echo hi); RC=$?; rc_is 2 "$RC" "-t $v refused" "$O"; has "$O" "^ERROR: -t $v asks for no time limit .*give an explicit limit ≤ MaxTime 1-00:00:00" "...saying so (-t $v)"; done
rc_is 2 "$(subo "$P" --rs-mode plan -t 0 -- echo hi >/dev/null; echo $?)" "...a plan too (-t 0)"; nosub "...nothing submitted"
for v in 0:30 0:0:30 1; do rc_is 0 "$(subo "$P" -t "$v" -- echo hi >/dev/null; echo $?)" "-t $v (Slurm rounds a started minute up: not 0) submitted"; done
for c in 'DEFAULT_TIME=0' 'FXSLURM_DEFAULT_TIME=UNLIMITED' 'SBATCH_EXTRA="--time=0"' 'SBATCH_EXTRA="-t 0"' 'SBATCH_EXTRA="-tINFINITE"' 'SBATCH_EXTRA="--time 00:00:00"'; do
  printf 'REMOTE_DIR=/x\n%s\n' "$c" > "$XP/.hpc.conf"; O=$(subo "$XP" -- echo hi); RC=$?
  rc_is 2 "$RC" "the conf's $c refused" "$O"; has "$O" "\(DEFAULT_TIME\|SBATCH_EXTRA's --time\) [^ ]* asks for no time limit" "...saying so, naming the conf key ($c)"; done
cp -R "$RS_USER_DIR" "$T/user-t0"; printf 't_policy() { SB_ARGS+=(--time=0); return 0; }\n' > "$T/user-t0/targets/fx-slurm/policy.local.sh"
PT0=$(RS_USER_DIR=$T/user-t0 mk_proj fx-slurm 'REMOTE_DIR=/x'); O=$(subo "$PT0" -- echo hi); RC=$?
rc_is 2 "$RC" "the policy's SB_ARGS --time=0 refused" "$O"; has "$O" "^ERROR: the policy's --time 0 asks for no time limit" "...named as the policy's"
printf 't_policy() { TIME=UNLIMITED; return 0; }\n' > "$T/user-t0/targets/fx-slurm/policy.local.sh"
PT0=$(RS_USER_DIR=$T/user-t0 mk_proj fx-slurm 'REMOTE_DIR=/x'); rc_is 2 "$(subo "$PT0" -- echo hi >/dev/null; echo $?)" "the policy setting TIME=UNLIMITED refused"
for v in 1h 1:2:3:4 1-2-3 ' ' 1:100 9999999999; do rc_is 2 "$(subo "$P" -t "$v" -- echo hi >/dev/null; echo $?)" "-t '$v' (not a spec this reads) refused"; done
nosub "...nothing submitted"
cp -R "$RS_USER_DIR" "$T/user-cap"; printf "\nT_MAXTIME='7 days'\n" >> "$T/user-cap/targets/fx-slurm/profile.sh"
PCA=$(RS_USER_DIR=$T/user-cap mk_proj fx-slurm 'REMOTE_DIR=/x'); rc_is 2 "$(subo "$PCA" -t 30 -- echo hi >/dev/null; echo $?)" "an unreadable MaxTime ('7 days') refuses (never 'no cap')"
echo "-- D2 (I): no here-string / heredoc in submit.sh: a full \$TMPDIR under bash 4.2 here-strings (temp files) changes no check --"
hasnt "$(grep -v '^ *#' "$RS_HOME/remote/submit.sh")" '<<' "submit.sh has no here-string or heredoc"
if fulltmp_ok; then
  printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="--time=1-12:00:00"\n' > "$XP/.hpc.conf"; : > "$T/sbatch.log"
  O=$(fulltmp env PATH="$T/bin:$PATH" bash "$XP/.fx-slurm/submit.sh" --same-name-ok -- echo hi 2>&1); RC=$?   # -t: the default 1-00:00:00
  rc_is 2 "$RC" "TMPDIR full, BASH_COMPAT=42: SBATCH_EXTRA --time 1-12:00:00 is still over MaxTime 1-00:00:00" "$O"
  has "$O" "^ERROR: SBATCH_EXTRA's --time 1-12:00:00 exceeds 'gpu' MaxTime" "...named"; nosub "...nothing submitted"; hasnt "$O" 'cannot create temp file' "...no temp file needed"
  rows "5|dup|RUNNING|None|0|N/A|$D|"; printf 'REMOTE_DIR=/x\n' > "$D/.hpc.conf"; : > "$T/sbatch.log"
  O=$(fulltmp env PATH="$T/sq:$T/bin:$PATH" bash "$D/.fx-slurm/submit.sh" -n dup -- echo hi 2>&1); RC=$?; rm -f "$T/squeue.rows"
  rc_is 6 "$RC" "...and the duplicate guard still reads squeue's rows: a live 'dup' is exit 6" "$O"; nosub "...nothing submitted (dup)"
else echo "  SKIP: no user namespace here (unshare -rm) or here-strings do not fail on a full TMPDIR: the full-TMPDIR check runs on Linux"; fi
echo "-- --rs-chain: a singleton segment (adds --dependency=singleton, the duplicate guard lets it through) --"
rows "5|chn|RUNNING|None|0|N/A|$D|"
O=$(sq "$D" --rs-chain -n chn -- echo hi); RC=$?
rc_is 0 "$RC" "--rs-chain next to a live same-name job: submits (it waits for it)" "$O"; has "$O" '^ARG:--dependency=singleton$' "...with --dependency=singleton"
[ "$(printf '%s\n' "$O" | grep -c '^ARG:--dependency')" = 1 ] && ok "...once" || bad "...once"; hasnt "$O" 'ARG:--rs-chain\|passing .--rs-chain' "...the flag never reaches sbatch or the policy"
O=$(sq "$D" --rs-mode plan --rs-chain -n chn -- echo hi); has "$(blk "$O")" '^chain=1$' "plan: chain=1"; has "$(blk "$O")" '^extra=--dependency=singleton$' "...and the word in extra"
O=$(sq "$D" -n chn -- echo hi); rc_is 6 $? "without --rs-chain the same submit is a duplicate (exit 6)"; rm -f "$T/squeue.rows"
for x in '--dependency=afterok:5' '-d afterany:5'; do printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="%s"\n' "$x" > "$D/.hpc.conf"
  rc_is 2 "$(PATH="$T/sq:$T/bin:$PATH" bash "$D/.fx-slurm/submit.sh" --rs-chain -n c2 -- echo hi >/dev/null 2>&1; echo $?)" "--rs-chain + SBATCH_EXTRA '$x': a conflict, exit 2"; done
nosub "...nothing submitted"
printf 'REMOTE_DIR=/x\nSBATCH_EXTRA="--dependency=singleton"\n' > "$D/.hpc.conf"; O=$(sq "$D" --rs-chain -n c3 -- echo hi)
[ "$(printf '%s\n' "$O" | grep -c '^ARG:--dependency=singleton$')" = 1 ] && ok "--rs-chain + SBATCH_EXTRA's own singleton: one --dependency=singleton" || bad "--rs-chain + SBATCH_EXTRA singleton"
printf 'REMOTE_DIR=/x\n' > "$D/.hpc.conf"; O=$(subo "$P" -n x -- echo --rs-chain); has "$O" '^ARG:--rs-chain$' "after --, --rs-chain is the payload's"; hasnt "$O" 'ARG:--dependency' "...and adds nothing"

echo "-- R5-4: info_prior = the run's earlier attempts here (receipts of <run id> / <run id>--aNN, + squeue rows of this WorkDir) --"
pri() { printf '%s\n' "$1" | sed -n 's/^info_prior=//p'; }
rcp() { mkdir -p "$1/.rs/attempts/$2"; printf 'job=%s\nname=%s\npartition=gpu\nproj=%s\nnonce=%s\nat=1\n' "$4" "$3" "$1" "$2" > "$1/.rs/attempts/$2/receipt"; }
IP=$(mk_proj fx-slurm 'REMOTE_DIR=/x'); ln -s "$IP" "$T/iplink"
O=$(sq "$IP" --rs-mode plan -n r5 -- echo hi); RC=$?; HI=$(bh "$O")
rc_is 0 "$RC" "a plan of a run with no history here" "$O"; [ "$(pri "$O")" = 0 ] && ok "...info_prior=0" || bad "...info_prior=0 (got '$(pri "$O")')"
rcp "$IP" x1 r5 101; rcp "$IP" x2 r5--a02 102; rcp "$IP" x3 r5--a1 103; rcp "$IP" x4 r5x 104; rcp "$IP" x5 r5--a02x 105; rcp "$IP" x6 other 106
rcp "$IP" x7 'r5--a003' 107; mkdir -p "$IP/.rs/attempts/x8"   # (no receipt: a plan, or never submitted)
O=$(sq "$IP" --rs-mode plan -n r5 -- echo hi); [ "$(pri "$O")" = 3 ] && ok "receipts named r5, r5--a02, r5--a003 count; r5--a1, r5x, r5--a02x, other and a dir without one do not: info_prior=3" || bad "receipts counted (got '$(pri "$O")')"
[ "$(bh "$O")" = "$HI" ] && ok "...envelope only: the bound_hash is the same as with no history" || bad "...info_prior changed the bound_hash"
prh() { printf '%s\n' "$1" | sed -n 's/^info_prior_here=//p'; }
[ "$(prh "$O")" = 3 ] && ok "info_prior_here=3: receipts without target= (older ones) count as this target's (fail closed)" || bad "untargeted receipts here (got '$(prh "$O")')"
rcp "$IP" y1 r6 401; printf 'target=fx-slurm\n' >> "$IP/.rs/attempts/y1/receipt"
rcp "$IP" y2 r6--a02 402; printf 'target=fx-other\n' >> "$IP/.rs/attempts/y2/receipt"   # a dir two targets share
O=$(sq "$IP" --rs-mode plan -n r6 -- echo hi)
[ "$(pri "$O")" = 2 ] && [ "$(prh "$O")" = 1 ] && ok "a receipt of another target: in info_prior (2), not in info_prior_here (1)" \
  || bad "per-target count (info_prior '$(pri "$O")', info_prior_here '$(prh "$O")')"
O=$(sq "$IP" --rs-mode plan -n r5--a04 -- echo hi); [ "$(pri "$O")" = 3 ] && ok "a plan named r5--a04: the run id r5 (minus --aNN, as rsk's ledger reads it) -> 3" || bad "r5--a04 (got '$(pri "$O")')"
O=$(sq "$IP" --rs-mode plan -n r5x -- echo hi); [ "$(pri "$O")" = 1 ] && ok "another run (r5x): only its own receipt" || bad "r5x (got '$(pri "$O")')"
rows "101|r5|RUNNING|None|0|N/A|$IP|" "201|r5--a07|COMPLETED|None|0|N/A|$IP|" "202|r5|PENDING|Priority|0|N/A|/elsewhere|" "203|r5--a08|FAILED|None|0|N/A|$T/iplink|" \
  "204|r5x|RUNNING|None|0|N/A|$IP|" "205|r5|RUNNING|None|0|N/A||"
O=$(sq "$IP" --rs-mode plan -n r5--a09 -- echo hi); RC=$?
rc_is 0 "$RC" "squeue rows of the run (not the plan's own name: no duplicate)" "$O"
[ "$(pri "$O")" = 5 ] && ok "+ squeue rows of this WorkDir (also via a symlink, also ended but still listed), none twice: job 101 has a receipt -> 3 + 201 + 203 = 5" || bad "squeue rows counted (got '$(pri "$O")')"
[ "$(prh "$O")" = 5 ] && ok "...squeue rows are this cluster's own: info_prior_here=5 too" || bad "squeue rows here (got '$(prh "$O")')"
O=$(sq "$IP" --rs-mode plan --same-name-ok -n r5 -- echo hi); [ "$(pri "$O")" = 5 ] && ok "...also when the duplicate guard is off (--same-name-ok): squeue is still asked" || bad "--same-name-ok plan (got '$(pri "$O")')"
O=$(sq "$IP" --rs-mode plan --rs-chain -n r5 -- echo hi); [ "$(pri "$O")" = 5 ] && ok "...and for a chain segment (--rs-chain)" || bad "--rs-chain plan (got '$(pri "$O")')"
touch "$T/squeue.fail"; O=$(sq "$IP" --rs-mode plan --same-name-ok -n r5 -- echo hi); RC=$?
rc_is 0 "$RC" "squeue failing: the plan goes on" "$O"; [ "$(pri "$O")" = unknown ] && ok "...info_prior=unknown (rsk: a relaunch, fail closed)" || bad "squeue failing -> unknown (got '$(pri "$O")')"
[ "$(prh "$O")" = unknown ] && ok "...and info_prior_here=unknown" || bad "squeue failing -> here unknown (got '$(prh "$O")')"
O=$(sq "$IP" --rs-mode plan -n r5 -- echo hi); [ "$(pri "$O")" = unknown ] && ok "...also with the duplicate guard on (its warning, then unknown)" || bad "guard on, squeue failing (got '$(pri "$O")')"
rm -f "$T/squeue.fail" "$T/squeue.rows"
# info_wandb_env (envelope): does $PROJ/.wandb_env — env.sh sources it after the conf — name WANDB_MODE (rsk: a smoke's conf key)
pwe() { printf '%s\n' "$1" | sed -n 's/^info_wandb_env=//p'; }
O=$(sq "$IP" --rs-mode plan -n r7 -- echo hi); [ "$(pwe "$O")" = none ] && ok "info_wandb_env=none: no .wandb_env in the project" || bad "wandb_env none (got '$(pwe "$O")')"
printf 'export WANDB_API_KEY=k1secret\n' > "$IP/.wandb_env"; O=$(sq "$IP" --rs-mode plan -n r7 -- echo hi)
[ "$(pwe "$O")" = no ] && ok "...=no: a key only" || bad "wandb_env no (got '$(pwe "$O")')"; hasnt "$O" 'k1secret' "...the file is read, never printed"
[ "$(bh "$O")" = "$(bh "$(rm -f "$IP/.wandb_env"; sq "$IP" --rs-mode plan -n r7 -- echo hi)")" ] && ok "...envelope only: the bound_hash does not change" || bad "...info_wandb_env changed the bound_hash"
printf 'export WANDB_API_KEY=k1secret\nexport WANDB_MODE=online\n' > "$IP/.wandb_env"; O=$(sq "$IP" --rs-mode plan -n r7 -- echo hi)
[ "$(pwe "$O")" = names ] && ok "...=names: it sets WANDB_MODE (the conf's disabled may be undone)" || bad "wandb_env names (got '$(pwe "$O")')"
if [ "$(id -u)" != 0 ]; then chmod 000 "$IP/.wandb_env"; O=$(sq "$IP" --rs-mode plan -n r7 -- echo hi)
  [ "$(pwe "$O")" = unreadable ] && ok "...=unreadable: it cannot be read" || bad "wandb_env unreadable (got '$(pwe "$O")')"; chmod 600 "$IP/.wandb_env"
else echo "  SKIP: root reads any file: the unreadable .wandb_env case is not testable"; fi
rm -f "$IP/.wandb_env"; mkdir "$IP/.wandb_env"; O=$(sq "$IP" --rs-mode plan -n r7 -- echo hi)
[ "$(pwe "$O")" = none ] && ok "...a directory named .wandb_env: none (env.sh sources only a file: [ -f ])" || bad "wandb_env dir (got '$(pwe "$O")')"
rmdir "$IP/.wandb_env"
if [ "$(id -u)" != 0 ]; then chmod 000 "$IP/.rs/attempts/x6/receipt"
  O=$(sq "$IP" --rs-mode plan -n r5 -- echo hi); [ "$(pri "$O")" = unknown ] && ok "a receipt that cannot be read: info_prior=unknown" || bad "unreadable receipt (got '$(pri "$O")')"
  chmod 644 "$IP/.rs/attempts/x6/receipt"; else echo "  SKIP: root reads any receipt: the unreadable-receipt case is not testable"; fi
cp -R "$RS_USER_DIR" "$T/user-glob"; printf 'set -f; shopt -s failglob\n' > "$T/user-glob/targets/fx-slurm/policy.local.sh"
IG=$(RS_USER_DIR=$T/user-glob mk_proj fx-slurm 'REMOTE_DIR=/x'); rcp "$IG" g1 r5 301
O=$(sq "$IG" --rs-mode plan --same-name-ok -n r5 -- echo hi); RC=$?   # (no duplicate guard: nothing else turns globbing back on)
rc_is 0 "$RC" "a policy that turns on set -f and failglob" "$O"; [ "$(pri "$O")" = 1 ] && ok "...cannot hide a receipt (info_prior=1, not 0)" || bad "set -f policy hides receipts (got '$(pri "$O")')"
O=$(sq "$IP" --rs-mode plan -n r5 -- echo hi); W1=$(wid "$O"); HX=$(bh "$O")
O=$(sq "$IP" --rs-expect "$HX" --rs-warnings "$W1" -n r5 -- echo hi); RC=$?
rc_is 0 "$RC" "--rs-expect: info_prior is no part of the approval (submits)" "$O"; hasnt "$O" '^@@plan' "...and prints no block when it holds"
rcp "$IP" x9 r5 108; O=$(sq "$IP" --rs-expect "$HX" --rs-warnings "$W1" -n r5 -- echo hi); RC=$?
rc_is 0 "$RC" "...nor does a new attempt of the run since the plan" "$O"

echo "-- R5-10: the policy template's gate idiom (WARNING, then test FORCE): printed under -y too, so a plan shows it from the real call --"
TG=$(sed -n 's/^  # \(\[ "\$PART" != paid \] || .*\)$/\1/p' "$RS_HOME/targets/_template-slurm/policy.sh")
has "$TG" "echo \"WARNING: .*\" >&2; \[ \"\$FORCE\" = 1 \] || exit 1; }\$" "the template's example gate is written in the idiom (the WARNING, then FORCE)"
tgp() { cp -R "$RS_USER_DIR" "$T/$1"; { printf '%s\n' "eval \"\$(declare -f t_partition | sed '1s/^t_partition/t_partition_shipped/')\"" \
  't_partition() { [ "$1" != paid ] || { P_GPUS=1-4; return 0; }; t_partition_shipped "$1"; }' "t_policy() {" "  $2" "  return 0" "}"; } > "$T/$1/targets/fx-slurm/policy.local.sh"; }
tgp user-tg "$TG"; PT=$(RS_USER_DIR=$T/user-tg mk_proj fx-slurm 'REMOTE_DIR=/x')
O=$(subo "$PT" --rs-mode plan -p paid -n tg -- echo hi); RC=$?; HT=$(bh "$O"); WT=$(wid "$O")
rc_is 0 "$RC" "plan -p paid with the template's gate" "$O"; has "$(blk "$O")" '^warnings=1$' "...its WARNING counted once"
[ "$(printf '%s\n' "$O" | grep -c "^WARNING: 'paid' is charged")" = 2 ] && ok "...printed by the probe AND by the real call (FORCE=1): the plan shows it without the probe" || bad "...printed twice (probe + real call)"
O=$(subo "$PT" -p paid -n tg -- echo hi); RC=$?; rc_is 1 "$RC" "a submit without -y stops at it" "$O"; nosub "...nothing submitted"
O=$(subo "$PT" -p paid -y -n tg -- echo hi); RC=$?; rc_is 0 "$RC" "-y submits past it" "$O"; has "$O" "^WARNING: 'paid' is charged" "...and the -y submit logs the WARNING (the idiom prints it before testing FORCE)"
O=$(subo "$PT" --rs-expect "$HT" --rs-warnings "$WT" -y -p paid -n tg -- echo hi); RC=$?; rc_is 0 "$RC" "the approved submit (its card's warnings_id): submits" "$O"
tgp user-tg2 '[ "$PART" != paid ] || [ "$FORCE" = 1 ] || { echo "WARNING: '"'"'$PART'"'"' is charged to the group'"'"'s account. Re-run -y to submit there." >&2; exit 1; }'
PT2=$(RS_USER_DIR=$T/user-tg2 mk_proj fx-slurm 'REMOTE_DIR=/x'); O=$(subo "$PT2" -p paid -y -n tg -- echo hi); RC=$?
rc_is 0 "$RC" "(the P2 form: FORCE tested first)" "$O"; hasnt "$O" '^WARNING:' "...silent under -y — why the template prints first"
O=$(subo "$PT2" --rs-mode plan -p paid -n tg -- echo hi); [ "$(printf '%s\n' "$O" | grep -c "^WARNING: 'paid' is charged")" = 1 ] \
  && ok "...a plan sees the P2 form only through the probe (once)" || bad "...P2 form: plan prints it once (probe only)"

echo "-- the api=3 pre-scan: separate words, validated before the claim --"
B0=$(natt "$P")
for a in '--rs-mode apply' '--rs-mode' '--rs-mode plan --rs-mode plan' '--rs-mode=plan' '--rs-expect abc' "--rs-expect $(printf %s "$H1" | tr a-f A-F)" \
         "--rs-expect ${H1}0" "--rs-expect $H1 --rs-expect $H1" "--rs-expect=$H1" '--rs-expect' '--rs-chain=1' '--rs-foo' '--rs-'; do
  O=$(subo "$P" $a -- echo hi); RC=$?; [ "$RC" = 2 ] && ok "'${a:0:40}' refused (exit 2)" || bad "'${a:0:40}' refused (exit 2, got $RC)"; done
[ "$(natt "$P")" = "$B0" ] && ok "...none of them claimed an attempt dir" || bad "...an invalid api=3 flag claimed a dir"; nosub "...nor submitted"
has "$(subo "$P" -- echo hi; cat "$T/sbatch.log")" 'job\.sbatch echo hi$' "(a plain submit still goes out)"
B0=$(natt "$P")   # an --rs- word as an option's VALUE (-n --rs-chain) is refused, never taken as the flag; nor one glued in a word
for a in '-n --rs-chain --exp' '-p --rs-chain' '-t --rs-mode plan' "-g --rs-expect $H1" '-n--rs-chain --exp' '--x--rs-chain' '-y --gpu--rs-chain'; do
  O=$(subo "$P" $a -- echo hi); RC=$?; [ "$RC" = 2 ] && ok "--rs- value: '${a:0:30}' refused (exit 2)" || bad "--rs- value: '$a' refused (exit 2, got $RC)"; done
[ "$(natt "$P")" = "$B0" ] && ok "...before the claim" || bad "...an --rs- value claimed a dir"; nosub "...nothing submitted (no --dependency=singleton smuggled in)"
O=$(subo "$P" -y --rs-chain -n okc -- echo hi); RC=$?; rc_is 0 "$RC" "after a flag that takes no value (-y), --rs-chain is the flag" "$O"; has "$O" '^ARG:--dependency=singleton$' "...a singleton"

echo "-- OLD submit.sh (P2 6df6e56, pre-P2 8c8129e) given --rs-mode plan / --rs-expect H: exit 2, nothing submitted --"
for c in 6df6e56 8c8129e; do
  if OS=$(git -C "$RS_HOME" show "$c:remote/submit.sh" 2>/dev/null) && [ -n "$OS" ]; then
    OP=$(mk_proj fx-slurm 'REMOTE_DIR=/x'); printf '%s\n' "$OS" > "$OP/.fx-slurm/submit.sh"
    for a in '--rs-mode plan -- echo hi' "--rs-expect $H1 -- echo hi" '-p gpu -y --rs-mode plan -g 1 -- echo hi' "--rs-chain --rs-mode plan --rs-expect $H1 -- echo hi"; do
      O=$(subo "$OP" $a); RC=$?
      [ "$RC" = 2 ] && has "$O" "unknown arg '\(plan\|$H1\)'" "$c + '${a:0:40}': exit 2 (the bare value word: unknown arg)" || bad "$c + '$a': exit 2 (got $RC)"
      nosub "$c + '${a:0:40}': sbatch never reached"; done
    O=$(subo "$OP" --rs-chain -n lone -- echo hi)
    [ "$?" = 0 ] && hasnt "$O" 'ARG:--dependency' "$c + a LONE --rs-chain: taken as a policy flag, submitted WITHOUT the singleton (so rsk sends it only after api=3)" || bad "$c + lone --rs-chain"
  else echo "  SKIP: no git history ($c): an installed copy — the old-parser check runs in the clone"; fi
done
