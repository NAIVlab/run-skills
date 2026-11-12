#!/usr/bin/env bash
# tests/48-output-root.sh — phase A: OUTPUT_ROOT, the project's own out-of-tree output root (rs_output_root, rs_root_rel):
# run-pull --root (paths relative to the root, same landing) and run-sync --root (a root push and nothing else). The rsync
# stub logs its args (rsync.last: the last call's) and maps `host:path` to a local dir ($T/home/path when relative), then runs the REAL rsync, so -R,
# -u, -K, the excludes and "a missing root is never created" are rsync's own behaviour; ssh is the logging stub (never called).
set -u
. "$RS_HOME/tests/lib.sh"
REAL=$(command -v rsync || true)
if [ -z "$REAL" ]; then echo "-- OUTPUT_ROOT: skipped (no rsync on this machine) --"; return 0 2>/dev/null || exit 0; fi
cat > "$T/bin/rsync" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$T/rsync.log"; printf '%s\n' "\$*" >> "$T/rsync.calls"; printf '%s\n' "\$@" > "$T/rsync.last"
a=(); for x in "\$@"; do case "\$x" in [a-z]*:*) x=\${x#*:}; case "\$x" in /*) ;; *) x="$T/home/\$x" ;; esac ;; esac; a+=("\$x"); done
exec "$REAL" "\${a[@]}"
EOS
chmod +x "$T/bin/rsync"
# run SCRIPT DIR [env...] [-- args...] : bin/SCRIPT from DIR with the stub PATH and HOME=$T/home; the logs truncated first
run() { local s=$1 d=$2; shift 2; local e=(); while [ "$#" -gt 0 ] && [ "$1" != -- ]; do e+=("$1"); shift; done; [ "$#" = 0 ] || shift
  ( cd "$d" && : > "$T/rsync.log" && : > "$T/rsync.calls" && : > "$T/ssh-host.log" && : > "$T/launch.log" &&
    env ${e[@]+"${e[@]}"} HOME="$T/home" PATH="$T/bin:$PATH" bash "$RS_HOME/bin/$s" "$@" 2>&1 ); }
pull() { run run-pull "$@"; }; push() { run run-sync "$@"; }
none() { [ ! -s "$T/rsync.log" ] && [ ! -s "$T/ssh-host.log" ]; }   # nothing copied, nothing sshed
C() { ( . "$RS_HOME/lib/common.sh"; eval "$1" ) 2>&1; }
mkdir -p "$T/home"
R=$T/remote; O=$T/oroot; mkdir -p "$R/logs" "$O/ckpts/run1" "$O/res" "$O/.venv" "$O/oth"
echo m1 > "$O/ckpts/run1/model_1.pt"; echo k > "$O/ckpts/run1/.wandb_env"; echo r > "$O/res/r.txt"
P=$T/pp; mkdir -p "$P"
conf() { printf 'REMOTE_DIR=%s\n' "$R" > "$P/.hpc.conf"; [ "$#" = 0 ] || printf '%s\n' "$@" >> "$P/.hpc.conf"; }

echo "-- the key: unset = off (never guessed), tagged first, stale exports ignored, honoured by the lint --"
conf
X=$(pull "$P" TARGET=fx-slurm OUTPUT_ROOT="$O" -- --root ckpts/run1); RC=$?
[ "$RC" = 2 ] && none && ok "pull --root without OUTPUT_ROOT in the conf: exit 2, nothing copied (a stale export ignored)" || bad "pull --root unset (rc=$RC)"
has "$X" 'declare OUTPUT_ROOT or FXSLURM_OUTPUT_ROOT in \./\.hpc\.conf — the root this project.s runs write to outside its dir on fx-slurm' "...says which key, which conf, which target"
X=$(push "$P" TARGET=fx-slurm FXSLURM_OUTPUT_ROOT="$O" -- --root logs); RC=$?
[ "$RC" = 2 ] && none && has "$X" 'declare OUTPUT_ROOT or FXSLURM_OUTPUT_ROOT' "sync --root without OUTPUT_ROOT: exit 2, nothing pushed, no ssh" || bad "sync --root unset (rc=$RC)"
conf "OUTPUT_ROOT=$T/generic" "FXSLURM_OUTPUT_ROOT=$O"
X=$(pull "$P" TARGET=fx-slurm -- --root ckpts/run1); RC=$?
[ "$RC" = 0 ] && has "$(cat "$T/rsync.log")" "^fx:$O/\./ckpts/run1\$" "<TAG>_OUTPUT_ROOT beats OUTPUT_ROOT" || { bad "tagged key (rc=$RC)"; echo "$X" | sed 's/^/    | /'; }
conf "OUTPUT_ROOT=$O"
X=$(pull "$P" TARGET=fx-slurm FXSLURM_OUTPUT_ROOT=/stale -- --root -n ckpts/run1)
has "$(cat "$T/rsync.log")" "^fx:$O/\./ckpts/run1\$" "the generic key alone; an exported <TAG>_OUTPUT_ROOT is unset before the conf is read"
printf 'FXSLURM_OUTPUT_ROOT=/a\nWSBOX_OUTPUT_ROOT=/b\nFXSLURM_NICE=1\n' > "$T/lint.conf"
L=$(C "rs_load_target fx-slurm; rs_lint_conf '$T/lint.conf'"); hasnt "$L" 'OUTPUT_ROOT' "the lint honours <TAG>_OUTPUT_ROOT (slurm)"
has "$L" 'FXSLURM_NICE is not honoured' "...and still warns about a key that is not prefixable"
L=$(C "rs_load_target ws-box; rs_lint_conf '$T/lint.conf'"); hasnt "$L" 'OUTPUT_ROOT' "the lint honours <TAG>_OUTPUT_ROOT (nohup)"
for k in RS_PREFIXABLE_SLURM RS_PREFIXABLE_NOHUP; do has " $(C "echo \$$k") " ' OUTPUT_ROOT ' "$k lists OUTPUT_ROOT"; done
for s in run-pull run-sync; do has "$(grep '^rs_load_conf ' "$RS_HOME/bin/$s")" ' OUTPUT_ROOT' "$s unsets OUTPUT_ROOT (+ <TAG>_) before sourcing the conf"; done

echo "-- run-pull --root: source <xfer>:<root>/./<path>, landing ./<path> --"
X=$(pull "$P" TARGET=fx-slurm -- --root ./ckpts/run1/); RC=$?; RL=$(cat "$T/rsync.log")
[ "$RC" = 0 ] && ok "pull --root exits 0" || { bad "pull --root exits 0 (rc=$RC)"; echo "$X" | sed 's/^/    | /'; }
has "$RL" "^fx:$O/\./ckpts/run1\$" "source = <host>:<OUTPUT_ROOT>/./<path> (the -R anchor; ./ and trailing / normalised)"
hasnt "$RL" "$R" "the project dir is not the source"; has "$RL" '^-u$' "-u: a newer local file is kept"; has "$RL" '^-K$' "-K kept"
hasnt "$RL" 'delete' "never --delete"; [ ! -s "$T/ssh-host.log" ] && ok "pull --root never sshes" || bad "pull --root never sshes"
[ "$(cat "$P/ckpts/run1/model_1.pt" 2>/dev/null)" = m1 ] && ok "lands at ./ckpts/run1/ as without --root" || bad "lands at ./ckpts/run1"
[ ! -e "$P/ckpts/run1/.wandb_env" ] && ok "the excludes hold inside a root tree (.wandb_env)" || bad "excludes inside the root tree"
has "$X" "pull (root) fx:$O/{ckpts/run1}" "header: pull (root) <host>:<root>/{…}"; has "$X" "pull done <- fx:$O " "done line names the root"
hasnt "$X" 'NOTE:' "no push-back NOTE for ckpts/ (run-sync excludes it)"
X=$(pull "$P" TARGET=fx-slurm -- --root res); has "$X" 'NOTE: run-sync would push 1 of these files into the project dir' "push-back NOTE kept for a dir run-sync would push (res/)"
rm -rf "$P/ckpts" "$P/res"
X=$(pull "$P" TARGET=fx-slurm -- -n --root ckpts/run1); RL=$(cat "$T/rsync.log")
has "$RL" '^--dry-run$' "-n passes --dry-run"; has "$X" 'Total file size' "-n: count + size (--stats)"
[ ! -e "$P/ckpts" ] && has "$X" 'dry run: nothing written' "-n writes nothing" || bad "-n writes nothing"
X=$(pull "$P" TARGET=fx-slurm -- logs); has "$(cat "$T/rsync.log")" "^fx:$R/\./logs\$" "without --root: the project dir, as before"

echo "-- --root paths: plain, relative, no env/harness state in ANY component (exit 2, nothing copied) --"
for a in ../x /abs a/../b a/./b a//b . '' 'a b' -x 'b*' 'r/?' 'a;b' '$HOME' .venv x/.venv/y q/.venv-fx/lib .cache x/.cache/y .local \
         q/.config/z .git p/.git/config .wandb_env res/.wandb_env x/.hpc.conf x/.ws.conf .rs x/.rs/attempts x/.run-source \
         x/.fx-slurm/env.sh .fx-home x/.ws/launch.sh .fx-packed; do
  pull "$P" TARGET=fx-slurm -- --root "$a" >/dev/null; RC=$?
  [ "$RC" = 2 ] && none && ok "pull --root refused: '$a'" || bad "pull --root refused: '$a' (rc=$RC)"
done
mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$P/lnk"
pull "$P" TARGET=fx-slurm -- --root lnk/x >/dev/null; RC=$?
[ "$RC" = 2 ] && none && [ -L "$P/lnk" ] && ok "pull --root: a local symlink on the landing path is refused" || bad "pull --root symlink (rc=$RC)"
rm -f "$P/lnk"

echo "-- OUTPUT_ROOT itself: absolute, plain, a dedicated dir outside the project dir (exit 2, nothing copied) --"
for r in / "$R" "$R/" "$R/ckpts" "$T" "$(dirname "$T")" rel/out "'\$USER/out'" "$O/../x" "$O/./x" "/$O" "\"$T/a b\"" "'~'" "'~/'" "'\$HOME'"; do
  conf "OUTPUT_ROOT=$r"; X=$(pull "$P" TARGET=fx-slurm -- --root ckpts/run1); RC=$?
  [ "$RC" = 2 ] && none && ok "OUTPUT_ROOT=$r refused" || bad "OUTPUT_ROOT=$r refused (rc=$RC)"
done
conf "OUTPUT_ROOT=$R"; X=$(pull "$P" TARGET=fx-slurm -- --root ckpts/run1); has "$X" 'is the project dir or inside it' "...the project dir: named as such"
conf "OUTPUT_ROOT=$T"; X=$(pull "$P" TARGET=fx-slurm -- --root ckpts/run1); has "$X" 'contains the project dir' "...a root holding the project dir: named as such"
conf "OUTPUT_ROOT=$T"; X=$(push "$P" TARGET=fx-slurm -- --root logs); [ $? = 2 ] && none && ok "run-sync --root checks the root the same way" || bad "run-sync --root root check"
H=$(C "rs_rpath '\$HOME/a//b/./c/'; rs_rpath '\${HOME}'; rs_rpath projects/y/; rs_rpath '~/x'; rs_rpath /"); H=$(printf '%s\n' "$H" | tr '\n' ' ')
[ "$H" = "~/a/b/c ~ ~/projects/y ~/x / " ] && ok "rs_rpath: one spelling (\$HOME / \${HOME} / ~ / a relative dir -> ~/…; //, /./, trailing / dropped)" || bad "rs_rpath ($H)"

echo "-- run-sync --root: those paths into OUTPUT_ROOT, nothing else --"
conf "OUTPUT_ROOT=$O"; rm -rf "$O"; mkdir -p "$O"
mkdir -p "$P/ckpts/run2/__pycache__" "$P/res"; echo m2 > "$P/ckpts/run2/model_2.pt"; echo k > "$P/ckpts/run2/.wandb_env"; echo c > "$P/ckpts/run2/__pycache__/x.pyc"
echo r > "$P/res/r.txt"; echo src > "$P/train.py"; echo key > "$P/.wandb_env"
X=$(push "$P" TARGET=fx-slurm -- --root ckpts/run2); RC=$?; RL=$(cat "$T/rsync.last")
[ "$RC" = 0 ] && ok "sync --root exits 0" || { bad "sync --root exits 0 (rc=$RC)"; echo "$X" | sed 's/^/    | /'; }
[ "$(grep -c . "$T/rsync.calls")" = 2 ] && ok "two rsync calls (the root's listing, the push), nothing else" || bad "two rsync calls ($(grep -c . "$T/rsync.calls"))"
[ "$(head -1 "$T/rsync.calls")" = "--timeout=300 --list-only --exclude=* fx:$O/." ] && ok "first: the root listed, rsync only, '.' alone" \
  || bad "the root's listing ($(head -1 "$T/rsync.calls"))"
for w in -azR -u -K --safe-links --timeout=300; do has "$RL" "^$w\$" "root push argv: $w"; done
hasnt "$RL" 'delete' "never --delete"; has "$RL" "^fx:$O/\./\$" "destination <host>:<root>/./ (a missing root is never created)"
[ "$(grep -vc '^-' "$T/rsync.last")" = 2 ] && has "$RL" '^ckpts/run2$' "sources: only the named path" || bad "only the named path ($(grep -v '^-' "$T/rsync.last" | tr '\n' ' '))"
hasnt "$(cat "$T/rsync.log")" 'run-source\|/remote/\|profile\.sh\|MANIFEST\|chmod=F600\|\.hpc\.conf\|^\./$' "no project code, deploy, stamp, conf or .wandb_env push"
[ ! -s "$T/ssh-host.log" ] && ok "a root push never sshes (no mkdir: a transfer host takes rsync only)" || bad "root push sshes"
[ "$(cat "$O/ckpts/run2/model_2.pt" 2>/dev/null)" = m2 ] && ok "lands at <root>/ckpts/run2/ (-R)" || bad "lands at <root>/ckpts/run2"
[ ! -e "$O/ckpts/run2/.wandb_env" ] && [ ! -e "$O/ckpts/run2/__pycache__" ] && [ ! -e "$O/train.py" ] && ok "no .wandb_env / __pycache__ inside, no sibling" || bad "root push excludes / siblings"
has "$X" "root push ckpts/run2 -> fx:$O/ " "announces: root push <paths> -> <host>:<root>/"; has "$X" "root push done -> fx:$O " "done line"
X=$(push "$P" TARGET=fx-slurm -- --root=res --root ckpts/run2/); RL=$(cat "$T/rsync.log")
has "$RL" '^res$' "--root=PATH form"; has "$RL" '^ckpts/run2$' "--root repeatable (trailing / normalised)"
echo remote-newer > "$O/ckpts/run2/model_2.pt"; touch -t 203001010000 "$O/ckpts/run2/model_2.pt"; touch -t 202001010000 "$P/ckpts/run2/model_2.pt"
push "$P" TARGET=fx-slurm -- --root ckpts/run2 >/dev/null
[ "$(cat "$O/ckpts/run2/model_2.pt")" = remote-newer ] && ok "-u: a newer remote file is never replaced" || bad "-u keeps the newer remote file"
echo m3 > "$P/res/new.txt"; X=$(push "$P" TARGET=fx-slurm -- -n --root res); RL=$(cat "$T/rsync.log")
has "$RL" '^--dry-run$' "-n passes --dry-run"; has "$RL" '^--itemize-changes$' "...itemized"; [ ! -e "$O/res/new.txt" ] && has "$X" 'dry run: nothing written' "-n writes nothing" || bad "-n writes nothing"
mkdir -p "$O/real" "$P/lk"; ln -s real "$O/lk"; echo l > "$P/lk/f"; push "$P" TARGET=fx-slurm -- --root lk >/dev/null
[ -L "$O/lk" ] && ok "-K: a symlinked dir in the root stays a symlink (never replaced by a real dir)" || bad "remote symlink kept (-K)"
rm -rf "$P/lk"

echo "-- run-sync --root: refusals (exit 2, nothing pushed) --"
for a in "-D --root res" "--root res -D" "--root res --delete" "--root res --also res" "--also res --root res" "--root res --take-over" \
         "--root" "--root=" "--root nothere" "--root ../x" "--root /abs" "--root .venv" "--root ckpts/.git" "--root .rs/x" "--root .fx-slurm" \
         "--root x/.ws" "--root res --root .wandb_env"; do
  push "$P" TARGET=fx-slurm -- $a >/dev/null; RC=$?
  [ "$RC" = 2 ] && none && ok "sync refused: $a" || bad "sync refused: $a (rc=$RC)"
done
X=$(push "$P" TARGET=fx-slurm -- --root res -D); has "$X" 'never deletes' "-D with --root: says a root push never deletes"
mkdir -p "$T/elsewhere/sub"; ln -s "$T/elsewhere" "$P/lnk"; push "$P" TARGET=fx-slurm -- --root lnk/sub >/dev/null; RC=$?
[ "$RC" = 2 ] && none && ok "sync --root: a local symlink on the path is refused (rsync would skip it silently)" || bad "sync --root symlink (rc=$RC)"
rm -f "$P/lnk"
conf "OUTPUT_ROOT=$T/no-such-root"; X=$(push "$P" TARGET=fx-slurm -- --root res); RC=$?
[ "$RC" != 0 ] && [ ! -e "$T/no-such-root" ] && has "$X" 'cannot be listed (rsync exit [1-9]' "a missing root: rsync's exit reported, the root never created (its parent exists)" \
  || bad "missing root not created (rc=$RC)"
[ "$(grep -c . "$T/rsync.calls")" = 1 ] && has "$X" 'never creates it: ask the user to create it there, or fix OUTPUT_ROOT / FXSLURM_OUTPUT_ROOT in \./\.hpc\.conf' \
  "...stopped at the listing (no push), what to do named" || bad "a missing root: stopped at the listing"
X=$(push "$P" TARGET=fx-slurm -- -n --root res); RC=$?   # rsync -n alone itemizes 'created directory <root>/.' and exits 0
[ "$RC" != 0 ] && [ ! -e "$T/no-such-root" ] && [ "$(grep -c . "$T/rsync.calls")" = 1 ] && ! printf '%s\n' "$X" | grep -q 'root push done' \
  && has "$X" 'cannot be listed' "-n on a missing root: refused as the real push is (no 'dry run … done')" || bad "-n on a missing root (rc=$RC)"
: > "$T/afile"; conf "OUTPUT_ROOT=$T/afile"; push "$P" TARGET=fx-slurm -- -n --root res >/dev/null; RC=$?
[ "$RC" != 0 ] && [ "$(grep -c . "$T/rsync.calls")" = 1 ] && ok "a root that is a file: refused at the listing" || bad "a root that is a file (rc=$RC)"
conf "OUTPUT_ROOT=$T/no-such-parent/root"; push "$P" TARGET=fx-slurm -- --root res >/dev/null; RC=$?
[ "$RC" != 0 ] && [ ! -e "$T/no-such-parent" ] && ok "...nor its parent" || bad "missing parent not created (rc=$RC)"

echo "-- nohup: a \$HOME-relative root --"
mkdir -p "$T/home/data/wsroot/ckpts/r" "$T/home/projects/y"; echo w > "$T/home/data/wsroot/ckpts/r/m.pt"
W=$T/ww; mkdir -p "$W"; printf "WS_REMOTE_DIR=projects/y\nOUTPUT_ROOT=/generic\nWSBOX_OUTPUT_ROOT='~/data/wsroot'\n" > "$W/.ws.conf"
X=$(pull "$W" TARGET=ws-box -- --root ckpts/r); RC=$?
[ "$RC" = 0 ] && has "$(cat "$T/rsync.log")" '^wsbox:data/wsroot/\./ckpts/r$' "nohup: '~/…' -> a \$HOME-relative source, the tagged key first" || bad "nohup pull --root (rc=$RC)"
[ -f "$W/ckpts/r/m.pt" ] && ok "nohup: lands in the local project" || bad "nohup: lands"
printf "WS_REMOTE_DIR=projects/y\nOUTPUT_ROOT='\$HOME/data/wsroot'\n" > "$W/.ws.conf"; mkdir -p "$W/ev"; echo e > "$W/ev/e.json"
X=$(push "$W" TARGET=ws-box -- --root ev); RC=$?
[ "$RC" = 0 ] && has "$(cat "$T/rsync.log")" '^wsbox:data/wsroot/\./$' "nohup: '\$HOME/…' single-quoted -> the same \$HOME-relative root" || bad "nohup sync --root (rc=$RC)"
[ -f "$T/home/data/wsroot/ev/e.json" ] && ok "nohup: pushed into the root" || bad "nohup: pushed"
printf "WS_REMOTE_DIR=projects/y\nOUTPUT_ROOT='~/projects/y/out'\n" > "$W/.ws.conf"
pull "$W" TARGET=ws-box -- --root ckpts/r >/dev/null; [ $? = 2 ] && none && ok "nohup: a root inside the (\$HOME-relative) project dir is refused" || bad "nohup: root inside the project dir"
printf "WS_REMOTE_DIR=projects/y\nOUTPUT_ROOT='\${HOME}/projects'\n" > "$W/.ws.conf"
pull "$W" TARGET=ws-box -- --root ckpts/r >/dev/null; [ $? = 2 ] && none && ok "nohup: a root holding the project dir is refused" || bad "nohup: root holding the project dir"

echo "-- the home dir: an absolute path at or under the local \$HOME is the target's home (an unquoted \$HOME or ~ in the conf) --"
H=$(C "HOME=/h/u; rs_rpath /h/u; rs_rpath /h/u/x/; rs_rpath /h/ux; rs_rpath /h; rs_rpath '~/y'; HOME=/; rs_rpath /h/u"); H=$(printf '%s\n' "$H" | tr '\n' ' ')
[ "$H" = "~ ~/x /h/ux /h ~/y /h/u " ] && ok "rs_rpath: the local \$HOME and below -> ~ / ~/… (a sibling /h/ux stays; HOME=/ maps nothing)" || bad "rs_rpath home ($H)"
mkdir -p "$T/home/.ssh" "$W/src"; echo secret > "$T/home/.ssh/id_x"; echo s > "$W/src/train.py"
for c in 'OUTPUT_ROOT=$HOME:/ or your home dir' 'OUTPUT_ROOT=~:/ or your home dir' 'OUTPUT_ROOT=$HOME/:/ or your home dir' \
         'OUTPUT_ROOT=$HOME/projects/y:is the project dir or inside it' 'OUTPUT_ROOT=~/projects/y/out:is the project dir or inside it' \
         'OUTPUT_ROOT=$HOME/projects:contains the project dir' "OUTPUT_ROOT=$T:contains your home dir"; do
  printf 'WS_REMOTE_DIR=projects/y\n%s\n' "${c%%:*}" > "$W/.ws.conf"   # unquoted: the local shell expands it, as in a real conf
  X=$(pull "$W" TARGET=ws-box -- --root data/wsroot/ckpts/r); RC=$?
  [ "$RC" = 2 ] && none && has "$X" "${c#*:}" "nohup ${c%%:*} (unquoted) refused: ${c#*:}" || bad "nohup ${c%%:*} refused (rc=$RC)"
  X=$(push "$W" TARGET=ws-box -- --root src); RC=$?
  [ "$RC" = 2 ] && none && ok "...and run-sync --root src with it (no push into the project dir)" || bad "run-sync --root with ${c%%:*} (rc=$RC)"
done
[ ! -e "$W/.ssh" ] && [ ! -e "$T/home/projects/y/src" ] && ok "no private key pulled, nothing pushed into the project dir" || bad "home / project dir reached"
printf 'WS_REMOTE_DIR=projects/y\nOUTPUT_ROOT=$HOME/data/wsroot\n' > "$W/.ws.conf"
X=$(pull "$W" TARGET=ws-box -- --root ckpts/r); RC=$?
[ "$RC" = 0 ] && has "$(cat "$T/rsync.log")" "^wsbox:$T/home/data/wsroot/\./ckpts/r\$" "an unquoted \$HOME/<dir> outside the project dir: allowed, used as written (never re-homed)" \
  || bad "unquoted \$HOME/data/wsroot (rc=$RC)"
for a in .ssh/id_x .gnupg x/.aws/credentials .netrc; do
  pull "$W" TARGET=ws-box -- --root "$a" >/dev/null; RC=$?
  [ "$RC" = 2 ] && none && ok "--root refused: '$a' (credentials, whatever the root)" || bad "--root refused: '$a' (rc=$RC)"
done
for c in "$T/home/proj2:'~/proj2'" "$T/home/proj2:'~/proj2/out'" "'~/proj2':$T/home/proj2" "'\$HOME/proj2':$T/home"; do
  printf 'REMOTE_DIR=%s\nOUTPUT_ROOT=%s\n' "${c%%:*}" "${c#*:}" > "$P/.hpc.conf"
  pull "$P" TARGET=fx-slurm -- --root ckpts/run1 >/dev/null; RC=$?
  [ "$RC" = 2 ] && none && ok "slurm REMOTE_DIR=${c%%:*} vs OUTPUT_ROOT=${c#*:}: refused (absolute under the local home = ~/…)" \
    || bad "slurm REMOTE_DIR=${c%%:*} vs OUTPUT_ROOT=${c#*:} (rc=$RC)"
done
