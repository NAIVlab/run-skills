#!/usr/bin/env bash
# tests/47-watch.sh — phase A: bin/run-watch. The ssh stub RUNS each stdin script under bash with stateful fake squeue /
# sacct / sbatch / ps reading $WORLD (rows in the formats reproduced on three clusters, design §12); submits go through
# the REAL deployed submit.sh. Covers: table rules, --approve and stale blocks, launch / max-active / one submit per
# target per round, settle = purged + terminal sacct (re-checked in the submit ssh), the empty-squeue guard, budgets,
# CANCELLED never resubmitted, requeue + requeue-storm, adoption rules, submit refused / unknown / interrupted,
# --adopt / --release, workstations detect-only, stall + resume checks, blind targets, lock, lost state, exit codes;
# P3: grep -a, <log>.rc, --rs-attempt nonces + the journal read, sticky unknowns across tables, --adopt identity,
# '#@ ok … conf=', the lock's pid/host/start, '#@ allow fail-stop'; round 3 (D11): fail-stop's pending cancels only with
# --act under an approved fail-stop, fail-stop and unknown submits across tables, a target column in state lines, the
# settle path's job name, base-10 numbers, lock exit 6, '#@ ok' lines / headers this copy cannot read; round 4: another
# table's fail-stop taken every round also by rows with their own state (R4-13), the settle path's and the submit ssh's
# WorkDir, older state lines' targets (R4-14), the rsk watch steer and RS_WATCH_PARENT (exit 7 once it is gone: R4-7);
# round 5: a table keeps every fail-stop that holds it, --release clears only its own (R5-7); a row's target is a plain
# target name rs_targets lists (R5-8); round 6: a --release not used yet is withdrawn once a fail-stop holds its table later in
# the same watch (several rounds: a sleep stub runs the world's next step between them); round 7: a table holding a NUL byte or a
# control character other than tab (a CR too) is refused at every read, with rsk's words, as are such --approve words (R7-7).
set -u
. "$RS_HOME/tests/lib.sh"
export WORLD=$T/world RBIN=$T/rbin TBIN=$T/bin; mkdir -p "$WORLD" "$RBIN"
cat > "$RBIN/squeue" <<'EOS'
#!/usr/bin/env bash
[ ! -f "$WORLD/squeue.fail" ] || exit 1
[ -f "$WORLD/squeue" ] || exit 0
case "$*" in *UserName*) awk -F'|' -v u="${USER:-$(id -un)}" 'NF { print $1 "|" $2 "|" ($8 != "" ? $8 : u) "|" $7 "|" $3 "|" }' "$WORLD/squeue" ;;
  *) grep -av '^$' "$WORLD/squeue" ;; esac; exit 0
EOS
cat > "$RBIN/sacct" <<'EOS'
#!/usr/bin/env bash
[ ! -f "$WORLD/sacct.fail" ] || exit 1
ids="" names="" fields=""
while [ "$#" -gt 0 ]; do case "$1" in -j) ids=$2; shift ;; --name=*) names=${1#--name=} ;; -o) fields=$2; shift ;; esac; shift; done
[ -f "$WORLD/sacct" ] || exit 0
while IFS='|' read -r id n st ec wd el lim u; do
  [ -n "$id" ] || continue
  [ -z "$ids" ] || case ",$ids," in *",$id,"*) ;; *) continue ;; esac
  [ -z "$names" ] || case ",$names," in *",$n,"*) ;; *) continue ;; esac
  [ ! -f "$WORLD/now-running" ] || case "$fields" in State*) st=RUNNING ;; esac; [ ! -f "$WORLD/prev-other" ] || case "$fields" in State,*) wd=/elsewhere/proj ;; esac
  case "$fields" in State) echo "$st" ;; State,JobName,WorkDir) echo "$st|$n|$wd" ;; JobID) echo "$id" ;; JobID,WorkDir) echo "$id|$wd" ;; *ElapsedRaw*) echo "$id|$n|$st|$ec|$wd|$el|$lim" ;;
    JobID,JobName,User,WorkDir) echo "$id|$n|${u:-${USER:-$(id -un)}}|$wd" ;; *) echo "$id|$n|$st|$ec|$wd" ;; esac
done < "$WORLD/sacct"
EOS
cat > "$RBIN/sbatch" <<'EOS'
#!/usr/bin/env bash
[ ! -f "$WORLD/sbatch.fail" ] || { echo "sbatch: error: Batch job submission failed: Socket timed out on send/recv operation" >&2; exit 1; }
[ ! -f "$WORLD/sbatch.reject" ] || { echo "sbatch: error: Batch job submission failed: Invalid partition name specified" >&2; exit 1; }
n=$(cat "$WORLD/nextjid"); echo $((n + 1)) > "$WORLD/nextjid"; printf '%s\n' "$*" >> "$WORLD/sbatch.log"; echo "Submitted batch job $n"
EOS
cat > "$RBIN/ps" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do p=$a; done; [ -f "$WORLD/ps.$p" ] && cat "$WORLD/ps.$p" || exit 1
EOS
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$WORLD/scancel.log"\n' > "$RBIN/scancel"
cat > "$T/bin/ssh" <<'EOS'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
h=$1; shift; echo "$h" >> "$WORLD/ssh.log"
[ ! -f "$WORLD/ssh.fail.$h" ] || { echo "ssh: connect to host $h port 22: Connection refused" >&2; exit 255; }
[ "$*" = "bash -s" ] || { echo "$*" >> "$WORLD/ssh-bad.log"; exit 99; }
s=$(cat); printf '%s\n@@@@\n' "$s" >> "$WORLD/scripts.log"
[ ! -f "$WORLD/ssh.hang.$h" ] || sleep 20
[ ! -f "$WORLD/grab-lock" ] || cp "$(cat "$WORLD/grab-lock")/info" "$WORLD/lock.info" 2>/dev/null
case "$s" in *"DEPLOY="*) k=sub ;; *"CAN='"*) k=can ;; *) k=obs ;; esac   # rsk watch SIGKILLed during this kind of ssh (its pid in the file)
[ ! -f "$WORLD/kill-parent.$k" ] || { kill -KILL "$(cat "$WORLD/kill-parent.$k")"; rm -f "$WORLD/kill-parent.$k"; }
[ -z "${RW_LC:-}" ] || export LC_ALL=$RW_LC   # a remote login shell in a UTF-8 locale (ssh forwards LANG)
case "$s" in *"DEPLOY="*)   # a submit ssh: the connection drops after it ran, or the watcher dies right after it
  if [ -f "$WORLD/ssh.drop-after" ]; then printf '%s\n' "$s" | PATH="$RBIN:$TBIN:$PATH" bash -s > /dev/null 2>&1
    echo "client_loop: send disconnect: Broken pipe" >&2; exit 255; fi
  if [ -f "$WORLD/crash.after-submit" ]; then rm -f "$WORLD/crash.after-submit"; printf '%s\n' "$s" | PATH="$RBIN:$TBIN:$PATH" bash -s; kill -KILL "$PPID"; exit 0; fi ;; esac
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
has "$O" '^under: #@ allow launch preempt=2$' "...and the allow line it approves them under, once prefixed (no '#@ #@')"
has "$(sed -n 3p "$P/t.tsv")" '^#@ ok [0-9-]* sum=[0-9]* conf=[0-9a-f]\{12\} "yes, run a and b"$' "--approve inserts '#@ ok … conf=<sha256[:12] of .hpc.conf>' above the rows"
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
has "$O" ' SUMMARY target=fx-slurm reference=/.*/fx-slurm/reference\.md -- re-read' "the summary names each target's reference (survives a context summary)"
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
O=$(rw t.tsv --once); [ "$?" = 6 ] && has "$O" 'holds' "a live lock holder: exit 6 (not 2: rsk watch maps it)" || bad "lock conflict exit 6"
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

echo "-- P3: grep -a, <log>.rc, attempt nonces + the journal, sticky unknowns, --adopt identity, conf=, lock, fail-stop --"
UL=$(locale -a 2>/dev/null | grep -aim1 -E '^(c|en_us)\.utf-?8$'); B=$(printf '\377')
reset; approved "a fx-slurm - $ROW"; printf '%s\n' "9|some${B}one|RUNNING|None|0|$NOW|/elsewhere|" "1000|a|PENDING|Resources$B|0|N/A|$P|" > "$WORLD/squeue"
O=$(RW_LC=$UL rw t.tsv --once); has "$O" 'ADOPT name=a .*job=1000' "a squeue row with a byte that is not UTF-8 is still read (grep -a; locale ${UL:-default})"
reset; { echo '#@ run-watch v1'; echo "w5 ws-box - -"; echo "w6 ws-box - -"; echo "w7 ws-box out/w7.done -"; } > "$WP/t.tsv"; rm -rf "$WP/out"
for w in w5 w6 w7; do printf 'x\n' > "$WP/logs/$w-20261023-130000.log"; echo 4005 > "$WP/logs/$w-20261023-130000.log.pid"; done   # ps: gone
printf 'rc=1 term=0 at=%s\n' "$NOW" > "$WP/logs/w5-20261023-130000.log.rc"; printf 'rc=0 term=0 at=%s\n' "$NOW" > "$WP/logs/w6-20261023-130000.log.rc"
printf 'rc=0 term=1 at=%s\n' "$NOW" > "$WP/logs/w7-20261023-130000.log.rc"; O=$(rww t.tsv --once)
has "$O" 'ATTENTION name=w5 .*reason=ended rc=1 term=0' "nohup: <log>.rc read: ended rc=N term=K"; hasnt "$O" 'ended-unverified' "  ...never ended-unverified with an .rc"
has "$O" 'DONE name=w6 .*exit=0 term=0 artifact=unchecked' "nohup rc=0 term=0, done '-': DONE (as Slurm's COMPLETED)"
has "$O" 'ATTENTION name=w7 .*reason=ended-no-artifact done=out/w7.done rc=0 term=1' "nohup: no artifact, the exit record shown"

reset; q; approved "#@ allow launch" "a fx-slurm - $ROW"; O=$(rw t.tsv --once --act --max-active 2); N=$(st a 16)
has "$O" 'LAUNCH name=a .*job=1000' "launch with an attempt nonce"
has "$(grep -a 'DEPLOY=' "$WORLD/scripts.log")" "NONCE='rw-[0-9]\{8\}T[0-9]\{6\}Z-[0-9]*-1'" "the submit ssh carries rw-<UTC>-<pid>-<n>"
printf %s "$N" | grep -Eq '^rw-[A-Za-z0-9][A-Za-z0-9._-]{0,60}$' && ok "the state records the nonce ($N)" || bad "state nonce ($N)"
has "$(cat "$WORLD/sbatch.log")" "rs=$N" "submit.sh got --rs-attempt: the job's comment carries rs=<nonce>"
[ -f "$P/.rs/attempts/$N/receipt" ] && ok "the attempt journal holds the receipt" || bad "journal receipt for $N"
sub1() { reset; approved "#@ allow preempt=2" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act --adopt a=1000 >/dev/null
  q; acct "1000|a|PREEMPTED|0:0|$P"; echo 2000 > "$WORLD/nextjid"; }
sub1; touch "$WORLD/ssh.drop-after"; O=$(rw t.tsv --once --act); rm -f "$WORLD/ssh.drop-after"
has "$O" 'reason=submit-unknown .*attempt=rw-' "ssh lost after the submit: submit-unknown, its attempt named"
[ "$(st a 2)" = submit-unknown ] && [ "$(st a 4)" = 1 ] && ok "  ...sticky, budget spent once" || bad "drop: state $(st a 2) preempts $(st a 4)"
q "2000|a|PENDING|Priority|0|N/A|$P|"; O=$(rw t.tsv --once --act)
has "$O" 'ADOPT name=a .*job=2000 note=receipt attempt=rw-' "the next read finds the attempt's receipt: job adopted"
[ "$(st a 2)" = active ] && [ "$(st a 4)" = 1 ] && [ "$(nsub)" = 1 ] && ok "  ...active, preempts 1, one sbatch" || bad "receipt adopt ($(st a 2) $(st a 4) $(nsub))"
sub1; touch "$WORLD/sbatch.reject"; O=$(rw t.tsv --once --act); rm -f "$WORLD/sbatch.reject"
has "$O" 'reason=submit-unknown' "sbatch rejected it after '+ sbatch': unknown in-band"
O=$(rw t.tsv --once --act); has "$O" 'reason=submit-refused attempt=rw-.*verdict=refused' "the journal's verdict=refused: held submit-refused"
[ "$(st a 2)" = held ] && [ "$(st a 4)" = 0 ] && ok "  ...budget given back (keyed by the nonce)" || bad "refused: $(st a 2) preempts $(st a 4)"
rw t.tsv --once --act >/dev/null; [ "$(st a 4)" = 0 ] && ok "  ...and only once" || bad "refund twice ($(st a 4))"
sub1; touch "$WORLD/sbatch.fail"; rw t.tsv --once --act >/dev/null; rm -f "$WORLD/sbatch.fail"; O=$(rw t.tsv --once --act)
has "$O" 'reason=submit-unknown .*journal=.*verdict=unknown' "the journal's verdict=unknown: stays submit-unknown"
sub1; touch "$WORLD/crash.after-submit"; ( export TMPDIR=$T; rw t.tsv --once --act ) >/dev/null 2>&1
[ "$(st a 2)" = submitting ] && [ "$(st a 4)" = 1 ] && ok "killed right after the submit: the intent was on disk (submitting, preempts 1)" || bad "crash state ($(st a 2) $(st a 4))"
q "2000|a|PENDING|Priority|0|N/A|$P|"; O=$(rw t.tsv --once --act)
has "$O" 'reason=submit-interrupted' "restart: submit-interrupted"; has "$O" 'ADOPT name=a .*job=2000 note=receipt' "  ...settled from the journal"
[ "$(st a 4)" = 1 ] && [ "$(nsub)" = 1 ] && ok "  ...the budget is not counted twice, no second sbatch" || bad "crash: preempts $(st a 4) sbatch $(nsub)"
reset; q; approved "#@ allow launch" "a fx-slurm - $ROW"; cp "$P/.fx-slurm/submit.sh" "$T/submit.keep"
printf '#!/usr/bin/env bash\n[ "$1" != --rs-attempt ] || { echo "ERROR: unknown arg '"'"'$2'"'"' (flags: -p -g ...)" >&2; exit 2; }\n' > "$P/.fx-slurm/submit.sh"
O=$(rw t.tsv --once --act --max-active 2); cp "$T/submit.keep" "$P/.fx-slurm/submit.sh"
has "$O" "reason=submit-refused rc=2 .*predates --rs-attempt: run-sync" "a deploy older than --rs-attempt refuses it: held, says re-sync"

reset; approved "#@ allow preempt=2" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act --adopt a=1000 >/dev/null
q; acct "1000|a|PREEMPTED|0:0|$P"; touch "$WORLD/sbatch.fail"; rw t.tsv --once --act >/dev/null; rm -f "$WORLD/sbatch.fail"
approved "b fx-slurm - -"; rw t.tsv --once >/dev/null; approved "#@ allow preempt=2" "a fx-slurm - $ROW" "b fx-slurm - -"; rw t.tsv --once --act >/dev/null
[ "$(st a 2)" = submit-unknown ] && [ "$(nsub)" = 0 ] && ok "submit-unknown, removed and re-added: still submit-unknown" || bad "removed path ($(st a 2))"
approved "b fx-slurm - -"; acct; { echo '#@ run-watch v1'; echo '#@ allow launch'; echo "a fx-slurm - $ROW"; } > "$P/t2.tsv"; rw t2.tsv --approve go >/dev/null
O=$(rw t2.tsv --once --act --max-active 3); has "$O" 'name=a .*reason=submit-unknown -- another table' "the row moved to another table: still submit-unknown there"
[ "$(awk -F'\t' '$1 == "a" { print $2 }' "$P/logs/run-watch/t2.state")" = submit-unknown ] && [ "$(nsub)" = 0 ] && ok "  ...and never launched again" || bad "moved row launched ($(nsub))"
rm -f "$P/t2.tsv" "$P/logs/run-watch/t2.state"*

reset; approved "a fx-slurm - $ROW"; q "1000|b|RUNNING|None|0|$NOW|$P|" "1001|a|RUNNING|None|0|$NOW|/other/proj|"
O=$(rw t.tsv --once --adopt a=1000); has "$O" 'name=a .*job=1000 reason=adopt-refused why=name=b' "--adopt of another name's job: refused"; hasnt "$O" 'ADOPT name=a .*job=1000' "  ...not adopted"
O=$(rw t.tsv --once --adopt a=1001); has "$O" 'reason=adopt-refused why=workdir=/other/proj' "--adopt of another project's job: refused"
reset; approved "a fx-slurm - $ROW"; q; acct "1002|a|COMPLETED|0:0|$P|||someone-else"
O=$(rw t.tsv --once --adopt a=1002); has "$O" 'reason=adopt-refused why=user=someone-else' "--adopt of another user's job (sacct): refused"
O=$(rw t.tsv --once --adopt a=1009); has "$O" 'reason=adopt-refused why=no-such-job' "--adopt of a job nobody lists: refused"
ln -s "$P" "$T/plink"; q "1003|a|RUNNING|None|0|$NOW|$T/plink|"; O=$(rw t.tsv --once --adopt a=1003)
has "$O" 'ADOPT name=a .*job=1003 note=manual' "--adopt: a WorkDir that resolves to the project (physical path) is the project"
reset; approved "a fx-slurm - $ROW"; q; acct "1004|a|COMPLETED|0:0|$P"; O=$(rw t.tsv --once --adopt a=1004)
has "$O" 'ADOPT name=a .*job=1004 note=manual' "--adopt of this row's ended job (sacct: name, user, WorkDir)"; has "$O" 'DONE name=a .*job=1004' "  ...settled in the same round"

reset; q; approved "#@ allow launch" "a fx-slurm - $ROW"; cp "$P/.hpc.conf" "$T/conf.keep"; echo '# edited' >> "$P/.hpc.conf"
O=$(rw t.tsv --once --act --max-active 3); has "$O" 'reason=approval-stale changed=conf' "an edited .hpc.conf makes a conf= approval stale"
has "$O" 'why=not-approved' "  ...its rows wait for a new OK"; [ "$(nsub)" = 0 ] && ok "  ...0 submits" || bad "conf stale: 0 submits"
cp "$T/conf.keep" "$P/.hpc.conf"; O=$(rw t.tsv --once --act --max-active 3); has "$O" 'LAUNCH name=a' "the approved conf back: the approval holds again"
reset; q; table "#@ allow launch" "a fx-slurm - $ROW" "b fx-slurm - $ROW"; rw t.tsv --approve "old words" >/dev/null
sed 's/ conf=[0-9a-f]*//' "$P/t.tsv" > "$T/t.old"; cp "$T/t.old" "$P/t.tsv"; echo '# edited' >> "$P/.hpc.conf"
O=$(rw t.tsv --once --act --max-active 3); has "$O" 'LAUNCH name=a' "an '#@ ok' line without conf= (older) stays valid"; hasnt "$O" 'approval-stale' "  ...a conf edit does not make it stale"
[ "$(echo "$O" | grep -c 'NOTE approval-unbound lines=t.tsv:3')" = 1 ] && ok "  ...one NOTE per run" || bad "unbound NOTE once"
O=$(rw t.tsv --approve "again"); has "$O" 'nothing to approve' "  ...and --approve leaves it alone (no repeated OK)"; cp "$T/conf.keep" "$P/.hpc.conf"
R2=$(mk_proj fx-slurm ""); L2=$T/local2; mkdir -p "$R2/logs" "$L2/logs"; printf 'REMOTE_DIR=%s\n' "$R2" > "$L2/.hpc.conf"; printf 'REMOTE_DIR=%s\n# drift\n' "$R2" > "$R2/.hpc.conf"
{ echo '#@ run-watch v1'; echo '#@ allow launch'; echo "a fx-slurm - $ROW"; } > "$L2/t.tsv"; rwin() { ( cd "$L2" && PATH="$T/bin:$PATH" RS_WATCH_OBS_TIMEOUT=15 RS_WATCH_SUBMIT_TIMEOUT=15 bash "$RS_HOME/bin/run-watch" "$@" 2>&1 ); }
reset; q; rwin t.tsv --approve go >/dev/null; O=$(rwin t.tsv --once --act --max-active 3)
has "$O" 'reason=submit-skipped n=1 -- conf-differs' "the deployed .hpc.conf is not the approved one: no submit"; [ "$(nsub)" = 0 ] && ok "  ...0 submits" || bad "conf-differs: 0 submits"
cp "$L2/.hpc.conf" "$R2/.hpc.conf"; O=$(rwin t.tsv --once --act --max-active 3); has "$O" 'LAUNCH name=a' "  ...synced: submitted"

reset; approved "a fx-slurm - $ROW"; q; mkdir -p "$P/logs/run-watch/.lock"; echo $$ > "$P/logs/run-watch/.lock/pid"
echo "$(uname -n) 2026-11-04T10:00:00+0000 1" > "$P/logs/run-watch/.lock/info"; O=$(rw t.tsv --once --act); RC=$?
[ "$RC" = 6 ] && has "$O" "pid=$$ host=$(uname -n) started=2026-11-04T10:00:00+0000 act=1" "a live watcher's lock: exit 6, its pid, host and start" || bad "lock report (rc=$RC)"
[ "$(nsub)" = 0 ] && ok "  ...--act does not run beside it" || bad "--act beside a live watcher"
echo 999999 > "$P/logs/run-watch/.lock/pid"; echo "other-host-x 2026-11-04T10:00:00+0000 0" > "$P/logs/run-watch/.lock/info"
O=$(rw t.tsv --once); [ "$?" = 6 ] && has "$O" 'host=other-host-x .*another host' "another host's lock is never broken (exit 6)" || bad "other host lock"
rm -rf "$P/logs/run-watch/.lock"; echo "$P/logs/run-watch/.lock" > "$WORLD/grab-lock"; rw t.tsv --once >/dev/null; rm -f "$WORLD/grab-lock"
has "$(cat "$WORLD/lock.info" 2>/dev/null)" "^$(uname -n) [0-9T:+-]* 0$" "a running watcher records host, start time and act in its lock"

fs() {   # fs ALLOW-EXTRA: a, b, d, e follow live jobs; c waits for a slot (never submitted)
  reset; approved "#@ allow launch errors=0 $1" "a fx-slurm - $ROW" "b fx-slurm - $ROW" "c fx-slurm - $ROW" "d fx-slurm - $ROW" "e fx-slurm - $ROW"
  q "1000|a|RUNNING|None|0|$NOW|$P|" "1001|b|RUNNING|None|0|$NOW|$P|" "1003|d|RUNNING|None|0|$NOW|$P|" "1004|e|RUNNING|None|0|$NOW|$P|"
  rw t.tsv --once --act --max-active 4 --adopt a=1000 --adopt b=1001 --adopt d=1003 --adopt e=1004 >/dev/null
  q "1001|b|RUNNING|None|0|$NOW|$P|" "1003|d|RUNNING|None|0|$NOW|/other/proj|" "1004|e|RUNNING|None|0|$NOW|$P|someone-else|"; }
fs fail-stop; [ "$(nsub)" = 0 ] && ok "fail-stop setup: c not submitted yet" || bad "fail-stop setup"
acct "1000|a|FAILED|1:0|$P"; O=$(rw t.tsv --once --act --max-active 4); RC=$?
has "$O" 'ATTENTION name=a .*reason=fail-stop trigger=a:1000 state=FAILED exit=1:0 errors=0/0' "FAILED, errors budget 0: fail-stop with its evidence"
has "$O" 'CANCEL name=b .*job=1001 by=fail-stop trigger=a:1000' "a live row of the table (identity checked): cancelled"
[ "$(cat "$WORLD/scancel.log")" = 1001 ] && ok "  ...one scancel, of exactly the verified id" || bad "scancel: $(cat "$WORLD/scancel.log" 2>/dev/null)"
has "$O" 'ATTENTION name=c .*reason=fail-stop-held trigger=a:1000' "an unsubmitted row: held"; [ "$(st c 2)" = held ] && [ "$(nsub)" = 0 ] && ok "  ...held, never submitted" || bad "c held ($(st c 2), $(nsub))"
has "$O" 'name=d .*reason=fail-stop-not-cancelled why=workdir=/other/proj' "a WorkDir mismatch: not cancelled, says why"
has "$O" 'name=e .*reason=fail-stop-not-cancelled why=user=someone-else' "a user mismatch: not cancelled, says why"
q; O=$(rw t.tsv --once --act --max-active 4); [ "$(grep -c . "$WORLD/scancel.log")" = 1 ] && [ "$(nsub)" = 0 ] && ok "next round: no second cancel, still no submit" || bad "fail-stop next round"
O=$(rw t.tsv --once --act --max-active 4 --release a); has "$O" 'NOTE name=a .*fail-stop cleared' "--release of the failed row resumes the group"
[ "$(st c 2)" = pending ] && ok "  ...its held rows are pending again" || bad "c after release ($(st c 2))"
for s in PREEMPTED TIMEOUT "CANCELLED by 4242"; do fs fail-stop; acct "1000|a|$s|0:0|$P"; O=$(rw t.tsv --once --act --max-active 4)
  [ ! -s "$WORLD/scancel.log" ] && hasnt "$O" 'fail-stop' "$s never triggers fail-stop" || bad "$s triggered fail-stop"; done
fs ""; acct "1000|a|FAILED|1:0|$P"; O=$(rw t.tsv --once --act --max-active 4)
[ ! -s "$WORLD/scancel.log" ] && hasnt "$O" 'fail-stop' "no fail-stop in #@ allow: nothing cancelled or held" || bad "fail-stop absent"
fs fail-stop; acct "1000|a|FAILED|1:0|$P"; O=$(rw t.tsv --once --max-active 4); [ ! -s "$WORLD/scancel.log" ] && ok "fail-stop without --act: nothing cancelled" || bad "fail-stop without --act"
reset; approved "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
cut -f1-15 "$P/logs/run-watch/t.state" > "$T/st15"; cp "$T/st15" "$P/logs/run-watch/t.state"; O=$(rw t.tsv --once)
[ "$(st a 2)" = active ] && [ "$(st a 3)" = 1000 ] && hasnt "$O" 'state-lost' "a state file from before the nonce columns (15 fields) still loads" || bad "15-field state ($(st a 2))"

echo "-- review M8: a row is one run by name: a renamed or copied table keeps its spent budgets (and its state) --"
reset; approved "#@ allow preempt=1" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act --adopt a=1000 >/dev/null
q; acct "1000|a|PREEMPTED|0:0|$P"; echo 2000 > "$WORLD/nextjid"; rw t.tsv --once --act >/dev/null
q "2000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act >/dev/null
[ "$(st a 2):$(st a 4):$(nsub)" = "active:1:1" ] && ok "setup: a resubmitted once under preempt=1 (1/1), job 2000 running" || bad "M8 setup ($(st a 2):$(st a 4):$(nsub))"
mv "$P/t.tsv" "$P/u.tsv"; O=$(rw u.tsv --once --act)
has "$O" 'NOTE name=a .*state from logs/run-watch/t\.state: status=active job=2000 preempts=1' "renamed table: the row takes its state (status, job, spent budget) from t.state"
hasnt "$O" 'ADOPT' "...no re-adoption from scratch"
q; acct "1000|a|PREEMPTED|0:0|$P" "2000|a|PREEMPTED|0:0|$P"; echo 3000 > "$WORLD/nextjid"; O=$(rw u.tsv --once --act)
has "$O" 'ATTENTION name=a .*reason=preempted why=budget action=needs-ok preempt=1/1' "...2000 preempted: the budget is spent (1/1) -> needs-ok"
[ "$(nsub)" = 1 ] && ok "...no second resubmit under a preempt=1 approval" || bad "renamed table resubmitted again ($(nsub) submits)"
cp "$P/u.tsv" "$P/t.tsv"; sed 's/	1	0	0	/	0	0	0	/' "$P/logs/run-watch/t.state" > "$T/t0" && cp "$T/t0" "$P/logs/run-watch/t.state"
[ "$(st a 4)" = 0 ] || bad "M8 copy setup: t.state preempts reset ($(st a 4))"
O=$(rw t.tsv --once --act); has "$O" 'NOTE name=a budgets-from=logs/run-watch/u\.state preempts=1' "copied table with a stale own state: its spent budget is never fewer than another state file holds"
[ "$(st a 4)" = 1 ] && [ "$(nsub)" = 1 ] && ok "...preempts=1, still no second resubmit" || bad "copy: preempts $(st a 4), $(nsub) submits"
reset; approved "a fx-slurm - $ROW"; mkdir -p "$P/logs/run-watch"; { echo '#run-watch-state v1'; printf 'a\tactive\t7\n'; } > "$P/logs/run-watch/old.state"
O=$(rw t.tsv --once); [ "$(st a 2)" = held ] && [ "$(st a 4)" = 9999 ] && ok "another state file naming the row in a line that does not parse: held, budgets unknown" || bad "unparsable other state ($(st a 2) $(st a 4))"

echo "-- review L6: fail-stop names a row whose submit was unknown, and cancels it once it is tracked --"
reset; approved "#@ allow launch errors=0 fail-stop" "a fx-slurm - $ROW" "b fx-slurm - $ROW"
echo 1001 > "$WORLD/nextjid"; q "1000|a|RUNNING|None|0|$NOW|$P|"; touch "$WORLD/sbatch.fail"
rw t.tsv --once --act --max-active 4 --adopt a=1000 >/dev/null; rm -f "$WORLD/sbatch.fail"
[ "$(st b 2)" = submit-unknown ] && ok "setup: b's submit outcome unknown" || bad "L6 setup ($(st b 2))"
q "1001|b|RUNNING|None|0|$NOW|$P|"; acct "1000|a|FAILED|1:0|$P"; O=$(rw t.tsv --once --act --max-active 4)
has "$O" 'ATTENTION name=b .*reason=fail-stop-not-cancelled why=submit-unknown trigger=a:1000' "fail-stop: b (submit-unknown) named, not cancelled blind"
[ ! -s "$WORLD/scancel.log" ] && ok "...no scancel of an unverified job" || bad "...scancel ran: $(cat "$WORLD/scancel.log")"
O=$(rw t.tsv --once --act --max-active 4 --adopt b=1001)
has "$O" 'CANCEL name=b .*job=1001 by=fail-stop fail-stop=a' "once b is tracked (--adopt): cancelled, identity checked"
[ "$(cat "$WORLD/scancel.log" 2>/dev/null)" = 1001 ] && ok "...one scancel of 1001" || bad "...scancel: $(cat "$WORLD/scancel.log" 2>/dev/null)"
O=$(rw t.tsv --once --act --max-active 4); [ "$(grep -c . "$WORLD/scancel.log")" = 1 ] && ok "...and only once" || bad "...cancelled twice"

echo "-- review L9: a row never carries --rs-* words; the journal's verdict=planned settles like refused --"
reset; q; table "#@ allow launch" "a fx-slurm - --rs-mode plan -p gpu -g 1 -t 1:00:00 -- python train.py"; O=$(rw t.tsv --approve "go"); RC=$?
[ "$RC" = 2 ] && has "$O" "no --rs-\* word ('--rs-mode')" "a row with --rs-mode: the table is refused (exit 2)" || bad "--rs-* row (rc=$RC)"
table "a fx-slurm - -p gpu -- python train.py --rs-mode plan"; O=$(rw t.tsv --once); [ "$?" != 2 ] && ok "...after --, the payload's own words are its business" || bad "--rs-* after --"
reset; approved "#@ allow launch" "a fx-slurm - $ROW"; q; touch "$WORLD/sbatch.fail"; rw t.tsv --once --act --max-active 2 >/dev/null; rm -f "$WORLD/sbatch.fail"
N=$(st a 16); [ "$(st a 2)" = submit-unknown ] && [ -d "$P/.rs/attempts/$N" ] || bad "L9 setup ($(st a 2) $N)"
printf 'stage=plan rc=0 verdict=planned at=1\n' > "$P/.rs/attempts/$N/result"; O=$(rw t.tsv --once --act --max-active 2)
has "$O" "ATTENTION name=a .*reason=submit-refused attempt=$N .*verdict=planned" "verdict=planned: nothing was queued -> held submit-refused (never stuck unknown)"
[ "$(st a 2)" = held ] && ok "...held" || bad "...held ($(st a 2))"

echo "-- round 3 (D11): fail-stop's pending cancels need --act and an approved fail-stop (G4-1) --"
sf() { awk -F'	' -v n="$1" -v f="$2" '$1 == n { print $f }' "$P/logs/run-watch/$3.state"; }   # sf NAME FIELD STATE-NAME
l6() {   # a adopted (1000), b's launch unknown (sbatch timed out: attempt $N), then a FAILED: the group stops, b pending
  reset; approved "#@ allow launch errors=0 fail-stop" "a fx-slurm - $ROW" "b fx-slurm - $ROW"
  echo 1001 > "$WORLD/nextjid"; q "1000|a|RUNNING|None|0|$NOW|$P|"; touch "$WORLD/sbatch.fail"
  rw t.tsv --once --act --max-active 4 --adopt a=1000 >/dev/null; rm -f "$WORLD/sbatch.fail"; N=$(st b 16)
  q; acct "1000|a|FAILED|1:0|$P"; rw t.tsv --once --act --max-active 4 >/dev/null; q "1001|b|RUNNING|None|0|$NOW|$P|"; }
receipt() { printf 'job=%s\nname=%s\n' "$2" "$3" > "$P/.rs/attempts/$1/receipt"; }   # receipt NONCE JOB NAME: the job exists
l6; grep -q '^#failstop-pending b$' "$P/logs/run-watch/t.state" && ok "setup: the stop names b (submit-unknown) as pending" || bad "G4-1 setup"
receipt "$N" 1001 b; O=$(rw t.tsv --once); has "$O" 'ADOPT name=b .*job=1001 note=receipt' "a detect-only run tracks b from its receipt"
has "$O" 'ATTENTION name=b .*job=1001 reason=fail-stop-not-cancelled why=no-act fail-stop=a' "  ...reports the pending fail-stop cancel (why=no-act)"
[ ! -s "$WORLD/scancel.log" ] && ok "  ...and never runs scancel without --act" || bad "  ...scancel without --act: $(cat "$WORLD/scancel.log")"
grep -q '^#failstop-pending b$' "$P/logs/run-watch/t.state" && ok "  ...b stays pending for an --act run" || bad "  ...pending kept"
O=$(rw t.tsv --once --act --max-active 4); has "$O" 'CANCEL name=b .*job=1001 by=fail-stop fail-stop=a' "  ...which cancels it (identity checked)"
l6; O=$(rw t.tsv --once --adopt b=1001); has "$O" 'ADOPT name=b .*job=1001 note=manual' "--adopt without --act tracks b"
[ ! -s "$WORLD/scancel.log" ] && ok "  ...and cancels nothing" || bad "  ...--adopt without --act cancelled: $(cat "$WORLD/scancel.log")"
l6; sed 's/^#@ allow launch errors=0 fail-stop$/#@ allow launch errors=0/' "$P/t.tsv" > "$T/t.nofs"; cp "$T/t.nofs" "$P/t.tsv"
rw t.tsv --approve "no fail-stop any more, keep b running" >/dev/null; receipt "$N" 1001 b; O=$(rw t.tsv --once --act --max-active 4)
has "$O" 'NOTE table=t.tsv fail-stop-pending-dropped rows=b' "the table approved again without fail-stop: its pending cancel is dropped"
[ ! -s "$WORLD/scancel.log" ] && ok "  ...b is never cancelled for it" || bad "  ...withdrawn fail-stop cancelled: $(cat "$WORLD/scancel.log")"
hasnt "$(cat "$P/logs/run-watch/t.state")" '^#failstop-pending' "  ...nor kept for later"; has "$(cat "$P/logs/run-watch/t.state")" '^#failstop a 1000$' "  ...the stop itself still holds the group (--release a)"

echo "-- round 3 (D11): a table's fail-stop goes with its rows to a renamed or copied table (G4-2) --"
reset; approved "#@ allow launch preempt=1 errors=0 fail-stop" "a fx-slurm - $ROW" "b fx-slurm - $ROW" "c fx-slurm - $ROW"
q "1000|a|RUNNING|None|0|$NOW|$P|" "1001|b|RUNNING|None|0|$NOW|$P|" "1002|c|RUNNING|None|0|$NOW|$P|"
rw t.tsv --once --act --max-active 4 --adopt a=1000 --adopt b=1001 --adopt c=1002 >/dev/null
q "1001|b|RUNNING|None|0|$NOW|$P|" "1002|c|PREEMPTED|None|0|$NOW|$P|"; acct "1000|a|FAILED|1:0|$P"; O=$(rw t.tsv --once --act --max-active 4)
has "$O" 'CANCEL name=b .*job=1001 by=fail-stop' "setup: a FAILED stops the group (b cancelled, c ended in the queue)"
q; acct "1000|a|FAILED|1:0|$P" "1001|b|CANCELLED by 1|0:0|$P" "1002|c|PREEMPTED|0:0|$P"; O=$(rw t.tsv --once --act --max-active 4)
has "$O" 'ATTENTION name=c .*reason=preempted why=fail-stop' "  ...c's preemption waits on the stop"
mv "$P/t.tsv" "$P/u.tsv"; rm -f "$P/logs/run-watch/attention.seen"; O=$(rw u.tsv --once --act --max-active 4)
has "$O" 'reason=fail-stop-inherited trigger=a:1000 from=logs/run-watch/t.state' "a renamed table takes the stopped group's fail-stop with its rows"
has "$O" 'ATTENTION name=c .*reason=preempted why=fail-stop' "  ...c stays held by it"; hasnt "$O" 'RESUBMIT' "  ...no resubmit"
[ "$(nsub)" = 0 ] && ok "  ...0 submits: a rename never resumes a stopped group" || bad "  ...rename resumed the group ($(nsub) submits)"
grep -q '^#failstop a 1000$' "$P/logs/run-watch/u.state" && ok "  ...u.state records the stop" || bad "  ...u.state stop"
{ echo '#@ run-watch v1'; echo '#@ allow launch preempt=1 errors=0 fail-stop'; echo "c fx-slurm - $ROW"; } > "$P/v.tsv"; rw v.tsv --approve "c alone" >/dev/null
O=$(rw v.tsv --once --act --max-active 4); has "$O" 'reason=fail-stop-inherited trigger=a:1000 .*though it is not a row here' "a table holding only c takes the stop too"
[ "$(nsub)" = 0 ] && ok "  ...no resubmit of c there" || bad "  ...$(nsub)"
O=$(rw v.tsv --once --act --max-active 4 --release a); has "$O" 'RELEASE table=v.tsv fail-stop=a -- fail-stop cleared' "  ...--release of the trigger (not a row there) resumes that group"
hasnt "$(cat "$P/logs/run-watch/v.state")" '^#failstop \|^#failstop-pending' "  ...v.state no longer stopped"
has "$(cat "$P/logs/run-watch/v.state")" '^#failstop-released a:1000$' "  ...the released stop is remembered there (R4-13)"
O=$(rw v.tsv --once --act --max-active 4); hasnt "$O" 'fail-stop-inherited' "  ...so the next round does not take it again from u.state"; rm -f "$P/v.tsv"
O=$(rw u.tsv --once --act --max-active 4 --release a); has "$O" 'NOTE name=a .*fail-stop cleared' "  ...--release a there resumes it"
l6; mv "$P/t.tsv" "$P/u.tsv"; receipt "$N" 1001 b; O=$(rw u.tsv --once --act --max-active 4)
has "$O" 'ADOPT name=b .*job=1001 note=receipt' "renamed after the stop: b's unknown submit goes with it, settled from its journal"
has "$O" 'CANCEL name=b .*job=1001 by=fail-stop fail-stop=a' "  ...and its pending fail-stop cancel too"
[ "$(cat "$WORLD/scancel.log" 2>/dev/null)" = 1001 ] && ok "  ...one scancel of 1001" || bad "  ...scancel: $(cat "$WORLD/scancel.log" 2>/dev/null)"

echo "-- round 3 (D11): an unknown submit in ANY other state file is sticky, even over a row's own state (G4-3) --"
utab() { { echo '#@ run-watch v1'; echo "$1"; echo "a fx-slurm - $ROW"; } > "$P/u.tsv"; rw u.tsv --approve "go" >/dev/null; }
reset; q; utab "#@ allow launch"; rw u.tsv --once >/dev/null; [ "$(sf a 2 u)" = pending ] || bad "G4-3 setup: u pending ($(sf a 2 u))"
approved "#@ allow launch" "a fx-slurm - $ROW"; touch "$WORLD/sbatch.fail"; rw t.tsv --once --act --max-active 2 >/dev/null; rm -f "$WORLD/sbatch.fail"
N=$(st a 16); [ "$(st a 2)" = submit-unknown ] && ok "setup: t's launch of a is unknown (attempt $N)" || bad "G4-3 setup: t ($(st a 2))"
O=$(rw u.tsv --once --act --max-active 2)
has "$O" "ATTENTION name=a .*reason=submit-unknown attempt=$N from=logs/run-watch/t.state" "a row with its own (pending) state takes the other table's unknown submit"
hasnt "$O" 'LAUNCH' "  ...never launched past it"; [ "$(nsub):$(sf a 2 u)" = 0:submit-unknown ] && ok "  ...0 sbatch, submit-unknown" || bad "  ...$(nsub):$(sf a 2 u)"
receipt "$N" 1000 a; q "1000|a|PENDING|Priority|0|N/A|$P|"; O=$(rw u.tsv --once --act --max-active 2)
has "$O" 'ADOPT name=a .*job=1000 note=receipt' "  ...settled here from that attempt's journal (job 1000)"
O=$(rw u.tsv --once --act --max-active 2); hasnt "$O" 'reason=submit-unknown attempt=' "  ...once: t.state's stale unknown is not taken again"
[ "$(sf a 2 u):$(nsub)" = active:0 ] && ok "  ...active, still 0 sbatch" || bad "  ...$(sf a 2 u):$(nsub)"
reset; q; utab "#@ allow launch"; rw u.tsv --once >/dev/null
approved "#@ allow launch" "a fx-slurm - $ROW"; touch "$WORLD/sbatch.reject"; rw t.tsv --once --act --max-active 2 >/dev/null; rm -f "$WORLD/sbatch.reject"; N=$(st a 16)
O=$(rw u.tsv --once --act --max-active 2); has "$O" "NOTE name=a .*attempt=$N queued nothing .*back to pending" "the other table's attempt queued nothing (journal: refused): the row's own status back"
[ "$(nsub)" = 0 ] && ok "  ...nothing submitted in that round" || bad "  ...$(nsub)"
O=$(rw u.tsv --once --act --max-active 2); has "$O" 'LAUNCH name=a' "  ...then launched under its own approval"; [ "$(nsub)" = 1 ] && ok "  ...once" || bad "  ...$(nsub)"
reset; utab "#@ allow preempt=2"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw u.tsv --once --adopt a=1000 >/dev/null
approved "#@ allow preempt=2" "a fx-slurm - $ROW"; rw t.tsv --once --adopt a=1000 >/dev/null
q; acct "1000|a|PREEMPTED|0:0|$P"; echo 2000 > "$WORLD/nextjid"; touch "$WORLD/ssh.drop-after"; rw t.tsv --once --act >/dev/null; rm -f "$WORLD/ssh.drop-after"
[ "$(st a 2):$(nsub)" = submit-unknown:1 ] && ok "setup: t resubmitted a (job 2000), its ssh dropped: unknown" || bad "G4-3 resubmit setup ($(st a 2):$(nsub))"
O=$(rw u.tsv --once --act); has "$O" 'ADOPT name=a .*job=2000 note=receipt' "a copy with its own (active) state settles the other table's resubmit from its journal"
hasnt "$O" 'RESUBMIT' "  ...instead of resubmitting"; [ "$(nsub)" = 1 ] && ok "  ...one sbatch for one preemption" || bad "  ...$(nsub) sbatch"
for st17 in 17 15; do reset; approved "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
  cut -f1-$st17 "$P/logs/run-watch/t.state" > "$T/old.state"; cp "$T/old.state" "$P/logs/run-watch/t.state"; O=$(rw t.tsv --once)
  [ "$(st a 2):$(st a 3):$(awk -F'	' '$1 == "a" { print NF ":" $18 }' "$P/logs/run-watch/t.state")" = active:1000:18:fx-slurm ] && hasnt "$O" 'state-lost' \
    "a $st17-field state file (before the target column) still loads; its own row's target is filled in" || bad "$st17-field state ($(st a 2))"
done

echo "-- round 3 (D11): state lines carry the target; status and jobs only from the same target (G4-4) --"
U2=$T/user2; mkdir -p "$U2"; cp -R "$RS_USER_DIR/." "$U2/"; mkdir -p "$U2/targets/fx-y"   # a second cluster, host fy
sed 's/T_HOST=fx;/T_HOST=fy;/' "$U2/targets/fx-slurm/profile.sh" > "$U2/targets/fx-y/profile.sh"; cp "$U2/targets/fx-slurm/policy.sh" "$U2/targets/fx-y/"
( export RS_USER_DIR=$U2; . "$RS_HOME/lib/common.sh"; rs_load_target fx-y; d="$P/.fx-y"; mkdir -p "$d"; for f in $(rs_deploy_files); do cp "$f" "$d/"; done
  rs_deploy_profile "$d/profile.sh"; chmod +x "$d"/*.sh )
rwy() { ( export RS_USER_DIR=$U2; rw "$@" ); }
reset; approved "#@ allow preempt=1" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
[ "$(awk -F'	' '$1 == "a" { print NF ":" $18 }' "$P/logs/run-watch/t.state")" = 18:fx-slurm ] && ok "a state line records its target (18th column)" || bad "state target column"
utab "#@ allow preempt=1"; sed 's/^a fx-slurm /a fx-y /' "$P/u.tsv" > "$T/u.y"; cp "$T/u.y" "$P/u.tsv"; rwy u.tsv --approve "only resume a on fy if it is preempted" >/dev/null
q; acct "1000|other-exp|PREEMPTED|0:0|/elsewhere/proj"; echo 5000 > "$WORLD/nextjid"; O=$(rwy u.tsv --once --act)
has "$O" 'NOTE name=a target=fx-y budgets-from=logs/run-watch/t.state .*target-there=fx-slurm' "another target's state: only its spent budgets go with the run"
hasnt "$O" 'RESUBMIT' "  ...never a resubmit on another cluster's job id"; [ "$(nsub)" = 0 ] && ok "  ...0 submits" || bad "  ...$(nsub) submits"
has "$O" 'ATTENTION name=a target=fx-y .*not-submitted why=no-launch-allowed' "  ...a first submit there needs 'launch'"
reset; approved "#@ allow preempt=1" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
utab "#@ allow launch preempt=1"; sed 's/^a fx-slurm /a fx-y /' "$P/u.tsv" > "$T/u.y"; cp "$T/u.y" "$P/u.tsv"; rwy u.tsv --approve go >/dev/null
q; acct; echo 5000 > "$WORLD/nextjid"; O=$(rwy u.tsv --once --act --max-active 2)
has "$O" 'LAUNCH name=a target=fx-y job=5000' "an approved launch row on another target is launched (no accounting-gap on a job it never had)"
reset; approved "#@ allow preempt=1" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
approved "#@ allow preempt=1" "a fx-y - $ROW"; q; acct "1000|other-exp|PREEMPTED|0:0|/elsewhere/proj"; O=$(rwy t.tsv --once --act)
has "$O" 'NOTE name=a target=fx-y target-changed from=fx-slurm status-there=active job-there=1000' "a row moved to another target in its own table: its old jobs are not followed"
hasnt "$O" 'RESUBMIT' "  ...no resubmit"; [ "$(nsub):$(st a 2):$(st a 3)" = 0:pending:- ] && ok "  ...pending, no jobs, 0 submits" || bad "  ...$(nsub):$(st a 2):$(st a 3)"
reset; approved "#@ allow preempt=1" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
q; acct "1000|other-exp|PREEMPTED|0:0|$P"; O=$(rw t.tsv --once --act)
has "$O" 'ATTENTION name=a .*job=1000 reason=job-identity-mismatch name=other-exp' "a terminal sacct row naming another job never settles the row"
[ "$(nsub)" = 0 ] && ok "  ...0 submits" || bad "  ...$(nsub) submits"
reset; approved "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
cut -f1-17 "$P/logs/run-watch/t.state" > "$T/old.state"; mv "$T/old.state" "$P/logs/run-watch/t.state"; rm -f "$P/logs/run-watch/t.state.prev"; mv "$P/t.tsv" "$P/u.tsv"
O=$(rw u.tsv --once); has "$O" 'NOTE name=a .*budgets-from=logs/run-watch/t.state .*target-there=-' "a line from before the target column: only its budgets go to another table"
has "$O" 'ADOPT name=a .*job=1000 state=RUNNING' "  ...its live job is adopted again by name and WorkDir"

echo "-- round 3 (D11): numbers are base 10 (G4-6) --"
reset; approved "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; O=$(rw t.tsv --every 0999 --for 1 --adopt a=01000); RC=$?
has "$O" 'START .* every=999 for=1 ' "--every 0999 is 999"; hasnt "$O" 'value too great' "  ...never read as octal (no crash after the first round)"
[ "$RC" = 3 ] && ok "  ...the lease ends: exit 3" || bad "  ...exit $RC"; has "$O" 'ADOPT name=a .*job=1000 note=manual' "--adopt a=01000 is job 1000"
O=$(rw t.tsv --once --every 0060); has "$O" 'START .* every=60 ' "--every 0060 is 60"
for v in 0059 1234567890 0x10; do O=$(rw t.tsv --once --every $v); [ "$?" = 2 ] && ok "--every $v refused" || bad "--every $v"; done
reset; approved "#@ allow preempt=08 errors=010" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; O=$(rw t.tsv --once --adopt a=1000); RC=$?
hasnt "$O" 'value too great' "'#@ allow preempt=08' is 8 (the requeue-storm threshold is arithmetic)"; [ "$RC" = 3 ] && ok "  ...exit 3" || bad "  ...exit $RC"
q "1000|a|RUNNING|None|8|$NOW|$P|"; O=$(rw t.tsv --once); has "$O" 'requeue-storm restarts=8' "  ...8 restarts reach it"

echo "-- round 3 (H-p2): '#@ ok' lines and headers this copy cannot read: refused, saying a newer run-watch wrote them --"
reset; q; table "#@ allow launch" '#@ ok 2026-11-05 sum=1 conf=0123456789ab v=4 "go"' "a fx-slurm - $ROW"; O=$(rw t.tsv --once); RC=$?
[ "$RC" = 2 ] && has "$O" "carrying v= — written by a newer run-watch" "an '#@ ok' key this copy does not know: exit 2, a newer run-watch named" || bad "unknown ok key (rc=$RC)"
has "$O" 'rsk update, then rsk setup' "  ...and how to update"; O=$(rw t.tsv --approve "again"); [ "$?" = 2 ] && ok "  ...--approve never writes over it" || bad "  ...--approve over it"
table '#@ ok sum=1 "x"' "a fx-slurm - $ROW"; O=$(rw t.tsv --once); [ "$?" = 2 ] && has "$O" 'malformed .*delete that line, then --approve' "a hand-edited '#@ ok' line: refused, says how to recover" || bad "malformed ok"
{ echo '#@ run-watch v2'; echo "a fx-slurm - -"; } > "$P/t.tsv"; O=$(rw t.tsv --once); [ "$?" = 2 ] && has "$O" "written for a newer run-watch (this copy reads v1)" "a '#@ run-watch v2' table: a newer run-watch named" || bad "v2 header"
[ "$(nsub)" = 0 ] && ok "  ...nothing submitted" || bad "  ...$(nsub)"
echo "-- round 3 (D2): the remote bodies (run on the login node / the box) parse rows by expansion, never a here-string --"
RB=$(awk "/^[A-Z_]+='rw_main\\(\\) \\{/,/^(rw_main'|}')\$/" "$RS_HOME/bin/run-watch")
[ "$(printf '%s\n' "$RB" | grep -c "^[A-Z_]*='rw_main() {")" -ge 4 ] && ok "the four remote bodies found (OBS_SLURM OBS_WS SUBMIT_SH CANCEL_SH)" || bad "remote bodies found"
hasnt "$RB" '<<' "...none has a here-string or heredoc (bash <= 5.0 writes them to \$TMPDIR: a full one read rows as empty)"

echo "-- round 4 (R4-13): another table's fail-stop is looked up every round, also for rows with a state of their own --"
g42() {   # g42 "U-ROWS": t = a b c (errors=1 fail-stop); u.tsv = U-ROWS, same allow line, approved and watched once (detect-only)
  reset; approved "#@ allow launch preempt=1 errors=1 fail-stop" "a fx-slurm - $ROW" "b fx-slurm - $ROW" "c fx-slurm - $ROW"   # BEFORE the stop:
  { echo '#@ run-watch v1'; echo '#@ allow launch preempt=1 errors=1 fail-stop'; for r in $1; do echo "$r fx-slurm - $ROW"; done; } > "$P/u.tsv"   # its own state
  rw u.tsv --approve "these too" >/dev/null; q "1000|a|RUNNING|None|0|$NOW|$P|" "1001|b|RUNNING|None|0|$NOW|$P|" "1002|c|RUNNING|None|0|$NOW|$P|"
  rw t.tsv --once --act --max-active 3 --adopt a=1000 --adopt b=1001 --adopt c=1002 >/dev/null; rw u.tsv --once >/dev/null
  q "1001|b|RUNNING|None|0|$NOW|$P|" "1002|c|RUNNING|None|0|$NOW|$P|"; acct "1000|a|FAILED|1:0|$P"; echo 2000 > "$WORLD/nextjid"
  rw t.tsv --once --act --max-active 3 >/dev/null   # a retried (errors 1/1) as job 2000, which fails too: the group stops
  q "1001|b|RUNNING|None|0|$NOW|$P|" "1002|c|PREEMPTED|None|0|$NOW|$P|"; acct "1000|a|FAILED|1:0|$P" "2000|a|FAILED|1:0|$P"; rw t.tsv --once --act --max-active 3 >/dev/null
  q; acct "1000|a|FAILED|1:0|$P" "2000|a|FAILED|1:0|$P" "1001|b|CANCELLED by 1|0:0|$P" "1002|c|PREEMPTED|0:0|$P"; echo 3000 > "$WORLD/nextjid"
  rw t.tsv --once --act --max-active 3 >/dev/null; }
g42 "a b c"; grep -q '^#failstop a 2000$' "$P/logs/run-watch/t.state" && [ "$(nsub)" = 1 ] && [ "$(sf a 2 u)" = active ] && ok "setup: t stopped its group (a:2000), one sbatch (the retry); u.state has its own lines" || bad "R4-13 copy setup ($(nsub) $(sf a 2 u))"
O=$(rw u.tsv --once --act --max-active 3); has "$O" 'reason=fail-stop-inherited trigger=a:2000 from=logs/run-watch/t.state' "an exact copy watched before the stop takes t's stop (rows with their own state)"
hasnt "$O" 'RESUBMIT\|LAUNCH\|RETRY' "  ...never resumes the stopped group"; [ "$(nsub)" = 1 ] && ok "  ...0 sbatch from u (c's preemption, a's newer job)" || bad "  ...u submitted ($(nsub))"
g42 "b c d"; O=$(rw u.tsv --once --act --max-active 3)
has "$O" 'reason=fail-stop-inherited trigger=a:2000 .*though it is not a row here' "a subset (b c d) watched before the stop takes it too"
has "$O" 'ATTENTION name=d .*not-submitted why=fail-stop' "  ...its row that t never had is held by it"; [ "$(nsub)" = 1 ] && ok "  ...0 sbatch from u" || bad "  ...u submitted ($(nsub))"
O=$(rw u.tsv --once --act --max-active 3 --release a); has "$O" 'RELEASE table=u.tsv fail-stop=a -- fail-stop cleared' "  ...--release a there resumes u's rows"
has "$(cat "$P/logs/run-watch/u.state")" '^#failstop-released a:2000$' "  ...and u.state remembers that release"
grep -q '^#failstop a 2000$' "$P/logs/run-watch/t.state" || bad "  ...t.state still stopped"; O=$(rw u.tsv --once --act --max-active 3)
hasnt "$O" 'fail-stop-inherited' "  ...so t.state's stop (still there) never holds u again"
reset; approved "#@ allow launch errors=0 fail-stop" "a fx-slurm - $ROW" "b fx-slurm - $ROW"   # b's launch unknown, u = b alone watched before the stop
{ echo '#@ run-watch v1'; echo '#@ allow launch errors=0 fail-stop'; echo "b fx-slurm - $ROW"; } > "$P/u.tsv"; rw u.tsv --approve "b too" >/dev/null
echo 1001 > "$WORLD/nextjid"; q "1000|a|RUNNING|None|0|$NOW|$P|"; touch "$WORLD/sbatch.fail"; rw t.tsv --once --act --max-active 4 --adopt a=1000 >/dev/null
rm -f "$WORLD/sbatch.fail"; N=$(st b 16); rw u.tsv --once >/dev/null; q; acct "1000|a|FAILED|1:0|$P"; rw t.tsv --once --act --max-active 4 >/dev/null
[ "$(sf b 2 u)" = submit-unknown ] && grep -q '^#failstop-pending b$' "$P/logs/run-watch/t.state" && ok "setup: t's stop names b (submit-unknown) pending; u holds b's own state" || bad "R4-13 pending setup ($(sf b 2 u))"
q "1001|b|RUNNING|None|0|$NOW|$P|"; receipt "$N" 1001 b; O=$(rw u.tsv --once --act --max-active 4)
has "$O" 'CANCEL name=b .*job=1001 by=fail-stop fail-stop=a' "  ...u takes the stop with b's pending cancel: b tracked from its receipt, cancelled (identity checked)"
[ "$(cat "$WORLD/scancel.log" 2>/dev/null)" = 1001 ] && ok "  ...one scancel of 1001" || bad "  ...scancel: $(cat "$WORLD/scancel.log" 2>/dev/null)"

echo "-- round 4 (R4-14): the settle path checks WorkDir; a line from before the target column follows its jobs only on its own target --"
reset; approved "#@ allow preempt=1" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
q; acct "1000|a|PREEMPTED|0:0|/elsewhere/other-proj"; O=$(rw t.tsv --once --act)
has "$O" 'ATTENTION name=a .*job=1000 reason=job-identity-mismatch name=a workdir=/elsewhere/other-proj state=PREEMPTED' "a same-named job of another project's WorkDir never settles the row"
[ "$(nsub)" = 0 ] && ok "  ...0 submits" || bad "  ...$(nsub) submits"
reset; approved "#@ allow preempt=2" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
q; acct "1000|a|PREEMPTED|0:0|$P"; touch "$WORLD/prev-other"; O=$(rw t.tsv --once --act); rm -f "$WORLD/prev-other"
has "$O" 'WARN name=a .*reason=submit-skipped n=1 -- prev-identity name=a workdir=/elsewhere/proj' "the submit ssh re-checks the job's name and WorkDir too"
[ "$(nsub):$(st a 4)" = 0:0 ] && ok "  ...nothing submitted, budget refunded" || bad "  ...$(nsub):$(st a 4)"
reset; approved "#@ allow preempt=1" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
cut -f1-17 "$P/logs/run-watch/t.state" > "$T/old.state"; cp "$T/old.state" "$P/logs/run-watch/t.state"   # as dbd3255 wrote it (one #target)
table "#@ allow preempt=1" "a fx-y - $ROW"; rwy t.tsv --approve "a on fy now" >/dev/null
q; acct "1000|a|PREEMPTED|0:0|$P"; echo 5000 > "$WORLD/nextjid"; O=$(rwy t.tsv --once --act)
has "$O" 'NOTE name=a target=fx-y target-changed from=fx-slurm status-there=active job-there=1000' "a 17-field line, the row moved to another target: its target is the file's one #target"
hasnt "$O" 'RESUBMIT' "  ...its job id is not followed on the new target (even one naming this row and project)"; [ "$(nsub)" = 0 ] && ok "  ...0 submits" || bad "  ...$(nsub) submits"
reset; table "a fx-slurm - $ROW" "c fx-y - $ROW"; rwy t.tsv --approve go >/dev/null
q "1000|a|RUNNING|None|0|$NOW|$P|" "1002|c|RUNNING|None|0|$NOW|$P|"; rwy t.tsv --once --adopt a=1000 --adopt c=1002 >/dev/null
cut -f1-17 "$P/logs/run-watch/t.state" > "$T/old.state"; cp "$T/old.state" "$P/logs/run-watch/t.state"; O=$(rwy t.tsv --once)
has "$O" 'NOTE name=a target=fx-slurm target-changed from=? ' "a 17-field file of a watch of two targets: its lines' targets are unknown"
has "$O" 'ADOPT name=a .*job=1000 state=RUNNING' "  ...jobs adopted again by name and WorkDir"; has "$O" 'ADOPT name=c target=fx-y .*job=1002 state=RUNNING' "  ...on each row's own target"
reset; approved "a fx-slurm - $ROW" "b fx-slurm - -"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
approved "b fx-slurm - -"; rw t.tsv --once >/dev/null; cut -f1-17 "$P/logs/run-watch/t.state" > "$T/old.state"; cp "$T/old.state" "$P/logs/run-watch/t.state"
approved "a fx-slurm - $ROW" "b fx-slurm - -"; O=$(rw t.tsv --once); has "$O" 'NOTE name=a .*target-changed from=? status-there=active' "a removed row's 17-field line: its target is unknown, so is its job"

echo "-- round 4 (R4-7): --act / --approve go through rsk watch; once its pid (RS_WATCH_PARENT) is gone run-watch stops (exit 7) --"
mkdir -p "$T/rskbin"; printf '#!/bin/sh\necho "rsk stub $*" >> "%s/rsk.log"\n' "$T" > "$T/rskbin/rsk"; chmod +x "$T/rskbin/rsk"
NORSK=$(printf %s "$PATH" | tr ':' '\n' | while IFS= read -r d; do [ -n "$d" ] && [ ! -x "$d/rsk" ] && printf '%s:' "$d"; done)
rwd() { local pp=$1; shift; ( cd "$P" && env -u RS_VIA_RSK PATH="$pp" RS_WATCH_OBS_TIMEOUT=15 RS_WATCH_SUBMIT_TIMEOUT=15 bash "$RS_HOME/bin/run-watch" "$@" 2>&1 ); }   # called directly
reset; q; approved "#@ allow launch" "a fx-slurm - $ROW"; O=$(rwd "$T/rskbin:$T/bin:$PATH" t.tsv --once --act --max-active 2); RC=$?
[ "$RC" = 2 ] && has "$O" '^use: rsk watch t.tsv … --act … (the project.s watch lease; every row checked against the ledger.s denies)' "rsk installed, --act called directly: points at rsk watch, exit 2" || bad "R4-7 --act steer (rc=$RC)"
[ ! -s "$WORLD/ssh.log" ] && [ "$(nsub)" = 0 ] && ok "  ...before any ssh, nothing submitted" || bad "  ...ssh or sbatch ran"; [ ! -s "$T/rsk.log" ] && ok "  ...and never runs rsk itself" || bad "  ...ran rsk"
table "#@ allow launch" "b fx-slurm - $ROW"; cp "$P/t.tsv" "$T/t.unok"; O=$(rwd "$T/rskbin:$T/bin:$PATH" t.tsv --approve "go"); RC=$?
[ "$RC" = 2 ] && has "$O" '^use: rsk watch t.tsv --approve (the user.s OK' "--approve called directly: points at rsk watch … --approve, exit 2" || bad "R4-7 --approve steer (rc=$RC)"
cmp -s "$P/t.tsv" "$T/t.unok" && ok "  ...nothing written" || bad "  ...the table was rewritten"; hasnt "$O" '"go"' "  ...the words given are not echoed into a ready-to-run line"
O=$( cd "$P" && RS_VIA_RSK= PATH="$T/rskbin:$T/bin:$PATH" bash "$RS_HOME/bin/run-watch" t.tsv --approve go 2>&1 ); [ "$?" = 2 ] && ok "an empty RS_VIA_RSK counts as unset" || bad "empty RS_VIA_RSK"
approved "#@ allow launch" "a fx-slurm - $ROW"; O=$(rwd "$T/rskbin:$T/bin:$PATH" t.tsv --once); RC=$?
[ "$RC" = 4 ] && hasnt "$O" '^use: rsk\|^NOTE: run-skills is installed without rsk' "watching without --act / --approve runs directly, no steer" || bad "read-only direct watch (rc=$RC)"
mkdir -p "$T/uvbin" "$T/uvtool"; printf '#!/bin/sh\ncase "$*" in "tool dir --bin") echo "%s/uvtool" ;; esac\n' "$T" > "$T/uvbin/uv"; cp "$T/rskbin/rsk" "$T/uvtool/rsk"; chmod +x "$T/uvbin/uv"
O=$(rwd "$T/uvbin:$T/bin:${NORSK%:}" t.tsv --once --act --max-active 2); RC=$?
[ "$RC" = 2 ] && has "$O" '^use: rsk watch t.tsv' "rsk in uv's tool bin dir (not on PATH): steered too" || bad "rsk via uv tool dir (rc=$RC)"
reset; q; approved "#@ allow launch" "a fx-slurm - $ROW"; O=$(rwd "$T/bin:${NORSK%:}" t.tsv --once --act --max-active 2)
has "$O" 'LAUNCH name=a ' "no rsk installed: --act acts directly"; [ "$(printf '%s\n' "$O" | grep -c '^NOTE: run-skills is installed without rsk: run-watch acts directly')" = 1 ] && ok "  ...with one NOTE line" || bad "  ...NOTE"
O=$( export RS_WATCH_PARENT=abc; rw t.tsv --once ); [ "$?" = 2 ] && ok "RS_WATCH_PARENT that is not a pid: exit 2" || bad "RS_WATCH_PARENT=abc"
reset; q; approved "#@ allow launch" "a fx-slurm - $ROW"; O=$( export RS_WATCH_PARENT=$$; rw t.tsv --once --act --max-active 2 ); RC=$?
[ "$RC" = 7 ] && has "$O" 'reason=parent-gone parent=[0-9]* at=start' "RS_WATCH_PARENT alive but not run-watch's parent (a reused pid): exit 7 at the start" || bad "not the parent (rc=$RC)"
[ ! -s "$WORLD/ssh.log" ] && [ "$(nsub)" = 0 ] && ok "  ...before any ssh, nothing submitted" || bad "  ...ssh or sbatch ran"
rwp() {   # rwp OBS|SUB|CAN|never ARGS...: run-watch as rsk watch starts it (RS_WATCH_PARENT = its parent's pid); the ssh stub SIGKILLs
  local at=$1; shift   # that parent during the first ssh of that kind (a killed rsk watch)
  ( cd "$P" && PATH="$T/bin:$PATH" RS_WATCH_OBS_TIMEOUT=15 RS_WATCH_SUBMIT_TIMEOUT=15 \
      bash -c '[ "$1" = never ] || echo "$$" > "$WORLD/kill-parent.$1"; shift; RS_WATCH_PARENT=$$ bash "$@" 2>&1; rc=$?; exit "$rc"' rwp "$at" "$RS_HOME/bin/run-watch" "$@" ) 2>/dev/null; }
O=$(rwp never t.tsv --once --act --max-active 2); has "$O" 'LAUNCH name=a .*job=1000' "its parent alive: run-watch acts"; hasnt "$O" 'parent-gone' "  ...no parent-gone"
reset; q; approved "#@ allow launch" "a fx-slurm - $ROW"; O=$(rwp obs t.tsv --once --act --max-active 2)
has "$O" 'ATTENTION reason=parent-gone parent=[0-9]* at=decisions' "rsk watch SIGKILLed during the read: stops before any decision"; has "$O" 'EXIT code=7' "  ...exit 7"
[ "$(nsub)" = 0 ] && [ ! -d "$P/logs/run-watch/.lock" ] && [ "$(st a 2)" = pending ] && ok "  ...0 submits, lock released, state saved" || bad "  ...$(nsub) $(st a 2)"
reset; q; table "#@ allow launch" "a fx-slurm - $ROW" "c fx-y - $ROW"; rwy t.tsv --approve go >/dev/null; O=$( export RS_USER_DIR=$U2; rwp sub t.tsv --once --act --max-active 2 )
has "$O" 'LAUNCH name=a target=fx-slurm job=1000' "SIGKILLed during the first target's submit: that submit is reported"; has "$O" 'reason=parent-gone .*at=submit' "  ...the next submit is not sent"
[ "$(nsub):$(st c 2)" = 1:pending ] && has "$O" 'EXIT code=7' "  ...one sbatch, c pending, exit 7" || bad "  ...$(nsub):$(st c 2)"
reset; table "#@ allow launch errors=0 fail-stop" "a fx-slurm - $ROW" "b fx-slurm - $ROW" "c fx-y - $ROW"; rwy t.tsv --approve go >/dev/null
q "1000|a|RUNNING|None|0|$NOW|$P|" "1001|b|RUNNING|None|0|$NOW|$P|" "1002|c|RUNNING|None|0|$NOW|$P|"; rwy t.tsv --once --act --max-active 4 --adopt a=1000 --adopt b=1001 --adopt c=1002 >/dev/null
q "1001|b|RUNNING|None|0|$NOW|$P|" "1002|c|RUNNING|None|0|$NOW|$P|"; acct "1000|a|FAILED|1:0|$P"; O=$( export RS_USER_DIR=$U2; rwp can t.tsv --once --act --max-active 4 )
has "$O" 'CANCEL name=b .*job=1001 by=fail-stop' "SIGKILLed during a fail-stop cancel: that cancel is reported"; has "$O" 'reason=parent-gone .*at=cancel' "  ...the next cancel is not sent"
[ "$(cat "$WORLD/scancel.log" 2>/dev/null)" = 1001 ] && grep -q '^#failstop-pending c$' "$P/logs/run-watch/t.state" && ok "  ...one scancel; c kept as a pending fail-stop cancel" || bad "  ...scancel $(cat "$WORLD/scancel.log" 2>/dev/null)"
O=$(rwy t.tsv --once --act --max-active 4); has "$O" 'CANCEL name=c target=fx-y job=1002 by=fail-stop fail-stop=a' "  ...the next --act run sends it (identity checked)"

echo "-- round 5 (R5-7): a table keeps every fail-stop that holds it; --release clears only the stops its trigger named --"
mk5() { local f=$1; shift; { echo '#@ run-watch v1'; echo '#@ allow launch errors=0 fail-stop'; for r in "$@"; do echo "$r fx-slurm - $ROW"; done; } > "$P/$f"; rw "$f" --approve "ok $f" >/dev/null; }
reset; mk5 t.tsv a b; mk5 v.tsv x c; mk5 u.tsv b c d   # u: a row of each stopped group (b of t's, c of v's) + d, never launched
q "1000|a|RUNNING|None|0|$NOW|$P|" "1001|b|RUNNING|None|0|$NOW|$P|" "1002|x|RUNNING|None|0|$NOW|$P|" "1003|c|RUNNING|None|0|$NOW|$P|"
rw t.tsv --once --act --max-active 2 --adopt a=1000 --adopt b=1001 >/dev/null; rw v.tsv --once --act --max-active 2 --adopt x=1002 --adopt c=1003 >/dev/null
q "1001|b|RUNNING|None|0|$NOW|$P|" "1002|x|RUNNING|None|0|$NOW|$P|" "1003|c|RUNNING|None|0|$NOW|$P|"; acct "1000|a|FAILED|1:0|$P"; rw t.tsv --once --act --max-active 2 >/dev/null
q "1003|c|RUNNING|None|0|$NOW|$P|"; acct "1000|a|FAILED|1:0|$P" "1001|b|CANCELLED by 1|0:0|$P" "1002|x|FAILED|1:0|$P"; rw v.tsv --once --act --max-active 2 >/dev/null
q; acct "1000|a|FAILED|1:0|$P" "1001|b|CANCELLED by 1|0:0|$P" "1002|x|FAILED|1:0|$P" "1003|c|CANCELLED by 1|0:0|$P"
grep -q '^#failstop a 1000$' "$P/logs/run-watch/t.state" && grep -q '^#failstop x 1002$' "$P/logs/run-watch/v.state" && [ "$(sort "$WORLD/scancel.log" | paste -sd, -)" = 1001,1003 ] \
  && [ "$(nsub)" = 0 ] && ok "setup: t stopped (a:1000, b cancelled), v stopped (x:1002, c cancelled)" || bad "R5-7 setup"
O=$(rw u.tsv --once --act --max-active 3)
has "$O" 'reason=fail-stop-inherited trigger=a:1000 from=logs/run-watch/t.state' "a table with rows of two stopped groups takes t's stop"
has "$O" 'reason=fail-stop-inherited trigger=x:1002 from=logs/run-watch/v.state also-held-by=a:1000' "  ...and v's beside it (FS-release-one-of-two-stops)"
[ "$(grep -c '^#failstop ' "$P/logs/run-watch/u.state")" = 2 ] && ok "  ...u.state keeps both" || bad "  ...u.state: $(grep '^#failstop' "$P/logs/run-watch/u.state" | paste -sd'|' -)"
O=$(rw u.tsv --once --act --max-active 3 --release a)
has "$O" 'RELEASE table=u.tsv fail-stop=a held-by=x:1002 -- that fail-stop is cleared; another still holds this table .*--release x (user OK)' "--release a clears t's stop only and names the one still holding u"
hasnt "$O" 'LAUNCH' "  ...d stays held (the reproduction launched it)"; [ "$(nsub)" = 0 ] && ok "  ...0 sbatch" || bad "  ...$(nsub) sbatch"
SU=$(cat "$P/logs/run-watch/u.state"); has "$SU" '^#failstop x 1002$' "  ...u.state: x's stop kept"; hasnt "$SU" '^#failstop a ' "  ...a's gone"
has "$SU" '^#failstop-released a:1000$' "  ...and remembered as released"
O=$(rw u.tsv --once --act --max-active 3); hasnt "$O" 'trigger=a:1000\|LAUNCH' "the next run: a's stop is not taken again, x's still holds"; [ "$(nsub)" = 0 ] && ok "  ...0 sbatch" || bad "  ...$(nsub)"
O=$(rw u.tsv --once --act --max-active 3 --release x); has "$O" 'RELEASE table=u.tsv fail-stop=x -- fail-stop cleared' "--release x then clears the last stop"
has "$O" 'LAUNCH name=d ' "  ...the group resumes: d launched"; [ "$(nsub)" = 1 ] && ok "  ...one sbatch" || bad "  ...$(nsub)"
reset; mk5 u.tsv a b d; mk5 v.tsv x d   # u's own stop first, then v's (v shares d): v forms its own stop beside u's
q "1000|a|RUNNING|None|0|$NOW|$P|" "1001|b|RUNNING|None|0|$NOW|$P|" "1002|x|RUNNING|None|0|$NOW|$P|"
rw u.tsv --once --act --max-active 2 --adopt a=1000 --adopt b=1001 >/dev/null; rw v.tsv --once --act --max-active 1 --adopt x=1002 >/dev/null
q "1001|b|RUNNING|None|0|$NOW|$P|" "1002|x|RUNNING|None|0|$NOW|$P|"; acct "1000|a|FAILED|1:0|$P"; rw u.tsv --once --act --max-active 2 >/dev/null
q; acct "1000|a|FAILED|1:0|$P" "1001|b|CANCELLED by 1|0:0|$P" "1002|x|FAILED|1:0|$P"; O=$(rw v.tsv --once --act --max-active 1)
has "$O" 'ATTENTION name=x .*reason=fail-stop trigger=x:1002' "v holding u's stop still forms its own when x fails (both groups stop)"
grep -q '^#failstop x 1002$' "$P/logs/run-watch/v.state" && [ "$(nsub)" = 0 ] && ok "  ...v.state records it, 0 sbatch" || bad "  ...v stop ($(nsub))"
O=$(rw u.tsv --once --act --max-active 2); has "$O" 'reason=fail-stop-inherited trigger=x:1002 from=logs/run-watch/v.state also-held-by=a:1000' "u (its own stop a) takes v's stop too"
O=$(rw u.tsv --once --act --max-active 2 --release a)
has "$O" 'ATTENTION name=a .*reason=release-held held-by=x:1002 -- .*--release x (user OK), then --release a' "--release a of u's own trigger: a gets no submit while x's stop holds u"
has "$O" 'RELEASE table=u.tsv fail-stop=a held-by=x:1002' "  ...a's stop is cleared"; [ "$(nsub)" = 0 ] && ok "  ...0 sbatch (no retry of a, no launch of d)" || bad "  ...$(nsub)"
O=$(rw u.tsv --once --act --max-active 2 --release x); has "$O" 'RELEASE table=u.tsv fail-stop=x -- fail-stop cleared' "--release x: no stop left"
has "$O" 'LAUNCH name=d ' "  ...d (held by u's stop) launched"; hasnt "$O" 'name=a .*RE\(SUBMIT\|TRY\)' "  ...a still waits for its own --release"
O=$(rw u.tsv --once --act --max-active 2 --release a); has "$O" 'RESUBMIT name=a .*release=1' "--release a once more: its one submit"
[ "$(nsub)" = 2 ] && ok "  ...two sbatch in all (d, a)" || bad "  ...$(nsub)"
l6; printf '#failstop z 1999\n' >> "$P/logs/run-watch/t.state"   # a second stop on t (trigger z: not a row here, as one taken from another table)
O=$(rw t.tsv --once --act --max-active 4 --release a); has "$O" 'ATTENTION name=a .*reason=release-held held-by=z:1999' "--release a while z's stop holds t: a stays held"
[ "$(nsub)" = 0 ] && ok "  ...0 sbatch" || bad "  ...$(nsub)"
ST5=$(cat "$P/logs/run-watch/t.state"); has "$ST5" '^#failstop z 1999$' "  ...t.state keeps z's stop"; hasnt "$ST5" '^#failstop-pending' "  ...a's pending cancel of b went with a's stop"
receipt "$N" 1001 b; O=$(rw t.tsv --once --act --max-active 4); has "$O" 'ADOPT name=b .*job=1001 note=receipt' "b tracked from its receipt"
[ ! -s "$WORLD/scancel.log" ] && ok "  ...never cancelled for a's released stop" || bad "  ...scancel: $(cat "$WORLD/scancel.log")"
l6; printf '#failstop z 1999\n' >> "$P/logs/run-watch/t.state"; rw t.tsv --once >/dev/null   # rewritten by this copy: each stop with its own pending line
[ "$(grep '^#failstop' "$P/logs/run-watch/t.state" | paste -sd'|' -)" = '#failstop a 1000|#failstop-pending b|#failstop z 1999|#failstop-pending ' ] \
  && ok "two stops in a state file: each '#failstop' line followed by its own '#failstop-pending' (an empty one too)" || bad "layout: $(grep '^#failstop' "$P/logs/run-watch/t.state" | paste -sd'|' -)"
mkdir -p "$T/old5/bin" "$T/old5/lib"   # the run-watch before R5-7 (678091e) reads one stop: the last pair
if git -C "$RS_HOME" show 678091e:bin/run-watch > "$T/old5/bin/run-watch" 2>/dev/null && git -C "$RS_HOME" show 678091e:lib/common.sh > "$T/old5/lib/common.sh" 2>/dev/null; then
  receipt "$N" 1001 b; O=$( cd "$P" && PATH="$T/bin:$PATH" RS_WATCH_OBS_TIMEOUT=15 RS_WATCH_SUBMIT_TIMEOUT=15 bash "$T/old5/bin/run-watch" t.tsv --once --act --max-active 4 2>&1 )
  [ ! -s "$WORLD/scancel.log" ] && [ "$(nsub)" = 0 ] && ok "678091e's run-watch on that file: the table stays held, b's pending (a's) is not taken as z's" || bad "older copy: scancel $(cat "$WORLD/scancel.log" 2>/dev/null) sbatch $(nsub)"
else ok "678091e not in this clone's history: the older-copy check SKIP"; fi

echo "-- round 5 (R5-8): a row's target is a target name, spelled as rs_targets lists it --"
reset; q
for tg in fx-slurm/ fx-slurm/. fx-slurm// ./fx-slurm fx-slurm/../fx-slurm; do
  table "#@ allow launch" "a $tg - $ROW"; O=$(rw t.tsv --approve go); RC=$?
  [ "$RC" = 2 ] && [ "$(grep -c '^#@ ok' "$P/t.tsv")" = 0 ] && has "$O" "target '$tg'" "target '$tg': --approve refused (exit 2), nothing written" || bad "target '$tg': --approve (rc=$RC)"
  O=$(rw t.tsv --once --act --max-active 1); RC=$?
  [ "$RC" = 2 ] && [ "$(nsub)" = 0 ] && [ ! -s "$WORLD/ssh.log" ] && ok "  ...--act refused (exit 2) before any ssh" || bad "  ...--act (rc=$RC, $(nsub) sbatch)"
done
if [ "$(id -u)" != 0 ]; then   # a target whose profile resolves but which rs_targets does not list (its root not listable)
  U3=$T/user3; mkdir -p "$U3"; cp -R "$RS_USER_DIR/." "$U3/"; chmod 311 "$U3/targets"
  ( export RS_USER_DIR=$U3; . "$RS_HOME/lib/common.sh"; ! rs_targets | grep -qx fx-slurm && rs_target_dir fx-slurm >/dev/null ) \
    && ok "setup: rs_target_dir resolves fx-slurm in a root rs_targets cannot list" || bad "R5-8 setup"
  reset; q; table "#@ allow launch" "a fx-slurm - $ROW"; ( export RS_USER_DIR=$U3; rw t.tsv --approve go ) >/dev/null
  O=$( export RS_USER_DIR=$U3; rw t.tsv --once --act --max-active 1 ); RC=$?; chmod 755 "$U3/targets"
  [ "$RC" = 2 ] && has "$O" "target 'fx-slurm' is not a target name this harness lists" "a target rs_targets does not list is refused (exit 2)" || bad "unlisted target (rc=$RC)"
  [ ! -s "$WORLD/ssh.log" ] && [ "$(nsub)" = 0 ] && ok "  ...before any ssh" || bad "  ...ssh or sbatch ran"
else ok "running as root (permissions not enforced): the unlisted-target check SKIP"; fi

echo "-- round 6: a --release not used yet is withdrawn once a fail-stop holds its table later in the same watch --"
mkdir -p "$T/sbin"; RSL=$(command -v sleep)   # several rounds: the between-rounds sleep runs the world's next step (none left: TERM)
cat > "$T/sbin/sleep" <<EOS
#!/usr/bin/env bash
case "\$1" in [0-9]|[0-4][0-9]) exec "$RSL" "\$@" ;; esac   # a watchdog or the lock wait: the real sleep
n=\$(( \$(cat "\$WORLD/step" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$WORLD/step"
if [ -f "\$WORLD/step\$n.sh" ]; then . "\$WORLD/step\$n.sh"; else kill -TERM "\$PPID"; fi
EOS
chmod +x "$T/sbin/sleep"
wstep() {   # wstep N "QUEUE-ROWS" SACCT-ROWS...: the world after the Nth between-rounds sleep (queue rows: no spaces)
  local n=$1 r; { printf 'printf "%%s\\n" %q' "$OTHER"; for r in $2; do printf ' %q' "$r"; done; echo ' > "$WORLD/squeue"'; shift 2
    printf 'printf "%%s\\n"'; for r in "$@"; do printf ' %q' "$r"; done; echo ' > "$WORLD/sacct"'; } > "$WORLD/step$n.sh"; }
rwm() { ( cd "$P" && PATH="$T/sbin:$T/bin:$PATH" RS_WATCH_OBS_TIMEOUT=15 RS_WATCH_SUBMIT_TIMEOUT=15 bash "$RS_HOME/bin/run-watch" "$@" 2>&1 ); }
rel6() {   # t = c (never launched) b (its job 1001 cancelled: held) [a (1000 running)]; c's launch takes round 1's one submit
  reset; approved "#@ allow launch errors=0 fail-stop" "c fx-slurm - $ROW" "b fx-slurm - $ROW" "$@"
  q "1000|a|RUNNING|None|0|$NOW|$P|" "1001|b|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt b=1001 $([ "$#" = 0 ] || echo --adopt a=1000) >/dev/null
  q "1000|a|RUNNING|None|0|$NOW|$P|"; acct "1001|b|CANCELLED by 1|0:0|$P"; rw t.tsv --once >/dev/null; echo 2000 > "$WORLD/nextjid"; }
rel6 "a fx-slurm - $ROW"; [ "$(st b 2):$(st c 2):$(st a 2):$(nsub)" = held:pending:active:0 ] && ok "setup: b held (its job cancelled), c never launched, a running" || bad "round 6 setup ($(st b 2):$(st c 2):$(st a 2))"
wstep 1 "2000|c|RUNNING|None|0|$NOW|$P|" "1001|b|CANCELLED by 1|0:0|$P" "1000|a|FAILED|1:0|$P"
wstep 2 "" "1001|b|CANCELLED by 1|0:0|$P" "1000|a|FAILED|1:0|$P" "2000|c|CANCELLED by 1|0:0|$P"
O=$(rwm t.tsv --act --max-active 5 --every 60 --release b)
has "$O" 'LAUNCH name=c .*job=2000' "round 1: c launched (the target's one submit); b's released resubmit waits a round"
has "$O" 'ATTENTION name=a .*reason=fail-stop trigger=a:1000' "round 2: a FAILED, errors spent: the group stops"; has "$O" 'CANCEL name=c .*job=2000 by=fail-stop' "  ...c cancelled"
has "$O" 'ATTENTION name=b .*job=1001 reason=release-withdrawn fail-stop=a' "  ...b's --release, given before that stop and not used yet, is withdrawn"
hasnt "$O" 'RESUBMIT name=b' "  ...b is never resubmitted past the stop (HEAD did, in round 3)"
[ "$(nsub):$(st b 2)" = 1:held ] && ok "  ...one sbatch (c), b held" || bad "  ...$(nsub) sbatch, b $(st b 2)"
rel6; mk5 v.tsv x d; q "1002|x|RUNNING|None|0|$NOW|$P|"; rw v.tsv --once --adopt x=1002 >/dev/null   # v = x d: x fails, v stops (d held)
q; acct "1001|b|CANCELLED by 1|0:0|$P" "1002|x|FAILED|1:0|$P"; rw v.tsv --once --act --max-active 2 >/dev/null; echo 2000 > "$WORLD/nextjid"
grep -q '^#failstop x 1002$' "$P/logs/run-watch/v.state" && [ "$(nsub)" = 0 ] && ok "setup: v stopped (x:1002), d never launched" || bad "round 6 v setup ($(nsub))"
wstep 1 "2000|c|RUNNING|None|0|$NOW|$P|" "1001|b|CANCELLED by 1|0:0|$P" "1002|x|FAILED|1:0|$P"
printf 'printf "d fx-slurm - %s\\n" >> t.tsv; bash %q t.tsv --approve "and d" > /dev/null\n' "$ROW" "$RS_HOME/bin/run-watch" >> "$WORLD/step1.sh"   # the user adds d (v's group)
O=$(rwm t.tsv --act --max-active 5 --every 60 --release b)
has "$O" 'reason=fail-stop-inherited trigger=x:1002 from=logs/run-watch/v.state' "round 2: d, added and approved during the watch, brings v's stop to t"
has "$O" 'ATTENTION name=b .*job=1001 reason=release-withdrawn fail-stop=x' "  ...b's --release not used yet is withdrawn"
hasnt "$O" 'RESUBMIT name=b' "  ...no resubmit of b past it (HEAD resubmitted it in round 2)"; [ "$(nsub)" = 1 ] && ok "  ...one sbatch (c)" || bad "  ...$(nsub) sbatch"
reset; approved "#@ allow preempt=1" "a fx-slurm - $ROW"; q "1000|a|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --adopt a=1000 >/dev/null
q; acct "1000|a|CANCELLED by 1|0:0|$P"; echo 2000 > "$WORLD/nextjid"; O=$(rwm t.tsv --act --every 60 --release a); has "$O" 'RESUBMIT name=a .*release=1' "control: with no stop, the release is used (one resubmit)"
hasnt "$O" 'release-withdrawn' "  ...and never withdrawn"

echo "-- round 7 (R7-7): a table holding a NUL byte or a control character other than tab is refused (exit 2), as rsk refuses it --"
M7='a NUL byte or a control character other than tab — a run-watch table is plain text (LF line ends); rsk and run-watch both refuse it'
reset; q; printf '%b\n' '#@ run-watch v1' '#@ allow launch errors=0 fail\0-stop' "a fx-slurm - $ROW" "b fx-slurm - $ROW" > "$P/t.tsv"; cp "$P/t.tsv" "$T/t7"
O=$(rw t.tsv --approve "go ahead, stop the group if one fails"); RC=$?   # bash's read drops the NUL (fail-stop), rsk's reader kept it
[ "$RC" = 2 ] && cmp -s "$P/t.tsv" "$T/t7" && ok "'#@ allow … fail<NUL>-stop': --approve refused (exit 2), nothing written" || bad "NUL in the allow line: --approve (rc=$RC)"
has "$O" "^ERROR: t.tsv: line 2 holds 0x00, $M7\$" "  ...rsk's words, naming the line and the byte"
reset; approved "#@ allow launch errors=0 fail-stop" "a fx-slurm - $ROW" "b fx-slurm - $ROW"
q "1000|a|RUNNING|None|0|$NOW|$P|" "1001|b|RUNNING|None|0|$NOW|$P|"; rw t.tsv --once --act --max-active 2 --adopt a=1000 --adopt b=1001 >/dev/null
printf '%b\n' '#@ run-watch v1' '#@ allow launch errors=0 fail\0-stop' "$(grep '^#@ ok' "$P/t.tsv")" "a fx-slurm - $ROW" "b fx-slurm - $ROW" > "$P/t.tsv"
q "1001|b|RUNNING|None|0|$NOW|$P|"; acct "1000|a|FAILED|1:0|$P"; : > "$WORLD/ssh.log"; O=$(rw t.tsv --once --act --max-active 2); RC=$?
[ "$RC" = 2 ] && [ ! -s "$WORLD/ssh.log" ] && [ ! -s "$WORLD/scancel.log" ] && ok "  ...that NUL put into an approved table: --act refused before any ssh, b never cancelled (74b15fb cancelled it)" \
  || bad "  ...approved table + NUL: rc=$RC scancel=$(cat "$WORLD/scancel.log" 2>/dev/null)"
reset; q; printf '%b\n' '#@ run-watch v1' '#@ allow launch' "a\0 fx-slurm - $ROW" > "$P/t.tsv"; O=$(rw t.tsv --approve go); RC=$?
[ "$RC" = 2 ] && [ "$(grep -ac '^#@ ok' "$P/t.tsv")" = 0 ] && has "$O" "line 3 holds 0x00, " "a row 'a<NUL>' (bash: a; rsk: 'a\\x00', missing a deny of a): --approve refused" || bad "NUL in a row name (rc=$RC)"
O=$(rw t.tsv --once --act --max-active 1); RC=$?; [ "$RC" = 2 ] && [ "$(nsub)" = 0 ] && ok "  ...--act refused, 0 sbatch" || bad "  ...--act (rc=$RC, $(nsub) sbatch)"
for c in '1 0x0d CRLF line ends@crlf' '3 0x01 a ^A in a comment@# note \001' '3 0x0b a vertical tab in a comment (rsk would split the line there)@# x\013#@ allow launch fail-stop' \
         '3 0x0c a form feed@# x\014' '3 0x1b an ESC@# \033[2J' '3 0x1c a file separator@# x\034y' '3 0x7f a DEL@# x\177' '2 0x1f a unit separator after the allow words@#@ allow launch \037'; do
  w=${c%%@*}; l=${c#*@}; reset; q
  case "$w:$l" in *:crlf) printf '%b\r\n' '#@ run-watch v1' '#@ allow launch' "a fx-slurm - $ROW" ;; 2\ *) printf '%b\n' '#@ run-watch v1' "$l" "a fx-slurm - $ROW" ;;
    *) printf '%b\n' '#@ run-watch v1' '#@ allow launch' "$l" "a fx-slurm - $ROW" ;; esac > "$P/t.tsv"
  O=$(rw t.tsv --approve go); RC=$?; w=${w#* }; h=${w%% *}
  [ "$RC" = 2 ] && [ "$(grep -ac '^#@ ok' "$P/t.tsv")" = 0 ] && has "$O" "line ${c%% *} holds $h, " "${w#* }: refused (exit 2), nothing written" || bad "${w#* } (rc=$RC)"
done
reset; q; printf '#@ run-watch v1\n#@ allow launch\na\tfx-slurm -\t%s\n' "$ROW" > "$P/t.tsv"; O=$(rw t.tsv --approve go); RC=$?; O=$(rw t.tsv --once --act --max-active 1)
[ "$RC" = 0 ] && printf '%s\n' "$O" | grep -q 'LAUNCH name=a ' && ok "a tab is not refused (it separates a row's fields, as before)" || bad "a table with tabs (rc=$RC)"
reset; q; table "#@ allow launch" "a fx-slurm - $ROW"; cp "$P/t.tsv" "$T/t7"
for w in 'an ESC@go\033[2J ahead' 'a CR@go\rahead' 'a ^A@go\001'; do O=$(rw t.tsv --approve "$(printf '%b' "${w#*@}")"); RC=$?
  [ "$RC" = 2 ] && cmp -s "$P/t.tsv" "$T/t7" && ok "--approve words holding ${w%%@*}: refused (exit 2), nothing written" || bad "--approve words holding ${w%%@*} (rc=$RC)"; done
O=$(rw t.tsv --approve "$(printf 'go\tahead')"); [ "$?" = 0 ] && grep -q '^#@ ok .* "go	ahead"$' "$P/t.tsv" && ok "  ...a tab in them is not" || bad "  ...--approve words with a tab"
reset; q; table "#@ allow launch" "# 中文注释：先跑 a" "a fx-slurm - $ROW"; O=$(rw t.tsv --approve "可以，跑吧"); RC=$?   # UTF-8: bytes >= 0x80, never control
[ "$RC" = 0 ] && grep -q '^#@ ok .* "可以，跑吧"$' "$P/t.tsv" && [ "$(rw t.tsv --once >/dev/null; echo $?)" = 4 ] && ok "  ...nor UTF-8 text (the user's words, a comment): approved and read" || bad "  ...UTF-8 words / comment (rc=$RC)"
reset; approved "#@ allow launch" "a fx-slurm - $ROW"; q; wstep 1 "1000|a|RUNNING|None|0|$NOW|$P|"
cat >> "$WORLD/step1.sh" <<'EOS'
printf '# edited\0 during the watch\n' >> t.tsv
EOS
O=$(rwm t.tsv --act --max-active 1 --every 60); RC=$?
has "$O" 'LAUNCH name=a .*job=1000' "a watch: round 1 launches a"; [ "$RC" = 2 ] && has "$O" "^ERROR: t.tsv: line 5 holds 0x00, $M7\$" "  ...a NUL written into the table during the watch: refused at the next read (exit 2)" || bad "  ...mid-watch NUL (rc=$RC)"
[ ! -d "$P/logs/run-watch/.lock" ] && [ "$(nsub)" = 1 ] && ok "  ...one sbatch, the lock released" || bad "  ...$(nsub) sbatch, lock $(ls -d "$P/logs/run-watch/.lock" 2>/dev/null)"
