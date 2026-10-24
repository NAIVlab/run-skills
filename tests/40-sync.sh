#!/usr/bin/env bash
# tests/40-sync.sh — phase A: bin/run-sync + bin/run-bootstrap with rsync/ssh stubs (nothing leaves the box):
# protected excludes, derived + literal deploy-dir excludes, EXTRA_EXCLUDES, first-line summary, REMOTE_HOST,
# T_REMOTE_DIR_REQUIRED, WSBOX_REMOTE_DIR precedence, transfer host (all rsyncs, never ssh), deployed profile carries T_NAME, no ln -s, SYNC_ALSO -R
# semantics with the real rsync. Run by selftest.sh with RS_HOME set:  bash tests/40-sync.sh
set -u
. "$RS_HOME/tests/lib.sh"
stub_rsync
# the stub only logs args; also keep whatever profile.sh gets pushed (run-sync deploys a temp copy, then removes it)
printf 'for a in "$@"; do [ -f "$a" ] && case "$a" in *profile.sh) cat "$a" > "%s/profile.deployed" ;; */run-source) cat "$a" > "%s/stamp.deployed" ;; esac; done; exit 0\n' "$T" "$T" >> "$T/bin/rsync"
# sync_in DIR [env...] [-- flags...] : run-sync from DIR with the stub PATH and a private HOME (no real wandb_env)
sync_in() { local d=$1; shift; local e=(); while [ "$#" -gt 0 ] && [ "$1" != -- ]; do e+=("$1"); shift; done; [ "$#" = 0 ] || shift
  ( cd "$d" && : > "$T/launch.log" && : > "$T/rsync.log" && : > "$T/ssh-host.log" && env ${e[@]+"${e[@]}"} HOME="$T/home" PATH="$T/bin:$PATH" bash "$RS_HOME/bin/run-sync" "$@" 2>&1 ); }
excl() { has "$1" "^--exclude=$(printf %s "$2" | sed 's/[.*]/\\&/g')\$" "excludes $2"; }
mkdir -p "$T/home"

echo "-- slurm: fx-slurm --"
P=$(mk_proj fx-slurm 'REMOTE_DIR=/x
ENV_KIND=uv
EXTRA_EXCLUDES="*.bin scratch/"
FXHOME_ENV_KIND=uv') || { bad "mk_proj"; exit 1; }
O=$(sync_in "$P" TARGET=fx-slurm); RC=$?
[ "$RC" = 0 ] && ok "run-sync exits 0 with stubs" || { bad "run-sync exits 0 (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
has "$(echo "$O" | head -1)" '^\[fx-slurm\] remote: fx:/x  *tag: FXSLURM  *deploy: \.fx-slurm' "first line: remote, tag, deploy dir"
RL=$(cat "$T/rsync.log")
for e in .git .claude/ .codex/ __pycache__/ '*.pyc' '*.parquet' /.venv '/.venv-*' /.cache/ /.local/ /.config/ /bin/ /tmp/ /wandb/ \
         /wandb-artifacts/ /logs/ /ckpts/ /checkpoints/ /outputs/ /data/ .wandb_env .fx-slurm/ .fx-home/ .ws/ .fx-packed/ '*.bin' scratch/; do
  excl "$RL" "$e"
done
has "$RL" '^\./$' "source is ./"; has "$RL" '^fx:/x/$' "destination host:dir/"
has "$RL" '/remote/env.sh$' "deploys env.sh"; has "$RL" '/remote/submit.sh$' "deploys submit.sh"
has "$RL" '/remote/job.sbatch$' "deploys job.sbatch"; has "$RL" '/remote/bootstrap.sh$' "deploys bootstrap.sh"
has "$RL" '/remote/status.sh$' "deploys status.sh"
has "$RL" '/targets/fx-slurm/policy.sh$' "deploys the target's policy.sh"; has "$RL" '^fx:/x/\.fx-slurm/' "deploy files land in <dir>/.fx-slurm/"
has "$RL" '\.hpc\.conf$' "conf pushed"; hasnt "$RL" 'chmod=F600' "no wandb_env anywhere -> none pushed"
has "$(cat "$T/profile.deployed" 2>/dev/null)" "^T_NAME='fx-slurm'$" "deployed profile carries T_NAME"
has "$(cat "$T/profile.deployed" 2>/dev/null)" 'T_KIND=slurm' "deployed profile is the target's"
L=$(cat "$T/launch.log")
hasnt "$L" 'ln -s' "no ln -s in any ssh command"; has "$L" 'mkdir -p' "ssh creates the remote dirs"; has "$L" 'chmod +x' "ssh chmods the remote scripts"
has "$O" 'not honoured' "run-sync lints the conf (FXHOME_ENV_KIND)"
: > "$P/.wandb_env"
O=$(sync_in "$P" TARGET=fx-slurm); RL=$(cat "$T/rsync.log")
has "$RL" '^--chmod=F600$' "wandb_env pushed as mode 600"; has "$RL" '^fx:/x/\.wandb_env$' "wandb_env destination"
O=$(sync_in "$P" TARGET=fx-slurm -- -n); RL=$(cat "$T/rsync.log")
has "$RL" '^--dry-run$' "-n passes --dry-run"; [ -s "$T/launch.log" ] && bad "dry run never sshes" || ok "dry run never sshes"
hasnt "$RL" '\.hpc\.conf$\|chmod=F600' "dry run pushes neither the conf nor the wandb file (a new project's dir does not exist yet)"
has "$O" '(dry) would push ./.hpc.conf' "dry run names the conf it would push"; has "$O" 'dry: not pushed' "dry run says the wandb file was not pushed"
O=$(sync_in "$P" TARGET=fx-slurm -- -D); has "$(cat "$T/rsync.log")" '^--delete$' "-D passes --delete"
sync_in "$P" TARGET=fx-slurm -- -Z >/dev/null && bad "unknown flag rejected" || ok "unknown flag rejected"
O=$(sync_in "$P" CLUSTER=fx-slurm); has "$(echo "$O" | head -1)" '^\[fx-slurm\] remote: fx:/x' "CLUSTER= is accepted as TARGET"
O=$(sync_in "$P" -u TARGET -u CLUSTER -u STATION); RC=$?
[ "$RC" = 2 ] && has "$O" 'set TARGET=' "no TARGET -> exit 2 with hint" || bad "no TARGET -> exit 2 (rc=$RC)"
O=$(sync_in "$P" TARGET=nope); RC=$?
[ "$RC" = 2 ] && has "$O" "unknown target 'nope'" "unknown target -> exit 2" || bad "unknown target -> exit 2 (rc=$RC)"
O=$(sync_in "$P" TARGET=fx-slurm REMOTE_DIR=/stale FXSLURM_REMOTE_DIR=/stale REMOTE_HOST=stale)
has "$(echo "$O" | head -1)" 'remote: fx:/x ' "stale exported REMOTE_DIR/REMOTE_HOST ignored"
P2=$(mk_proj fx-slurm 'REMOTE_DIR=/x
FXSLURM_REMOTE_DIR=/tagged
REMOTE_HOST=alt
SYNC_ALSO="data/prompts data/missing"')
mkdir -p "$P2/data/prompts"; : > "$P2/data/prompts/a.txt"
O=$(sync_in "$P2" TARGET=fx-slurm); RL=$(cat "$T/rsync.log")
has "$(echo "$O" | head -1)" 'remote: alt:/tagged ' "REMOTE_HOST overrides T_HOST; FXSLURM_REMOTE_DIR beats REMOTE_DIR"
has "$RL" '^-azR$' "SYNC_ALSO uses rsync -R"; has "$RL" '^data/prompts$' "SYNC_ALSO pushes the listed path"
hasnt "$RL" 'data/missing' "SYNC_ALSO skips a missing path"

echo "-- --also: one-off SYNC_ALSO --"
mkdir -p "$P2/img"; : > "$P2/img/big.sif"
O=$(sync_in "$P2" TARGET=fx-slurm -- --also img/big.sif --also=data/prompts); RC=$?; RL=$(cat "$T/rsync.log")
[ "$RC" = 0 ] && has "$RL" '^img/big\.sif$' "--also PATH force-pushes that path" || bad "--also PATH (rc=$RC)"
[ "$(printf '%s\n' "$RL" | grep -c '^data/prompts$')" = 2 ] && ok "--also=PATH adds to the conf's SYNC_ALSO (both pushed)" || bad "--also=PATH adds to SYNC_ALSO"
has "$O" 'sync-also: img/big.sif' "--also announced like SYNC_ALSO"
sync_in "$P2" TARGET=fx-slurm -- --also >/dev/null && bad "--also without a path rejected" || ok "--also without a path rejected"
O=$(sync_in "$P2" TARGET=fx-slurm -- --also 'a b'); [ $? = 2 ] && has "$O" 'no spaces' "--also with a space rejected" || bad "--also with a space rejected"
O=$(sync_in "$P2" TARGET=fx-slurm -- '--also=a b'); [ $? = 2 ] && has "$O" 'no spaces' "--also= with a space rejected" || bad "--also= with a space rejected"
O=$(sync_in "$P2" TARGET=fx-slurm); hasnt "$(cat "$T/rsync.log")" 'big\.sif' "--also lasts one sync"
rm -rf "$P2/img"

echo "-- provenance stamp + another checkout's dir --"
excl "$RL" /.run-source
O=$(sync_in "$P" TARGET=fx-slurm); RL=$(cat "$T/rsync.log"); ST=$(cat "$T/stamp.deployed" 2>/dev/null)
HERE=$(cd "$P" && pwd -P)
has "$RL" '^fx:/x/\.run-source$' "stamp pushed to <dir>/.run-source"
has "$ST" "^path=$HERE\$" "stamp: local path"; has "$ST" '^commit=none$' "stamp: no git -> commit=none"
has "$ST" '^synced=20[0-9-]*T' "stamp: sync time"; has "$O" 'source: -@none dirty=-' "sync prints the source line"
has "$(cat "$T/launch.log")" "cat '/x/\.run-source'" "the mkdir ssh also reads the previous stamp (no extra round trip)"
[ "$(wc -l < "$T/ssh-host.log" | tr -d ' ')" = 2 ] && ok "still two ssh calls per sync (mkdir+read, chmod)" || bad "two ssh calls per sync ($(wc -l < "$T/ssh-host.log"))"
O=$(sync_in "$P" TARGET=fx-slurm -- -n); hasnt "$(cat "$T/rsync.log")" '^fx:/x/\.run-source$' "dry run writes no stamp"
has "$O" 'dry: stamp not written' "dry run says so"
if command -v git >/dev/null 2>&1; then
  ( cd "$P" && git init -q && git checkout -q -b feat 2>/dev/null; GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t \
    GIT_COMMITTER_EMAIL=t@t git commit -q --allow-empty -m x && : > untracked.txt )
  CM=$(cd "$P" && git rev-parse HEAD)
  O=$(sync_in "$P" TARGET=fx-slurm); ST=$(cat "$T/stamp.deployed" 2>/dev/null)
  has "$ST" "^commit=$CM\$" "stamp: full commit"; has "$ST" '^branch=feat$' "stamp: branch"
  has "$ST" '^dirty=[1-9]' "stamp: dirty count (untracked counts)"; has "$O" "source: feat@$(printf %s "$CM" | cut -c1-9) dirty=" "source line: branch@short"
  rm -rf "$P/.git" "$P/untracked.txt"
  ( cd "$P" && git init -q ); O=$(sync_in "$P" TARGET=fx-slurm); ST=$(cat "$T/stamp.deployed" 2>/dev/null)
  has "$ST" '^commit=none$' "unborn repo: commit=none"; [ "$(grep -c '^none$' "$T/stamp.deployed")" = 0 ] && ok "unborn repo: no stray line" || bad "unborn repo: no stray line"
  rm -rf "$P/.git"
fi
printf 'path=%s\nhost=hostA\nbranch=main\n' "$HERE" > "$T/run-source.remote"
O=$(sync_in "$P" TARGET=fx-slurm); [ $? = 0 ] && ok "same checkout's stamp -> syncs" || bad "same checkout's stamp -> syncs"
printf 'path=/elsewhere/wt2\nhost=hostB\nbranch=exp/x\ncommit=0123456789abcdef\nsynced=2026-01-01T00:00:00+0000\n' > "$T/run-source.remote"
O=$(sync_in "$P" TARGET=fx-slurm); RC=$?
[ "$RC" = 2 ] && has "$O" 'last synced from another checkout: /elsewhere/wt2 (hostB, exp/x@012345678, 2026-01-01' "another checkout's dir -> exit 2, names it" \
  || bad "another checkout's dir refused (rc=$RC)"
has "$O" '--take-over' "refusal names --take-over"
[ "$(grep -c '^\./$' "$T/rsync.log")" = 0 ] && ok "refused before any code is pushed" || bad "refused before any code is pushed"
O=$(sync_in "$P" TARGET=fx-slurm -- -n); [ $? = 0 ] && ok "dry run is not refused (it reads nothing remote)" || bad "dry run not refused"
O=$(sync_in "$P" TARGET=fx-slurm -- --take-over); RC=$?
[ "$RC" = 0 ] && has "$O" "take-over: /x was synced from /elsewhere/wt2" "--take-over syncs and says whose dir it took" || bad "--take-over (rc=$RC)"
has "$(cat "$T/stamp.deployed")" "^path=$HERE\$" "--take-over restamps with this checkout"
rm -f "$T/run-source.remote"

echo "-- transfer host: all rsync paths, control host unchanged --"
cp -R "$RS_USER_DIR" "$T/user-xfer"
printf '\nT_XFER_HOST=profile-xfer\n' >> "$T/user-xfer/targets/fx-slurm/profile.sh"
: > "$P2/.wandb_env"
O=$(sync_in "$P2" RS_USER_DIR="$T/user-xfer" TARGET=fx-slurm XFER_HOST=stale)
RL=$(cat "$T/rsync.log")
[ "$(printf '%s\n' "$RL" | grep -c '^profile-xfer:/tagged')" = 6 ] \
  && ok "profile transfer host handles code, SYNC_ALSO, stamp, harness, conf and wandb file; stale export ignored" \
  || bad "profile transfer host handles all rsync paths"
hasnt "$RL" '^alt:\|^stale:' "rsync never uses the control host or inherited XFER_HOST"
has "$(echo "$O" | tail -1)" 'sync done -> alt:/tagged .*; files via profile-xfer' "last line names the transfer host (survives | tail -1)"
has "$(cat "$T/ssh-host.log")" '^alt$' "ssh uses REMOTE_HOST"
hasnt "$(cat "$T/ssh-host.log")" 'xfer\|stale' "control commands never go to the transfer host"
printf '\nXFER_HOST=conf-xfer\nFXSLURM_XFER_HOST=tag-xfer\n' >> "$P2/.hpc.conf"
O=$(sync_in "$P2" RS_USER_DIR="$T/user-xfer" TARGET=fx-slurm)
[ "$(cat "$T/rsync.log" | grep -c '^profile-xfer:/tagged')" = 6 ] \
  && ok "conf XFER_HOST / <TAG>_XFER_HOST lines are ignored: the transfer host is a profile fact" || bad "conf XFER_HOST ignored"
O=$(sync_in "$P2" RS_USER_DIR="$T/user-xfer" TARGET=fx-slurm -- -n)
has "$(cat "$T/rsync.log")" '^profile-xfer:/tagged' "dry run keeps the transfer destination"
[ ! -s "$T/ssh-host.log" ] && ok "transfer-host dry run never sshes" || bad "transfer-host dry run sshes"
O=$(cd "$P2" && TARGET=fx-slurm HOME="$T/home" with_path bash "$RS_HOME/bin/run-bootstrap" 2>&1)
has "$(cat "$T/ssh-host.log")" '^alt$' "bootstrap keeps using the control host with a transfer host configured"
hasnt "$(cat "$T/ssh-host.log")" 'xfer' "bootstrap never uses the transfer host"
O=$(sync_in "$P" TARGET=fx-slurm XFER_HOST=stale)
has "$(cat "$T/rsync.log")" '^fx:/x/$' "without conf/profile transfer host, falls back to control host"
rm -f "$P2/.wandb_env"; grep -v 'XFER_HOST=' "$P2/.hpc.conf" > "$P2/.hpc.conf.new" && mv "$P2/.hpc.conf.new" "$P2/.hpc.conf"   # leave $P2 as it was found

cp -R "$RS_USER_DIR" "$T/user2"; mkdir -p "$T/user2/targets/fx-req"
{ cat "$RS_USER_DIR/targets/fx-slurm/profile.sh"; echo 'T_REMOTE_DIR_REQUIRED=1'; } > "$T/user2/targets/fx-req/profile.sh"
mkdir -p "$T/req"; printf 'REMOTE_DIR=/x\n' > "$T/req/.hpc.conf"
O=$(sync_in "$T/req" RS_USER_DIR="$T/user2" TARGET=fx-req); RC=$?
[ "$RC" = 2 ] && has "$O" 'does not share a filesystem' "T_REMOTE_DIR_REQUIRED=1 without FXREQ_REMOTE_DIR -> exit 2" || bad "T_REMOTE_DIR_REQUIRED enforced (rc=$RC)"
[ -s "$T/rsync.log" ] && bad "nothing rsynced when refused" || ok "nothing rsynced when refused"
printf 'REMOTE_DIR=/x\nFXREQ_REMOTE_DIR=/own\n' > "$T/req/.hpc.conf"
O=$(sync_in "$T/req" RS_USER_DIR="$T/user2" TARGET=fx-req)
has "$(echo "$O" | head -1)" '^\[fx-req\] remote: fx:/own ' "T_REMOTE_DIR_REQUIRED=1 with the tagged key syncs"
has "$(cat "$T/rsync.log")" '^--exclude=\.fx-req/$' "deploy-dir exclude derived for an overlay target"

echo "-- nohup: ws-box --"
W=$(mk_proj ws-box 'WS_REMOTE_DIR=projects/x
WSBOX_REMOTE_DIR=projects/y') || { bad "mk_proj ws-box"; exit 1; }
O=$(sync_in "$W" TARGET=ws-box); RC=$?
[ "$RC" = 0 ] && ok "nohup run-sync exits 0" || { bad "nohup run-sync exits 0 (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
has "$(echo "$O" | head -1)" '^\[ws-box\] remote: wsbox:projects/y  *tag: WSBOX  *deploy: \.ws' "WSBOX_REMOTE_DIR beats WS_REMOTE_DIR; deploy .ws"
RL=$(cat "$T/rsync.log")
has "$RL" '^wsbox:projects/y/$' "destination is \$HOME-relative"; has "$RL" '^wsbox:projects/y/\.ws/' "deploy files land in .ws/"
has "$RL" '/remote/env.sh$' "nohup deploys env.sh"; has "$RL" '/remote/bootstrap.sh$' "nohup deploys bootstrap.sh"
has "$RL" '/remote/status.sh$' "nohup deploys status.sh"
hasnt "$RL" 'submit.sh\|job.sbatch\|policy.sh' "nohup deploys nothing slurm-ish"; has "$RL" '\.ws\.conf$' ".ws.conf pushed"
excl "$RL" .fx-slurm/; excl "$RL" .ws/; excl "$RL" /.config/; excl "$RL" '/.venv-*'
has "$(cat "$T/profile.deployed" 2>/dev/null)" "^T_NAME='ws-box'$" "nohup profile carries T_NAME"
hasnt "$(cat "$T/launch.log")" 'ln -s' "nohup: no ln -s either"
O=$(sync_in "$W" STATION=ws-box); has "$(echo "$O" | head -1)" '^\[ws-box\] remote: wsbox:' "STATION= is accepted as TARGET"
printf 'ENV_KIND=uv\n' > "$W/.ws.conf"
O=$(sync_in "$W" TARGET=ws-box); RC=$?
[ "$RC" = 2 ] && has "$O" 'WS_REMOTE_DIR (or WSBOX_REMOTE_DIR)' "no remote dir -> exit 2, never guessed" || bad "no remote dir -> exit 2 (rc=$RC)"

echo "-- SYNC_ALSO -R semantics (real rsync) --"
if command -v rsync >/dev/null 2>&1; then
  S=$T/s; mkdir -p "$S/data/prompts" "$T/dst"; echo x > "$S/data/prompts/a.txt"; echo y > "$S/data/big.bin"
  RS=$(cd "$S" && rsync -aznR --itemize-changes data/prompts "$T/dst/" 2>&1)
  has "$RS" 'data/prompts/a.txt' "-R pushes the listed subtree with its path"; hasnt "$RS" 'big.bin' "siblings untouched"
fi

echo "-- run-bootstrap (ssh wrapper) --"
printf 'REMOTE_DIR=/x\n' > "$P/.hpc.conf"
O=$(cd "$P" && : > "$T/launch.log" && TARGET=fx-slurm HOME="$T/home" with_path bash "$RS_HOME/bin/run-bootstrap" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "run-bootstrap exits 0 with the ssh stub" || { bad "run-bootstrap exits 0 (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
L=$(cat "$T/launch.log")
has "$L" "cd '/x'" "run-bootstrap cds into REMOTE_DIR"; has "$L" 'PROJ=\$PWD' "exports PROJ=\$PWD on the remote"
has "$L" "TARGET='fx-slurm'" "exports TARGET on the remote"; has "$L" '\.fx-slurm/bootstrap\.sh' "runs the deployed bootstrap.sh"
printf 'WS_REMOTE_DIR=projects/x\n' > "$W/.ws.conf"
O=$(cd "$W" && : > "$T/launch.log" && TARGET=ws-box HOME="$T/home" with_path bash "$RS_HOME/bin/run-bootstrap" 2>&1)
L=$(cat "$T/launch.log")
has "$L" "cd 'projects/x'" "nohup: cd is \$HOME-relative"; has "$L" "TARGET='ws-box'.*\.ws/bootstrap\.sh" "nohup: TARGET + .ws/bootstrap.sh"

echo "-- run-bootstrap --job --"
boot_job() { local d=$1; shift; ( cd "$d" && : > "$T/launch.log" && env "$@" HOME="$T/home" PATH="$T/bin:$PATH" bash "$RS_HOME/bin/run-bootstrap" ${JOBARGS[@]+"${JOBARGS[@]}"} 2>&1 ); }
printf 'REMOTE_DIR=/x\nJOB_NAME=proj\n' > "$P/.hpc.conf"
JOBARGS=(--job -p gpu -c 4); O=$(boot_job "$P" TARGET=fx-slurm); RC=$?; L=$(cat "$T/launch.log")
[ "$RC" = 0 ] && ok "--job exits 0 with the ssh stub" || { bad "--job exits 0 (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
has "$L" "cd '/x' && bash '\.fx-slurm/submit\.sh' '-p' 'gpu' '-c' '4' '-n' 'proj-bootstrap' -- bash \"\$PWD/\.fx-slurm/bootstrap\.sh\"" \
  "--job submits the deployed bootstrap via submit.sh, named <JOB_NAME>-bootstrap"
JOBARGS=(--job -p gpu -n mine); O=$(boot_job "$P" TARGET=fx-slurm); L=$(cat "$T/launch.log")
has "$L" "'-n' 'mine' --" "an explicit -n is kept"; hasnt "$L" 'proj-bootstrap' "and no second -n is added"
JOBARGS=(--job); O=$(boot_job "$P" TARGET=fx-slurm); RC=$?
[ "$RC" = 2 ] && has "$O" 'sets no T_BOOTSTRAP_JOB' "--job without flags or T_BOOTSTRAP_JOB -> exit 2" || bad "--job without defaults refused (rc=$RC)"
[ -s "$T/launch.log" ] && bad "nothing sshed when refused" || ok "nothing sshed when refused"
cp -R "$RS_USER_DIR" "$T/user-boot"; printf "\nT_BOOTSTRAP_JOB='-p gpu -c 8 -m 32G -t 02:00:00'\n" >> "$T/user-boot/targets/fx-slurm/profile.sh"
JOBARGS=(--job); O=$(boot_job "$P" RS_USER_DIR="$T/user-boot" TARGET=fx-slurm T_BOOTSTRAP_JOB=stale); L=$(cat "$T/launch.log")
has "$L" "'-p' 'gpu' '-c' '8' '-m' '32G' '-t' '02:00:00' '-n' 'proj-bootstrap' --" "--job alone uses the profile's T_BOOTSTRAP_JOB (stale export ignored)"
JOBARGS=(--job -p gpu -- x); O=$(boot_job "$P" TARGET=fx-slurm); [ $? = 2 ] && has "$O" 'submit.sh flags only' "--job refuses a payload" || bad "--job refuses a payload"
JOBARGS=(--job -p gpu -n "a'b"); O=$(boot_job "$P" TARGET=fx-slurm); [ $? = 2 ] && has "$O" 'no quotes' "--job refuses a quote in a flag" || bad "--job refuses a quote"
JOBARGS=(--jobs); O=$(boot_job "$P" TARGET=fx-slurm); [ $? = 2 ] && has "$O" 'usage:' "unknown flag -> usage" || bad "unknown flag -> usage"
JOBARGS=(--job -c 4); O=$(boot_job "$P" TARGET=fx-slurm); [ $? = 2 ] && has "$O" 'needs -p' "--job without -p refused (no silent GPU job)" || bad "--job without -p refused"
printf "REMOTE_DIR=/x\nJOB_NAME=\"it's\"\n" > "$P/.hpc.conf"
JOBARGS=(--job -p gpu); O=$(boot_job "$P" TARGET=fx-slurm); [ $? = 2 ] && has "$O" 'JOB_NAME too' "a quote in JOB_NAME is refused too" || bad "quote in JOB_NAME refused"
printf 'REMOTE_DIR=/x\nJOB_NAME=proj\n' > "$P/.hpc.conf"
printf "\nT_BOOTSTRAP_JOB='  '\n" >> "$T/user-boot/targets/fx-slurm/profile.sh"
JOBARGS=(--job); O=$(boot_job "$P" RS_USER_DIR="$T/user-boot" TARGET=fx-slurm); [ $? = 2 ] && has "$O" 'sets no T_BOOTSTRAP_JOB' "whitespace-only T_BOOTSTRAP_JOB = unset" || bad "whitespace T_BOOTSTRAP_JOB"
JOBARGS=(--job -c 4); O=$(boot_job "$W" TARGET=ws-box); [ $? = 2 ] && has "$O" 'needs a Slurm target' "--job on a nohup target refused" || bad "--job on nohup refused"
JOBARGS=()

stub_fail ssh
(cd "$P" && TARGET=fx-slurm HOME="$T/home" with_path bash "$RS_HOME/bin/run-bootstrap" >/dev/null 2>&1) && bad "ssh failure propagates" || ok "ssh failure propagates"
