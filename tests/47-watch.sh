#!/usr/bin/env bash
# tests/47-watch.sh — phase A: bin/run-watch. The ssh stub RUNS each stdin script under bash with stateful fake squeue /
# sacct / sbatch / ps reading $WORLD (rows in the formats reproduced on three clusters, design §12); submits go through
# the REAL deployed submit.sh. Covers: table rules, --approve and stale blocks, launch / max-active / one submit per
# target per round, settle = purged + terminal sacct (re-checked in the submit ssh), the empty-squeue guard, budgets,
# CANCELLED never resubmitted, requeue + requeue-storm, adoption rules, submit refused / unknown / interrupted,
# --adopt / --release, workstations detect-only, stall + resume checks, blind targets, lock, lost state, exit codes.
set -u
. "$RS_HOME/tests/lib.sh"
export WORLD=$T/world RBIN=$T/rbin TBIN=$T/bin; mkdir -p "$WORLD" "$RBIN"
cat > "$RBIN/squeue" <<'EOS'
#!/usr/bin/env bash
[ ! -f "$WORLD/squeue.fail" ] || exit 1
[ ! -f "$WORLD/squeue" ] || grep -v '^$' "$WORLD/squeue"; exit 0
EOS
cat > "$RBIN/sacct" <<'EOS'
#!/usr/bin/env bash
[ ! -f "$WORLD/sacct.fail" ] || exit 1
ids="" names="" fields=""
while [ "$#" -gt 0 ]; do case "$1" in -j) ids=$2; shift ;; --name=*) names=${1#--name=} ;; -o) fields=$2; shift ;; esac; shift; done
[ -f "$WORLD/sacct" ] || exit 0
while IFS='|' read -r id n st ec wd el lim; do
  [ -n "$id" ] || continue
  [ -z "$ids" ] || case ",$ids," in *",$id,"*) ;; *) continue ;; esac
  [ -z "$names" ] || case ",$names," in *",$n,"*) ;; *) continue ;; esac
  case "$fields" in State) [ -f "$WORLD/now-running" ] && echo RUNNING || echo "$st" ;; JobID) echo "$id" ;; JobID,WorkDir) echo "$id|$wd" ;; *ElapsedRaw*) echo "$id|$n|$st|$ec|$wd|$el|$lim" ;; *) echo "$id|$n|$st|$ec|$wd" ;; esac
done < "$WORLD/sacct"
EOS
cat > "$RBIN/sbatch" <<'EOS'
#!/usr/bin/env bash
[ ! -f "$WORLD/sbatch.fail" ] || { echo "sbatch: error: Batch job submission failed: Socket timed out on send/recv operation" >&2; exit 1; }
n=$(cat "$WORLD/nextjid"); echo $((n + 1)) > "$WORLD/nextjid"; printf '%s\n' "$*" >> "$WORLD/sbatch.log"; echo "Submitted batch job $n"
EOS
cat > "$RBIN/ps" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do p=$a; done; [ -f "$WORLD/ps.$p" ] && cat "$WORLD/ps.$p" || exit 1
EOS
cat > "$T/bin/ssh" <<'EOS'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
h=$1; shift; echo "$h" >> "$WORLD/ssh.log"
[ ! -f "$WORLD/ssh.fail.$h" ] || { echo "ssh: connect to host $h port 22: Connection refused" >&2; exit 255; }
[ "$*" = "bash -s" ] || { echo "$*" >> "$WORLD/ssh-bad.log"; exit 99; }
s=$(cat); printf '%s\n@@@@\n' "$s" >> "$WORLD/scripts.log"
[ ! -f "$WORLD/ssh.hang.$h" ] || sleep 20
printf '%s\n' "$s" | PATH="$RBIN:$TBIN:$PATH" bash -s
EOS
chmod +x "$RBIN"/* "$T/bin/ssh"
P=$(mk_proj fx-slurm ""); printf 'REMOTE_DIR=%s\n' "$P" > "$P/.hpc.conf"; mkdir -p "$P/logs"
WP=$T/wsp; mkdir -p "$WP/logs"; printf 'WS_REMOTE_DIR=%s\n' "$WP" > "$WP/.ws.conf"
rw() { ( cd "$P" && PATH="$T/bin:$PATH" RS_WATCH_OBS_TIMEOUT=${OBS_TO:-15} RS_WATCH_SUBMIT_TIMEOUT=15 bash "$RS_HOME/bin/run-watch" "$@" 2>&1 ); }
rww() { ( cd "$WP" && PATH="$T/bin:$PATH" RS_WATCH_OBS_TIMEOUT=15 bash "$RS_HOME/bin/run-watch" "$@" 2>&1 ); }
reset() { rm -rf "$P/logs/run-watch" "$WP/logs/run-watch" "$WORLD"/*; echo 1000 > "$WORLD/nextjid"; : > "$WORLD/sbatch.log"; }
NOW=$(date +%s)
OTHER="9|someone-else|RUNNING|None|0|$NOW|/elsewhere|"   # keeps the user's queue non-empty (the empty-squeue guard)
q() { printf '%s\n' "$OTHER" "$@" > "$WORLD/squeue"; }   # rows: jid|name|state|reason|restarts|start|workdir|
acct() { printf '%s\n' "$@" > "$WORLD/sacct"; }          # rows: jid|name|state|exit|workdir[|elapsed-s|limit-min]
nsub() { grep -c . "$WORLD/sbatch.log"; }
table() { { echo '#@ run-watch v1'; printf '%s\n' "$@"; } > "$P/t.tsv"; }
approved() { table "$@"; rw t.tsv --approve "go ahead" >/dev/null; }
st() { awk -F'	' -v n="$1" -v f="$2" '$1 == n { print $f }' "$P/logs/run-watch/t.state"; }   # st NAME FIELD (2 status, 3 jobs, 4 preempts)
ROW="-p gpu -g 1 -t 1:00:00 -- python train.py"

echo "-- table rules: every violation is exit 2 and no submit --"
reset; q
for bad in "a fx-slurm - -p gpu -- x;y" 'a fx-slurm - -p gpu -- $HOME' "a fx-slurm - -p gpu python" "a fx-slurm - -n x -p gpu -- y" \
           "a fx-slurm - -p gpu --gpu-user-asked -- y" "a fx-slurm - -g 1 -- y" "a ws-box - -p gpu -- y" "a fx-slurm ../x -" \
           "a nosuch - -" "-a fx-slurm - -"; do
  table "$bad"; O=$(rw t.tsv --once); RC=$?
  [ "$RC" = 2 ] && [ "$(nsub)" = 0 ] && ok "refused: $bad" || { bad "refused: $bad (rc=$RC)"; echo "$O" | head -3; }
done
table "a fx-slurm - -" "a fx-slurm - -"; O=$(rw t.tsv --once); [ "$?" = 2 ] && ok "duplicate name refused" || bad "duplicate name refused"
printf 'a fx-slurm - -\n' > "$P/t.tsv"; O=$(rw t.tsv --once); [ "$?" = 2 ] && ok "missing '#@ run-watch v1' refused" || bad "missing header refused"
table "#@ allow launch preempt=x"; O=$(rw t.tsv --once); [ "$?" = 2 ] && ok "bad allow word refused" || bad "bad allow word refused"
table "# only a comment"; O=$(rw t.tsv --once); [ "$?" = 2 ] && ok "a table without rows is exit 2" || bad "empty table exit 2"
table "#@ allow launch" "a fx-slurm - $ROW"; rw t.tsv --approve "go" >/dev/null
O=$(rw t.tsv --once --act); [ "$?" = 2 ] && has "$O" 'max-active' "--act with launch allowed needs --max-active" || bad "--max-active required"
O=$(rw t.tsv --once --every 10); [ "$?" = 2 ] && ok "--every below 60 refused" || bad "--every below 60 refused"

echo "-- --approve: the program writes the checksum; edits and budget changes go stale --"
reset; q; table "#@ allow launch preempt=2" "a fx-slurm - $ROW" "b fx-slurm - $ROW"
O=$(rw t.tsv --approve 'yes, run a and b'); has "$O" 'approving block' "--approve prints what it approves"
has "$(sed -n 3p "$P/t.tsv")" '^#@ ok [0-9-]* sum=[0-9]* "yes, run a and b"$' "--approve inserts '#@ ok' above the rows"
cp "$P/t.tsv" "$T/t.before"; O=$(rw t.tsv --approve 'again'); has "$O" 'nothing to approve' "a second --approve changes nothing"
cmp -s "$P/t.tsv" "$T/t.before" && ok "table untouched when nothing is pending" || bad "table untouched when nothing is pending"
for w in '' 'say "hi"'; do O=$(rw t.tsv --approve "$w"); [ "$?" = 2 ] && ok "--approve '$w' refused" || bad "--approve '$w' refused"; done
O=$(rw t.tsv --approve x --act); [ "$?" = 2 ] && ok "--approve with --act refused" || bad "--approve with --act refused"
sed -i 's/-t 1:00:00/-t 2:00:00/' "$P/t.tsv"; O=$(rw t.tsv --once --act --max-active 4); RC=$?
has "$O" 'reason=approval-stale' "an edited row makes its block stale"; [ "$(nsub)" = 0 ] && ok "stale block: 0 submits" || bad "stale block: 0 submits"
has "$O" 'not-submitted.*why=not-approved' "stale rows wait for a new OK"; [ "$RC" = 4 ] && ok "only human-waiting rows: exit 4" || bad "exit 4 ($RC)"
rw t.tsv --approve 'ok with 2h' >/dev/null; [ "$(grep -c '^#@ ok' "$P/t.tsv")" = 1 ] && ok "--approve replaces the stale '#@ ok'" || bad "--approve replaces the stale ok"
printf 'c fx-slurm - %s\n' "$ROW" >> "$P/t.tsv"; reset; q; O=$(rw t.tsv --once --act --max-active 4)
has "$O" 'approval-stale' "an appended row (same block) makes it stale: no inherited approval"
reset; q; table "#@ allow launch preempt=2" "a fx-slurm - $ROW"; rw t.tsv --approve go >/dev/null
sed -i 's/preempt=2/preempt=60/' "$P/t.tsv"; O=$(rw t.tsv --once --act --max-active 4)
has "$O" 'approval-stale' "raising the budget makes every block stale"; [ "$(nsub)" = 0 ] && ok "raised budget: 0 submits" || bad "raised budget: 0 submits"

echo "-- launch: needs launch + OK + --act; one submit per target per round; --max-active --"
reset; q; approved "#@ allow preempt=2" "a fx-slurm - $ROW"
O=$(rw t.tsv --once --act); has "$O" 'not-submitted.*why=no-launch-allowed' "no 'launch' in #@ allow: never a first submit"
reset; q; table "#@ allow launch" "a fx-slurm - $ROW"; O=$(rw t.tsv --once --act --max-active 2)
has "$O" 'why=not-approved' "no '#@ ok': not submitted"
reset; q; approved "#@ allow launch preempt=2" "a fx-slurm - $ROW" "b fx-slurm - $ROW"
O=$(rw t.tsv --once); RC=$?; has "$O" 'ATTENTION name=a .*not-submitted.*why=no-act' "without --act: reported, not submitted"
[ "$(nsub)" = 0 ] && [ "$RC" = 4 ] && ok "detect-only: 0 submits, exit 4" || bad "detect-only: 0 submits, exit 4 (rc=$RC)"
O=$(rw t.tsv --once --act --max-active 2); RC=$?
has "$O" 'LAUNCH name=a target=fx-slurm job=1000 log=logs/a_1000.out' "LAUNCH with the submit.sh receipt's job id"
[ "$(nsub)" = 1 ] && ok "one submit per target per round" || bad "one submit per target per round ($(nsub))"
has "$(cat "$WORLD/sbatch.log")" '--job-name=a ' "the job is named after the row (submit.sh -n)"
hasnt "$(cat "$WORLD/sbatch.log")" '--comment=acked' "no *-user-asked flag replayed"
[ "$(st a 2)" = active ] && [ "$(st a 3)" = 1000 ] && ok "state: a active, job 1000" || bad "state: a active job 1000"
[ "$RC" = 3 ] && ok "--once with rows moving: exit 3" || bad "--once exit 3 ($RC)"
q "1000|a|PENDING|Priority|0|N/A|$P|"; O=$(rw t.tsv --once --act --max-active 1)
[ "$(nsub)" = 1 ] && ok "--max-active 1 with a pending job: b waits" || bad "--max-active holds b"
hasnt "$O" 'ATTENTION name=b' "waiting for a slot is not a human matter"
O=$(rw t.tsv --once --act --max-active 2); has "$O" 'LAUNCH name=b .*job=1001' "a free slot: b launched"
hasnt "$(cat "$WORLD/scripts.log")" "'-y'" "run-watch never adds -y"

echo "-- settle: purged from the queue + terminal sacct; the submit ssh re-checks --"
reset; q "1000|a|RUNNING|None|0|$NOW|$P|"; approved "#@ allow preempt=2" "a fx-slurm - $ROW"
O=$(rw t.tsv --once --act --adopt a=1000); has "$O" 'ADOPT name=a .*job=1000 note=manual' "--adopt NAME=JOBID"
q "1000|a|PREEMPTED|None|0|$NOW|$P|"; acct "1000|a|PREEMPTED|0:0|$P"; O=$(rw t.tsv --once --act)
[ "$(nsub)" = 0 ] && ok "ended but still in the queue (MinJobAge): 0 submits" || bad "unpurged: 0 submits"
printf '' > "$WORLD/squeue"; O=$(rw t.tsv --once --act)
has "$O" 'WARN target=fx-slurm reason=observe-failed .*empty squeue' "had jobs, now an empty squeue: the round is a failed observation"
[ "$(nsub)" = 0 ] && ok "empty-squeue guard: 0 submits" || bad "empty-squeue guard: 0 submits"
O=$(rw t.tsv --once --act); has "$O" "RESUBMIT name=a target=fx-slurm job=1000 prev=1000 state=PREEMPTED preempts=1/2" "empty again: believed, resubmitted once, same name"
[ "$(nsub)" = 1 ] && has "$(cat "$WORLD/sbatch.log")" '--job-name=a ' "resubmit keeps the name" || bad "one resubmit"
q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act >/dev/null
q; acct "1000|a|PREEMPTED|0:0|$P"
touch "$WORLD/now-running"; O=$(rw t.tsv --once --act)
has "$O" 'WARN name=a .*reason=submit-skipped n=1 -- sacct-now=RUNNING' "the submit ssh re-checks sacct: changed state, nothing submitted"
[ "$(nsub)" = 1 ] && [ "$(st a 4)" = 1 ] && ok "skipped submit: budget refunded (preempts 1)" || bad "skip refunds (preempts=$(st a 4))"
rm -f "$WORLD/now-running"; O=$(rw t.tsv --once --act); has "$O" 'RESUBMIT name=a .*preempts=2/2' "second resubmit"
q; acct "1001|a|PREEMPTED|0:0|$P"; O=$(rw t.tsv --once --act); RC=$?
has "$O" 'ATTENTION name=a .*reason=preempted why=budget action=needs-ok preempt=2/2' "budget spent: reported"
[ "$(nsub)" = 2 ] && [ "$RC" = 4 ] && ok "budget spent: no submit, exit 4" || bad "budget spent (rc=$RC, $(nsub))"
hasnt "$(cat "$WORLD/scripts.log")" 'scancel\|scontrol\|kill \|sbatch\|rm -\|mkdir' "remote scripts never cancel, kill, write or call sbatch themselves"

echo "-- requeue: same id back in the queue = counted, never acted on; storm reported at each multiple --"
reset; approved "#@ allow preempt=2" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act --adopt a=1000 >/dev/null
q "1000|a|PENDING|BeginTime|1|N/A|$P|"; O=$(rw t.tsv --once --act); has "$O" 'REQUEUE name=a .*restarts=1' "REQUEUE event"
q "1000|a|RUNNING|None|2|$NOW|$P|"; O=$(rw t.tsv --once --act); has "$O" 'reason=requeue-storm restarts=2' "storm at the preempt budget (2)"
q "1000|a|RUNNING|None|3|$NOW|$P|"; O=$(rw t.tsv --once --act); hasnt "$O" 'requeue-storm' "no repeat before the next multiple"
q "1000|a|RUNNING|None|4|$NOW|$P|"; O=$(rw t.tsv --once --act); has "$O" 'requeue-storm restarts=4' "again at 2x"
[ "$(nsub)" = 0 ] && ok "requeues: 0 submits" || bad "requeues: 0 submits"
reset; approved "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
q "1000|a|RUNNING|None|6|$NOW|$P|"; O=$(rw t.tsv --once); has "$O" 'requeue-storm restarts=6' "no preempt budget: threshold 6"

echo "-- terminal states --"
for c in "COMPLETED|done|DONE name=a .*done=out/a.done" "COMPLETED||reason=completed-not-done" "CANCELLED by 4242||reason=cancelled by=4242" \
         "FAILED||reason=failed why=budget" "TIMEOUT||reason=timeout why=budget" "WEIRD||reason=unknown-state" "PREEMPTED|done|reason=artifact-but-preempted"; do
  s=${c%%|*}; r=${c#*|}; d=${r%%|*}; r=${r#*|}
  reset; approved "#@ allow preempt=5" "a fx-slurm out/a.done $ROW"; rm -rf "$P/out"; [ -z "$d" ] || { mkdir -p "$P/out"; touch "$P/out/a.done"; }
  q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act --adopt a=1000 >/dev/null
  q; acct "1000|a|$s|0:0|$P"; O=$(rw t.tsv --once --act); RC=$?
  has "$O" "$r" "settled $s${d:+ + done}: $r"; [ "$(nsub)" = 0 ] && ok "settled $s: 0 submits" || bad "settled $s: 0 submits"
done
[ "$RC" = 4 ] && ok "a held row: exit 4" || bad "held exit 4 ($RC)"
reset; approved "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
q; acct "1000|a|COMPLETED|0:0|$P"; O=$(rw t.tsv --once); RC=$?; has "$O" 'DONE name=a .*artifact=unchecked' "done '-': DONE unchecked"
[ "$RC" = 0 ] && ok "every row done: exit 0" || bad "all done exit 0 ($RC)"
reset; approved "#@ allow errors=1 timeout=1" "a fx-slurm - $ROW" "b fx-slurm - $ROW"
q "1000|a|RUNNING|None|0|$NOW|$P|" "1001|b|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 --adopt b=1001 >/dev/null
q; acct "1000|a|OUT_OF_MEMORY|0:125|$P" "1001|b|TIMEOUT|0:0|$P"; echo 2000 > "$WORLD/nextjid"
O=$(rw t.tsv --once --act); has "$O" 'RETRY name=a .*state=OUT_OF_MEMORY errors=1/1' "errors=1: one retry"
q "2000|a|PENDING|Priority|0|N/A|$P|"; O=$(rw t.tsv --once --act); has "$O" 'RESUBMIT name=b .*state=TIMEOUT timeouts=1/1' "timeout=1: one continuation (next round: one submit per target per round)"

echo "-- at-limit: ended within min(15 min, limit/10) of the time limit = a timeout, whatever sacct calls it --"
lim() {   # lim DONE ALLOW "STATE|EXIT|ELAPSED|LIMIT": adopt job 1000 of row a, then it settles that way
  reset; approved "$2" "a fx-slurm $1 $ROW"; rm -rf "$P/out"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
  q; acct "1000|a|${3%%|*}|$(echo "$3" | cut -d'|' -f2)|$P|$(echo "$3" | cut -d'|' -f3-)"; echo 2000 > "$WORLD/nextjid"; }
lim - "#@ allow timeout=1" "FAILED|138:0|259055|4320"; O=$(rw t.tsv --once --act)   # a USR1 death 145 s early (design §12)
has "$O" 'RESUBMIT name=a .*state=FAILED at-limit left=145s timeouts=1/1' "FAILED 145 s before a 3-day limit: timeout budget"
lim - "#@ allow timeout=1" "FAILED|10:0|5254|90"; O=$(rw t.tsv --once --act)   # same death as another site records it
has "$O" 'RESUBMIT name=a .*state=FAILED at-limit left=146s' "exit code not read: FAILED 10:0 at-limit too"
lim - "#@ allow timeout=1" "FAILED|1:0|3600|4320"; O=$(rw t.tsv --once --act)
has "$O" 'reason=failed why=budget action=needs-ok errors=0/0' "FAILED early: errors budget, not timeout"; [ "$(nsub)" = 0 ] && ok "FAILED early: 0 submits" || bad "FAILED early: 0 submits"
lim - "" "FAILED|138:0|259055|4320"; O=$(rw t.tsv --once --act)
has "$O" 'reason=failed why=budget action=needs-ok timeout=0/0 at-limit left=145s' "at-limit without a timeout budget: needs-ok says why"
lim - "#@ allow timeout=1" "FAILED|1:0|200|5"; O=$(rw t.tsv --once --act)   # 100 s left of 5 min > 30 s (a tenth)
has "$O" 'reason=failed why=budget action=needs-ok errors=0/0' "short limit: window is a tenth of it"; [ "$(nsub)" = 0 ] && ok "short limit: 0 submits" || bad "short limit: 0 submits"
lim - "#@ allow timeout=1" "FAILED|1:0|290|5"; O=$(rw t.tsv --once --act); has "$O" 'state=FAILED at-limit left=10s' "short limit: inside its window"
lim - "#@ allow timeout=1" "FAILED|138:0||"; O=$(rw t.tsv --once --act); has "$O" 'reason=failed why=budget' "no elapsed/limit: errors, as before"
lim out/a.done "#@ allow timeout=1" "COMPLETED|0:0|259000|4320"; O=$(rw t.tsv --once --act)
has "$O" 'RESUBMIT name=a .*state=COMPLETED at-limit left=200s timeouts=1/1' "COMPLETED at-limit, done-path missing: a continuation"
lim - "#@ allow timeout=1" "COMPLETED|0:0|259000|4320"; O=$(rw t.tsv --once --act); RC=$?
has "$O" 'reason=completed-at-limit at-limit left=200s' "COMPLETED at-limit, done '-': held, not DONE"; hasnt "$O" 'DONE name=a' "  ...and no DONE"
[ "$RC" = 4 ] && [ "$(nsub)" = 0 ] && ok "completed-at-limit: exit 4, 0 submits" || bad "completed-at-limit: exit 4, 0 submits ($RC)"
lim out/a.done "#@ allow timeout=1" "COMPLETED|0:0|259000|4320"; mkdir -p "$P/out"; touch "$P/out/a.done"; O=$(rw t.tsv --once --act)
has "$O" 'DONE name=a .*done=out/a.done' "COMPLETED at-limit with its done-path: DONE"

echo "-- adoption of rows run-watch never submitted --"
reset; approved "#@ allow launch" "a fx-slurm - $ROW"
q "1000|a|RUNNING|None|0|$NOW|$P|"; acct "990|a|PREEMPTED|0:0|$P" "995|a|PREEMPTED|0:0|$P"
O=$(rw t.tsv --once --act --max-active 3); has "$O" 'ADOPT name=a .*job=1000' "one live job (+ sacct history of the name): adopted"
reset; approved "#@ allow launch" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|" "1001|a|PENDING|Priority|0|N/A|$P|"
O=$(rw t.tsv --once --act --max-active 3); has "$O" 'reason=name-ambiguous jobs=1000,1001' "two live jobs: held"
reset; approved "#@ allow launch" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|/other/proj|"
O=$(rw t.tsv --once --act --max-active 3); has "$O" 'reason=workdir-mismatch' "a live job of another project dir: held"
reset; approved "#@ allow launch preempt=3" "a fx-slurm - $ROW"; q; acct "990|a|PREEMPTED|0:0|$P" "995|a|PREEMPTED|0:0|$P" "999|a|COMPLETED|0:0|/other"
O=$(rw t.tsv --once --act --max-active 3); has "$O" 'ATTENTION name=a .*job=995 reason=adopted-terminal state=PREEMPTED' "only ended jobs here: the newest, held"
[ "$(nsub)" = 0 ] && ok "adopted-terminal: no resubmit on its own" || bad "adopted-terminal: no resubmit"
O=$(rw t.tsv --once --act --max-active 3 --release a); has "$O" 'RELEASE name=a' "--release prints RELEASE"
has "$O" 'RESUBMIT name=a .*prev=995 .*preempts=1/3' "released: one resubmit"
O=$(rw t.tsv --once --release a); [ "$?" = 2 ] && ok "--release without --act refused" || bad "--release needs --act"
reset; approved "#@ allow launch" "a fx-slurm out/a.done $ROW"; mkdir -p "$P/out"; touch "$P/out/a.done"; q
O=$(rw t.tsv --once --act --max-active 3); has "$O" 'DONE name=a .*artifact-present' "done exists before any submit: DONE, nothing launched"; rm -rf "$P/out"

echo "-- submit outcomes: refused (no + sbatch) / unknown (sticky) / interrupted --"
reset; approved "#@ allow launch preempt=1" "a fx-slurm - -p vip -- python x.py"; q
O=$(rw t.tsv --once --act --max-active 3); has "$O" 'reason=submit-refused rc=3 .*REFUSED' "policy refusal: held with the reason"
[ "$(st a 2)" = held ] && [ "$(nsub)" = 0 ] && ok "refused: held, no sbatch" || bad "refused: held"
reset; approved "#@ allow preempt=2" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act --adopt a=1000 >/dev/null
q; acct "1000|a|PREEMPTED|0:0|$P"; touch "$WORLD/sbatch.fail"; O=$(rw t.tsv --once --act); RC=$?
has "$O" 'reason=submit-unknown' "sbatch ran and failed: outcome unknown"; [ "$(st a 2)" = submit-unknown ] && [ "$(st a 4)" = 1 ] && ok "unknown: sticky, budget kept spent" || bad "unknown state"
rm -f "$WORLD/sbatch.fail"; O=$(rw t.tsv --once --act); [ "$(nsub)" = 0 ] && ok "submit-unknown: never retried on its own" || bad "unknown not retried"
q "1500|a|PENDING|Priority|0|N/A|$P|"; O=$(rw t.tsv --once --act); has "$O" 'candidates=1500' "unknown: a same-name live job is listed, not adopted"
[ "$(st a 2)" = submit-unknown ] && ok "unknown stays unknown with a candidate" || bad "unknown stays"
has "$(rw t.tsv --once --act --adopt a=1500)" 'ADOPT name=a .*job=1500' "--adopt clears it"; [ "$(st a 2)" = active ] && ok "adopted: active" || bad "adopted: active"
sed -i 's/^a	active/a	submitting/' "$P/logs/run-watch/t.state"; O=$(rw t.tsv --once --act)
has "$O" 'reason=submit-interrupted' "a submit in flight at the last stop: submit-unknown"

echo "-- observation failures: no decisions; blind after 3; recovery noted --"
reset; approved "#@ allow preempt=2" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act --adopt a=1000 >/dev/null
q; acct "1000|a|PREEMPTED|0:0|$P"; touch "$WORLD/ssh.fail.fx"
for n in 1 2 3; do O=$(rw t.tsv --once --act); done
has "$O" 'ATTENTION target=fx-slurm reason=blind' "3 failed rounds: blind"; [ "$(nsub)" = 0 ] && ok "blind: 0 submits" || bad "blind: 0 submits"
rm -f "$WORLD/ssh.fail.fx"; touch "$WORLD/squeue.fail"; O=$(rw t.tsv --once --act); has "$O" '@@fail squeue' "a failing squeue is a failed observation"
rm -f "$WORLD/squeue.fail"; O=$(rw t.tsv --once --act); has "$O" 'NOTE target=fx-slurm observing-again' "recovery noted"
has "$O" 'RESUBMIT name=a' "decisions resume after recovery"
reset; approved "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
q; acct; for n in 1 2 3; do O=$(rw t.tsv --once); done; has "$O" 'reason=accounting-gap' "gone from the queue, no sacct row: accounting gap, never 'not submitted'"
: > "$WORLD/ssh.log"; rw t.tsv --once >/dev/null; [ "$(grep -c . "$WORLD/ssh.log")" = 1 ] && ok "one ssh per target per round" || bad "one ssh per round ($(grep -c . "$WORLD/ssh.log"))"
touch "$WORLD/ssh.hang.fx"; s0=$(date +%s); O=$(OBS_TO=2 rw t.tsv --once); s1=$(date +%s); rm -f "$WORLD/ssh.hang.fx"
[ $((s1 - s0)) -lt 12 ] && has "$O" 'observe-failed' "a hung host is cut at the deadline ($((s1 - s0)) s)" || bad "deadline ($((s1 - s0)) s)"

echo "-- running jobs: stall and the optional resume check --"
reset; table "#@ resume /resumed from step/ after=1" "a fx-slurm - $ROW"; rw t.tsv --approve go >/dev/null
q "1000|a|RUNNING|None|0|$((NOW - 9000))|$P|"; printf '[x] target=fx-slurm job=1000 restart=0 node=n1\n' > "$P/logs/a_1000.out"
touch -d "@$((NOW - 5000))" "$P/logs/a_1000.out"; O=$(rw t.tsv --once --adopt a=1000 --stall-after 3600)
has "$O" 'STALL name=a .*job=1000 quiet=' "silent log on a long-running job: STALL"
O=$(rw t.tsv --once --stall-after 3600); hasnt "$O" 'STALL' "the same silence is reported once"
q "1000|a|RUNNING|None|1|$((NOW - 120))|$P|"; printf '[x] target=fx-slurm job=1000 restart=1 node=n1\nepoch 3\n' >> "$P/logs/a_1000.out"
O=$(rw t.tsv --once --stall-after 0); has "$O" 'REQUEUE name=a' "requeue seen"
O=$(rw t.tsv --once --stall-after 0); has "$O" 'reason=no-resume restarts=1' "no resume line 2 min after the restart: no-resume"
printf 'resumed from step 400\n' >> "$P/logs/a_1000.out"; q "1000|a|RUNNING|None|2|$((NOW - 120))|$P|"
printf '[x] target=fx-slurm job=1000 restart=2 node=n1\nresumed from step 900\n' >> "$P/logs/a_1000.out"
rw t.tsv --once --stall-after 0 >/dev/null; O=$(rw t.tsv --once --stall-after 0); hasnt "$O" 'no-resume' "a matching line after the restart header: quiet"
reset; approved "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$((NOW - 120))|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
hasnt "$(tail -n 40 "$WORLD/scripts.log")" 'RESUME=. [0-9]' "no '#@ resume': the log is never read"

echo "-- workstations: detect-only --"
reset; { echo '#@ run-watch v1'; echo "w1 ws-box out/w1.done -"; echo "w2 ws-box out/w2.done -"; echo "w3 ws-box - -"; echo "w4 ws-box - -"; } > "$WP/t.tsv"
mkdir -p "$WP/out"; touch "$WP/out/w2.done"
for w in w1 w2 w3; do printf 'x\n' > "$WP/logs/$w-20261022-130000.log"; done
echo 4001 > "$WP/logs/w1-20261022-130000.log.pid"; echo "  50 Sl" > "$WORLD/ps.4001"
echo 4002 > "$WP/logs/w2-20261022-130000.log.pid"; echo 4003 > "$WP/logs/w3-20261022-130000.log.pid"
O=$(rww t.tsv --once); has "$O" 'ADOPT name=w1 .*proc=alive' "alive process: followed"; has "$O" 'DONE name=w2 .*exit=unknown' "gone + done: DONE"
has "$O" 'reason=ended-unverified' "gone, done '-': held"; has "$O" 'WARN name=w4 .*no-log' "no log yet: WARN"
for n in 2 3; do O=$(rww t.tsv --once); done; has "$O" 'ATTENTION name=w4 .*reason=not-launched' "still no log after 3 rounds: not-launched"
[ ! -s "$WORLD/ssh-bad.log" ] && ok "workstations: only observation ssh (never a launch)" || bad "workstation ssh: $(cat "$WORLD/ssh-bad.log")"

echo "-- lock, lost state, removed rows --"
reset; approved "a fx-slurm - $ROW"; q; mkdir -p "$P/logs/run-watch/.lock"; echo $$ > "$P/logs/run-watch/.lock/pid"
O=$(rw t.tsv --once); [ "$?" = 2 ] && has "$O" 'holds' "a live lock holder: exit 2" || bad "lock conflict exit 2"
echo 999999 > "$P/logs/run-watch/.lock/pid"; O=$(rw t.tsv --once); has "$O" 'NOTE stale-lock' "a dead holder's lock is taken over"
[ ! -d "$P/logs/run-watch/.lock" ] && ok "lock released at exit" || bad "lock released at exit"
rw t.tsv --once >/dev/null; rm -f "$P/logs/run-watch/t.state"; O=$(rw t.tsv --once)
has "$O" 'status=held job=- why=state-lost' "state lost (an older copy exists): every row held, budgets not rebuilt"
reset; approved "a fx-slurm - $ROW" "b fx-slurm - -"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
approved "b fx-slurm - -"; O=$(rw t.tsv --once); has "$O" 'NOTE name=a removed still-active job=1000' "a removed row is kept, its live job named"
approved "a fx-slurm - $ROW" "b fx-slurm - -"; O=$(rw t.tsv --once); has "$O" 'NOTE name=a .*status active' "the row back: its state restored"

echo "-- review regressions --"
reset; approved "#@ allow preempt=1" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act --adopt a=1000 >/dev/null
rw t.tsv --once --act >/dev/null; rm -f "$P/logs/run-watch/t.state"; rw t.tsv --once --act >/dev/null
q "2000|a|RUNNING|None|0|$NOW|$P|"; O=$(rw t.tsv --once --act); has "$O" 'ADOPT name=a .*job=2000' "lost state: a rerun is still followed"
q; acct "2000|a|PREEMPTED|0:0|$P"; O=$(rw t.tsv --once --act)
has "$O" 'reason=preempted why=budget-unknown action=needs-ok preempt=unknown/1' "lost state: spent budgets stay unknown after an adoption"
[ "$(nsub)" = 0 ] && ok "lost state: no resubmit on a rebuilt budget" || bad "lost state: no resubmit"
reset; approved "#@ allow launch" "a fx-slurm - $ROW" "b fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"
O=$(rw t.tsv --once --act --max-active 1); has "$O" 'ADOPT name=a' "a is adopted"
[ "$(nsub)" = 0 ] && ok "--max-active counts a job adopted in the same round" || bad "--max-active counts an adopted job ($(nsub))"
reset; approved "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
q; acct "1000|a|COMPLETED|0:0|$P"; O=$(rw t.tsv --once); [ "$?" = 0 ] && ok "all done: exit 0" || bad "all done: exit 0"
q "1100|a|PENDING|Priority|0|N/A|$P|"; O=$(rw t.tsv --once); RC=$?
has "$O" 'ADOPT name=a .*job=1100 note=new-job' "an all-done table is still observed: a manual rerun is adopted"; [ "$RC" = 3 ] && ok "and the watch goes on (exit 3)" || bad "rerun of a done row: exit 3 ($RC)"
reset; approved "#@ allow preempt=2" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
q; acct "1000|a|PREEMPTED|0:0|$P"; O=$(rw t.tsv --once); has "$O" 'why=no-act' "preempted, watched without --act: needs-ok"
acct "1000|a|PREEMPTED|0:0|$P" "1200|a|COMPLETED|0:0|$P"; O=$(rw t.tsv --once --act)
has "$O" 'ADOPT name=a .*job=1200 prev=1000 note=newer-job' "the user's own finished rerun is followed"; [ "$(nsub)" = 0 ] && ok "no resubmit over a newer job" || bad "no resubmit over a newer job"
O=$(rw t.tsv --once --act); has "$O" 'DONE name=a .*job=1200' "the rerun's end is reported"
reset; approved "#@ allow preempt=2" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act --adopt a=1000 >/dev/null
q; acct "1000|a|PREEMPTED|0:0|$P"; touch "$WORLD/sbatch.fail"; rw t.tsv --once --act >/dev/null
O=$(rw t.tsv --once --act --release a); has "$O" 'reason=submit-unknown prev=1000' "a second unknown outcome after --release is reported again"
rm -f "$WORLD/sbatch.fail"; q "1500|a|RUNNING|None|0|$NOW|$P|"; O=$(rw t.tsv --once --act --release a)
has "$O" 'ADOPT name=a .*job=1500 prev=1000 note=newer-job' "release given; a newer live job is followed instead of resubmitting"
q; acct "1000|a|PREEMPTED|0:0|$P" "1500|a|CANCELLED by 4242|0:0|$P"; O=$(rw t.tsv --once --act)
has "$O" 'reason=cancelled by=4242' "the release was for job 1000: a later CANCELLED job is held"; [ "$(nsub)" = 0 ] && ok "release not reused for another job" || bad "release reused ($(nsub))"
reset; approved "#@ allow launch" "a fx-slurm - $ROW"; q; acct "999|a|COMPLETED|0:0|/other/proj"
O=$(rw t.tsv --once --act --max-active 3); has "$O" 'LAUNCH name=a' "another project's same-name job does not block a launch (re-check filters WorkDir)"
reset; approved "#@ allow preempt=5" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act --adopt a=1000 >/dev/null
q; acct "1000|a|PREEMPTED|0:0|$P"; touch "$WORLD/now-running"; for n in 1 2 3; do O=$(rw t.tsv --once --act); done; rm -f "$WORLD/now-running"
has "$O" 'reason=submit-skipped n=3' "three skipped submits in a row: held for a human"; [ "$(st a 2)" = held ] && ok "skips escalate to held" || bad "skips escalate"

