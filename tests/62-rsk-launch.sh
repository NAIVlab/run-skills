#!/usr/bin/env bash
# tests/62-rsk-launch.sh — phase A: rsk launch / cancel / watch end to end, the real CLI (python -I, src on the path)
# against the fixture targets with an EXECUTING ssh stub (the "remote" runs here: HOME=$T/home), so the deployed
# submit.sh / launch.sh make the plan and the stub sbatch / scancel / setsid'd runs record what was done. Stub
# squeue/sacct render one jobs table ($T/jobs: id|user|name|state|workdir|comment) in whatever fields are asked.
# Covers: plan -> card + exit 4; --approve -> --rs-expect submit, ledger attempt, approval use; a covering grant;
# a deny (exit 3); warnings a plain grant does not cover (-y only after an approved card with warnings); conf drift
# (exit 6); a sweep under one approval; a superseded / used plan (exit 6); ssh lost -> SUBMIT_UNKNOWN, reconciled by
# rsk status; an old deploy (needs: sync); the local duplicate; relaunch; cancel (identity: name, WorkDir, user);
# nohup: busy GPU never grant-covered, approved card -> --gpu-busy-ok, cancel TERM/KILL; the watch lease.
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
while [ \$# -gt 0 ]; do case "\$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
echo "\$1" >> "$T/ssh-host.log"; shift; cmd="\$*"
if [ "\$cmd" = "bash -s" ]; then body=\$(cat); printf '%s\n' "\$body" >> "$T/ssh-body.log"
  if [ -f "$T/ssh.drop" ] && printf '%s' "\$body" | grep -q -- '--rs-expect'; then
    rm -f "$T/ssh.drop"; ( cd "$H" && HOME="$H" bash -c "\$body" ) >/dev/null 2>&1; exit 255; fi
  cd "$H" && HOME="$H" exec bash -c "\$body"
fi
printf '%s\n' "\$cmd" >> "$T/ssh-cmd.log"
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
cat > "$T/bin/scancel" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/scancel.log"
for j in "\$@"; do awk -F'|' -v OFS='|' -v j="\$j" '\$1 == j { \$4 = "CANCELLED" } 1' "$T/jobs" > "$T/jobs.x" && mv "$T/jobs.x" "$T/jobs"; done
EOS
cat > "$T/bin/nvidia-smi" <<EOS
#!/usr/bin/env bash
case "\$*" in
  *index,name,*) printf '0, F, 0 %%, 8000 MiB, 49140 MiB\n1, F, 0 %%, 2 MiB, 49140 MiB\n2, F, 0 %%, 5 MiB, 49140 MiB\n3, F, 0 %%, 9000 MiB, 49140 MiB\n' ;;
  *index,uuid,memory.used*) printf '0, GPU-aaaa0000-0000, 8000\n1, GPU-aaaa0000-0001, 2\n2, GPU-aaaa0000-0002, 5\n3, GPU-aaaa0000-0003, 9000\n' ;;
  "--query-compute-apps=gpu_uuid,pid --format=csv,noheader") cat "$T/apps" 2>/dev/null; exit 0 ;;
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
has "$(att exp--train--d--scratch--s0 a01)" '^NOT_SUBMITTED not_submitted' "...ledger: NOT_SUBMITTED"
printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$P" > "$P/.hpc.conf"

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

echo "-- an old deploy (no api=3) -> needs: sync, nothing run --"
P2=$(mk_proj fx-slurm 'x'); printf 'REMOTE_DIR=%s\nENV_KIND=none\n' "$P2" > "$P2/.hpc.conf"; printf 'api=2\n' > "$P2/.fx-slurm/API"
CWD=$P2; O=$(rsk launch -T fx-slurm -n old1 -- c); RC=$?
[ "$RC" = 6 ] && has "$O" '^needs: sync (the deploy predates rsk launch: rsk sync -T fx-slurm)' "api=2 -> exit 6, needs: sync" || bad "old deploy (rc=$RC)"
[ ! -d "$P2/.rs/attempts" ] && ok "...the old submit.sh never ran" || bad "...the old submit.sh never ran"
CWD=$P

echo "-- relaunch: the run's next attempt (aNN), same configuration --"
O=$(rsk launch --relaunch exp--smoke--b--scratch--s0); RC=$?
[ "$RC" = 6 ] && ok "relaunch while a01 is live -> exit 6" || bad "relaunch of a live run (rc=$RC)"
awk -F'|' -v OFS='|' '$1 == 102 { $4 = "COMPLETED" } 1' "$T/jobs" > "$T/jobs.x" && mv "$T/jobs.x" "$T/jobs"; rsk status >/dev/null
O=$(rsk launch --relaunch exp--smoke--b--scratch--s0); RC=$?
[ "$RC" = 4 ] && has "$O" '^  name       exp--smoke--b--scratch--s0--a02$' "relaunch plans <run>--a02 from the recorded bound fields" || { bad "relaunch (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }
has "$O" 'action relaunch not in launch' "...a launch-only grant does not cover a relaunch"; has "$O" '^  payload    python t.py$' "...same payload"

echo "-- cancel: the user's words, identity (name + WorkDir + user) in one ssh, then scancel --"
: > "$T/scancel.log"; O=$(rsk cancel exp--smoke--base--scratch--s0 --approve "cancel the smoke"); RC=$?
[ "$RC" = 0 ] && has "$(cat "$T/scancel.log")" '^101$' "cancel RUN --approve -> scancel 101" || { bad "cancel (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }
has "$O" '^approval ap-.*cancel of job(s) 101' "...recorded as a cancel approval naming the job"
has "$(att exp--smoke--base--scratch--s0 a01)" '^CANCELLING' "...ledger: CANCELLING (until status sees the end)"
printf '777|%s|stray|PENDING|/elsewhere/proj|\n778|someone|theirs|RUNNING|%s|\n' "$ME" "$P" >> "$T/jobs"; : > "$T/scancel.log"
O=$(rsk cancel --job 777 -T fx-slurm --approve "cancel job 777"); RC=$?
[ "$RC" = 6 ] && has "$O" 'identity does not match (workdir=/elsewhere/proj)' "a job of another WorkDir -> refused (exit 6)" || bad "workdir differs (rc=$RC)"
O=$(rsk cancel --job 778 -T fx-slurm --approve "cancel job 778"); RC=$?
[ "$RC" = 3 ] && has "$O" 'belongs to someone' "someone else's job -> exit 3" || bad "another user's job (rc=$RC)"
[ ! -s "$T/scancel.log" ] && ok "...scancel never called for either" || bad "...scancel called"
O=$(rsk cancel exp--ablate--sa--scratch--s0); RC=$?
[ "$RC" = 4 ] && has "$O" '^needs user: approval — cancel job' "the agent's own cancel without cancel_own -> exit 4" || bad "cancel without words (rc=$RC)"
rsk grant deny --quote "leave the sb ablation alone" --name 'exp--ablate--sb*' --action cancel >/dev/null
O=$(rsk cancel exp--ablate--sb--scratch--s0 --approve "cancel sb"); RC=$?
[ "$RC" = 3 ] && has "$O" 'leave the sb ablation alone' "a deny on cancel wins over the user's words -> exit 3" || bad "deny on cancel (rc=$RC)"
rsk grant add --quote "you may stop your own smoke runs" -T fx-slurm --action cancel_own --max-live none --max-launches none --expires 2099-12-31 >/dev/null
O=$(rsk cancel exp--smoke--w--scratch--s0); RC=$?
[ "$RC" = 0 ] && has "$O" '^cancelled: job ' "a cancel_own grant covers the agent's own run" || bad "cancel_own (rc=$RC)"

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
rsk grant add --quote "launch anything on the box" -T ws-box --action launch --allow-warnings --max-live none --max-launches none --expires 2099-12-31 >/dev/null
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

echo "-- nohup cancel: receipt + /proc start + boot_id, TERM to the group, KILL after the grace --"
O=$(rsk cancel busy1 --approve "stop busy1" --grace 5); RC=$?
[ "$RC" = 0 ] && has "$O" '^cancelled: pid [0-9]* (busy1 a01) on ws-box — TERM, its group is gone, rc 143' "TERM -> gone, rc 143 from <log>.rc" || { bad "nohup cancel (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }
has "$(att busy1 a01)" '^CANCELLED' "...ledger: CANCELLED"
O=$(rsk launch -T ws-box -d 3 -N stub1 -- "sh -c 'trap \"\" TERM; sleep 60'"); RC=$?
[ "$RC" = 0 ] || bad "a TERM-immune run launches (rc=$RC)"
O=$(rsk cancel stub1 --approve "stop it" --grace 2); RC=$?
[ "$RC" = 0 ] && has "$O" 'then KILL after the grace' "a run that ignores TERM -> KILL after the grace" || { bad "KILL fallback (rc=$RC)"; printf '%s\n' "$O" | sed 's/^/    | /'; }
