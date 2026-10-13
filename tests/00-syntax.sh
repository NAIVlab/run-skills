#!/usr/bin/env bash
# tests/00-syntax.sh — phase A: every script in the harness parses (bash -n), and the files that get sourced by
# a possibly-zsh login shell on the remote (env.sh, profiles) also parse under zsh -n when zsh is installed.
# Run by selftest.sh with RS_HOME set:  bash tests/00-syntax.sh
set -u
. "$RS_HOME/tests/lib.sh"

n=0; f_bad=0
for f in "$RS_HOME"/bin/* "$RS_HOME"/lib/*.sh "$RS_HOME"/remote/* "$RS_HOME"/targets/*/*.sh "$RS_HOME"/templates/pack/install.sh \
         "$RS_HOME"/tests/*.sh "$RS_HOME"/selftest.sh "$RS_HOME"/install.sh; do
  [ -f "$f" ] || continue
  n=$((n+1)); bash -n "$f" 2>/dev/null || { bad "bash -n ${f#"$RS_HOME"/}"; f_bad=1; }
done
[ "$f_bad" = 0 ] && ok "all $n scripts parse (bash -n)"
[ "$n" -ge 10 ] && ok "harness has at least 10 scripts ($n)" || bad "harness has at least 10 scripts (got $n)"
for f in "$RS_HOME"/remote/submit.sh "$RS_HOME"/remote/job.sbatch "$RS_HOME"/remote/bootstrap.sh "$RS_HOME"/remote/status.sh "$RS_HOME"/selftest.sh; do
  [ -f "$f" ] || continue
  head -1 "$f" | grep -q '^#!' && ok "shebang: ${f#"$RS_HOME"/}" || bad "shebang: ${f#"$RS_HOME"/}"
done

if command -v zsh >/dev/null 2>&1; then
  z_bad=0
  for f in "$RS_HOME"/remote/env.sh "$RS_HOME"/targets/*/profile.sh; do
    [ -f "$f" ] || continue
    zsh -n "$f" 2>/dev/null || { bad "zsh -n ${f#"$RS_HOME"/}"; z_bad=1; }
  done
  [ "$z_bad" = 0 ] && ok "sourced-on-remote files parse under zsh"
  # the fixtures written by selftest.sh must be zsh-clean too (they stand in for real profiles)
  for f in "$RS_USER_DIR"/targets/*/profile.sh; do
    [ -f "$f" ] || continue
    zsh -n "$f" 2>/dev/null && ok "zsh -n fixture $(basename "$(dirname "$f")")/profile.sh" \
      || bad "zsh -n fixture $(basename "$(dirname "$f")")/profile.sh"
  done
fi
# zsh-safety of env.sh is textual too: bashisms that zsh -n would not catch
E=$(grep -v '^[[:space:]]*#' "$RS_HOME/remote/env.sh")   # header comments may name the bashisms
hasnt "$E" 'BASH_SOURCE' "env.sh: no BASH_SOURCE"
hasnt "$E" '\${![A-Za-z_]' "env.sh: no \${!var} indirection"
hasnt "$E" '\[\[' "env.sh: no [[ ]]"
hasnt "$E" '\^\^' "env.sh: no \${var^^}"
hasnt "$E" '^ *set -e' "env.sh: never set -e"
