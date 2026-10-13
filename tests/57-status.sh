#!/usr/bin/env bash
# tests/57-status.sh — phase A: remote/status.sh (the agent's one bounded monitoring read) on both fixture kinds:
# squeue → sacct → unknown fallbacks (each labelled with why), harness markers (starts/restart/footer; trainer lines
# that merely contain `target=` are not headers), byte-bounded window (a CR progress-bar log where `tail -n 60`
# would return the whole file), hint counts before display truncation (a cut is marked `…`), wandb URL from the head
# (any host), symlinked / FIFO / unreadable / ambiguous logs, ckpt_entry, -n deep read, nohup PID alive / reused-or-skew /
# gone / missing / ps failure, argument errors. Run by selftest.sh:  bash tests/57-status.sh
# Live facts behind the stubs (a production Slurm 25.05.8 cluster, 2026-09-11): `squeue -h -j ID --Format='State:0|,…'` prints one
# unpadded `|`-separated row; `squeue -h -j <unknown>` = rc 1 + "slurm_load_jobs error: Invalid job id specified";
# `sacct -j ID -X -n -P -o State,ExitCode,Elapsed,End` = `CANCELLED by <uid>|0:0|00:09:40|2026-07-23T15:59:02` (no
# trailing `|`); `ps -o etimes=` exists on the workstations. status.sh itself targets Linux (GNU stat, procps).
set -u
. "$RS_HOME/tests/lib.sh"
if ! stat -c %s /dev/null >/dev/null 2>&1 || ! ps -o etimes= -p $$ >/dev/null 2>&1; then
  ok "SKIP 57-status: status.sh is a Linux remote script (needs GNU stat + procps etimes)"; exit 0; fi
mkdir -p "$T/bin"
cat > "$T/bin/squeue" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" 42 "*) echo "RUNNING|None|00:10:00|1-00:00:00|0|n1" ;; *" 45 "*) echo "slurm_load_jobs error: Unable to contact slurm controller (connect failure)" >&2; exit 1 ;;
                *" 46 "*) echo "squeue: warning: something harmless" >&2; echo "PENDING|Priority|0:00|2:00:00|0|" ;;
                *" 47 "*) exit 1 ;; *" 48 "*) echo "garbage" ;; *" 49 "*) echo "banner: cluster notice"; echo "RUNNING|None|00:02:00|1:00:00|1|n3" ;; *" 50 "*) : ;;
                *" 55 "*) echo "maintenance|window|at|noon|not|set" ;;
                *) echo "slurm_load_jobs error: Invalid job id specified" >&2; exit 1 ;; esac
EOF
cat > "$T/bin/sacct" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$T/sacct.args"
case " \$* " in
  *" 43 "*) echo "FAILED|1:0|00:09:40|2026-09-11T10:00:00" ;;
  *" 45 "*) echo "RUNNING|0:0|00:01:00|Unknown" ;;
  *" 51 "*) echo "COMPLETED|0:0|00:01:00|2026-09-11T10:00:00"; exit 1 ;;
  *" 52 "*) echo "service unavailable"; exit 1 ;;
  *" 53 "*) echo "garbage|not-an-exit|0|Unknown" ;;
  *" 54 "*) echo "banner: cluster notice"; echo "CANCELLED by 123|0:15|00:01:00|2026-09-11T10:00:00" ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/squeue" "$T/bin/sacct"
st() { PATH="$T/bin:$PATH" bash "$1/.$2/status.sh" "${@:3}" 2>&1; }
mkdir -p "$T/failbin"   # grep / stat that fail (exit 2 / 1) only for the argument named in RS_GREPFAIL / RS_STATFAIL
printf '#!/usr/bin/env bash\nif [ -n "${RS_GREPFAIL:-}" ]; then case " $* " in *"$RS_GREPFAIL"*) echo "grep: memory exhausted" >&2; exit 2 ;; esac; fi\nexec %s "$@"\n' "$(command -v grep)" > "$T/failbin/grep"
printf '#!/usr/bin/env bash\nif [ -n "${RS_STATFAIL:-}" ]; then case " $* " in *"$RS_STATFAIL"*) echo "stat: cannot statx" >&2; exit 1 ;; esac; fi\nexec %s "$@"\n' "$(command -v stat)" > "$T/failbin/stat"
chmod +x "$T/failbin/grep" "$T/failbin/stat"
ste() { local e=$1 p=$2 t=$3; shift 3; env "$e" PATH="$T/failbin:$T/bin:$PATH" bash "$p/.$t/status.sh" "$@" 2>&1; }
tail_count() { local got; got=$(printf '%s\n' "$O" | grep -c '^tail: ')
  if [ "$got" -eq "$1" ]; then ok "$2"; else bad "$2 (expected $1, got $got)"; printf '%s\n' "$O" | head -n 15 | sed 's/^/    | /'; fi; }
age() { local when=$(( $(date +%s) - $2 )); touch -d "@$when" "$1" 2>/dev/null || touch -t "$(date -r "$when" +%Y%m%d%H%M.%S)" "$1"; }   # age FILE SECONDS (GNU, else BSD)
sparse() { dd if=/dev/null of="$1" bs=1 seek="$2" 2>/dev/null; }                                                                     # sparse FILE BYTES (portable truncate)
rewrite() { local f=$1; shift; sed "$@" "$f" > "$f.new" && mv "$f.new" "$f"; }                                                        # rewrite FILE SED-ARGS (no sed -i)

J=$(mk_proj fx-slurm 'REMOTE_DIR=/x') || { bad "mk_proj fx-slurm"; exit 1; }
mkdir -p "$J/logs" "$J/ckpts/run"
L="$J/logs/run_42.out"
{ echo "[Thu Sep 11 10:00:00 2026] target=fx-slurm job=42 restart=0 node=n1 cpus=4 gpus=0"; echo "RUN: python train.py"
  echo "wandb: View run at https://wandb.ai/me/proj/runs/abc123"
  for i in $(seq 1 6000); do printf '  %d%%|          | %d/2000000 [06:56<10:28:00, 52.19it/s]\r' $((i/60)) $((i*5)); done; echo
  printf 'step 1200 loss=nan lr=1e-4\n'; printf '\033[31mERROR\033[0m painted red\n'
  printf 'Traceback (most recent call last):\n  File "x.py", line 1\nRuntimeError: CUDA out of memory. Tried to allocate 20 GiB\n'
  echo "[Thu Sep 11 10:09:40 2026] EXIT rc=1 usr1=0 term=0 job=42 restart=0"; } > "$L"
cp "$L" "$J/logs/run_43.out"
touch "$J/ckpts/run/step_100.pt"; age "$J/ckpts/run/step_100.pt" 600; touch "$J/ckpts/run/step_200.pt"
[ "$(tail -n 60 "$L" | wc -c)" -gt 200000 ] && ok "fixture: tail -n 60 of the CR log returns the whole file (the problem)" || bad "fixture: CR log shape"

echo "-- slurm: running job, big CR log, ckpt dir --"
O=$(st "$J" fx-slurm 42 ckpts/run); RC=$?
[ "$RC" = 0 ] && ok "status.sh exits 0" || bad "status.sh exits 0 (rc=$RC)"
has "$O" '^job=42 state=RUNNING reason=None elapsed=00:10:00 left=1-00:00:00 restarts=0 nodes=n1$' "squeue line parsed into fields"
has "$O" "^log=$J/logs/run_42.out bytes=[0-9]* age=[0-9]*s$" "log found from the job id (logs/*_<jobid>.out), size + age"
has "$O" '^starts=1 restart=0 footer=EXIT rc=1 usr1=0 term=0 job=42 restart=0$' "start count + footer from the harness markers"
has "$O" '^scan=partial (last 262144 of [0-9]* bytes) hints: traceback=1 oom=1 nonfinite=1 error=2' "window-scoped hint counts, coverage=partial"
has "$O" '^last_hint=RuntimeError: CUDA out of memory' "last_hint = the last matching line"
has "$O" '^wandb=https://wandb.ai/me/proj/runs/abc123' "wandb URL found in the file head although outside the window"
has "$O" '^tail: ERROR painted red$' "ANSI colour stripped from a displayed line"
has "$O" '^tail: \[Thu Sep 11 10:09:40 2026\] EXIT rc=1' "last line displayed"
has "$O" "^ckpt_entry=step_200.pt age=[0-9]*s dir=$J/ckpts/run resume=unverified$" "newest entry + age, resume remains unverified"
tail_count 5 "5 tail lines by default"
n=$(printf %s "$O" | wc -c); [ "$n" -le 2048 ] && ok "digest is bounded: $n bytes for a $(wc -c < "$L")-byte log" || bad "digest bounded ($n bytes)"
[ "$(printf %s "$O" | tr -cd '\r' | wc -c)" = 0 ] && ok "no carriage returns in the output" || bad "no carriage returns in the output"
O=$(st "$J" fx-slurm -n 40 42); tail_count 40 "-n 40 = deep read (40 lines)"
[ "$(printf %s "$O" | awk '{ if (length($0) > 206) c++ } END { print c+0 }')" = 0 ] && ok "every displayed line cut to 200 chars" || bad "line cut"
O=$(st "$J" fx-slurm -n 999 42); tail_count 200 "-n is capped at 200"
O=$(trap '' PIPE; st "$J" fx-slurm 42); tail_count 5 "ignored SIGPIPE: exactly 5 log lines"
hasnt "$O" 'Broken pipe\|error writing' "ignored SIGPIPE: no reader diagnostics mixed into the digest"
tl0=$(ls -d "${TMPDIR:-/tmp}"/rs-status.* 2>/dev/null | wc -l); O=$(st "$J" fx-slurm 42); tl1=$(ls -d "${TMPDIR:-/tmp}"/rs-status.* 2>/dev/null | wc -l)
[ "$tl0" = "$tl1" ] && ok "no temp dir left behind" || bad "temp dir leaked in ${TMPDIR:-/tmp} ($tl0 -> $tl1)"
ln -s "$L" "$J/logs/link_42.out"; mv "$L" "$T/real_42.out"; ln -sf "$T/real_42.out" "$L"; rm -f "$J/logs/link_42.out"
O=$(st "$J" fx-slurm 42); has "$O" "^log=$J/logs/run_42.out bytes=$(wc -c < "$T/real_42.out") " "a symlinked log reports the target's size, not the link's"
has "$O" '^scan=partial' "…so the window gates use the real size"; mv "$T/real_42.out" "$L"
age "$J/ckpts/run/step_200.pt" 60; printf 'incomplete' > "$J/ckpts/run/step_300.pt.tmp"
O=$(st "$J" fx-slurm 42 ckpts/run); has "$O" '^ckpt_entry=step_300.pt.tmp .*resume=unverified$' "a temporary save is directory activity, never certified resumable"
O=$(st "$J" fx-slurm 42 ckpts/missing); has "$O" '^ckpt_entry=none (no dir ' "missing checkpoint dir"
mkdir -p "$J/ckpts/empty"; O=$(st "$J" fx-slurm 42 ckpts/empty); has "$O" '^ckpt_entry=none (empty ' "empty checkpoint dir"

echo "-- slurm: gone from squeue -> sacct; nowhere -> unknown; no log yet --"
O=$(st "$J" fx-slurm 43)
has "$O" '^job=43 state=FAILED exit=1:0 elapsed=00:09:40 end=2026-09-11T10:00:00 (sacct; gone from the queue)$' "sacct fallback when squeue has no record"
has "$(cat "$T/sacct.args")" '^-j 43 -X -n -P -o State,ExitCode,Elapsed,End$' "sacct is asked for -X -n -P and exactly these columns (the row regex depends on it)"
O=$(st "$J" fx-slurm 45)
has "$O" '^job=45 state=RUNNING exit=0:0 elapsed=00:01:00 end=Unknown (sacct; squeue FAILED (exit 1: slurm_load_jobs error: Unable to contact' "a squeue failure is reported as such, never as the job being gone"
O=$(st "$J" fx-slurm 46); has "$O" '^job=46 state=PENDING reason=Priority elapsed=0:00 left=2:00:00 restarts=0 nodes=none$' "a stderr warning next to a valid row does not corrupt the row"
O=$(st "$J" fx-slurm 47); has "$O" '^job=47 state=unknown (squeue FAILED (exit 1); sacct has no record)$' "a silent nonzero squeue is a failure, not an absence"
O=$(st "$J" fx-slurm 48); has "$O" '^job=48 state=unknown (unparsable squeue output, queue state unverified; sacct has no record)$' "unparsable stdout is never presented as absence"
O=$(st "$J" fx-slurm 49); has "$O" '^job=49 state=RUNNING reason=None elapsed=00:02:00 left=1:00:00 restarts=1 nodes=n3$' "a banner before the row: the row-shaped line is the one parsed"
O=$(st "$J" fx-slurm 50); has "$O" '^job=50 state=unknown (not in the queue; sacct has no record)$' "a clean empty squeue answer = not in the queue"
O=$(st "$J" fx-slurm 55); has "$O" '^job=55 state=unknown (unparsable squeue output' "a six-field banner is not a row (state word + restart count validated)"
for id in 51 52; do O=$(st "$J" fx-slurm "$id"); has "$O" "^job=$id state=unknown .*sacct FAILED (exit 1)" "sacct exit 1: stdout cannot certify a state ($id)"; done
O=$(st "$J" fx-slurm 53); has "$O" '^job=53 state=unknown .*unparsable sacct output' "malformed accounting fields stay unknown"
O=$(st "$J" fx-slurm 54); has "$O" '^job=54 state=CANCELLED by 123 exit=0:15 elapsed=00:01:00' "valid accounting row after a banner"
O=$(st "$J" fx-slurm 44)
has "$O" '^job=44 state=unknown (gone from the queue; sacct has no record)$' "unknown when neither squeue nor sacct answers"
has "$O" '^log=none (logs/<name>_44.out appears when the job starts)$' "no log yet is said, not guessed"
printf 'https://wandb.ai/me/p/runs/only' > "$J/logs/url_only.out"; O=$(st "$J" fx-slurm logs/url_only.out)
has "$O" '^wandb=https://wandb.ai/me/p/runs/only (wandb' "head and window regions are not spliced (URL-only file, no newline)"
has "$O" '^starts=0 footer=none (no harness marker: not started' "a slurm log without a header says so instead of printing nothing"
printf 'wandb: View run at https://wandb.mylab.edu/team/p/runs/self1).\n' > "$J/logs/self.out"; O=$(st "$J" fx-slurm logs/self.out)
has "$O" '^wandb=https://wandb.mylab.edu/team/p/runs/self1 (wandb' "a self-hosted run URL is found, trailing punctuation dropped"
{ echo "[Fri Sep 11 10:00:00 2026] target=fx-slurm job=5 restart=0 node=n1 cpus=4 gpus=0"; } > "$J/logs/run_5.out"; sparse "$J/logs/run_5.out" 70000000
O=$(st "$J" fx-slurm logs/run_5.out); has "$O" '^starts=unknown (no harness marker in the last 64 MiB)$' "marker scan is bounded: a header beyond 64 MiB is reported unknown, not read"
echo "[Fri Sep 11 10:09:40 2026] EXIT rc=0 usr1=0 term=0 job=5 restart=0" >> "$J/logs/run_5.out"; O=$(st "$J" fx-slurm logs/run_5.out)
has "$O" '^starts_in_last_64MiB=0 restart=? footer=EXIT rc=0 usr1=0 term=0 job=5 restart=0$' "header outside the window: the count is labelled window-scoped, restart unknown"
# head-boundary fixtures: > 256 KiB of filler AFTER the URL keeps it out of the tail window, so only the head logic sees it
filler() { yes 'filler line with nothing of interest' | head -c 300000; }
{ head -c $(( 65536 - 32 )) /dev/zero | tr '\0' 'x'; printf 'https://wandb.ai/me/p/runs/edge\n'; filler; } > "$J/logs/edge.out"
[ "$(head -c 65536 "$J/logs/edge.out" | tail -c 1 | od -An -c | tr -d ' ')" = '\n' ] && ok "fixture: URL line ends exactly at byte 65536" || bad "fixture: boundary URL"
O=$(st "$J" fx-slurm logs/edge.out); has "$O" '^wandb=https://wandb.ai/me/p/runs/edge (wandb' "a complete line ending exactly at the head boundary is kept"
{ head -c $(( 65536 - 28 )) /dev/zero | tr '\0' 'x'; printf 'https://wandb.ai/me/p/runs/edge\n'; filler; } > "$J/logs/edge2.out"   # byte 65536 = the 'e' of edge
O=$(st "$J" fx-slurm logs/edge2.out); has "$O" '^wandb=none' "a URL cut mid-run-id by the head boundary is dropped, not reported as …/runs/e"
{ echo "[Fri Sep 11 10:00:00 2026] target=fx-slurm job=7 restart=0 node=n1 cpus=4 gpus=0"; echo "[Fri Sep 11 10:09:40 2026] EXIT rc=143 usr1=0 term=1 job=7 restart=0"
  echo "[Fri Sep 11 10:00:00 2026] target=fx-slurm job=7 restart=1 node=n2 cpus=4 gpus=0"; echo "RUN: python train.py"; echo "resumed from ckpts/run/step_200.pt"
  echo "[step 10] target=0.5 loss=0.4"; echo "[eval] EXIT rc=abc"
  echo "INFO cmdline: [Thu] target=fx-slurm job=7 restart=9 node=n1 cpus=4"
  echo "[step 1000] target=fx-slurm job=7 restart=9 node=n1 cpus=4"; } > "$J/logs/run_7.out"   # trainers echoing the header grammar without a timestamp
O=$(st "$J" fx-slurm logs/run_7.out)
has "$O" '^starts=2 restart=1 footer=none (start open' "requeued log: 2 headers, 1 footer -> the second start is open; trainer lines with target=/EXIT rc=, or without the harness timestamp, are not markers"
has "$O" '^scan=full hints: traceback=0 oom=0 nonfinite=0 error=0' "small log: coverage=full, no hints"
has "$O" '^wandb=none' "no URL -> wandb=none"; has "$O" "^log=$J/logs/run_7.out " "a relative log path resolves under the project dir"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$J/logs/run_7.out"; O=$(st "$J" fx-slurm logs/run_7.out); RC=$?; chmod 644 "$J/logs/run_7.out"
  has "$O" '^starts=unknown scan=unknown wandb=unknown (log read FAILED: ' "an unreadable log is a failed read, not zero hints"
  hasnt "$O" '^scan=full\|^tail: ' "…no hint counts or tail lines are invented"; [ "$RC" = 0 ] && ok "digest still exits 0 (the failure is in the text)" || bad "exit on unreadable log (rc=$RC)"
else ok "SKIP unreadable-log check (running as root)"; fi
{ echo "[Fri Sep 11 10:00:00 2026] target=fx-slurm job=8 restart=0 node=n1 cpus=4 gpus=0"; echo "[Fri Sep 11 10:00:00 2026] target=fx-slurm job=8 restart=1 node=n2 cpus=4 gpus=0"
  echo "[Fri Sep 11 10:09:40 2026] EXIT rc=0 usr1=0 term=0 job=8 restart=1"; } > "$J/logs/run_8.out"
O=$(st "$J" fx-slurm logs/run_8.out)
has "$O" '^starts=2 restart=1 footer=EXIT rc=0 usr1=0 term=0 job=8 restart=1$' "first start killed without a footer, second completed -> closed (last marker decides)"
{ echo "[Fri Sep 11 10:00:00 2026] target=fx-slurm job=9 restart=0 node=n1 cpus=4 gpus=0"; echo "wandb: View run at https://wandb.ai/me/p/runs/zz9"
  for i in $(seq 1 3000); do printf '  %d%%|          | %d/2000 [00:56<00:28, 52it/s]\r' $((i/30)) "$i"; done   # no newline: the footer lands on the progress line
  echo "[Fri Sep 11 10:09:40 2026] EXIT rc=0 usr1=1 term=0 job=9 restart=0"; } > "$J/logs/run_9.out"
O=$(st "$J" fx-slurm logs/run_9.out)
has "$O" '^starts=1 restart=0 footer=EXIT rc=0 usr1=1 term=0 job=9 restart=0$' "a footer glued to a CR progress line is reported clean"
has "$O" '^wandb=https://wandb.ai/me/p/runs/zz9 (wandb' "URL followed by CR progress text is cut at the CR"
n=$(printf %s "$O" | wc -c); [ "$n" -le 2048 ] && ok "digest still bounded with a glued URL ($n bytes)" || bad "digest bounded with a glued URL ($n bytes)"
{ printf '[Fri Sep 11 10:00:00 2026] target=%s job=10 restart=123 node=n1\n' "$(head -c 250 /dev/zero | tr '\0' 't')"; printf 'a %s b\n' "$(head -c 300 /dev/zero | tr '\0' 'z')"; } > "$J/logs/run_10.out"
O=$(st "$J" fx-slurm logs/run_10.out); has "$O" '^starts=1 restart=123 footer=none' "a long target name: the anchored marker keeps restart= intact (mandatory part is never clipped)"
has "$O" '^tail: a z*…$' "a cut display line carries the … marker"
mkfifo "$J/logs/fifo.out"; O=$(st "$J" fx-slurm logs/fifo.out); has "$O" "^log=not-a-regular-file ($J/logs/fifo.out)$" "a FIFO is named for what it is, never read"
{ echo "[Fri Sep 11 10:00:00 2026] target=fx-slurm job=60 restart=0 node=n1 cpus=4 gpus=0"; echo "mine"; } > "$J/logs/a_60.out"
{ echo "[Fri Sep 11 10:00:00 2026] target=other job=60 restart=0 node=n1 cpus=4 gpus=0"; echo "theirs"; } > "$J/logs/b_60.out"
O=$(st "$J" fx-slurm 60); has "$O" "^log=$J/logs/a_60.out " "two logs for one job id: the header naming THIS target wins"
rewrite "$J/logs/a_60.out" 's/target=fx-slurm/target=other/'; O=$(st "$J" fx-slurm 60)
has "$O" '^log=ambiguous (2 files match logs/\*_60.out' "…and with no such header the match is ambiguous, not the newest file"
{ echo "[Fri Sep 11 10:00:00 2026] target=other job=61 restart=0 node=n1 cpus=4 gpus=0"; } > "$J/logs/x_61.out"; O=$(st "$J" fx-slurm 61)
has "$O" "^log=ambiguous (logs/\*_61.out belongs to target 'other', not 'fx-slurm')" "a single log whose header names another target is refused"
mkfifo "$J/logs/a_62.out"; { echo "[Fri Sep 11 10:00:00 2026] target=fx-slurm job=62 restart=0 node=n1 cpus=4 gpus=0"; } > "$J/logs/b_62.out"
O=$(timeout 5 bash -c 'PATH="$1:$PATH" bash "$2/.fx-slurm/status.sh" 62 2>&1' _ "$T/bin" "$J"); RC=$?
[ "$RC" = 0 ] && has "$O" "^log=$J/logs/b_62.out " "a FIFO among the job-id matches is skipped, the regular log is used (no hang)" || bad "FIFO among matches (rc=$RC)"
printf 'see https://github.com/org/repo/actions/runs/123456 for CI\n' > "$J/logs/gh.out"; O=$(st "$J" fx-slurm logs/gh.out)
has "$O" '^wandb=none' "a /runs/ URL on a non-wandb line (GitHub Actions) is not a run URL"
printf 'clone https://github.com/wandb/wandb/actions/runs/123456 please\n' > "$J/logs/gh2.out"; O=$(st "$J" fx-slurm logs/gh2.out)
has "$O" '^wandb=none' "…nor one whose URL merely contains the word wandb"
if [ "$(id -u)" != 0 ]; then
  { echo "[Fri Sep 11 10:00:00 2026] target=other job=63 restart=0 node=n1 cpus=4 gpus=0"; } > "$J/logs/a_63.out"; : > "$J/logs/b_63.out"; chmod 000 "$J/logs/b_63.out"
  O=$(st "$J" fx-slurm 63); chmod 644 "$J/logs/b_63.out"
  has "$O" '^log=ambiguous (a candidate logs/\*_63.out could not be read' "an unreadable candidate is never assumed headerless"
  { echo "[Fri Sep 11 10:00:00 2026] target=fx-slurm job=64 restart=0 node=n1 cpus=4 gpus=0"; echo "[Fri Sep 11 10:09:40 2026] EXIT rc=0 usr1=0 term=0 job=64 restart=0"; } > "$J/logs/a_64.out"
  { echo "[Fri Sep 11 10:00:00 2026] target=fx-slurm job=64 restart=0 node=n2 cpus=4 gpus=0"; } > "$J/logs/b_64.out"; chmod 000 "$J/logs/b_64.out"
  O=$(st "$J" fx-slurm 64); chmod 644 "$J/logs/b_64.out"
  has "$O" '^log=ambiguous (a candidate logs/\*_64.out could not be read' "one readable match does not override an unreadable candidate of the same target"
  hasnt "$O" 'footer=EXIT rc=0' "…so the older attempt's footer is never reported as this run's"
else ok "SKIP unreadable-candidate checks (running as root)"; fi
O=$(ste 'RS_GREPFAIL=EXIT rc=' "$J" fx-slurm logs/run_42.out); has "$O" '^starts=unknown (marker read FAILED (exit 2): grep: memory exhausted)$' "a failing marker grep (exit 2) is reported, not read as 'no markers'"
O=$(ste 'RS_GREPFAIL=runs/' "$J" fx-slurm logs/run_42.out); has "$O" '^wandb=unknown (URL scan FAILED (exit 2): grep: memory exhausted)$' "a failing URL grep (exit 2) is reported, not read as 'no URL'"
has "$O" '^scan=partial' "…and the rest of the digest still reports what it did read"
O=$(ste 'RS_STATFAIL=run_42.out' "$J" fx-slurm logs/run_42.out)
has "$O" '^log=.*bytes=unknown age=unknown (stat failed)$' "a failing stat says unknown instead of bytes=0 age=0"
has "$O" '^starts=unknown scan=unknown wandb=unknown (log read FAILED' "…and no markers, hints or URL are reported for a log it could not measure"
hasnt "$O" '^scan=full\|^tail: ' "…nor a full-coverage claim"
O=$(ste 'RS_TMP_UNUSED=1' "$J" fx-slurm 42); has "$O" '^job=42 state=RUNNING' "the failure stubs are inert without their env var"
O=$(TMPDIR=/nonexistent/nope PATH="$T/bin:$PATH" bash "$J/.fx-slurm/status.sh" 42 2>&1); RC=$?
[ "$RC" = 0 ] && has "$O" '^job=42 state=RUNNING' "an unusable inherited TMPDIR falls back to /tmp instead of killing the digest" || bad "unusable TMPDIR (rc=$RC)"
has "$O" '^starts=1 restart=0 footer=EXIT rc=1' "…and the digest is complete"
mkdir -p "$T/nosearch"; chmod 600 "$T/nosearch"   # writable but not searchable: the check passes, mktemp still fails
O=$(TMPDIR="$T/nosearch" PATH="$T/bin:$PATH" bash "$J/.fx-slurm/status.sh" 42 2>&1); RC=$?; chmod 755 "$T/nosearch"
[ "$RC" = 0 ] && has "$O" '^starts=1 restart=0 footer=EXIT rc=1' "a writable-but-unsearchable TMPDIR still falls back to /tmp" || bad "unsearchable TMPDIR (rc=$RC)"

echo "-- nohup: PID states --"
W=$(mk_proj ws-box 'WS_REMOTE_DIR=projects/y') || { bad "mk_proj ws-box"; exit 1; }
mkdir -p "$W/logs"; NL="$W/logs/t-20260911-100000.log"; printf 'step 1 loss=0.9\nstep 2 loss=0.8\n' > "$NL"
sleep 300 & SP=$!; echo "$SP" > "$NL.pid"
O=$(st "$W" ws "$NL"); has "$O" "^proc=alive pid=$SP etime=[0-9]*s cpu=[0-9.]*% cmd=sleep 300$" "live pid from <log>.pid -> alive + cmd"
hasnt "$O" '^starts=' "nohup log: no harness marker line"; has "$O" '^tail: step 2 loss=0.8$' "nohup: last line displayed"
age "$NL.pid" 8; O=$(st "$W" ws "$NL"); has "$O" "^proc=alive pid=$SP " "a pid file a few seconds older than the process is clock noise, still alive"
age "$NL.pid" 120; O=$(st "$W" ws "$NL"); has "$O" "^proc=unknown pid=$SP (that process is [0-9]s old but the launch was 1[0-9][0-9]s ago: reused pid or clock skew)$" "a process much younger than the launch = reused pid OR skew: unknown, never gone"
has "$(cat "$RS_HOME/remote/status.sh")" 'cannot stat $LOG.pid' "an unstat-able pid file cannot certify alive (branch present)"
mkdir -p "$T/psfail"; printf '#!/usr/bin/env bash\necho "ps: cannot access /proc" >&2; exit 2\n' > "$T/psfail/ps"; chmod +x "$T/psfail/ps"
O=$(PATH="$T/psfail:$T/bin:$PATH" bash "$W/.ws/status.sh" "$NL" 2>&1); has "$O" '^proc=unknown (ps FAILED or unparsable (exit 2: ps: cannot access /proc))$' "a failing ps is a failed query, never proc=gone"
printf '#!/usr/bin/env bash\necho "     12 S    0.0 sleep 300"; exit 1\n' > "$T/psfail/ps"
O=$(PATH="$T/psfail:$T/bin:$PATH" bash "$W/.ws/status.sh" "$NL" 2>&1); has "$O" '^proc=unknown (ps FAILED or unparsable (exit 1))$' "a row with exit 1 is not trusted as alive"
printf '#!/usr/bin/env bash\necho "weird"\n' > "$T/psfail/ps"
O=$(PATH="$T/psfail:$T/bin:$PATH" bash "$W/.ws/status.sh" "$NL" 2>&1); has "$O" '^proc=unknown (ps FAILED or unparsable (exit 0))$' "a short ps row never reaches the field parser (set -u safe)"
W2=$(mk_proj ws-box 'WS_REMOTE_DIR=projects/z'); mkdir -p "$W2/logs"; cp "$NL" "$W2/logs/u.log"; echo "$SP" > "$W2/logs/u.log.pid"
rewrite "$W2/.ws/profile.sh" 's/^T_KIND=nohup;/   export T_KIND=nohup;/'; O=$(st "$W2" ws logs/u.log)
has "$O" "^proc=alive pid=$SP " "an indented / exported T_KIND line is still the kind"; hasnt "$O" 'no usable T_KIND' "…and not reported unknown"
has "$O" '^target=ws-box kind=nohup$' "the digest always names the target and kind it used"
W3=$(mk_proj ws-box 'WS_REMOTE_DIR=projects/q'); mkdir -p "$W3/logs"; printf 'step 1 loss=0.9\n' > "$W3/logs/u.log"
rewrite "$W3/.ws/profile.sh" "s/^T_KIND=nohup;/T_KIND='nohup extra';/"; O=$(st "$W3" ws logs/u.log)
has "$O" '^target=ws-box kind=unknown (no usable T_KIND in ' "a quoted profile value is read whole, not truncated into a valid one"
rewrite "$W3/.ws/profile.sh" "s/^T_NAME='ws-box'\$/T_NAME='ws box'/"; O=$(st "$W3" ws logs/u.log)
has "$O" '^target=unknown kind=unknown ' "…same for a quoted T_NAME with a space"
rewrite "$W2/.ws/profile.sh" 's/^ *export T_KIND=nohup; //'; O=$(st "$W2" ws logs/u.log)
has "$O" '^target=ws-box kind=unknown (no usable T_KIND in ' "a profile without T_KIND is said"; has "$O" "^proc=alive pid=$SP " "…and the pid file is still inspected on evidence"
touch "$NL.pid"; rm -f "$NL"; O=$(st "$W" ws "$NL"); has "$O" "^log=none ($NL)$" "missing log is said"; has "$O" "^proc=alive pid=$SP " "…and the pid is still inspected"
hasnt "$O" '^tail: ' "no tail lines without a log"; printf 'step 1 loss=0.9\nstep 2 loss=0.8\n' > "$NL"
printf '12\000345\n' > "$NL.pid"; O=$(st "$W" ws "$NL"); has "$O" '^proc=unknown (unreadable ' "a NUL inside the pid file -> unknown (raw bytes checked before the shell strips NUL)"
head -c 1048576 /dev/zero | tr '\0' '7' > "$NL.pid"; O=$(st "$W" ws "$NL"); has "$O" '^proc=unknown (unreadable ' "a 1 MiB newline-free pid file -> unknown after a 65-byte read"
for bad_pid in '' 'broken: 12345' '0' '12345678901' '10 32281' "12345$(printf '%70s' '')junk" "$SP
9"; do printf '%s\n' "$bad_pid" > "$NL.pid"; O=$(st "$W" ws "$NL")
  case "$bad_pid" in "$SP"*) has "$O" "^proc=alive pid=$SP " "pid file: first line wins" ;;
    *) has "$O" '^proc=unknown (unreadable ' "pid file '$(printf %s "$bad_pid" | head -c 12)' -> unknown, never a manufactured identity" ;; esac
done; echo "$SP" > "$NL.pid"
kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
O=$(st "$W" ws "$NL"); has "$O" "^proc=gone pid=$SP exit=unknown (nothing records a nohup exit" "dead pid -> gone, exit unknown (never invented)"
rm -f "$NL.pid"; O=$(st "$W" ws "$NL"); has "$O" "^proc=unknown (no $NL.pid)$" "no pid file -> proc=unknown"
O=$(st "$W" ws logs/nope.log); has "$O" "^log=none ($W/logs/nope.log)$" "missing log named, not invented"

if command -v python3 >/dev/null 2>&1; then   # a real zombie: the child exits, the parent never reaps it
  python3 -c 'import os,sys,time
p = os.fork()
if p == 0: os._exit(0)
print(p); sys.stdout.flush(); time.sleep(30)' > "$T/zpid" & ZP=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/zpid" ] && break; sleep 0.2; done
  Z=$(cat "$T/zpid"); printf '%s\n' "$Z" > "$NL.pid"; O=$(st "$W" ws "$NL")
  has "$O" "^proc=zombie pid=$Z (exited, not reaped)$" "a zombie child is reported as such, not alive"
  kill "$ZP" 2>/dev/null; wait "$ZP" 2>/dev/null
else ok "SKIP zombie fixture (no python3)"; fi
printf '%s\n' "$SP" > "$NL.pid"; printf '12\00034\r\033[31m5\n' > "$NL.pid"
O=$(st "$W" ws "$NL"); has "$O" '^proc=unknown (unreadable ' "control bytes in the pid file -> unknown"
[ "$(printf %s "$O" | tr -cd '\r\033' | wc -c)" = 0 ] && ok "…and the raw bytes never reach the digest" || bad "raw pid bytes reach the digest"

echo "-- usage --"
st "$J" fx-slurm >/dev/null 2>&1; [ $? = 2 ] && ok "no argument -> usage, exit 2" || bad "no argument -> exit 2"
st "$J" fx-slurm "" >/dev/null 2>&1; [ $? = 2 ] && ok "empty argument -> exit 2" || bad "empty argument -> exit 2"
st "$J" fx-slurm 42 ckpts/run extra >/dev/null 2>&1; [ $? = 2 ] && ok "a third argument -> exit 2 (never silently ignored)" || bad "third argument -> exit 2"
O=$(st "$W" ws 12345); [ $? = 2 ] && has "$O" 'nohup target takes the log path' "a job id on a nohup target -> exit 2" || bad "job id on nohup -> exit 2"
O=$(st "$J" fx-slurm 12345_3); [ $? = 2 ] && has "$O" 'array / hetjob id' "an array id -> exit 2 (never reinterpreted as a log path)" || bad "array id -> exit 2"
O=$(st "$J" fx-slurm 42 -n); [ $? = 2 ] && has "$O" 'not a checkpoint dir' "a flag in the ckpt slot -> exit 2" || bad "flag in the ckpt slot -> exit 2"
O=$(st "$J" fx-slurm 042); has "$O" '^job=42 state=RUNNING' "a job id's leading zeros are stripped (squeue and the log glob agree)"
O=$(st "$J" fx-slurm -n 0 42); [ $? = 2 ] && has "$O" 'positive integer' "-n 0 refused" || bad "-n 0 refused"
O=$(st "$J" fx-slurm -n 00 42); [ $? = 2 ] && has "$O" 'positive integer' "-n 00 refused" || bad "-n 00 refused"
O=$(st "$J" fx-slurm -n 007 42); tail_count 7 "-n 007 = 7 lines"
O=$(st "$J" fx-slurm -n 99999999999999999999 42); RC=$?; [ "$RC" = 0 ] && [ "$(printf %s "$O" | grep -c '^tail: ')" -le 200 ] && hasnt "$O" 'integer expression' "an oversized -n is capped, no arithmetic error" || bad "oversized -n (rc=$RC)"
O=$(st "$J" fx-slurm --bogus 42); [ $? = 2 ] && has "$O" "unknown flag '--bogus'" "unknown flag refused" || bad "unknown flag refused"
O=$(timeout 5 bash "$J/.fx-slurm/status.sh" -n 2>&1); RC=$?; [ "$RC" = 2 ] && has "$O" '-n needs a count' "-n without a value exits 2 (no loop)" || bad "-n without a value (rc=$RC)"
O=$(timeout 5 bash "$J/.fx-slurm/status.sh" -n 5 -n 2>&1); RC=$?; [ "$RC" = 2 ] && ok "trailing -n exits 2 (no loop)" || bad "trailing -n (rc=$RC)"
hasnt "$(grep -v "^ *#" "$RS_HOME/remote/status.sh")" 'env\.sh' "status.sh never sources env.sh (read-only, no state)"
has "$(cat "$RS_HOME/remote/status.sh")" '^D=.*W=262144; MW=67108864; HW=65536; CUT=200$' "the documented bounds (256 KiB window, 64 MiB markers, 64 KiB head, 200 chars) are the script's constants"
