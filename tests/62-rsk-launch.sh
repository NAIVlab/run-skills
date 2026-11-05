#!/usr/bin/env bash
# tests/62-rsk-launch.sh — phase A: rsk launch / cancel / watch end to end, the real CLI (python -I, src on the path)
# against the fixture targets with an EXECUTING ssh stub (the "remote" runs here: HOME=$T/home), so the deployed
# submit.sh / launch.sh make the plan and the stub sbatch / scancel / setsid'd runs record what was done. Stub
# squeue/sacct render one jobs table ($T/jobs: id|user|name|state|workdir|comment) in whatever fields are asked.
# Covers: plan -> card + exit 4; --approve -> --rs-expect submit, ledger attempt, approval use; a covering grant;
# a deny (exit 3); warnings a plain grant does not cover (-y only after an approved card with warnings); conf drift
# (exit 6); a sweep under one approval; a superseded / used plan (exit 6); ssh lost -> SUBMIT_UNKNOWN, reconciled by
# rsk status; an old deploy (needs: sync); the local duplicate; relaunch; cancel (identity: name, WorkDir, user);
# nohup: busy GPU never grant-covered, approved card -> --gpu-busy-ok, cancel TERM/KILL; the watch lease. The P3 review
# findings (H1 H2 H3 M1 M3 M4 M5 M6 M7 L2 L3 L4 L5), the round-3 decisions (D1 D3 D5 D6 D8 D9 D10; C-stale-API,
# F-unknown, grants#1/3/4, H1-owner/msg, G-space), the round-4 ones (R4-1 R4-2 R4-4 R4-6 R4-8 R4-15) and the round-5 ones
# (R5-1 R5-4 R5-5 R5-8 R5-9), the round-6 ones (R6-1 R6-4 R6-5 R6-7 R6-8 R6-9), the round-7 ones (R7-1 R7-2 R7-5 R7-6
# R7-7), the round-8 ones (R8-1 R8-2 R8-3) and NF8 (cancel --asked and ranges, a box's launcher WARNINGs never grant-covered,
# the card's unknown source), each end to end.
# Run by selftest.sh with RS_HOME set:  bash tests/62-rsk-launch.sh
set -u
. "$RS_HOME/tests/lib.sh"
PY=${RS_PYTHON:-python3}
if [ -d "$RS_HOME/src/remote_run" ]; then SRC=$RS_HOME/src
elif [ -f "$RS_HOME/../__init__.py" ] && [ -f "$RS_HOME/../cli.py" ]; then SRC=$(cd "$RS_HOME/../.." && pwd)
else SRC=""; fi
if [ "${RS_SKIP_PY:-0}" = 1 ]; then echo "  SKIP: 62-rsk-launch (RS_SKIP_PY=1)"; exit 0; fi
if [ -z "$SRC" ]; then echo "  SKIP: 62-rsk-launch ($RS_HOME carries no remote_run package)"; exit 0; fi
if ! "$PY" -I -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
  if [ "${RS_PACKAGED:-0}" = 1 ]; then bad "python >= 3.11 for rsk launch ('$PY')"; else
    echo "  SKIP: 62-rsk-launch (needs python >= 3.11; set RS_PYTHON=...)"; fi; exit 0; fi
H=$T/home; mkdir -p "$H/projects" "$T/lhome" "$T/state"; export RS_STATE_DIR=$T/state
ME=$(id -un)
cat > "$T/bin/ssh" <<EOS
#!/usr/bin/env bash
# executing ssh stub: -o options dropped, the host logged, the command run here (cd \$H, HOME=\$H) as the remote would;
# \`bash -s\` takes its body on stdin. \$T/ssh.drop: the next submit (--rs-expect) runs, then its reply is lost (255).
# \$T/ssh.noconnect: ssh's own refusal, nothing run (the session never opened). \$T/ssh.fallback: a ProxyCommand's first
# route refused (the same line on stderr), its second connected: the command RUNS there, then the link dies (255, no output).
while [ \$# -gt 0 ]; do case "\$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
echo "\$1" >> "$T/ssh-host.log"
[ ! -f "$T/ssh.noconnect" ] || { echo "ssh: connect to host \$1 port 22: Connection refused" >&2; exit 255; }
shift; cmd="\$*"
if [ -f "$T/ssh.fallback" ]; then echo "ssh: connect to host bastion-a port 22: Connection refused" >&2
  [ "\$cmd" != "bash -s" ] || cmd=\$(cat); ( cd "$H" && HOME="$H" bash -c "\$cmd" ) >/dev/null 2>&1; exit 255; fi
if [ "\$cmd" = "bash -s" ]; then body=\$(cat); printf '%s\n' "\$body" >> "$T/ssh-body.log"
  if [ -f "$T/ssh.drop" ] && printf '%s' "\$body" | grep -q -- '--rs-expect'; then
    rm -f "$T/ssh.drop"; ( cd "$H" && HOME="$H" bash -c "\$body" ) >/dev/null 2>&1; exit 255; fi
  cd "$H" && HOME="$H" exec bash -c "\$body"
fi
printf '%s\n' "\$cmd" >> "$T/ssh-cmd.log"
if [ -f "$T/ssh.failtable" ] && printf '%s' "\$cmd" | grep -q -- '--query-gpu=index,name'; then
  echo "ssh: connect to host wsbox port 22: Connection timed out" >&2; exit 255; fi
if [ -f "$T/ssh.drop" ] && printf '%s' "\$cmd" | grep -q -- '--rs-expect'; then
  rm -f "$T/ssh.drop"; ( cd "$H" && HOME="$H" bash -c "\$cmd" ) >/dev/null 2>&1; exit 255; fi
cd "$H" && HOME="$H" exec bash -c "\$cmd"
EOS
cat > "$T/bin/sbatch" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/sbatch.log"; n=\$(( \$(cat "$T/jobid" 2>/dev/null || echo 100) + 1 )); echo "\$n" > "$T/jobid"
nm=""; wd=""; co=""; for a in "\$@"; do case "\$a" in --job-name=*) nm=\${a#*=} ;; --chdir=*) wd=\${a#*=} ;; --comment=*) co=\${a#*=} ;; esac; done
printf '%s|%s|%s|PENDING|%s|%s\n' "\$n" "$ME" "\$nm" "\$wd" "\$co" >> "$T/jobs"; echo "Submitted batch job \$n"
EOS
# squeue -O / sacct -o: the asked fields of $T/jobs (-u / -j filters); squeue ends every field with '|', sacct -P joins
cat > "$T/bin/squeue" <<EOS
#!/usr/bin/env bash
f=""; u=""; j=""; while [ \$# -gt 0 ]; do case "\$1" in -O) f=\$2; shift 2 ;; -u) u=\$2; shift 2 ;; -j) j=\$2; shift 2 ;; *) shift ;; esac; done
[ -f "$T/jobs" ] || exit 0
awk -F'|' -v fmt="\$f" -v u="\$u" -v j=",\$j," 'BEGIN { n = split(fmt, f, ","); for (i = 1; i <= n; i++) sub(/:.*/, "", f[i]) }
  (u == "" || \$2 == u) && (j == ",," || index(j, "," \$1 ",")) { s = ""; for (i = 1; i <= n; i++) { k = f[i]
    v = k == "JobID" ? \$1 : k == "UserName" ? \$2 : k == "Name" ? \$3 : k == "State" ? \$4 : k == "WorkDir" ? \$5 : k == "Comment" ? \$6 : k == "Reason" ? "None" : "0"
    s = s v "|" }; print s }' "$T/jobs"
EOS
cat > "$T/bin/sacct" <<EOS
#!/usr/bin/env bash
f=""; u=""; j=""; while [ \$# -gt 0 ]; do case "\$1" in -o) f=\$2; shift 2 ;; -u) u=\$2; shift 2 ;; -j) j=\$2; shift 2 ;; -S) shift 2 ;; *) shift ;; esac; done
[ -f "$T/jobs" ] || exit 0
awk -F'|' -v fmt="\$f" -v u="\$u" -v j=",\$j," 'BEGIN { n = split(fmt, f, ",") }
  (u == "" || \$2 == u) && (j == ",," || index(j, "," \$1 ",")) { s = ""; for (i = 1; i <= n; i++) { k = f[i]
    v = k == "JobID" ? \$1 : k == "JobName" ? \$3 : k == "User" ? \$2 : k == "State" ? \$4 : k == "WorkDir" ? \$5 : k == "ExitCode" ? "0:0" : "Unknown"
    s = s (i > 1 ? "|" : "") v }; print s }' "$T/jobs"
EOS
# \$T/scancel.err: the cancel is applied, then scancel prints that file and exits 1 (a timed-out reply to an applied RPC)
cat > "$T/bin/scancel" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/scancel.log"
for j in "\$@"; do awk -F'|' -v OFS='|' -v j="\$j" '\$1 == j { \$4 = "CANCELLED" } 1' "$T/jobs" > "$T/jobs.x" && mv "$T/jobs.x" "$T/jobs"; done
[ ! -f "$T/scancel.err" ] || { cat "$T/scancel.err" >&2; exit 1; }
EOS
cat > "$T/bin/nvidia-smi" <<EOS
#!/usr/bin/env bash
case "\$*" in
  *index,name,*) printf '0, F, 0 %%, 8000 MiB, 49140 MiB\n1, F, 0 %%, 2 MiB, 49140 MiB\n2, F, 0 %%, 5 MiB, 49140 MiB\n3, F, 0 %%, 9000 MiB, 49140 MiB\n' ;;
  *index,uuid,memory.used*) printf '0, GPU-aaaa0000-0000, 8000\n1, GPU-aaaa0000-0001, 2\n2, GPU-aaaa0000-0002, 5\n3, GPU-aaaa0000-0003, 9000\n' ;;
  "--query-compute-apps=gpu_uuid,pid --format=csv,noheader") cat "$T/apps" 2>/dev/null; [ ! -f "$T/apps.next" ] || mv "$T/apps.next" "$T/apps"; exit 0 ;;
  *) echo "nvidia-smi stub: unexpected \$*" >&2; exit 2 ;;
esac
EOS
chmod +x "$T/bin/"*
RSK_PY='import sys; sys.path[:0] = sys.argv[1:2]; from remote_run import cli; sys.exit(cli.main(sys.argv[2:]))'
[ -z "${RS_B1_DRIVER:-}" ] || RSK_PY=$(cat "$RS_B1_DRIVER")
CWD=""
rsk() { ( cd "$CWD" && HOME="$T/lhome" PATH="$T/bin:$PATH" "$PY" -I -c "$RSK_PY" "$SRC" "$@" 2>&1 ); }
pyl() { HOME="$T/lhome" "$PY" -I -c "import sys, json; sys.path[:0] = sys.argv[1:2]; from remote_run import ledger as L, grants as G; $1" "$SRC" "${@:2}"; }
att() { pyl 'a = L.Ledger(sys.argv[2]).read_run(sys.argv[3]).data["attempts"][sys.argv[4]]; s = a["submissions"][-1]
print(L.attempt_state(a), s["submit"], s["job"] or (s.get("proc") or {}).get("pid", ""), a["request"]["grant"], len(a["submissions"]))' "$CWD" "$@"; }
pid_of() { printf '%s\n' "$1" | sed -n 's/^needs user: approval — plan \(p-[^ ]*\).*/\1/p' | tail -n 1; }
reap() { local r p; for r in "$T"/proj_*/.rs/attempts/*/receipt; do [ -f "$r" ] || continue; p=$(sed -n 's/^pgid=//p' "$r")
  [ -n "$p" ] && [ "$(awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$p/stat" 2>/dev/null)" = "$(sed -n 's/^start=//p' "$r")" ] && kill -KILL -- "-$p" 2>/dev/null; done; }
trap 'reap; [ -z "${LP:-}" ] || kill "$LP" 2>/dev/null; rm -rf "$T"' EXIT

P=$(mk_proj fx-slurm 'x') || { bad "mk_proj fx-slurm"; exit 1; }
printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$P" > "$P/.hpc.conf"; CWD=$P
N1=exp--smoke--base--scratch--s0--a01

echo "-- slurm: plan -> the card, exit 4; nothing submitted --"
O=$(rsk launch -T fx-slurm -n "$N1" -g 1 -- python train.py --lr 1e-3); RC=$?; PL1=$(pid_of "$O")
[ "$RC" = 4 ] && [ -n "$PL1" ] && ok "plan: exit 4, needs user: approval — plan <id>" || { bad "plan: exit 4 (rc=$RC)"; printf '%s\n' "$O" | head -30 | sed 's/^/    | /'; }
nosub "...nothing reached sbatch"
has "$O" "^plan $PL1 — launch on fx-slurm (slurm)" "card: plan id, action, target, kind"
has "$O" '^  partition  gpu$' "card: partition (decoded)"; has "$O" '^  gres       gpu:1$' "card: gres"; has "$O" '^  mem        40G$' "card: mem"
has "$O" '^  payload    python train.py --lr 1e-3$' "card: payload words"; has "$O" '^  warnings   0' "card: warnings 0"
has "$O" '^  reference  .*fx-slurm/reference.md' "card: the reference path"; has "$O" '^  bound_hash [0-9a-f]\{64\}$' "card: bound_hash"
has "$O" '^  source     deployed none' "card: source commit (deployed vs local HEAD)"
has "$O" '^  source     deployed none dirty=none · local HEAD none dirty=- — unknown (not a git checkout, no commit yet, or no sync stamp) — cannot compare$' \
  "NF8-card-source-unknown: no stamp, no git checkout: the source line says unknown, never DIFFERENT code"; hasnt "$O" 'DIFFERENT code' "...nowhere on the card"
has "$O" 'no approval or grant recorded' "card: why nothing covers it"
hasnt "$O" '--approve' "no ready-to-run --approve line"
PN=$(grep -h -o -- '--rs-attempt rsk-[^ ]*' "$T/ssh-body.log" | tail -n 1 | cut -d' ' -f2)
has "$(cat "$P/.rs/attempts/$PN/result" 2>/dev/null)" 'verdict=planned' "the plan's remote attempt: verdict=planned"

echo "-- --approve: submitted with --rs-expect, ledger attempt + approval use --"
O=$(rsk launch --plan "$PL1" --approve "yes, run the smoke"); RC=$?
[ "$RC" = 0 ] && has "$O" '^submitted: exp--smoke--base--scratch--s0 a01 job 101 on fx-slurm' "approved -> submitted (job 101)" || { bad "approve (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }
has "$O" '^approval ap-.*launch of 1 approved plan' "an approval record (plan-approve) for the plan"
has "$O" 'plan: bound_hash=[0-9a-f]* = --rs-expect' "submit.sh checked --rs-expect (the replay)"
has "$(tail -n 1 "$T/sbatch.log")" "rs=rsk-" "the job's comment carries rs=<nonce>"
hasnt "$(grep -- '--rs-expect' "$T/ssh-body.log" | tail -n 1)" " -y " "no -y: the card showed no warning"
A=$(att exp--smoke--base--scratch--s0 a01); has "$A" '^SUBMITTED submitted 101 ap-' "ledger: a01 submitted, job 101, under the approval"
has "$(rsk grant list)" 'plans used 1/1' "the approval's use is counted"
O=$(rsk launch --plan "$PL1" --approve "again"); [ "$?" = 6 ] && has "$O" 'was used already' "a used plan -> exit 6" || bad "a used plan -> exit 6"
O=$(rsk status); has "$O" 'exp--smoke--base--scratch--s0 *a01  PENDING' "rsk status: the ledger run, observed PENDING"

echo "-- local duplicate: a live ledger run of that name -> exit 6 before any ssh --"
: > "$T/ssh-host.log"; O=$(rsk launch -T fx-slurm -n "$N1" -g 1 -- python train.py); RC=$?
[ "$RC" = 6 ] && has "$O" 'is live on fx-slurm in the ledger' "same run live -> exit 6" || bad "local duplicate (rc=$RC)"
[ ! -s "$T/ssh-host.log" ] && ok "...nothing sent" || bad "...nothing sent"
O=$(rsk launch -T fx-slurm -n "$N1" -g 1 --same-name-ok -- python train.py); [ "$?" = 4 ] && ok "--same-name-ok: planned (exit 4)" || bad "--same-name-ok plans"
has "$(grep -- '--rs-mode' "$T/ssh-body.log" | tail -n 1)" '--same-name-ok' "...and --same-name-ok reaches submit.sh"

echo "-- a covering grant: submitted at once --"
O=$(rsk grant add --quote "smoke runs on fx are fine" -T fx-slurm --class smoke --action launch --max-gpus 2 --max-live 5 --max-launches 9 --expires 2099-12-31)
GR=$(printf '%s\n' "$O" | sed -n 's/^\(g-[^ ]*\) .*/\1/p')
O=$(rsk launch -T fx-slurm -n exp--smoke--b--scratch--s0--a01 -g 1 -- python t.py); RC=$?
[ "$RC" = 0 ] && has "$O" "^covered by $GR (grant" "covered by the grant -> no question" || { bad "covered (rc=$RC)"; printf '%s\n' "$O" | tail -8 | sed 's/^/    | /'; }
has "$O" '^submitted: exp--smoke--b--scratch--s0 a01 job 102' "...submitted"
O=$(rsk launch -T fx-slurm -n exp--smoke--b2--scratch--s0--a01 -g 3 -- python t.py); RC=$?
[ "$RC" = 4 ] && has "$O" '3 GPUs > 2' "more GPUs than the grant's cap -> needs the user" || bad "outside the cap (rc=$RC)"

echo "-- warnings: a plain grant never covers them; the approved card's submit carries -y --"
stub_sinfo "-p gpu" "nodeA gpu:whatever:4 gpu:whatever:4 mix"
O=$(rsk launch -T fx-slurm -n exp--smoke--w--scratch--s0--a01 -g 1 -- python t.py); RC=$?; PW=$(pid_of "$O")
[ "$RC" = 4 ] && has "$O" 'the plan has 1 warning(s)' "a plan with a warning is not grant-covered" || bad "warnings (rc=$RC)"
has "$O" "^    WARNING: only 0 free of 'any'" "the card shows the WARNING verbatim"
O=$(rsk launch --plan "$PW" --approve "queue it anyway"); RC=$?
[ "$RC" = 0 ] && has "$(grep -- '--rs-expect' "$T/ssh-body.log" | tail -n 1)" ' -y ' "approved card with warnings -> submit with -y" || bad "-y after warnings (rc=$RC)"
has "$(rsk grant list)" 'warnings the user saw' "...the approval allows the warnings it saw"
rm -f "$T/sinfo.d/-p gpu"

echo "-- a deny wins; a policy refusal is exit 3 --"
rsk grant deny --quote "never the forbidden runs" --name 'forbidden*' --action launch >/dev/null
O=$(rsk launch -T fx-slurm -n forbidden-x -g 1 -- c); RC=$?
[ "$RC" = 3 ] && has "$O" 'never the forbidden runs' "a deny -> exit 3 with its quote" || bad "deny (rc=$RC)"
O=$(rsk launch -T fx-slurm -n exp--smoke--v--scratch--s0--a01 -p vip -- c); RC=$?
[ "$RC" = 3 ] && has "$O" 'REFUSED: vip is policy-gated' "a policy refusal during the plan -> exit 3, its line" || bad "policy refusal (rc=$RC)"

echo "-- conf drift between plan and approval -> exit 6 (--rs-expect), nothing submitted --"
O=$(rsk launch -T fx-slurm -n exp--train--d--scratch--s0--a01 -g 1 -- python t.py); PD=$(pid_of "$O")
printf 'DEFAULT_TIME=02:00:00\n' >> "$P/.hpc.conf"; : > "$T/sbatch.log"
O=$(rsk launch --plan "$PD" --approve "go"); RC=$?
[ "$RC" = 6 ] && has "$O" 'differs from the approved plan' "drift -> exit 6" || { bad "drift (rc=$RC)"; printf '%s\n' "$O" | tail -6 | sed 's/^/    | /'; }
nosub "...sbatch never ran"; has "$O" 'given back' "...the approval's use is given back"
has "$O" 'DEFAULT_TIME\|time: 1-00:00:00 → 02:00:00' "H1-msg: the refusal names what changed (time)"
has "$(att exp--train--d--scratch--s0 a01)" '^NOT_SUBMITTED not_submitted' "...ledger: NOT_SUBMITTED"
printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$P" > "$P/.hpc.conf"
O=$(rsk launch --plan "$PD"); RC=$?          # D10: proof of not-submitted freed the plan: the same approval, no new words
[ "$RC" = 0 ] && has "$O" '^submitted: exp--train--d--scratch--s0 a01 job ' "D10: the conf restored, --plan retries under the same approval" || { bad "D10 retry (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }

echo "-- a sweep: two plans, one approval; a superseded plan -> exit 6 --"
O=$(rsk launch -T fx-slurm -n exp--ablate--sa--scratch--s0--a01 -g 1 -- python t.py --a); SA=$(pid_of "$O")
O=$(rsk launch -T fx-slurm -n exp--ablate--sb--scratch--s0--a01 -g 1 -- python t.py --b); SB=$(pid_of "$O")
O=$(rsk launch --plan "$SA" --plan "$SB" --approve "run both ablations"); RC=$?
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$O" | grep -c '^submitted: ')" = 2 ] && ok "sweep: both submitted under one approval" || { bad "sweep (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }
[ "$(printf '%s\n' "$O" | grep -c '^approval ap-')" = 1 ] && has "$O" 'of 2 approved plan' "...one approval record over 2 plans" || bad "...one approval"
O=$(rsk launch -T fx-slurm -n exp--train--s--scratch--s0--a01 -g 1 -- python v1.py); S1=$(pid_of "$O")
O=$(rsk launch -T fx-slurm -n exp--train--s--scratch--s0--a01 -g 1 -- python v2.py)
: > "$T/sbatch.log"; O=$(rsk launch --plan "$S1" --approve "v1"); RC=$?
[ "$RC" = 6 ] && has "$O" 'superseded by p-' "a superseded plan -> exit 6" || bad "superseded (rc=$RC)"; nosub "...nothing submitted"

echo "-- ssh lost during the submit -> SUBMIT_UNKNOWN (sticky); rsk status reconciles it from the journal --"
touch "$T/ssh.drop"; O=$(rsk launch -T fx-slurm -n exp--smoke--u--scratch--s0--a01 -g 1 -- python t.py); RC=$?
[ "$RC" = 5 ] && has "$O" '^SUBMIT_UNKNOWN: exp--smoke--u--scratch--s0 a01' "reply lost -> exit 5, SUBMIT_UNKNOWN" || bad "ssh lost (rc=$RC)"
has "$(att exp--smoke--u--scratch--s0 a01)" '^SUBMIT_UNKNOWN unknown' "...ledger: SUBMIT_UNKNOWN"
O=$(rsk status); has "$O" 'exp--smoke--u--scratch--s0 a01: SUBMIT_UNKNOWN -> submitted (remote receipt (reconciled))' "rsk status: reconciled from the receipt"
has "$(att exp--smoke--u--scratch--s0 a01)" '^PENDING submitted 10[0-9]' "...ledger: submitted, the job id from the receipt"

echo "-- an old deploy (D9: the deployed submit.sh's '# rs-api=3' line, not the API file) -> needs: sync, nothing run --"
nomark() { grep -v '^# rs-api=' "$1" > "$1.x" && mv "$1.x" "$1"; }   # a script from before the marker
P2=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$P2" > "$P2/.hpc.conf"; nomark "$P2/.fx-slurm/submit.sh"
has "$(cat "$P2/.fx-slurm/API" 2>/dev/null)" '^api=3$' "(the stale API file still says api=3)"
CWD=$P2; O=$(rsk launch -T fx-slurm -n old1 -- c); RC=$?
[ "$RC" = 6 ] && has "$O" '^needs: sync (the deploy predates rsk launch: rsk sync -T fx-slurm)' "no marker line -> exit 6, needs: sync" || bad "old deploy (rc=$RC)"
[ ! -d "$P2/.rs/attempts" ] && ok "...the old submit.sh never ran" || bad "...the old submit.sh never ran"
P3=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$P3" > "$P3/.hpc.conf"; CWD=$P3
O=$(rsk launch -T fx-slurm -n exp--smoke--sk--a01 -g 1 -- python t.py); PSK=$(pid_of "$O")
if OLDS=$(git -C "$RS_HOME" show 8560838:remote/submit.sh 2>/dev/null) && [ -n "$OLDS" ]; then printf '%s\n' "$OLDS" > "$P3/.fx-slurm/submit.sh"
else nomark "$P3/.fx-slurm/submit.sh"; fi                     # C-stale-API: an older run-sync rewrote submit.sh, not API
: > "$T/sbatch.log"; O=$(rsk launch --plan "$PSK" --approve "yes, run it"); RC=$?
[ "$RC" = 6 ] && has "$O" '^needs: sync' "C-stale-API: the approved submit to an older submit.sh -> exit 6, needs: sync" || { bad "C-stale-API (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
nosub "...nothing submitted"; has "$(att exp--smoke--sk a01)" '^NOT_SUBMITTED not_submitted' "...ledger: NOT_SUBMITTED"
CWD=$P

echo "-- relaunch: the run's next attempt (aNN), same configuration --"
O=$(rsk launch --relaunch exp--smoke--b--scratch--s0); RC=$?
[ "$RC" = 6 ] && ok "relaunch while a01 is live -> exit 6" || bad "relaunch of a live run (rc=$RC)"
awk -F'|' -v OFS='|' '$1 == 102 { $4 = "COMPLETED" } 1' "$T/jobs" > "$T/jobs.x" && mv "$T/jobs.x" "$T/jobs"; rsk status >/dev/null
O=$(rsk launch --relaunch exp--smoke--b--scratch--s0); RC=$?
[ "$RC" = 4 ] && has "$O" '^  name       exp--smoke--b--scratch--s0--a02$' "relaunch plans <run>--a02 from the recorded bound fields" || { bad "relaunch (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }
has "$O" 'action relaunch not in launch' "...a launch-only grant does not cover a relaunch"; has "$O" '^  payload    python t.py$' "...same payload"

echo "-- cancel: the user's words, identity (name + WorkDir + user) in one ssh, then scancel --"
: > "$T/scancel.log"; O=$(rsk cancel exp--smoke--base--scratch--s0 --approve "cancel the smoke exp--smoke--base--scratch--s0"); RC=$?
[ "$RC" = 0 ] && has "$(cat "$T/scancel.log")" '^101$' "cancel RUN --approve -> scancel 101" || { bad "cancel (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }
has "$O" '^approval ap-.*cancel of job(s) 101' "...recorded as a cancel approval naming the job"
has "$(att exp--smoke--base--scratch--s0 a01)" '^CANCELLING' "...ledger: CANCELLING (until status sees the end)"
printf '777|%s|stray|PENDING|/elsewhere/proj|\n778|someone|theirs|RUNNING|%s|\n' "$ME" "$P" >> "$T/jobs"; : > "$T/scancel.log"
O=$(rsk cancel --job 777 -T fx-slurm --approve "cancel job 777"); RC=$?
[ "$RC" = 6 ] && has "$O" 'identity does not match (workdir=/elsewhere/proj)' "a job of another WorkDir -> refused (exit 6)" || bad "workdir differs (rc=$RC)"
O=$(rsk cancel --job 777 -T fx-slurm); RC=$?
[ "$RC" = 4 ] && ok "D6: the words for job 777 were used up by that refused cancel (no refund): again -> exit 4" || bad "D6 used up (rc=$RC)"
O=$(rsk cancel --job 778 -T fx-slurm --approve "cancel job 778"); RC=$?
[ "$RC" = 3 ] && has "$O" 'belongs to someone' "someone else's job -> exit 3" || bad "another user's job (rc=$RC)"
[ ! -s "$T/scancel.log" ] && ok "...scancel never called for either" || bad "...scancel called"
O=$(rsk cancel exp--ablate--sa--scratch--s0); RC=$?
[ "$RC" = 4 ] && has "$O" '^needs user: approval — cancel job' "the agent's own cancel without cancel_own -> exit 4" || bad "cancel without words (rc=$RC)"
rsk grant deny --quote "leave the sb ablation alone" --name 'exp--ablate--sb*' --action cancel >/dev/null
O=$(rsk cancel exp--ablate--sb--scratch--s0 --approve "cancel exp--ablate--sb--scratch--s0"); RC=$?
[ "$RC" = 3 ] && has "$O" 'leave the sb ablation alone' "a deny on cancel wins over the user's words -> exit 3" || bad "deny on cancel (rc=$RC)"
rsk grant add --quote "you may stop your own smoke runs" -T fx-slurm --action cancel_own --max-live none --max-launches none --expires 2099-12-31 >/dev/null
O=$(rsk cancel exp--smoke--w--scratch--s0); RC=$?
[ "$RC" = 0 ] && has "$O" '^cancelled: job ' "a cancel_own grant covers the agent's own run" || bad "cancel_own (rc=$RC)"

echo "-- review: --force / --rs-* are never policy flags (M3); a --class against the name's class (H3) --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R; : > "$T/ssh-host.log"
O=$(rsk launch -T fx-slurm -n exp--smoke--f--a01 -g 1 --force -- python t.py); RC=$?
[ "$RC" = 2 ] && has "$O" '--force is not a policy flag' "M3: --force -> exit 2 (rsk sends -y itself)" || bad "M3 --force (rc=$RC)"
O=$(rsk launch -T fx-slurm -n exp--smoke--f--a01 -g 1 --rs-mode -- python t.py); [ "$?" = 2 ] && ok "M3: an --rs-* word -> exit 2" || bad "M3 --rs-*"
O=$(rsk launch -T fx-slurm --class smoke -n exp--train--big--s0--a01 -g 1 -- python t.py); RC=$?
[ "$RC" = 2 ] && has "$O" 'contradicts the name' "H3: --class smoke on a train name -> exit 2" || bad "H3 class (rc=$RC)"
[ ! -s "$T/ssh-host.log" ] && ok "...all before any ssh" || bad "...all before any ssh"
rsk grant deny --quote "no train runs on fx this week" -T fx-slurm --class train >/dev/null
O=$(rsk launch -T fx-slurm -n exp--train--big--s0--a01 -g 1 -- python t.py); RC=$?
[ "$RC" = 3 ] && has "$O" 'no train runs on fx this week' "H3: the name's class meets a class deny -> exit 3" || bad "H3 deny (rc=$RC)"

echo "-- review M1: a deny of launch also stops a chain; L5: a chain under max_live 1 sends every segment --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
rsk grant add --quote "chain the long run, one at a time" -T fx-slurm --action chain --max-live 1 --max-launches 10 --expires 2099-12-31 >/dev/null
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm --chain 3 -n exp--train--long--a01 -g 1 -- python t.py); RC=$?
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$O" | grep -c '^submitted: ')" = 3 ] && ok "L5: 3 segments under max_live 1 (the attempt it extends holds its own slot)" || { bad "L5 chain (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
[ "$(wc -l < "$T/sbatch.log")" = 3 ] && ok "...3 sbatch calls" || bad "...3 sbatch calls"
rsk grant deny --quote "stop launching anything on fx today" -T fx-slurm --action launch >/dev/null
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm --chain 1 -n exp--smoke--d--a01 -g 1 -- python t.py); RC=$?
[ "$RC" = 3 ] && has "$O" 'stop launching anything on fx today' "M1: a deny of launch stops --chain -> exit 3" || bad "M1 deny chain (rc=$RC)"; nosub "...nothing submitted"

echo "-- review H2 / D1: SBATCH_EXTRA outside the allowlist is never a grant's call (the card names the words) --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\nSBATCH_EXTRA="--time=12:00:00 --nodes=2"\n' "$R" > "$R/.hpc.conf"; CWD=$R
rsk grant add --quote "1-GPU smoke runs up to an hour are fine" -T fx-slurm --action launch --max-gpus 1 --max-time 1:00:00 --max-live 2 --max-launches 2 --expires 2099-12-31 >/dev/null
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n exp--smoke--x--a01 -g 1 -t 30 -- python t.py); RC=$?
[ "$RC" = 4 ] && has "$O" 'SBATCH_EXTRA word(s) no standing grant covers (--time=12:00:00, --nodes=2)' "H2/D1: --time / --nodes in SBATCH_EXTRA -> exit 4" || bad "H2 extra time (rc=$RC)"
has "$O" "^  TIME       12:00:00 — an SBATCH_EXTRA / policy --time" "...the card says which time sbatch takes"; has "$O" '^  NO GRANT   SBATCH_EXTRA word(s) --time=12:00:00 --nodes=2' "...and names the words"
has "$O" '^  conf extra --time=12:00:00 --nodes=2$' "...the conf's words are bound (conf_extra)"; nosub "...nothing submitted"
for X in "--time=23:00:00 --comment -t1" "--thread-spec=1" "-S 1" "--core-spec=1"; do   # grants#1 (a time hidden in a value), grants#3
  printf 'REMOTE_DIR=%s\nENV_KIND=none\nSBATCH_EXTRA="%s"\n' "$R" "$X" > "$R/.hpc.conf"
  : > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n exp--smoke--x--a01 -g 1 -t 30 -- python t.py); RC=$?
  [ "$RC" = 4 ] && has "$O" 'no standing grant covers' "grants#1/grants#3: SBATCH_EXTRA '$X' -> not grant-covered (exit 4)" || bad "grants '$X' (rc=$RC)"; nosub "...nothing submitted ($X)"
done
printf 'REMOTE_DIR=%s\nENV_KIND=none\nSBATCH_EXTRA="--comment -t1 --qos=normal"\n' "$R" > "$R/.hpc.conf"
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n exp--smoke--y--a01 -g 1 -t 30 -- python t.py); RC=$?
[ "$RC" = 0 ] && has "$O" '^covered by g-' "D1: allowlisted words (--comment's value '-t1', --qos) -> grant-covered" || { bad "D1 allowlisted (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }

echo "-- review M4: the submit carries the card's warning count; a failed squeue under --rs-expect is never a -y gate --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
stub_sinfo "-p gpu" "nodeA gpu:whatever:4 gpu:whatever:4 mix"
O=$(rsk launch -T fx-slurm -n exp--smoke--w--a01 -g 1 -- python t.py); PLW=$(pid_of "$O")
printf '555|%s|exp--smoke--w--a01|RUNNING|%s|\n' "$ME" "$R" >> "$T/jobs"   # a live copy from outside rsk; squeue fails at submit
cp "$T/bin/squeue" "$T/squeue.ok"; printf '#!/usr/bin/env bash\necho "squeue: error: Socket timed out" >&2; exit 1\n' > "$T/bin/squeue"
: > "$T/sbatch.log"; O=$(rsk launch --plan "$PLW" --approve "yes, queue it anyway"); RC=$?
cp "$T/squeue.ok" "$T/bin/squeue"; rm -f "$T/sinfo.d/-p gpu"
[ "$RC" = 6 ] && has "$O" 'the duplicate check could not run' "M4: squeue fails under --rs-expect + -y: not submitted (exit 6)" || { bad "M4 squeue (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
nosub "...sbatch never ran (no second copy next to job 555)"
has "$(grep -- '--rs-expect' "$T/ssh-body.log" | tail -n 1)" '--rs-warnings [0-9a-f]\{64\} -y' "...the submit carried --rs-warnings <the card's warnings_id> with -y"

echo "-- review M5: two concurrent --approve of one plan: one submit, one approval; a later identical plan needs the user --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
O=$(rsk launch -T fx-slurm -n exp--smoke--r--a01 -g 1 -- python t.py); PLR=$(pid_of "$O"); : > "$T/sbatch.log"
( rsk launch --plan "$PLR" --approve "yes run it" > "$T/race1" 2>&1 ) & ( rsk launch --plan "$PLR" --approve "yes run it" > "$T/race2" 2>&1 ) & wait
[ "$(wc -l < "$T/sbatch.log")" = 1 ] && ok "M5: one sbatch" || bad "M5: one sbatch (got $(wc -l < "$T/sbatch.log"))"
[ "$(pyl 'print(sum(1 for r in L.Ledger(sys.argv[2]).state().grants if r["kind"] == "approval" and not r.get("revoked")))' "$R")" = 1 ] \
  && ok "...one approval recorded (the loser made none)" || bad "...one approval"
JR=$(cut -d'|' -f1,3 "$T/jobs" | sed -n 's/|exp--smoke--r--a01$//p' | tail -n 1); PATH="$T/bin:$PATH" scancel "$JR"; rsk status >/dev/null
O=$(rsk launch -T fx-slurm -n exp--smoke--r--a01 -g 1 -- python t.py); RC=$?
[ "$RC" = 4 ] && has "$O" '^not covered: ap-' "...the same configuration planned later: a new card for the user (exit 4)" || bad "M5 later plan (rc=$RC)"

echo "-- review M6: a SUBMIT_UNKNOWN attempt blocks a relaunch even with --same-name-ok --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
rsk grant add --quote "run and relaunch the smokes on fx" -T fx-slurm --action launch,relaunch --max-live none --max-launches none --expires 2099-12-31 >/dev/null
touch "$T/ssh.drop"; O=$(rsk launch -T fx-slurm -n exp--smoke--u--a01 -g 1 -- python t.py); [ "$?" = 5 ] || bad "M6 setup: SUBMIT_UNKNOWN"
: > "$T/sbatch.log"; O=$(rsk launch --relaunch exp--smoke--u --same-name-ok); RC=$?
[ "$RC" = 6 ] && has "$O" 'SUBMIT_UNKNOWN attempt' "M6: --relaunch --same-name-ok next to a SUBMIT_UNKNOWN -> exit 6" || bad "M6 (rc=$RC)"; nosub "...nothing submitted"

echo "-- review M7: an ENV_HOOK added after the card -> exit 6, nothing submitted --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
O=$(rsk launch -T fx-slurm -n exp--smoke--h--a01 -g 1 -- python t.py); PLH=$(pid_of "$O"); has "$O" '^  env hook   -$' "the card: env hook -"
printf 'REMOTE_DIR=%s\nENV_KIND=none\nENV_HOOK=hook.sh\nVENV_DIR=/elsewhere/venv\n' "$R" > "$R/.hpc.conf"; echo 'alias python=/bin/true' > "$R/hook.sh"
: > "$T/sbatch.log"; O=$(rsk launch --plan "$PLH" --approve "yes"); RC=$?
[ "$RC" = 6 ] && has "$O" 'differs from the approved plan' "M7: hook + VENV_DIR drift -> exit 6" || bad "M7 (rc=$RC)"; nosub "...nothing submitted"

echo "-- review L2: the answer cut after the identity check passed: the cancel approval is not given back --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
O=$(rsk launch -T fx-slurm -n exp--smoke--k--a01 -g 1 -- python t.py); O=$(rsk launch --plan "$(pid_of "$O")" --approve "yes")
mv "$T/bin/ssh" "$T/ssh.real"; printf '#!/usr/bin/env bash\n"%s/ssh.real" "$@" > "%s/full.out"; sed "/@@scancel/,\\$d" "%s/full.out"; exit 255\n' "$T" "$T" "$T" > "$T/bin/ssh"; chmod +x "$T/bin/ssh"
: > "$T/scancel.log"; O=$(rsk cancel exp--smoke--k --approve "cancel exp--smoke--k"); RC=$?; mv "$T/ssh.real" "$T/bin/ssh"
[ "$RC" = 5 ] && has "$O" 'the cancel may have been sent' "L2: cut after '@@c J ok' -> exit 5, 'may have been sent'" || bad "L2 (rc=$RC)"
[ -s "$T/scancel.log" ] && has "$(rsk grant list)" 'jobs used 1/1' "...scancel ran and the approval stays used (1/1)" || bad "L2 approval kept"
CWD=$P

echo "-- D3: --allow-warnings takes a kind; an availability grant covers the availability gate's warning, with -y --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
O=$(rsk grant add --quote "queue them" -T fx-slurm --action launch --allow-warnings --max-live none --max-launches none --expires none); RC=$?
[ "$RC" = 2 ] && ok "D3: a bare --allow-warnings (no kind) -> exit 2" || bad "D3 bare --allow-warnings (rc=$RC)"
rsk grant add --quote "queue the smokes even if the cluster is busy" -T fx-slurm --action launch --allow-warnings availability --max-live none --max-launches none --expires 2099-12-31 >/dev/null
has "$(rsk grant list)" "plans whose only warnings are the availability gate's" "...stored as the availability kind"
stub_sinfo "-p gpu" "nodeA gpu:whatever:4 gpu:whatever:4 mix"
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n exp--smoke--q--a01 -g 1 -- python t.py); RC=$?
[ "$RC" = 0 ] && has "$O" '^covered by g-' "D3: the availability gate's warning only, an availability grant -> covered, submitted" || { bad "D3 availability (rc=$RC)"; printf '%s\n' "$O" | tail -6 | sed 's/^/    | /'; }
has "$O" '^  warnings   1  (1 of them the availability gate' "...the card: 1 warning, the availability gate's"
has "$(grep -- '--rs-expect' "$T/ssh-body.log" | tail -n 1)" ' -y ' "...the submit carries -y (the grant's kind covers the card's warning)"
rm -f "$T/sinfo.d/-p gpu"

echo "-- D5 / r1-2 / grants#4: a relaunch grant resumes only an infrastructure end; a plain launch of a run that ran is a relaunch --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
rsk grant add --quote "run and auto-resume the smokes on fx" -T fx-slurm --action launch,relaunch --max-live none --max-launches none --expires 2099-12-31 >/dev/null
jobstate() { awk -F'|' -v OFS='|' -v j="$1" -v s="$2" '$1 == j { $4 = s } 1' "$T/jobs" > "$T/jobs.x" && mv "$T/jobs.x" "$T/jobs"; }
O=$(rsk launch -T fx-slurm -n exp--smoke--z -g 1 -- python t.py); JZ=$(printf '%s\n' "$O" | sed -n 's/^submitted: .* job \([0-9]*\) .*/\1/p')
O=$(rsk launch -T fx-slurm -n exp--smoke--p -g 1 -- python t.py); JP=$(printf '%s\n' "$O" | sed -n 's/^submitted: .* job \([0-9]*\) .*/\1/p')
jobstate "$JZ" FAILED; jobstate "$JP" PREEMPTED; rsk status >/dev/null
: > "$T/sbatch.log"; O=$(rsk launch --relaunch exp--smoke--z); RC=$?
[ "$RC" = 4 ] && has "$O" 'a relaunch grant resumes only an infrastructure end' "r1-2: FAILED is no infrastructure end -> a relaunch needs the user (exit 4)" || { bad "r1-2 FAILED (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
nosub "...nothing submitted"
O=$(rsk launch --relaunch exp--smoke--p); RC=$?
[ "$RC" = 0 ] && has "$O" '^submitted: exp--smoke--p a02 ' "D5: PREEMPTED -> the relaunch grant resumes it (a02)" || { bad "D5 PREEMPTED (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
rsk grant deny --quote "do not relaunch exp--smoke--z, it is broken" --action relaunch --name exp--smoke--z >/dev/null
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n exp--smoke--z -g 1 -- python t.py); RC=$?
[ "$RC" = 3 ] && has "$O" 'do not relaunch exp--smoke--z' "grants#4: a plain launch of a run that ran is a relaunch: the deny stops it (exit 3)" || bad "grants#4 (rc=$RC)"
has "$O" '— relaunch on fx-slurm' "...the card says relaunch"; nosub "...nothing submitted"

echo "-- F-unknown (slurm): submit.sh cannot claim its attempt dir -> NOT_SUBMITTED, never SUBMIT_UNKNOWN --"
if [ "$(id -u)" = 0 ]; then echo "  SKIP: F-unknown slurm (root ignores the read-only dir)"; else
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
O=$(rsk launch -T fx-slurm -n exp--smoke--nj--a01 -g 1 -- python t.py); PNJ=$(pid_of "$O")
chmod a-w "$R/.rs/attempts"; : > "$T/sbatch.log"; O=$(rsk launch --plan "$PNJ" --approve "yes"); RC=$?; chmod u+w "$R/.rs/attempts"
[ "$RC" = 2 ] && has "$O" '^not submitted: exp--smoke--nj a01 — submit.sh exit 2 with no .rs/attempts/' "F-unknown: no attempt dir -> not submitted (exit 2)" || { bad "F-unknown slurm (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
has "$(att exp--smoke--nj a01)" '^NOT_SUBMITTED not_submitted' "...ledger: NOT_SUBMITTED (the name is not blocked)"; nosub "...nothing submitted"
O=$(rsk launch --plan "$PNJ"); RC=$?
[ "$RC" = 0 ] && has "$O" '^submitted: exp--smoke--nj a01 ' "D10: the same plan, the same approval, once the dir is writable -> submitted" || bad "D10 slurm retry (rc=$RC)"
fi

echo "-- D8: rsk watch --act and --approve honour the denies --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
printf '#@ run-watch v1\n#@ allow launch\na fx-slurm - -p gpu -g 1 -t 1:00:00 -- python train.py\n' > "$R/t.tsv"
O=$(rsk watch t.tsv --approve "run a under the watch"); RC=$?
[ "$RC" = 0 ] && has "$(cat "$R/t.tsv")" '^#@ ok ' "the table approved (no deny yet)" || { bad "watch approve (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
rsk grant deny --quote "never launch anything on fx-slurm any more" -T fx-slurm >/dev/null
: > "$T/sbatch.log"; O=$(rsk watch t.tsv --once --act --max-active 1); RC=$?
[ "$RC" = 3 ] && has "$O" 'never launch anything on fx-slurm any more' "D8: a deny matching a row -> rsk watch --act exit 3, nothing started" || { bad "D8 act (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
nosub "...nothing submitted"; [ ! -d "$R/logs/run-watch" ] && ok "...run-watch never ran" || bad "...run-watch never ran"
printf 'b fx-slurm - -p gpu -g 1 -- python b.py\n' >> "$R/t.tsv"; cp "$R/t.tsv" "$T/t.before"
O=$(rsk watch t.tsv --approve "and b"); RC=$?
[ "$RC" = 3 ] && cmp -s "$R/t.tsv" "$T/t.before" && ok "D8: --approve over rows a deny matches -> exit 3, no '#@ ok' written" || bad "D8 approve (rc=$RC)"
CWD=$P

echo "-- round 4 R4-6: a policy flag is bound (flags=) and never a grant's call; R4-1: a deny of a run's plan stops its cancel --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
rsk grant add --quote "1-GPU smoke runs on fx are fine; kill a broken one yourself" -T fx-slurm --action launch,cancel_own --max-gpus 1 --max-live 5 --max-launches 5 --expires 2099-12-31 >/dev/null
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n exp--smoke--wn--a01 -g 1 -t 30 --whole-node -- python t.py); RC=$?; PF=$(pid_of "$O")
[ "$RC" = 4 ] && has "$O" 'policy flag(s) --whole-node' "R4-6: a policy flag -> no standing grant covers the plan (exit 4)" || { bad "R4-6 policy flag (rc=$RC)"; printf '%s\n' "$O" | tail -6 | sed 's/^/    | /'; }
has "$O" '^  policy     --whole-node  (bound' "...the card lists it, bound (flags=)"; nosub "...nothing submitted"
O=$(rsk launch --plan "$PF" --approve "yes, the whole node for this smoke"); RC=$?
[ "$RC" = 0 ] && has "$(grep -- '--rs-expect' "$T/ssh-body.log" | tail -n 1)" '--whole-node' "R4-6: the approved card's submit carries the flag (--rs-expect binds it)" || bad "R4-6 approved (rc=$RC)"
O=$(rsk launch -T fx-slurm -n exp--smoke--dr--a01 -g 1 -t 30 -- python t.py); RC=$?
HD=$(printf '%s\n' "$O" | sed -n 's/^  bound_hash \([0-9a-f]*\)$/\1/p')
[ "$RC" = 0 ] && [ -n "$HD" ] || bad "R4-1 setup: a covered launch (rc=$RC)"
rsk grant deny --quote "do not touch that run, whatever happens" --run "$HD" >/dev/null
: > "$T/scancel.log"; O=$(rsk cancel exp--smoke--dr); RC=$?
[ "$RC" = 3 ] && has "$O" 'do not touch that run' "R4-1: a deny of the run's plan (--run H) stops the agent's own cancel (exit 3)" || { bad "R4-1 deny --run vs cancel (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
[ ! -s "$T/scancel.log" ] && ok "...scancel never called" || bad "...scancel called"
printf '#@ run-watch v1\n#@ allow launch\nwr fx-slurm - -p gpu -g 1 -t 30 -- python t.py\n' > "$R/t.tsv"
O=$(rsk watch t.tsv --approve "watch wr"); RC=$?
[ "$RC" = 3 ] && has "$O" 'a deny of plans matches every row' "R4-1/N2: a row has no bound hash: a deny of plans matches it (exit 3, said why)" || bad "R4-1 watch row (rc=$RC)"

echo "-- R4-2: a relaunch grant repeats the attempt whose end it relies on; a plan named after an older attempt is a new one --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R; X=exp--train--lr--s0
jid() { printf '%s\n' "$1" | sed -n 's/^submitted: .* job \([0-9]*\) .*/\1/p' | tail -n 1; }
O=$(rsk launch -T fx-slurm -n $X--a01 -g 1 -t 30 -- python train.py --lr 1); O=$(rsk launch --plan "$(pid_of "$O")" --approve "run it with lr 1"); J1=$(jid "$O")
O=$(rsk cancel --job "$J1" -T fx-slurm --approve "cancel job $J1, lr 1 is wrong"); rsk status >/dev/null
O=$(rsk launch -T fx-slurm -n $X--a02 -g 1 -t 30 -- python train.py --lr 0.1); O=$(rsk launch --plan "$(pid_of "$O")" --approve "rerun it with lr 0.1"); J2=$(jid "$O")
[ -n "$J1" ] && [ -n "$J2" ] || bad "R4-2 setup: a01 and a02 submitted ($J1 $J2)"
rsk grant add --quote "auto-resume exp--train if it gets preempted, up to 3 times" -T fx-slurm --name 'exp--train--*' --action relaunch --max-live 1 --max-launches 3 --expires 2099-12-31 >/dev/null
jobstate "$J2" PREEMPTED; rsk status >/dev/null
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n $X--a01 -g 1 -t 30 -- python train.py --lr 1); RC=$?
[ "$RC" = 4 ] && has "$O" 'not the configuration of a02 it resumes' "R4-2: the cancelled a01's configuration named after a01 -> not covered by a02's preemption (exit 4)" || { bad "R4-2 (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
nosub "...nothing submitted"
O=$(rsk launch --relaunch $X); RC=$?
[ "$RC" = 0 ] && has "$O" "^submitted: $X a03 " "R4-2: a02's own configuration -> the relaunch grant resumes it (a03)" || { bad "R4-2 resume (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }

echo "-- R4-4: rsk watch --act checks every row for every action (--release too); a GPU-type deny matches every row of its target --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
printf '#@ run-watch v1\na fx-slurm - -p gpu -G gt-a -g 1 -t 1:00:00 -- python train.py\n' > "$R/t.tsv"   # no '#@ allow' line
O=$(rsk watch t.tsv --approve "watch a"); [ "$?" = 0 ] || bad "R4-4 setup: the table approved"
rsk grant deny --quote "never launch anything on fx-slurm any more" -T fx-slurm --action launch >/dev/null
: > "$T/sbatch.log"; O=$(rsk watch t.tsv --once --act --max-active 1 --release a); RC=$?
[ "$RC" = 3 ] && has "$O" 'row a on fx-slurm (launch)' "R4-4/N1: --release a under a launch deny (no '#@ allow' line) -> exit 3" || { bad "R4-4 release (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
nosub "...nothing submitted"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
printf '#@ run-watch v1\n#@ allow launch\na fx-slurm - -p gpu -G gt-a -g 1 -t 1:00:00 -- python train.py\n' > "$R/t.tsv"
rsk grant deny --quote "never use the gt-z GPUs" --gpu-type gt-z -T fx-slurm >/dev/null
O=$(rsk watch t.tsv --approve "watch a"); RC=$?
[ "$RC" = 3 ] && has "$O" 'GPU type is not certain here' "R4-4/N3: -G gt-a vs a gt-z deny: the partition may force a type -> exit 3, said why" || bad "R4-4 gpu type (rc=$RC)"

echo "-- R4-15: an unreadable grants.json -> rsk launch / cancel / watch --act exit 6, never 'no deny' --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
rsk grant deny --quote "never on fx-slurm" -T fx-slurm >/dev/null
GD=$(pyl 'print(L.Ledger(sys.argv[2]).dir)' "$R"); printf '{"version": 1, "records": [' > "$GD/grants.json"; rm -f "$GD/grants.json.prev"
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n exp--smoke--gu--a01 -g 1 -t 30 -- python t.py); RC=$?
[ "$RC" = 6 ] && has "$O" 'grants unreadable' "R4-15/N7: rsk launch -> exit 6 'grants unreadable'" || bad "R4-15 launch (rc=$RC)"
nosub "...nothing submitted"
printf '#@ run-watch v1\n#@ allow launch\na fx-slurm - -p gpu -g 1 -t 1:00:00 -- python train.py\n' > "$R/t.tsv"
O=$(rsk watch t.tsv --once --act --max-active 1); RC=$?
[ "$RC" = 6 ] && has "$O" 'grants unreadable' "R4-15/N7: rsk watch --act -> exit 6" || bad "R4-15 watch (rc=$RC)"
nosub "...nothing submitted"
: > "$T/scancel.log"; O=$(rsk cancel --job 101 -T fx-slurm --approve "cancel job 101"); RC=$?
[ "$RC" = 6 ] && has "$O" 'grants unreadable' "R4-15/N7: rsk cancel -> exit 6" || bad "R4-15 cancel (rc=$RC)"
[ ! -s "$T/scancel.log" ] && ok "...scancel never called" || bad "...scancel called"; CWD=$P

echo "-- round 5 R5-4: a run run-watch launched (never in the ledger) is a relaunch for rsk launch; R5-1 R5-8 R5-9 --"
R=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R" > "$R/.hpc.conf"; CWD=$R
rsk grant add --quote "run the a* experiments on fx-slurm" -T fx-slurm --name 'a*' --action launch --max-live 4 --max-launches 10 --expires none >/dev/null
printf '#@ run-watch v1\n#@ allow launch\na fx-slurm - -p gpu -g 1 -t 1:00:00 -- python train.py\n' > "$R/t.tsv"
O=$(rsk watch t.tsv --approve "run a under the watch"); RC=$?
: > "$T/sbatch.log"; O=$(rsk watch t.tsv --once --act --max-active 1); RC=$?
JA=$(printf '%s\n' "$O" | sed -n 's/.*LAUNCH name=a target=fx-slurm job=\([0-9][0-9]*\).*/\1/p' | head -n 1)
[ -n "$JA" ] && [ "$(grep -c . "$T/sbatch.log")" = 1 ] && [ -z "$(ls "$(pyl 'print(L.Ledger(sys.argv[2]).dir)' "$R")/runs" 2>/dev/null)" ] \
  && ok "R5-4 setup: run-watch launched a (job $JA); the ledger has no run" || { bad "R5-4 setup (rc=$RC, job '$JA')"; printf '%s\n' "$O" | tail -6 | sed 's/^/    | /'; }
jobstate "$JA" FAILED
O=$(rsk grant deny --quote "job $JA is broken: do not resubmit it" --job "$JA" --action relaunch); RC=$?
[ "$RC" = 2 ] && has "$O" "a deny of a run's launches names the run: --name" "R5-1: a deny by job id with a launch action -> exit 2 (it would match no launch)" || bad "R5-1 (rc=$RC)"
hasnt "$(rsk grant list)" "job $JA is broken" "...nothing recorded"
O=$(rsk grant deny --quote "never launch anything on fx-slrum" -T fx-slrum); RC=$?
[ "$RC" = 2 ] && has "$O" "unknown target 'fx-slrum'" "R5-9: a deny naming an unknown target -> exit 2 (it would match nothing)" || bad "R5-9 (rc=$RC)"
hasnt "$(rsk grant list)" 'fx-slrum' "...nothing recorded"
rsk grant deny --quote "do not relaunch a, it is broken" --action relaunch --name a >/dev/null
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n a -p gpu -g 1 -t 1:00:00 -- python train.py); RC=$?
[ "$RC" = 3 ] && has "$O" 'do not relaunch a, it is broken' "R5-4: rsk launch -n a after run-watch's a is a relaunch: the deny stops it (exit 3)" || { bad "R5-4 deny (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
has "$O" '— relaunch on fx-slurm' "...the card says relaunch"; nosub "...nothing submitted"
has "$O" '^  prior      1 earlier attempt(s) of a on fx-slurm' "...because the target's journal holds a's receipt (info_prior=1)"
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n a2 -p gpu -g 1 -t 1:00:00 -- python train.py); RC=$?
[ "$RC" = 0 ] && has "$O" '— launch on fx-slurm' "R5-4: a run the target never saw (info_prior=0) is a launch: the grant covers it" || { bad "R5-4 fresh (rc=$RC)"; printf '%s\n' "$O" | grep -E 'prior|covered|relaunch' | sed 's/^/    | /'; }
printf '#@ run-watch v1\n#@ allow launch\nb fx-slurm/ - -p gpu -g 1 -t 1:00:00 -- python b.py\n' > "$R/s.tsv"
rsk grant deny --quote "never launch b on fx-slurm" -T fx-slurm --name b >/dev/null; cp "$R/s.tsv" "$T/s.before"
O=$(rsk watch s.tsv --approve "run b"); RC=$?
[ "$RC" = 3 ] && cmp -s "$R/s.tsv" "$T/s.before" && has "$O" 'never launch b on fx-slurm' "R5-8: a row on 'fx-slurm/' meets the -T fx-slurm deny (exit 3, no '#@ ok')" || bad "R5-8 (rc=$RC)"

echo "-- round 5 R5-5: a failing scancel is unknown (the use kept); R6-4: ssh 255 before the first marker is unknown, whatever its stderr says --"
rsk grant add --quote "you may stop your own a runs" -T fx-slurm --name 'a*' --action cancel_own --max-live none --max-launches 3 --expires none >/dev/null
J2=$(pyl 'a = L.Ledger(sys.argv[2]).read_run("a2").data["attempts"]["a01"]; print(a["submissions"][-1]["job"])' "$R")
touch "$T/ssh.noconnect"; : > "$T/scancel.log"; O=$(rsk cancel a2); RC=$?; rm -f "$T/ssh.noconnect"
[ "$RC" = 5 ] && has "$O" 'the cancel may have been sent' "R6-4: ssh 'Connection refused', exit 255, no @@start -> exit 5, may have been sent" || bad "R6-4 cancel (rc=$RC)"
hasnt "$O" 'not reached' "...never 'not reached — nothing sent' (ssh's words are no proof)"
has "$(rsk grant list)" 'uses 1/3' "...the cancel_own use is kept"; has "$(att a2 a01)" '^SUBMITTED submitted' "...the ledger unchanged"
printf 'scancel: error: Kill job error on job id %s: Socket timed out on send/recv operation\n' "$J2" > "$T/scancel.err"
O=$(rsk cancel a2); RC=$?; rm -f "$T/scancel.err"
[ "$RC" = 5 ] && has "$O" "^UNKNOWN: job $J2 (a2 a01): scancel exit 1 (scancel: error: Kill job error on job id $J2: Socket timed out" "R5-5: scancel exit 1 (the cancel was applied) -> exit 5, unknown, quoting its own line (R6-8)" || { bad "R5-5 (rc=$RC)"; printf '%s\n' "$O" | tail -3 | sed 's/^/    | /'; }
hasnt "$O" 'not cancelled' "...never 'not cancelled'"; has "$(rsk grant list)" 'uses 2/3' "...the use is kept"
has "$(att a2 a01)" '^CANCELLING? submitted' "...the ledger: CANCELLING? (not confirmed)"
O=$(rsk launch -T fx-slurm -n a3 -p gpu -g 1 -t 1:00:00 -- python train.py); RC=$?; J3=$(jid "$O")
[ "$RC" = 0 ] && [ -n "$J3" ] || bad "R6-4 setup: a3 launched under the grant (rc=$RC)"
touch "$T/ssh.fallback"; : > "$T/scancel.log"; O=$(rsk cancel a3); RC=$?; rm -f "$T/ssh.fallback"
[ "$RC" = 5 ] && has "$O" 'the cancel may have been sent' "R6-4: a fallback route's 'Connection refused', the body ran, 255 -> exit 5, may have been sent" || bad "R6-4 fallback cancel (rc=$RC)"
has "$(cat "$T/scancel.log")" "^$J3\$" "...scancel DID run there (what 'not reached' used to deny)"; has "$(rsk grant list)" 'uses 3/3' "...the use is kept"
O=$(rsk launch -T fx-slurm -n c -p gpu -g 1 -t 1:00:00 -- python c.py); PC=$(pid_of "$O")   # R6-4 for a submit (integration)
touch "$T/ssh.noconnect"; : > "$T/sbatch.log"; O=$(rsk launch --plan "$PC" --approve "run c"); RC=$?; rm -f "$T/ssh.noconnect"
[ "$RC" = 5 ] && has "$O" '^SUBMIT_UNKNOWN: c a01 ' "R6-4 for rsk launch: ssh 'Connection refused', 255 -> exit 5, SUBMIT_UNKNOWN" \
  || { bad "R6-4 submit (rc=$RC, plan '$PC')"; printf '%s\n' "$O" | tail -3 | sed 's/^/    | /'; }
hasnt "$O" 'is free again' "...the plan is not released"; nosub "...nothing reached sbatch"
has "$(att c a01)" '^SUBMIT_UNKNOWN unknown' "...the ledger: SUBMIT_UNKNOWN (sticky)"
O=$(rsk launch --plan "$PC"); RC=$?
[ "$RC" = 6 ] && has "$O" 'was used already' "...the retry is refused (exit 6): never resubmitted blind" || bad "R6-4 submit retry (rc=$RC)"
nosub "...nothing submitted"
O=$(rsk launch -T fx-slurm -n d -p gpu -g 1 -t 1:00:00 -- python d.py); PD=$(pid_of "$O")
touch "$T/ssh.fallback"; : > "$T/sbatch.log"; O=$(rsk launch --plan "$PD" --approve "run d once"); RC=$?; rm -f "$T/ssh.fallback"
[ "$RC" = 5 ] && has "$O" '^SUBMIT_UNKNOWN: d a01 ' "R6-4: a fallback route's 'Connection refused', the submit ran there, 255 -> SUBMIT_UNKNOWN" || bad "R6-4 fallback submit (rc=$RC)"
[ "$(grep -c . "$T/sbatch.log")" = 1 ] && ok "...the job exists (1 sbatch)" || bad "...sbatch calls: $(grep -c . "$T/sbatch.log")"
jobstate "$(cat "$T/jobid")" COMPLETED                       # it ended: the remote duplicate guard no longer stops a retry
O=$(rsk launch --plan "$PD"); RC=$?
[ "$RC" = 6 ] && [ "$(grep -c . "$T/sbatch.log")" = 1 ] && ok "...the retry is refused: still 1 sbatch (was: submitted again)" || bad "R6-4 fallback retry (rc=$RC)"
rsk status >/dev/null
has "$(att d a01)" '^[A-Z]* submitted [0-9][0-9]* ' "...rsk status reconciles it from the journal's receipt (the job id)"

echo "-- round 6 R6-1: a relaunch deny naming a run stops every launch of it, also on a target whose journal never saw it --"
U6=$T/user-r61; cp -R "$RS_USER_DIR" "$U6"; mkdir -p "$U6/targets/fx2"; cp "$R/.hpc.conf" "$T/r.conf"
sed 's/T_HOST=fx;/T_HOST=fx2;/' "$U6/targets/fx-slurm/profile.sh" > "$U6/targets/fx2/profile.sh"; cp "$U6/targets/fx-slurm/policy.sh" "$U6/targets/fx2/"
( export RS_USER_DIR=$U6
  R2=$(mk_proj fx2 'x'); printf 'FX2_REMOTE_DIR=%s\n' "$R2" >> "$R/.hpc.conf"; cp "$R/.hpc.conf" "$R2/.hpc.conf"
  rsk grant add --quote "run the a* experiments on fx2 too" -T fx2 --name 'a*' --action launch --max-live 4 --max-launches 10 --expires none >/dev/null
  : > "$T/sbatch.log"; O=$(rsk launch -T fx2 -n a -p gpu -g 1 -t 1:00:00 -- python train.py); RC=$?
  [ "$RC" = 3 ] && has "$O" 'do not relaunch a, it is broken' "R6-1: run a on fx2 (run-watch ran it on fx-slurm) -> the relaunch deny naming a stops it (exit 3)" \
    || { bad "R6-1 xtarget (rc=$RC)"; printf '%s\n' "$O" | grep -E 'covered|denied|submitted|prior' | sed 's/^/    | /'; }
  has "$O" '— launch on fx2' "...the card says launch (fx2's journal holds no attempt of a)"
  has "$O" 'rsk cannot see every earlier attempt' "...the refusal says why a launch meets a relaunch deny"; nosub "...nothing submitted"
  rsk grant deny --quote "never relaunch anything on fx2" -T fx2 --action relaunch >/dev/null
  O=$(rsk launch -T fx2 -n a5 -p gpu -g 1 -t 1:00:00 -- python train.py); RC=$?
  [ "$RC" = 0 ] && has "$O" '— launch on fx2' "R6-1: a relaunch deny naming no run keeps the derived action: a fresh a5 is a covered launch" \
    || { bad "R6-1 unnamed (rc=$RC)"; printf '%s\n' "$O" | grep -E 'covered|denied|submitted|prior' | sed 's/^/    | /'; } )
cp "$T/r.conf" "$R/.hpc.conf"

echo "-- round 7 R7-2 + round 8 R8-3: a partition the profile does not list is exit 2 unless --unlisted-partition, then recorded with a NOTE (T_PARTITIONS: display only); R6-9 + R7-6: grant list and status flag a stored deny naming an unknown target; R6-7 --"
R6=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R6" > "$R6/.hpc.conf"; CWD=$R6
O=$(rsk grant deny --quote "never use the forbidden queue" -T fx-slurm --partition forbiden); RC=$?
[ "$RC" = 2 ] && has "$O" "partition forbiden is not in the profile's display list (T_PARTITIONS of fx-slurm: gpu, forbidden) — nothing recorded" "R8-3: a partition the profile does not list -> exit 2 naming it (a typo would never match: was recorded, inert)" || bad "R8-3 refusal (rc=$RC)"
has "$O" 'record it again with --unlisted-partition' "...it says how to record a real partition the display list omits"; hasnt "$(rsk grant list)" 'never use the forbidden queue' "...nothing recorded"
O=$(rsk grant deny --quote "never use the forbidden queue" -T fx-slurm --partition forbiden --unlisted-partition); RC=$?; DF=$(printf '%s\n' "$O" | sed -n 's/^\(d-[^ ]*\)  deny .*/\1/p')
[ "$RC" = 0 ] && has "$O" "NOTE: partition forbiden is not in the profile's display list (T_PARTITIONS of fx-slurm: gpu, forbidden) — recorded as given" "R8-3 / R7-2: with --unlisted-partition -> recorded (exit 0), a NOTE says so" || bad "R7-2 (rc=$RC)"
hasnt "$O" 'unknown partition' "...never 'unknown partition'"; has "$(rsk grant list)" 'never use the forbidden queue' "...recorded"
has "$(rsk grant list)" "NOTE: partition forbiden is not in the profile's display list" "...grant list repeats the NOTE"
hasnt "$(rsk grant list)" 'WARNING: .*partition' "...never 'never matches' for a partition (policy.sh decides what exists)"
O=$(rsk grant deny --quote "never the gt-zz GPUs" -T fx-slurm --gpu-type gt-zz --action cancel_own); RC=$?
[ "$RC" = 0 ] && has "$O" 'NOTE: GPU type gt-zz is not checked' "R6-5: a GPU type is not checked (no list), echoed" || bad "R6-5 gpu type (rc=$RC)"
pyl 'G.add(L.Ledger(sys.argv[2]), G.new_deny("never launch anything on fx-slurm again", {"targets": ["fx-slrum"]}))' "$R6"
has "$(rsk grant list)" 'WARNING: d-[^ ]* (deny): target fx-slrum is not one the harness knows .* never matches .* fix or revoke' "R6-9: grant list flags a stored deny naming an unknown target"
O=$(rsk status); has "$O" 'WARNING: d-[^ ]* (deny): target fx-slrum is not one the harness knows .* never matches .* fix or revoke' "R7-6: rsk status (the skill's first read) shows the same WARNING"
has "$O" "NOTE: partition forbiden is not in the profile's display list" "R7-6: ...and the partition NOTE"
rsk grant revoke "$DF" --quote "the forbidden queue is fine again" >/dev/null || bad "revoke $DF"   # (a partition deny matches every Slurm row of rsk watch: R6-7 below)
rsk grant deny --quote "do not cancel job 555 (the other project's eval)" --job 555 --action cancel >/dev/null
printf '#@ run-watch v1\n#@ allow launch\nw fx-slurm - -p gpu -g 1 -t 1:00:00 -- python w.py\n' > "$R6/w.tsv"
O=$(rsk watch w.tsv --approve "run w under the watch"); RC=$?
[ "$RC" = 0 ] && has "$(cat "$R6/w.tsv")" '^#@ ok ' "R6-7: a deny of job 555's cancel does not bind a table without fail-stop (approved)" || { bad "R6-7 (rc=$RC)"; printf '%s\n' "$O" | tail -3 | sed 's/^/    | /'; }
printf '#@ run-watch v1\n#@ allow launch fail-stop\nf fx-slurm - -p gpu -g 1 -t 1:00:00 -- python f.py\n' > "$R6/f.tsv"; cp "$R6/f.tsv" "$T/f.before"
O=$(rsk watch f.tsv --approve "run f, stop the rest if one fails"); RC=$?
[ "$RC" = 3 ] && cmp -s "$R6/f.tsv" "$T/f.before" && has "$O" 'do not cancel job 555' "R6-7: under fail-stop it binds (the row's job is not known here): exit 3, no '#@ ok'" || bad "R6-7 fail-stop (rc=$RC)"
CWD=$P

echo "-- round 7 R7-1: a deny written with an attempt's job name (<run>--aNN, as squeue shows it) stands for the whole run --"
R7=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R7" > "$R7/.hpc.conf"; CWD=$R7
rsk grant add --quote "run the smokes on fx and auto-resume them after a preemption" -T fx-slurm --action launch,relaunch --max-live none --max-launches none --expires 2099-12-31 >/dev/null
O=$(rsk launch -T fx-slurm -n exp--smoke--q -g 1 -- python t.py); J1=$(jid "$O"); jobstate "$J1" PREEMPTED; rsk status >/dev/null
O=$(rsk launch --relaunch exp--smoke--q); J2=$(jid "$O"); jobstate "$J2" PREEMPTED; rsk status >/dev/null
[ -n "$J1" ] && [ -n "$J2" ] && grep -q -- '--job-name=exp--smoke--q--a02' "$T/sbatch.log" && ok "R7-1 setup: a01 and a02 (job name exp--smoke--q--a02) preempted" || bad "R7-1 setup ($J1 $J2)"
O=$(rsk grant deny --quote "do not relaunch exp--smoke--q--a02, preemptions keep killing it" --action relaunch --name exp--smoke--q--a02); RC=$?
[ "$RC" = 0 ] && has "$O" "NOTE: name exp--smoke--q--a02 is an attempt's name (--aNN): the deny stands for run exp--smoke--q" "R7-1: recorded as given; the NOTE says the attempt's name stands for its run" || bad "R7-1 deny (rc=$RC)"
: > "$T/sbatch.log"; O=$(rsk launch --relaunch exp--smoke--q); RC=$?
[ "$RC" = 3 ] && has "$O" 'denied by d-.*preemptions keep killing it' "R7-1: the relaunch grant no longer resumes the run the user stopped by its attempt's name (exit 3)" || { bad "R7-1 relaunch (rc=$RC)"; printf '%s\n' "$O" | grep -E 'covered|denied|submitted' | sed 's/^/    | /'; }
nosub "...nothing submitted (was: a03 under the auto-resume grant)"
printf '#@ run-watch v1\n#@ allow launch preempt=2\nexp--smoke--q fx-slurm - -p gpu -g 1 -- python t.py\n' > "$R7/q.tsv"; cp "$R7/q.tsv" "$T/q.before"
O=$(rsk watch q.tsv --approve "watch q, resume it if preempted"); RC=$?
[ "$RC" = 3 ] && cmp -s "$R7/q.tsv" "$T/q.before" && has "$O" 'preemptions keep killing it' "R7-1: ...and a run-watch row of that run (named by its run id): exit 3, no '#@ ok'" || bad "R7-1 watch row (rc=$RC)"

echo "-- round 7 R7-2: T_PARTITIONS is a display list — a deny of a partition policy.sh accepts but the profile omits is recorded and enforced; commas separate --"
U7=$T/user-r72; cp -R "$RS_USER_DIR" "$U7"; mkdir -p "$U7/targets/fx-dbg"
sed "s/T_PARTITIONS='gpu forbidden'/T_PARTITIONS='gpu'/" "$U7/targets/fx-slurm/profile.sh" > "$U7/targets/fx-dbg/profile.sh"
printf '%s\n' 't_partition() { case "$1" in gpu|debug) P_GPUS=1-4 P_CPU_PER_GPU=8 P_MEM_PER_GPU=40 ;; *) return 1 ;; esac; }' 't_policy() { return 0; }' > "$U7/targets/fx-dbg/policy.sh"
( export RS_USER_DIR=$U7
  D7=$(mk_proj fx-dbg 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$D7" > "$D7/.hpc.conf"; CWD=$D7
  rsk grant add --quote "run the sweep on fx-dbg" -T fx-dbg --action launch --max-live 4 --max-launches 10 --expires 2099-12-31 >/dev/null
  O=$(rsk grant deny --quote "never use the debug partition, it is for the admins" -T fx-dbg --partition dbug); RC=$?
  [ "$RC" = 2 ] && has "$O" "partition dbug is not in the profile's display list (T_PARTITIONS of fx-dbg: gpu) — nothing recorded" "R8-3: a misspelt partition (dbug) -> exit 2 (was: recorded with the same NOTE as a real one, never matching)" || bad "R8-3 typo (rc=$RC)"
  hasnt "$(rsk grant list)" 'it is for the admins' "...nothing recorded"
  O=$(rsk grant deny --quote "never use the debug partition, it is for the admins" -T fx-dbg --partition debug); RC=$?
  [ "$RC" = 2 ] && has "$O" 'record it again with --unlisted-partition' "R8-3: a real partition the display list omits needs --unlisted-partition too (rsk cannot tell it from a typo)" || bad "R8-3 unlisted (rc=$RC)"
  O=$(rsk grant deny --quote "never use the debug partition, it is for the admins" -T fx-dbg --partition debug --unlisted-partition); RC=$?
  [ "$RC" = 0 ] && has "$O" "NOTE: partition debug is not in the profile's display list (T_PARTITIONS of fx-dbg: gpu)" "R7-2 / R8-3: the policy's debug partition with --unlisted-partition: the deny is recorded" || bad "R7-2 authority deny (rc=$RC)"
  : > "$T/sbatch.log"; O=$(rsk launch -T fx-dbg -n s1 -p debug -g 1 -t 30 -- python train.py); RC=$?
  [ "$RC" = 3 ] && has "$O" 'never use the debug partition' "R7-2: -p debug under the standing grant -> the deny wins (exit 3)" || { bad "R7-2 enforced (rc=$RC)"; printf '%s\n' "$O" | grep -E 'covered|denied|submitted|partition' | sed 's/^/    | /'; }
  has "$O" '^  partition  debug$' "...(the target's policy accepts debug: the plan names it)"; nosub "...nothing submitted"
  hasnt "$(rsk grant list)" 'WARNING' "...grant list never says 'never matches' about it"
  O=$(rsk launch -T fx-dbg -n s2 -p gpu -g 1 -t 30 -- python train.py); RC=$?
  [ "$RC" = 0 ] && has "$O" '^covered by g-' "...the grant still covers the other partition" || bad "R7-2 gpu (rc=$RC)"
  sed "s/T_PARTITIONS='gpu'/T_PARTITIONS='gpu,debug'/" "$U7/targets/fx-dbg/profile.sh" > "$T/p.x" && mv "$T/p.x" "$U7/targets/fx-dbg/profile.sh"
  O=$(rsk grant deny --quote "never debug on fx-dbg" -T fx-dbg --partition debug); RC=$?
  [ "$RC" = 0 ] && hasnt "$O" 'NOTE' "R7-2: T_PARTITIONS='gpu,debug' is two partitions (commas separate, as run-avail's sinfo -p list): no NOTE" || bad "R7-2 comma (rc=$RC)"
  hasnt "$(rsk grant list)" 'NOTE: partition' "...nor in grant list" )

echo "-- round 7 R7-7: a table with a NUL byte (or another control character but tab) is refused by rsk and run-watch alike --"
CWD=$R7
rsk grant deny --quote "do not cancel job 1001, whatever happens to the group" --job 1001 --action cancel -T fx-slurm >/dev/null
printf '#@ run-watch v1\n#@ allow launch errors=0 fail\0-stop\nn1 fx-slurm - -p gpu -g 1 -- python a.py\n' > "$R7/n.tsv"; cp "$R7/n.tsv" "$T/n.before"
for a in "--approve go" "--once --act" "--once"; do
  O=$(rsk watch n.tsv $a); RC=$?
  [ "$RC" = 2 ] && has "$O" '^rsk: n.tsv: line 2 holds 0x00, a NUL byte or a control character other than tab — a run-watch table is plain text (LF line ends); rsk and run-watch both refuse it$' "R7-7: rsk watch n.tsv $a -> exit 2 (was: fail-stop unseen, the job deny dropped)" || bad "R7-7 $a (rc=$RC)"
done
cmp -s "$R7/n.tsv" "$T/n.before" && ok "...the table untouched (no '#@ ok')" || bad "...the table untouched"
[ -z "$(pyl 'print(L.Ledger(sys.argv[2]).lease().data or "")' "$R7")" ] && ok "...no lease taken" || bad "...no lease taken"
W1=$(cd "$R7" && PATH="$T/bin:$PATH" bash "$RS_HOME/bin/run-watch" n.tsv --once 2>&1); RC=$?
W1=$(printf '%s\n' "$W1" | grep -o 'n\.tsv: line 2 holds 0x00, .*both refuse it' | head -n 1)
W2=$(rsk watch n.tsv --once | grep -o 'n\.tsv: line 2 holds 0x00, .*both refuse it' | head -n 1)
[ "$RC" = 2 ] && [ -n "$W1" ] && [ "$W1" = "$W2" ] && ok "R7-7: bin/run-watch refuses it too (exit 2), in the same words" || bad "R7-7 run-watch (rc=$RC: '$W1')"
printf '#@ run-watch v1\r\n#@ allow launch\r\nc1 fx-slurm - -p gpu -g 1 -- python a.py\r\n' > "$R7/c.tsv"
O=$(rsk watch c.tsv --once); RC=$?
[ "$RC" = 2 ] && has "$O" 'c.tsv: line 1 holds 0x0d' "R7-7: a CRLF table too (a CR is a control character)" || bad "R7-7 CRLF (rc=$RC)"
CWD=$P

echo "-- round 8 R8-1: a comma list written with spaces is split and stripped; whitespace inside an item or an empty item is exit 2 --"
R8=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R8" > "$R8/.hpc.conf"; CWD=$R8
rsk grant add --quote "run the sw sweep on fx-slurm; you may cancel your own sweep jobs" -T fx-slurm --action launch,cancel_own --max-live none --max-launches none --expires none >/dev/null
O=$(rsk launch -T fx-slurm -n sw1 -p gpu -g 1 -t 1:00:00 -- python t.py); S1=$(jid "$O")
O=$(rsk launch -T fx-slurm -n sw2 -p gpu -g 1 -t 1:00:00 -- python t.py); S2=$(jid "$O")
[ -n "$S1" ] && [ -n "$S2" ] && ok "R8-1 setup: sw1 (job $S1) and sw2 (job $S2) under the grant" || bad "R8-1 setup ('$S1' '$S2')"
O=$(rsk grant deny --quote "never cancel jobs $S1 or $S2" -T fx-slurm --job "$S1 $S2" --action cancel --action cancel_own); RC=$?
[ "$RC" = 2 ] && has "$O" "item '$S1 $S2' holds whitespace" "R8-1: --job '$S1 $S2' -> exit 2 naming the item (was: one entry that never matched)" || bad "R8-1 inner space (rc=$RC)"
O=$(rsk grant deny --quote "never cancel jobs $S1 or $S2" -T fx-slurm --job "$S1," --action cancel); RC=$?
[ "$RC" = 2 ] && has "$O" "an empty item" "R8-1: --job '$S1,' -> exit 2 (an empty item)" || bad "R8-1 empty item (rc=$RC)"
hasnt "$(rsk grant list)" "never cancel jobs" "...nothing recorded by either"
O=$(rsk grant deny --quote "never cancel jobs $S1 or $S2" -T fx-slurm --job "$S1, $S2" --action ' cancel, cancel_own'); RC=$?
[ "$RC" = 0 ] && has "$O" "DENY cancel, cancel_own: targets fx-slurm; jobs $S1, $S2\$" "R8-1: --job '$S1, $S2' -> the two job ids, stripped (was: '$S1', ' $S2')" || bad "R8-1 jobs (rc=$RC)"
: > "$T/scancel.log"; O=$(rsk cancel sw2); RC=$?
[ "$RC" = 3 ] && has "$O" "never cancel jobs $S1 or $S2" "R8-1: the agent's cancel_own of sw2 (job $S2) -> denied, exit 3 (was: cancelled)" || bad "R8-1 cancel (rc=$RC)"
[ ! -s "$T/scancel.log" ] && ok "...scancel never called" || bad "...scancel called"
O=$(rsk grant deny --quote "never launch b1 or b2" -T fx-slurm --name 'b1, b2' --action launch); RC=$?
[ "$RC" = 0 ] && has "$O" 'names b1, b2$' "R8-1: --name 'b1, b2' -> b1 and b2" || bad "R8-1 names (rc=$RC)"
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n b2 -p gpu -g 1 -t 1:00:00 -- python t.py); RC=$?
[ "$RC" = 3 ] && has "$O" 'never launch b1 or b2' "R8-1: rsk launch -n b2 under the grant -> denied, exit 3 (was: submitted)" || bad "R8-1 launch b2 (rc=$RC)"
nosub "...nothing submitted"
printf '#@ run-watch v1\n#@ allow launch\nb2 fx-slurm - -p gpu -g 1 -t 1:00:00 -- python b.py\n' > "$R8/b.tsv"; cp "$R8/b.tsv" "$T/b.before"
O=$(rsk watch b.tsv --approve "run b2 under the watch"); RC=$?
[ "$RC" = 3 ] && cmp -s "$R8/b.tsv" "$T/b.before" && has "$O" 'never launch b1 or b2' "R8-1: ...and rsk watch --approve of a row b2 -> exit 3, no '#@ ok'" || bad "R8-1 watch (rc=$RC)"
O=$(rsk grant deny --quote "never b 3" -T fx-slurm --name 'b 3' --action launch); RC=$?
[ "$RC" = 2 ] && has "$O" "item 'b 3' holds whitespace" "R8-1: --name 'b 3' -> exit 2" || bad "R8-1 name with a space (rc=$RC)"
O=$(rsk grant deny --quote "never the gt-a or gt-b GPUs" -T fx-slurm --gpu-type 'gt-a gt-b' --action launch); RC=$?
[ "$RC" = 2 ] && has "$O" "item 'gt-a gt-b' holds whitespace" "R8-1: --gpu-type 'gt-a gt-b' -> exit 2" || bad "R8-1 gpu type (rc=$RC)"
O=$(rsk grant deny --quote "never the forbidden or gpu partitions" -T ' fx-slurm' --partition 'forbidden, gpu' --action launch); RC=$?; DP=$(printf '%s\n' "$O" | sed -n 's/^\(d-[^ ]*\)  deny .*/\1/p')
[ "$RC" = 0 ] && hasnt "$O" 'NOTE' "R8-1: -T ' fx-slurm' --partition 'forbidden, gpu' -> fx-slurm, two listed partitions (no NOTE: was ' gpu', unlisted)" || bad "R8-1 partitions (rc=$RC)"
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n c1 -p gpu -g 1 -t 1:00:00 -- python t.py); RC=$?
[ "$RC" = 3 ] && has "$O" 'never the forbidden or gpu partitions' "R8-1: -p gpu under the grant -> denied, exit 3 (was: submitted)" || bad "R8-1 partition launch (rc=$RC)"
nosub "...nothing submitted"
rsk grant revoke "$DP" --quote "the gpu partition is fine again" >/dev/null || bad "revoke $DP"
GD=$(pyl 'print(L.Ledger(sys.argv[2]).dir)' "$R8")
pyl 'import json; p = sys.argv[2] + "/grants.json"; d = json.load(open(p)); r = next(x for x in d["records"] if x["kind"] == "deny" and "jobs" in x["scope"]); r["scope"]["jobs"] = ["999", " 998"]; json.dump(d, open(p, "w"))' "$GD"
rm -f "$GD/grants.json.prev"
has "$(rsk grant list)" "INVALID — taken as a deny: matches EVERYTHING .*scope.jobs: ' 998': whitespace in a scope item" "R8-1: a stored deny item with whitespace (a hand edit) -> invalid, a deny matching everything (fail closed)"
: > "$T/sbatch.log"; O=$(rsk launch -T fx-slurm -n d1 -p gpu -g 1 -t 1:00:00 -- python t.py); RC=$?
[ "$RC" = 3 ] && has "$O" 'a damaged record that may be a deny matches everything' "R8-1: ...a launch the grant covers -> exit 3 (fail closed)" || { bad "R8-1 fail closed (rc=$RC)"; printf '%s\n' "$O" | tail -3 | sed 's/^/    | /'; }
nosub "...nothing submitted"
CWD=$P

echo "-- round 8 R8-2: rsk cancel --approve: the user's words name what is cancelled (job id / pid, run id or name), else exit 4 --"
R82=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$R82" > "$R82/.hpc.conf"; CWD=$R82
rsk grant add --quote "run the sw sweep on fx-slurm" -T fx-slurm --action launch --max-live none --max-launches none --expires none >/dev/null
O=$(rsk launch -T fx-slurm -n sw1 -p gpu -g 1 -t 1:00:00 -- python t.py); S1=$(jid "$O")
O=$(rsk launch -T fx-slurm -n sw2 -p gpu -g 1 -t 1:00:00 -- python t.py); S2=$(jid "$O")
[ -n "$S1" ] && [ -n "$S2" ] && ok "R8-2 setup: sw1 (job $S1) and sw2 (job $S2), both live" || bad "R8-2 setup ('$S1' '$S2')"
: > "$T/scancel.log"; O=$(rsk cancel --job "$S2" -T fx-slurm --approve "cancel job $S1, it diverged"); RC=$?
[ "$RC" = 4 ] && has "$O" "^needs user: the words do not name $S2 — " "R8-2: --job $S2 with words naming job $S1 -> exit 4 (was: an approval for $S2, cancelled)" || { bad "R8-2 job (rc=$RC)"; printf '%s\n' "$O" | tail -3 | sed 's/^/    | /'; }
O=$(rsk cancel sw2 --approve "cancel sw1, it diverged"); RC=$?
[ "$RC" = 4 ] && has "$O" "^needs user: the words do not name sw2 — " "R8-2: rsk cancel sw2 with words naming sw1 -> exit 4" || bad "R8-2 run (rc=$RC)"
O=$(rsk cancel sw2 --approve "cancel sw10 and job 1$S2"); RC=$?
[ "$RC" = 4 ] && ok "R8-2: sw10 / 1$S2 do not name sw2 / $S2 (whole tokens only) -> exit 4" || bad "R8-2 tokens (rc=$RC)"
hasnt "$(rsk grant list)" 'approval' "...no approval recorded by any of them"; [ ! -s "$T/scancel.log" ] && ok "...scancel never called" || bad "...scancel called"
O=$(rsk cancel sw2 --approve "cancel job $S2."); RC=$?
[ "$RC" = 0 ] && has "$(cat "$T/scancel.log")" "^$S2\$" "R8-2: words naming job $S2 -> cancelled" || bad "R8-2 named job (rc=$RC)"
: > "$T/scancel.log"; O=$(rsk cancel --job "$S1" -T fx-slurm --approve "stop sw1, it diverged"); RC=$?
[ "$RC" = 0 ] && has "$(cat "$T/scancel.log")" "^$S1\$" "R8-2: --job $S1 with words naming its run sw1 -> cancelled" || bad "R8-2 named run (rc=$RC)"
echo "-- NF8: a yes to the agent's own question (--asked) names what the question names; a numeric range names the ids in it --"
O=$(rsk launch -T fx-slurm -n sw3 -p gpu -g 1 -t 1:00:00 -- python t.py); S3=$(jid "$O")
O=$(rsk launch -T fx-slurm -n sw4 -p gpu -g 1 -t 1:00:00 -- python t.py); S4=$(jid "$O")
O=$(rsk launch -T fx-slurm -n sw5 -p gpu -g 1 -t 1:00:00 -- python t.py); S5=$(jid "$O")
Q="sw3 (job $S3) diverged — cancel it?"; : > "$T/scancel.log"
O=$(rsk cancel sw3 --approve "yes"); RC=$?
[ "$RC" = 4 ] && has "$O" 'pass that question with --asked' "NF8: a bare yes names nothing -> exit 4, and rsk says how to pass the question it answers" || bad "NF8 bare yes (rc=$RC)"
O=$(rsk cancel sw4 --asked "$Q" --approve "yes"); RC=$?
[ "$RC" = 4 ] && has "$O" "^needs user: the words do not name sw4 — \"yes\" (answering \"$Q\") names none of: job $S4" "NF8: a yes to a question about sw3, passed for sw4 -> exit 4 (the slip R8-2 guards against)" || bad "NF8 asked other (rc=$RC)"
[ ! -s "$T/scancel.log" ] && ok "...scancel never called" || bad "...scancel called"
O=$(rsk cancel sw3 --asked "$Q" --approve "yes"); RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/scancel.log")" = "$S3" ] && has "$O" "(answering \"$Q\")" "NF8: --asked naming sw3 + the user's yes -> job $S3 cancelled once, no second question" || { bad "NF8 asked (rc=$RC)"; printf '%s\n' "$O" | tail -3 | sed 's/^/    | /'; }
has "$(rsk grant list)" "approval  via cli (asked: \"$Q\")" "...the approval keeps the question (its source) beside the words"
has "$(cat "$T"/state/projects/*/audit.jsonl)" "\"asked\": \"$Q\".*\"event\": \"cancel\"" "...and so does the audit's cancel line"
: > "$T/scancel.log"
for r in sw4 sw5; do O=$(rsk cancel "$r" --approve "cancel jobs $S4-$S5"); RC=$?
  [ "$RC" = 0 ] || { bad "NF8: rsk cancel $r --approve 'cancel jobs $S4-$S5' (rc=$RC)"; printf '%s\n' "$O" | tail -3 | sed 's/^/    | /'; }; done
[ "$(tr '\n' ' ' < "$T/scancel.log")" = "$S4 $S5 " ] && ok "NF8: 'cancel jobs $S4-$S5' names both ids in the range -> both cancelled" || bad "NF8 range ($(cat "$T/scancel.log"))"
CWD=$P

echo "-- watch: the lease (one watcher per project) --"
sleep 60 & LP=$!
pyl 'import socket, time; led = L.Ledger(sys.argv[2]); led.ensure(); p = int(sys.argv[3])
L.write_json(led.dir / "watch.lease", {"pid": p, "pid_start": L._pid_start(p), "host": socket.gethostname(), "boot_id": L.boot_id(), "started": L.now(), "until": time.time() + 600, "argv": []})' "$P" "$LP"
O=$(rsk watch some.table --once); RC=$?
[ "$RC" = 6 ] && has "$O" "a watch lease is held: pid $LP" "another live holder -> exit 6" || bad "lease conflict (rc=$RC)"
kill "$LP"; wait "$LP" 2>/dev/null; LP=""
O=$(rsk watch); RC=$?
[ "$RC" = 2 ] && has "$O" 'usage: run-watch' "a dead holder: run-watch runs (its usage error, exit 2)" || bad "watch runs (rc=$RC)"
[ -z "$(pyl 'print(L.Ledger(sys.argv[2]).lease().data or "")' "$P")" ] && ok "...and the lease is released" || bad "...lease released"

if [ ! -r /proc/self/stat ] || ! command -v setsid >/dev/null 2>&1; then
  echo "  SKIP: the nohup part (launch.sh needs Linux /proc + setsid)"; exit 0; fi
echo "-- nohup: a busy GPU is never a grant's call; the approved card launches onto it --"
W=$(mk_proj ws-box 'x'); ln -s "$W" "$H/projects/w"; printf 'WS_REMOTE_DIR=projects/w\nENV_KIND=none\n' > "$W/.ws.conf"; CWD=$W
printf 'GPU-aaaa0000-0001, %s\n' "$$" > "$T/apps"
O=$(rsk launch -T ws-box -d 1 -N busy1 -- sleep 30); RC=$?
[ "$RC" = 6 ] && has "$O" 'a GPU in use' "-d onto a busy GPU, no --gpu-busy-ok -> exit 6" || bad "busy -d (rc=$RC)"
! ls "$W"/logs/busy1-* >/dev/null 2>&1 && ok "...nothing launched" || bad "...nothing launched"
rsk grant add --quote "launch anything on the box" -T ws-box --action launch --allow-warnings any --max-live none --max-launches none --expires 2099-12-31 >/dev/null
O=$(rsk launch -T ws-box -d 1 -N busy1 --gpu-busy-ok -- sleep 30); RC=$?; PB=$(pid_of "$O")
[ "$RC" = 4 ] && has "$O" "never a standing grant's call" "--gpu-busy-ok: not covered even by a grant with --allow-warnings" || { bad "busy + grant (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }
has "$O" "^  busy now   1:$ME:$$" "card: who uses which GPU"; has "$O" '^  ON A BUSY GPU: GPU(s) 1' "card: ON A BUSY GPU"
O=$(rsk launch --plan "$PB" --approve "yes, share GPU 1 with my other job"); RC=$?
[ "$RC" = 0 ] && has "$O" '^launched: busy1 a01 pid [0-9]* on GPU(s) 1 of ws-box' "approved card -> launched onto GPU 1" || { bad "approved busy launch (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }
has "$(grep -- '--rs-expect' "$T/ssh-cmd.log" | tail -n 1)" '--gpu-busy-ok' "...run-launch was given --gpu-busy-ok"
has "$(att busy1 a01)" '^SUBMITTED submitted [0-9]' "...ledger: submitted with the pid"
has "$(pyl 'print(json.dumps(L.Ledger(sys.argv[2]).read_run("busy1").data["attempts"]["a01"]["submissions"][-1]["proc"]))' "$W")" '"start": "[0-9]' "...the receipt triple read back (start)"
O=$(rsk launch -T ws-box -d 2 -N free1 --nice 5 -- sleep 30); RC=$?
[ "$RC" = 0 ] && has "$O" '^covered by g-' "a free GPU: covered by the grant, launched" || bad "free GPU launch (rc=$RC)"
has "$O" '^  nice       5$' "...--nice reaches the plan (bound)"
O=$(rsk launch -T ws-box -d 3 -N ds1 -- deepspeed --num_gpus 4 train.py); RC=$?; PD=$(pid_of "$O")
[ "$RC" = 4 ] && has "$O" "no standing grant covers that, whatever its --allow-warnings" "NF8: a launcher WARNING (deepspeed --num_gpus 4) -> exit 4 under the box's --allow-warnings any grant" || { bad "NF8 box any (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
has "$O" '^  NO GRANT   1 launcher / container / env-dropping warning(s)' "...the card says NO GRANT"; ! ls "$W"/logs/ds1-* >/dev/null 2>&1 && ok "...nothing launched" || bad "...nothing launched"
O=$(rsk launch --plan "$PD" --approve "yes, deepspeed may take four GPUs"); RC=$?
[ "$RC" = 0 ] && has "$O" '^launched: ds1 a01 pid [0-9]* on GPU(s) 3 of ws-box' "...the user's approval of that card launches it" || { bad "NF8 approved card (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }

echo "-- nohup cancel: receipt + /proc start + boot_id, TERM to the group, KILL after the grace --"
O=$(rsk cancel busy1 --approve "stop busy1" --grace 5); RC=$?
[ "$RC" = 0 ] && has "$O" '^cancelled: pid [0-9]* (busy1 a01) on ws-box — TERM, its group is gone, rc 143' "TERM -> gone, rc 143 from <log>.rc" || { bad "nohup cancel (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }
has "$(att busy1 a01)" '^CANCELLED' "...ledger: CANCELLED"
O=$(rsk launch -T ws-box -d 3 -N stub1 -- "sh -c 'trap \"\" TERM; sleep 60'"); RC=$?
[ "$RC" = 0 ] || bad "a TERM-immune run launches (rc=$RC)"
O=$(rsk cancel stub1 --approve "stop busy1" --grace 2); RC=$?
[ "$RC" = 4 ] && has "$O" '^needs user: the words do not name stub1 — ' "R8-2 (nohup): words naming another run -> exit 4, nothing signalled" || bad "R8-2 nohup (rc=$RC)"
O=$(rsk cancel stub1 --approve "stop stub1" --grace 2); RC=$?
[ "$RC" = 0 ] && has "$O" 'then KILL after the grace' "a run that ignores TERM -> KILL after the grace" || { bad "KILL fallback (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }

echo "-- H1-owner / H1-msg: an approved busy landing binds who is on it; another occupant since -> exit 6, named --"
CWD=$W; U1=$(ps -o user= -p 1 2>/dev/null | tr -d ' '); printf 'GPU-aaaa0000-0001, %s\n' "$$" > "$T/apps"
O=$(rsk launch -T ws-box -d 1 -N share1 --gpu-busy-ok -- sleep 30); PS1=$(pid_of "$O")
has "$O" "^  busy ok    1:GPU-aaaa0000-0001:$ME$" "the card binds the GPU, its UUID and who is on it"
printf 'GPU-aaaa0000-0001, 1\n' > "$T/apps"                    # the user's own process ended; pid 1 ($U1) is on GPU 1 now
O=$(rsk launch --plan "$PS1" --approve "yes, share GPU 1 with my eval job"); RC=$?
[ "$RC" = 6 ] && has "$O" "busy_ok: 1:GPU-aaaa0000-0001:$ME → 1:GPU-aaaa0000-0001:${U1:-?}" "H1-owner/msg: another occupant -> exit 6, the refusal names the change" || { bad "H1-owner (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
hasnt "$O" 'the conf changed since' "...never blamed on the conf"; ! ls "$W"/logs/share1-* >/dev/null 2>&1 && ok "...nothing launched" || bad "...launched beside another user's process"
rm -f "$T/apps" "$T/apps.next"

echo "-- round 7 R7-5: the launcher config launch.sh read is bound (launch_cfg): a change after the card -> exit 6, named --"
W8=$(mk_proj ws-box 'x'); ln -s "$W8" "$H/projects/w8"; printf 'WS_REMOTE_DIR=projects/w8\nENV_KIND=none\n' > "$W8/.ws.conf"; CWD=$W8
rm -f "$T/apps" "$T/apps.next"; printf 'distributed_type: MULTI_GPU\nnum_processes: 1\ngpu_ids: 0\n' > "$W8/ddp.yaml"
O=$(rsk launch -T ws-box -g 1 -N ad -- accelerate launch --config_file ddp.yaml train.py); RC=$?; PAD=$(pid_of "$O")
[ "$RC" = 4 ] && has "$O" '^  launch cfg .*ddp\.yaml (sha256 [0-9a-f]\{12\})$' "R7-5: the card shows the config launch.sh read, with its digest" || { bad "R7-5 card (rc=$RC)"; printf '%s\n' "$O" | grep -E 'launch cfg|WARNING|lacks|needs' | sed 's/^/    | /'; }
printf '%s\n' "$O" | grep -A1 '^  launch cfg' | tail -n 1 | grep -q '^  busy ok' && ok "...shown in the bound order (right before busy ok)" || bad "...launch cfg before busy ok"
printf 'distributed_type: MULTI_GPU\nnum_processes: 1\ngpu_ids: 1\n' > "$W8/ddp.yaml"      # edited after the card
O=$(rsk launch --plan "$PAD" --approve "ok, accelerate on GPU 0 is fine"); RC=$?
[ "$RC" = 6 ] && has "$O" 'launch_cfg: .*ddp\.yaml (sha256 [0-9a-f]\{12\}) → .*ddp\.yaml (sha256 [0-9a-f]\{12\})' "R7-5: the config changed since the card -> exit 6, rsk names launch_cfg (was: launched onto gpu_ids 1)" || { bad "R7-5 drift (rc=$RC)"; printf '%s\n' "$O" | tail -6 | sed 's/^/    | /'; }
has "$O" 'changed: launch_cfg' "...the box says changed: launch_cfg"
! ls "$W8"/logs/ad-* >/dev/null 2>&1 && ok "...nothing launched" || bad "...launched with a config the user never saw"
has "$(att ad a01)" '^NOT_SUBMITTED' "...ledger: NOT_SUBMITTED"

echo "-- F-unknown (nohup) + D10: run-launch's GPU-table read fails before its launch ssh -> NOT_SUBMITTED; --plan retries --"
W5=$(mk_proj ws-box 'x'); ln -s "$W5" "$H/projects/w5"; printf 'WS_REMOTE_DIR=projects/w5\nENV_KIND=none\n' > "$W5/.ws.conf"; CWD=$W5
O=$(rsk launch -T ws-box -d 2 -N tf -- sleep 30); PTF=$(pid_of "$O")
touch "$T/ssh.failtable"; O=$(rsk launch --plan "$PTF" --approve "yes, launch tf"); RC=$?; rm -f "$T/ssh.failtable"
[ "$RC" = 5 ] && has "$O" 'before its launch ssh: nothing was sent' "F-unknown: the table read failed -> exit 5, not submitted" || { bad "F-unknown nohup (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
has "$(att tf a01)" '^NOT_SUBMITTED not_submitted' "...ledger: NOT_SUBMITTED (never SUBMIT_UNKNOWN)"
O=$(rsk launch --plan "$PTF"); RC=$?
[ "$RC" = 0 ] && has "$O" '^launched: tf a0[0-9] pid [0-9]* on GPU(s) 2' "D10: the same plan under the same approval -> launched" || { bad "D10 nohup retry (rc=$RC)"; printf '%s\n' "$O" | tail -12 | sed 's/^/    | /'; }

echo "-- L3-regex / G-space: a remote dir with a space; the receipt is read back --"
W6=$(mk_proj ws-box 'x'); ln -s "$W6" "$H/projects/w x"; printf 'WS_REMOTE_DIR="projects/w x"\nENV_KIND=none\n' > "$W6/.ws.conf"; CWD=$W6
rsk grant add --quote "launch on the box" -T ws-box --action launch --max-live 5 --max-launches 5 --expires 2099-12-31 >/dev/null
O=$(rsk launch -T ws-box -d 2 -N sp1 -- sleep 30); RC=$?
[ "$RC" = 0 ] && has "$O" '^launched: sp1 a01 pid [0-9]* on GPU(s) 2 of ws-box, log logs/sp1-' "G-space: launched, not SUBMIT_UNKNOWN" || { bad "G-space (rc=$RC)"; printf '%s\n' "$O" | tail -4 | sed 's/^/    | /'; }
has "$(att sp1 a01)" '^SUBMITTED submitted [0-9]' "...ledger: submitted with the pid"

echo "-- review H1: --gpu-busy-ok names the GPUs; a free card landing never sends it — a GPU busy since is refused --"
W2=$(mk_proj ws-box 'x'); ln -s "$W2" "$H/projects/w2"; printf 'WS_REMOTE_DIR=projects/w2\nENV_KIND=none\n' > "$W2/.ws.conf"; CWD=$W2
rsk grant add --quote "launch small runs on the box" -T ws-box --action launch --max-gpus 1 --max-live 3 --max-launches 3 --expires 2099-12-31 >/dev/null
rm -f "$T/apps" "$T/apps.next"; : > "$T/ssh-host.log"
O=$(rsk launch -T ws-box -g 1 -N r1 --gpu-busy-ok -- sleep 5); RC=$?
[ "$RC" = 2 ] && has "$O" '--gpu-busy-ok needs -d IDS' "H1: --gpu-busy-ok with a count -> exit 2 (the user's words name the GPU)" || bad "H1 count (rc=$RC)"
[ ! -s "$T/ssh-host.log" ] && ok "...before any ssh" || bad "...before any ssh (H1)"
printf 'GPU-aaaa0000-0001, %s\n' "$$" > "$T/apps.next"      # GPU 1 free for the plan, busy at the submit
O=$(rsk launch -T ws-box -d 1 -N r2 --gpu-busy-ok -- sleep 30); RC=$?
[ "$RC" = 6 ] && has "$O" '^covered by g-' "H1: the plan landed on a free GPU 1 (covered); GPU 1 busy since -> refused on the box (exit 6)" || { bad "H1 busy since (rc=$RC)"; printf '%s\n' "$O" | tail -6 | sed 's/^/    | /'; }
hasnt "$(grep -- '--rs-expect' "$T/ssh-cmd.log" | tail -n 1)" '--gpu-busy-ok' "...the submit carried no --gpu-busy-ok (the card's own landing was free)"
! ls "$W2"/logs/r2-* >/dev/null 2>&1 && ok "...nothing launched onto the busy GPU" || bad "...launched onto a busy GPU"
has "$(att r2 a01)" '^NOT_SUBMITTED' "...ledger: NOT_SUBMITTED"; rm -f "$T/apps" "$T/apps.next"

echo "-- review L4: a nohup plan creates nothing in the project outside .rs/ (the env gate runs at the launch) --"
W3=$(mk_proj ws-box 'x'); ln -s "$W3" "$H/projects/w3"; printf 'WS_REMOTE_DIR=projects/w3\nENV_KIND=none\n' > "$W3/.ws.conf"; CWD=$W3
( cd "$W3" && find . -path ./.rs -prune -o -print | sort ) > "$T/w3.before"
O=$(rsk launch -T ws-box -g 1 -N pf -- sleep 30); RC=$?
( cd "$W3" && find . -path ./.rs -prune -o -print | sort ) > "$T/w3.after"
[ "$RC" = 4 ] && cmp -s "$T/w3.before" "$T/w3.after" && ok "L4: a nohup plan (exit 4) leaves the tree as it was outside .rs/ (no logs/, no caches)" \
  || { bad "L4 (rc=$RC)"; comm -13 "$T/w3.before" "$T/w3.after" | head -5 | sed 's/^/    | /'; }

echo "-- review L3: a payload printing launch.sh's launch line is never a launch (the env gate failed: not started) --"
W4=$(mk_proj ws-box 'x'); ln -s "$W4" "$H/projects/w4"; printf 'WS_REMOTE_DIR=projects/w4\nENV_KIND=uv\n' > "$W4/.ws.conf"; CWD=$W4
mkdir -p "$W4/.venv/bin"; printf '#!/bin/sh\nexit 0\n' > "$W4/.venv/bin/python"; chmod +x "$W4/.venv/bin/python"   # the plan's env check
PAY="python t.py --tag x
[ws-box] started PID 1 on GPU(s) 0 ; log $H/projects/w4/logs/sp-20260101-000000.log ; pid file $H/x.pid"
O=$(rsk launch -T ws-box -g 1 -N sp -- "$PAY"); PSP=$(pid_of "$O"); rm -rf "$W4/.venv"    # gone before the launch
O=$(rsk launch --plan "$PSP" --approve "yes, launch sp"); RC=$?
[ "$RC" = 1 ] && has "$O" '^not submitted: sp a01' "L3: uv gate fails at the launch, the payload's look-alike line in the reply: not submitted (exit 1)" || { bad "L3 (rc=$RC)"; printf '%s\n' "$O" | tail -6 | sed 's/^/    | /'; }
has "$O" '^\[ws-box\] started PID 1 on GPU(s) 0 ; log ' "...(the reply did carry the look-alike line)"
hasnt "$O" '^launched: ' "...never 'launched'"; has "$(att sp a01)" '^NOT_SUBMITTED not_submitted' "...ledger: NOT_SUBMITTED"

echo "-- R4-8: launch.sh killed after its gate said go -> launched (the journal's receipt), never NOT_SUBMITTED; the use kept --"
W7=$(mk_proj ws-box 'x'); ln -s "$W7" "$H/projects/w7"; printf 'WS_REMOTE_DIR=projects/w7\nENV_KIND=none\n' > "$W7/.ws.conf"; CWD=$W7
sed 's|^stage done$|stage done; kill -KILL $$|' "$W7/.ws/launch.sh" > "$T/launch.k" && cat "$T/launch.k" > "$W7/.ws/launch.sh"
if grep -q 'kill -KILL \$\$' "$W7/.ws/launch.sh"; then
  rsk grant add --quote "launch on the box, at most 1 at a time and 1 in total" -T ws-box --action launch --max-live 1 --max-launches 1 --expires 2099-12-31 >/dev/null
  O=$(rsk launch -T ws-box -d 2 -N k1 -- sleep 60); RC=$?
  [ "$RC" = 0 ] && has "$O" '^launched: k1 a01 pid [0-9]*' "R4-8: launch.sh killed (137) after go -> launched, from the journal's receipt" || { bad "R4-8 (rc=$RC)"; printf '%s\n' "$O" | tail -6 | sed 's/^/    | /'; }
  has "$(att k1 a01)" '^SUBMITTED submitted [0-9]' "...ledger: submitted with the pid (never NOT_SUBMITTED)"
  has "$(rsk grant list)" 'launches 1/1' "...the grant's use is kept (launches 1/1)"
else bad "R4-8 setup: the deployed launch.sh has no 'stage done' line to kill itself after"; fi
