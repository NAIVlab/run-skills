#!/usr/bin/env bash
# tests/45-pull.sh — phase A: bin/run-pull. The rsync stub logs its args, maps `host:path` to a local "remote" dir
# ($T/home/path when relative) and runs the REAL rsync, so -R placement, -u, the excludes and the push-back check are
# exercised for real; ssh is the logging stub (run-pull must never call it). Also the INDEX "files via" cell and
# the transfer host (profile T_XFER_HOST, else the ssh host; conf/env XFER_HOST ignored), refusals.  bash tests/45-pull.sh
set -u
. "$RS_HOME/tests/lib.sh"
REAL=$(command -v rsync || true)
if [ -z "$REAL" ]; then echo "-- run-pull: skipped (no rsync on this machine) --"; return 0 2>/dev/null || exit 0; fi
cat > "$T/bin/rsync" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$T/rsync.log"
a=(); for x in "\$@"; do case "\$x" in [a-z]*:*) x=\${x#*:}; case "\$x" in /*) ;; *) x="$T/home/\$x" ;; esac ;; esac; a+=("\$x"); done
exec "$REAL" "\${a[@]}"
EOS
chmod +x "$T/bin/rsync"
# pull DIR [env...] [-- args...] : run-pull from DIR with the stub PATH; rsync.log / ssh-host.log truncated first
pull() { local d=$1; shift; local e=(); while [ "$#" -gt 0 ] && [ "$1" != -- ]; do e+=("$1"); shift; done; [ "$#" = 0 ] || shift
  ( cd "$d" && : > "$T/rsync.log" && : > "$T/ssh-host.log" && env ${e[@]+"${e[@]}"} HOME="$T/home" PATH="$T/bin:$PATH" bash "$RS_HOME/bin/run-pull" "$@" 2>&1 ); }
mkdir -p "$T/home"
cp -R "$RS_USER_DIR" "$T/user-xfer"; printf '\nT_XFER_HOST=profile-xfer\n' >> "$T/user-xfer/targets/fx-slurm/profile.sh"
R=$T/remote; mkdir -p "$R/logs" "$R/res/sub" "$R/res/__pycache__" "$R/.venv/bin" "$R/.fx-slurm"
echo log1 > "$R/logs/a.out"; echo r > "$R/res/sub/b.txt"; echo k > "$R/res/.wandb_env"; echo c > "$R/res/__pycache__/x.pyc"
P=$T/pp; mkdir -p "$P"; printf 'REMOTE_DIR=%s\nREMOTE_HOST=alt\n' "$R" > "$P/.hpc.conf"

echo "-- run-pull: transfer host, rsync only, -R placement --"
O=$(pull "$P" RS_USER_DIR="$T/user-xfer" TARGET=fx-slurm XFER_HOST=stale -- logs/a.out ./res/); RC=$?
[ "$RC" = 0 ] && ok "run-pull exits 0" || { bad "run-pull exits 0 (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
RL=$(cat "$T/rsync.log")
has "$RL" "^profile-xfer:$R/\./logs/a\.out\$" "source = <xfer>:<dir>/./<path> (profile transfer host; stale export ignored)"
has "$RL" "^profile-xfer:$R/\./res\$" "./ prefix and trailing / normalised"
has "$RL" '^-u$' "-u: a newer local file is kept"; hasnt "$RL" 'delete' "never --delete"; hasnt "$RL" '^alt:\|^stale:' "never the control host"
[ ! -s "$T/ssh-host.log" ] && ok "run-pull never sshes (restricted transfer shells refuse commands)" || bad "run-pull never sshes"
[ "$(cat "$P/logs/a.out" 2>/dev/null)" = log1 ] && ok "file lands at the same relative path" || bad "file lands at the same relative path"
[ -f "$P/res/sub/b.txt" ] && ok "dir lands with its subtree" || bad "dir lands with its subtree"
[ ! -e "$P/res/.wandb_env" ] && [ ! -e "$P/res/__pycache__" ] && ok ".wandb_env / __pycache__ inside a pulled dir are excluded" || bad "pull excludes"
has "$O" 'NOTE: run-sync would push 1 of these files back' "push-back NOTE for a path run-sync does not exclude (res/)"
has "$O" 'pull done <- profile-xfer:' "last line names the transfer host"
O=$(pull "$P" RS_USER_DIR="$T/user-xfer" TARGET=fx-slurm -- logs/a.out)
hasnt "$O" 'NOTE:' "no push-back NOTE for an excluded dir (logs/)"
printf 'SYNC_ALSO="logs/a.out"\n' >> "$P/.hpc.conf"
O=$(pull "$P" RS_USER_DIR="$T/user-xfer" TARGET=fx-slurm -- logs/a.out)
has "$O" 'NOTE: run-sync would push 1 of these' "push-back NOTE counts SYNC_ALSO (force-pushed despite the excludes)"
grep -v SYNC_ALSO "$P/.hpc.conf" > "$P/c.new" && mv "$P/c.new" "$P/.hpc.conf"

echo "-- run-pull: -u semantics (real rsync) --"
echo mine > "$P/logs/a.out"; touch -t 202001010000 "$R/logs/a.out"
pull "$P" TARGET=fx-slurm -- logs/a.out >/dev/null
[ "$(cat "$P/logs/a.out")" = mine ] && ok "an older remote copy never replaces a newer local file" || bad "-u keeps the newer local file"
echo log2 > "$R/logs/a.out"; touch -t 203001010000 "$R/logs/a.out"
pull "$P" TARGET=fx-slurm -- logs/a.out >/dev/null
[ "$(cat "$P/logs/a.out")" = log2 ] && ok "a newer remote copy is pulled" || bad "a newer remote copy is pulled"

echo "-- run-pull: precedence, dry run --"
O=$(pull "$P" TARGET=fx-slurm XFER_HOST=stale -- -n res)
has "$(cat "$T/rsync.log")" "^alt:$R/\./res\$" "no transfer host -> the control host (REMOTE_HOST); stale export ignored"
has "$(cat "$T/rsync.log")" '^--dry-run$' "-n passes --dry-run"; has "$O" 'Total file size' "-n prints rsync --stats (count + size)"
has "$O" 'dry run: nothing written' "-n says nothing was written"
printf 'XFER_HOST=conf-xfer\nFXSLURM_XFER_HOST=tag-xfer\n' >> "$P/.hpc.conf"; rm -rf "$P/res"
O=$(pull "$P" RS_USER_DIR="$T/user-xfer" TARGET=fx-slurm -- res -n)
has "$(cat "$T/rsync.log")" "^profile-xfer:$R/\./res\$" "conf XFER_HOST lines ignored (profile fact); -n after the paths works"
[ ! -e "$P/res" ] && ok "dry run writes nothing" || bad "dry run writes nothing"

echo "-- run-pull: refusals (exit 2, nothing copied) --"
for a in /etc/passwd ../x a/../b a/./b a//b . ./ '' 'a b' -x 'b*' '.c*' '.[a-z]*' 'res/?' 'a;b' '$HOME' .venv .venv-fx/lib .cache/x .local bin/uv .git/config .wandb_env \
         .hpc.conf .ws.conf .fx-slurm/env.sh .ws .fx-home; do
  pull "$P" TARGET=fx-slurm -- "$a" >/dev/null; RC=$?
  [ "$RC" = 2 ] && [ ! -s "$T/rsync.log" ] && ok "refused: '$a'" || bad "refused: '$a' (rc=$RC)"
done
mkdir -p "$R/res/inner" "$P/res" "$P/keep"; echo i > "$R/res/inner/f"; rm -rf "$P/res/inner"; ln -s ../keep "$P/res/inner"
pull "$P" TARGET=fx-slurm -- res >/dev/null
[ -L "$P/res/inner" ] && [ -f "$P/keep/f" ] && ok "a symlinked local dir inside a pulled tree stays a symlink (-K)" || bad "inner symlink kept (-K)"
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$P/locked"; chmod 000 "$P/locked"
  O=$(pull "$P" TARGET=fx-slurm -- res); chmod 755 "$P/locked"; rmdir "$P/locked"
  has "$O" 'could not check whether run-sync would push' "a failed push-back listing is reported, never read as 0"
fi
mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$P/lnk"
pull "$P" TARGET=fx-slurm -- lnk/x >/dev/null; RC=$?
[ "$RC" = 2 ] && [ ! -s "$T/rsync.log" ] && [ -L "$P/lnk" ] && ok "a local symlink on the path is refused (rsync would replace it)" || bad "local symlink refused (rc=$RC)"
pull "$P" TARGET=fx-slurm >/dev/null; [ "$?" = 2 ] && ok "no path -> usage, exit 2" || bad "no path -> exit 2"
O=$(pull "$P" TARGET=fx-slurm -- -n logs); [ "$?" = 0 ] && ok "a flag before the paths is accepted" || bad "-n before paths"
printf 'REMOTE_DIR=%s/missing\n' "$T" > "$P/.hpc.conf"
O=$(pull "$P" TARGET=fx-slurm -- logs); RC=$?
[ "$RC" = 23 ] && has "$O" 'rsync exit 23' "rsync's exit code propagates (23: source missing), not retried" || bad "rsync exit code propagates (rc=$RC)"

echo "-- run-pull: nohup (\$HOME-relative dir) --"
mkdir -p "$T/home/projects/y/logs"; echo z > "$T/home/projects/y/logs/z.log"
W=$T/ww; mkdir -p "$W"; printf 'WS_REMOTE_DIR=projects/x\nWSBOX_REMOTE_DIR=projects/y\n' > "$W/.ws.conf"
O=$(pull "$W" TARGET=ws-box -- logs); RC=$?
has "$(cat "$T/rsync.log")" '^wsbox:projects/y/\./logs$' "nohup: <TAG>_REMOTE_DIR, \$HOME-relative source"
[ "$RC" = 0 ] && [ -f "$W/logs/z.log" ] && ok "nohup: pulled into the local project" || bad "nohup: pulled (rc=$RC)"

echo "-- INDEX names the transfer host in the description cell, never in the host cell --"
C() { ( . "$RS_HOME/lib/common.sh"; eval "$1" ) 2>&1; }
RS_USER_DIR="$T/user-xfer" C "rs_gen_index slurm '$T/idx.md' /root" >/dev/null
has "$(grep '^| fx-slurm |' "$T/idx.md")" '^| fx-slurm | fx | .*files via `profile-xfer` (run-sync/run-pull only) |' "INDEX row: host stays the ssh alias, description adds files via"
C "rs_gen_index slurm '$T/idx0.md' /root" >/dev/null
hasnt "$(cat "$T/idx0.md")" 'files via' "no transfer host -> no 'files via'"
