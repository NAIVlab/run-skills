#!/usr/bin/env bash
# tests/vgate/envdrop.sh — the facts behind launch.sh's R7-3 WARNING (a tool that starts the command without this launch's
# environment, or outside its run), read from a box's INSTALLED tmux / screen / setpriv / systemd-run, only with the user's
# OK. No GPU is touched: each check runs a throwaway probe that records its CUDA_VISIBLE_DEVICES and its session id; every
# tmux / screen session lives on its own socket under a scratch dir and is ended before exit.
#   ssh <alias> 'bash -s' < tests/vgate/envdrop.sh                              (tmux screen setpriv)
#   ssh <alias> 'bash -s tmux screen setpriv systemd-run' < tests/vgate/envdrop.sh   (systemd-run starts one transient --user unit)
# One line per tool (or `<tool>=absent`); NOT in selftest as such (tests/88-vgate.sh runs its plumbing on a stub, and the
# tmux / setpriv facts on this machine's own tools when installed). The caller's CUDA_VISIBLE_DEVICES is 5 in every check;
# `unset` = the probe did not get it; `other` = the probe ran in another session than the caller (outside the caller's run).
#   tmux: tmux_version= tmux_server_env=<a session made while a server started without the variable runs> (want unset: the
#     session gets the server's environment, not the client's) tmux_first_env=<the session that starts the server> (want 5:
#     the server inherits that client's — the command still runs outside the caller's run) tmux_session=<other|same> (want other)
#   tmux (R8-6; a second line): tmux_split_prefix_env=<`tmux split -d` into the server's session: a command named by a PREFIX>
#     (want unset) tmux_prefix=<word>:<what `tmux <word>` runs>,… tmux_alias=<word>:<…>,… — each word asked of the running
#     server with an invalid flag (-~: tmux names the command it resolved and runs nothing): <command>, <c1>|<c2> when
#     ambiguous among the commands launch.sh warns about only, `ambiguous` (one it does not warn about among them), `unknown`.
#     want (tmux 3.2+): sp:split-window ru:run-shell i:if-shell pi:pipe-pane new:new-session new-:new-session|new-window
#     new-s:new-session new-w:new-window resp:respawn-pane|respawn-window display-po:display-popup send-k:send-keys, and
#     s r p n ne res display-p send-: ambiguous, split-p: unknown — launch.sh's thresholds (a tmux < 3.2 has no display-popup:
#     display-po unknown, display-p display-panes); aliases neww send splitw splitp split-pane respawnp respawnw run if popup
#     pipep: their commands (popup: 3.2+)
#   screen: screen_version= screen_dm_env=<screen -dmS> (the environment it got) screen_session=<other|same> (want other: -dm
#     detaches it from the caller)
#   setpriv: setpriv_version= setpriv_reset_env=<setpriv --reset-env> (want unset) setpriv_reset_prefix=<setpriv --res> (want
#     unset: its getopt_long takes a unique prefix)
#   systemd-run (only when named): systemd_run_env=<systemd-run --user --wait --quiet --collect> (want unset)
set -u
[ "$#" -gt 0 ] || set -- tmux screen setpriv
unset TMUX STY
W=$(mktemp -d) || exit 1
TS=""; SS=""
fin() { [ -z "$TS" ] || tmux -S "$TS" kill-server >/dev/null 2>&1; [ -z "$TS" ] || tmux -S "$TS.2" kill-server >/dev/null 2>&1
  [ -z "$SS" ] || SCREENDIR=$W/sd screen -S "$SS" -X quit >/dev/null 2>&1; rm -rf "$W"; }
trap fin EXIT
cd "$W" || exit 1
printf '#!/bin/sh\necho "${CUDA_VISIBLE_DEVICES-unset} $(ps -o sid= -p $$ | tr -d " ")" > "$1.tmp" && mv "$1.tmp" "$1"\n' > "$W/probe" && chmod +x "$W/probe" || exit 1
ME=$(ps -o sid= -p $$ | tr -d ' ')
TW=" new-session new-window split-window respawn-pane respawn-window run-shell if-shell display-popup pipe-pane send-keys "   # launch.sh's
tres() {   # tres WORD -> R: what `tmux WORD` runs on the server at $TS, asked with an invalid flag (-~), so it runs nothing
  local l c
  l=$(tmux -S "$TS" -f /dev/null "$1" -~ </dev/null 2>&1 | head -n 1)
  case "$l" in
    "usage: "*) l=${l#usage: }; R=${l%% *} ;;           # an older tmux: the resolved command's usage line
    "command "*": "*) l=${l#command }; R=${l%%:*} ;;    # a newer one: command <name>: invalid flag -~
    "ambiguous command: "*", could be: "*) l=${l#*, could be: }; R=""
      for c in $(printf %s "$l" | tr -d ,); do R="$R${R:+|}$c"; case "$TW" in *" $c "*) ;; *) R=ambiguous; break ;; esac; done ;;
    "unknown command: "*) R=unknown ;;
    *) R="?($(printf %s "$l" | tr -c 'A-Za-z0-9.:_-' '_' | cut -c1-40))" ;;
  esac; }
got() {   # got FILE -> V: the probe's CUDA_VISIBLE_DEVICES (fail(none): it wrote nothing within 10 s); S: other|same|unknown
  local i=0 l; while [ ! -s "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  l=$(cat "$1" 2>/dev/null) || l=""; V=${l%% *}; S=${l#* }; [ -n "$l" ] || { V="fail(none)"; S=""; }
  if [ -z "$S" ]; then S=unknown; elif [ "$S" = "$ME" ]; then S=same; else S=other; fi; }
for c in "$@"; do case "$c" in
  tmux) command -v tmux >/dev/null 2>&1 || { echo "tmux=absent"; continue; }
    TS=$W/tmux.sock
    env -u CUDA_VISIBLE_DEVICES tmux -S "$TS" -f /dev/null new-session -d -s base 'sleep 120' </dev/null >/dev/null 2>&1
    CUDA_VISIBLE_DEVICES=5 tmux -S "$TS" -f /dev/null new-session -d -s probe "$W/probe $W/t1" </dev/null >/dev/null 2>&1
    got "$W/t1"; a=$V; s=$S
    CUDA_VISIBLE_DEVICES=5 tmux -S "$TS.2" -f /dev/null new-session -d -s first "$W/probe $W/t2" </dev/null >/dev/null 2>&1; got "$W/t2"
    echo "tmux_version=$(tmux -V 2>/dev/null | tr ' ' '_') tmux_server_env=$a (want unset) tmux_first_env=$V (want 5) tmux_session=$s (want other)"
    CUDA_VISIBLE_DEVICES=5 tmux -S "$TS" -f /dev/null split -d -t base "$W/probe $W/t3" </dev/null >/dev/null 2>&1; got "$W/t3"; c=$V
    pr=""; for w in sp ru i pi new new- new-s new-w resp display-po send-k s r p n ne res display-p send- split-p; do tres "$w"; pr="$pr${pr:+,}$w:$R"; done
    al=""; for w in neww send splitw splitp split-pane respawnp respawnw run if popup pipep; do tres "$w"; al="$al${al:+,}$w:$R"; done
    echo "tmux_split_prefix_env=$c (want unset) tmux_prefix=$pr tmux_alias=$al" ;;
  screen) command -v screen >/dev/null 2>&1 || { echo "screen=absent"; continue; }
    mkdir -m 700 "$W/sd" || exit 1; SS=rs-vgate-$$
    SCREENDIR=$W/sd CUDA_VISIBLE_DEVICES=5 screen -dmS "$SS" "$W/probe" "$W/s1" </dev/null >/dev/null 2>&1
    got "$W/s1"; echo "screen_version=$(screen -v 2>/dev/null | head -n 1 | tr ' ' '_') screen_dm_env=$V screen_session=$S (want other)" ;;
  setpriv) command -v setpriv >/dev/null 2>&1 || { echo "setpriv=absent"; continue; }
    CUDA_VISIBLE_DEVICES=5 setpriv --reset-env "$W/probe" "$W/p1" </dev/null >/dev/null 2>&1
    CUDA_VISIBLE_DEVICES=5 setpriv --res "$W/probe" "$W/p2" </dev/null >/dev/null 2>&1
    got "$W/p1"; a=$V; got "$W/p2"
    echo "setpriv_version=$(setpriv --version 2>/dev/null | head -n 1 | tr ' ' '_') setpriv_reset_env=$a (want unset) setpriv_reset_prefix=$V (want unset)" ;;
  systemd-run) command -v systemd-run >/dev/null 2>&1 || { echo "systemd-run=absent"; continue; }
    CUDA_VISIBLE_DEVICES=5 timeout 120 systemd-run --user --wait --quiet --collect "$W/probe" "$W/y1" </dev/null >/dev/null 2>&1
    got "$W/y1"; echo "systemd_run_env=$V (want unset)" ;;
  *) echo "vgate=fail unknown check '$c' (tmux screen setpriv systemd-run)"; exit 2 ;;
esac; done
