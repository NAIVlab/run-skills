#!/usr/bin/env bash
# tests/88-vgate.sh — phase A: tests/vgate/slurm-remote.sh (the V-gate reproductions, never run against a target here)
# under stub sbatch/scontrol/squeue/sacct/scancel and an instant sleep: a scratch dir given relative to the remote home
# reaches sbatch as an absolute --chdir and job.sh writes absolute paths; a failed sbatch stops the gate (exit 1). And
# tests/vgate/launchers.sh on fake deepspeed / accelerate modules, tests/vgate/containers.sh on stub docker / podman /
# apptainer / singularity (their plumbing; the facts come from installed copies on a box, with the user's OK), and
# tests/vgate/envdrop.sh (R7-3) on this machine's own tmux / setpriv when installed (those facts, for real) and stubs.
set -u
. "$RS_HOME/tests/lib.sh"
G=$RS_HOME/tests/vgate/slurm-remote.sh; V=$T/vg; mkdir -p "$V/bin" "$V/home"
cat > "$V/bin/sbatch" <<EOS
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && { echo "slurm 0.0-stub"; exit 0; }
[ -f "$V/sbatch-fails" ] && { echo "sbatch: error: stub" >&2; exit 1; }
printf '%s\n' "\$*" >> "$V/sbatch.log"; echo \$(( 100 + \$(wc -l < "$V/sbatch.log") ))
EOS
for c in scontrol squeue sacct scancel sleep; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$c" "$V" > "$V/bin/$c"; done
chmod +x "$V/bin/"*
vg() { ( cd "$V/home" && PATH="$V/bin:$PATH" bash "$G" "$@" 2>&1 ); }

echo "-- slurm-remote.sh: a relative scratch dir --"
O=$(vg scratch/vg gpu); RC=$?; D=$(cd "$V/home/scratch/vg" 2>/dev/null && pwd -P)
[ "$RC" = 0 ] && [ -n "$D" ] && ok "gate runs to the end on stubs (exit 0)" || { bad "gate runs to the end on stubs (rc=$RC)"; echo "$O" | head -5 | sed 's/^/    | /'; }
has "$O" "dir=$D\$" "dir= is the physical scratch dir"
has "$O" '^bash_exit_fn=continued rc=3 (want continued rc=3) bash=' "bash fact: a function named exit replaces the builtin (submit.sh's probe passes a gate's exit 1)"
has "$(cat "$V/sbatch.log" 2>/dev/null)" "rs-vgate-rq --chdir $D job.sh\$" "requeue job: --chdir is absolute (not resolved again inside the scratch dir)"
has "$(cat "$D/job.sh" 2>/dev/null)" ">> \"$D/requeue.out\"" "job.sh appends to an absolute requeue.out"
has "$(cat "$V/sbatch.log" 2>/dev/null)" '^--parsable -p gpu -c 1 ' "no extra sbatch args: none passed"
has "$(cat "$V/sbatch.log" 2>/dev/null)" ' --hold --time=0 -J rs-vgate-t0 --wrap true$' "time-0 repro: a held job with --time=0 (D2: what 0 means)"
has "$O" '^time0=' "...printed as time0= (its TimeLimit, or sbatch's refusal)"
has "$(cat "$V/sbatch.log" 2>/dev/null)" ' --hold --time=00:02:00 --comment -t1 -J rs-vgate-cv --wrap true$' "value-word repro: --comment -t1 after --time=00:02:00 (a time hidden behind a value word)"
has "$O" '^comment_value=.*(want TimeLimit=00:02:00 comment=-t1' "...printed as comment_value="
has "$(cat "$V/sbatch.log" 2>/dev/null)" ' --hold --time=00:01:00 --requeue bare.sh -J rs-vgate-bare --comment=rs=vgate-bare$' "bare-word repro: a word after --requeue, then -J / --comment (submit.sh refuses such an SBATCH_EXTRA word)"
has "$O" '^bare_word=.*(want bare.sh|' "...printed as bare_word= (its Name|Comment)"; [ -f "$V/home/scratch/vg/bare.sh" ] && ok "...bare.sh written in the scratch dir" || bad "...bare.sh written in the scratch dir"
hasnt "$(grep -v '^ *#' "$G")" '[^+]"\${X\[@\]}"' "extra sbatch args expand as \${X[@]+...} (bash < 4.4 + set -u)"
C=$(cat "$V/calls.log" 2>/dev/null)   # the identity reads rsk cancel / run-watch rely on, each of the script's own jobs
has "$C" '^squeue -h -u [^ ]* -O JobID:0|,UserName:0|,Name:0|,WorkDir:0|$' "identity read: squeue -u -O JobID,UserName,Name,WorkDir"
has "$C" '^squeue -h -u [^ ]* --states=all -O JobID:0|,Name:0|,UserName:0|,WorkDir:0|,State:0|$' "identity read: run-watch's / rsk cancel's squeue format"
has "$C" '^squeue -h -j 10[0-9] -O JobID:0|,UserName:0|$' "identity read: squeue -j (another user's job by id)"
has "$C" '^sacct -X -n -j 10[0-9] -o JobID,JobName,User,WorkDir -P$' "identity read: sacct -j -o JobID,JobName,User,WorkDir -P"
S=$(cat "$V/sbatch.log" 2>/dev/null)   # --rs-chain's singleton: two held jobs of one name, the second released, both cancelled
[ "$(printf '%s\n' "$S" | grep -c -- '--hold -t 00:01:00 -J rs-vgate-single --dependency=singleton --wrap true$')" = 2 ] \
  && ok "singleton repro: two held 1-min jobs of one name with --dependency=singleton" || bad "singleton repro: the two submits"
has "$C" '^scontrol release 10[0-9]$' "...the second is released (the first stays held)"
has "$C" '^squeue -h -j 10[0-9] -O State:0|,Reason:0|$' "...its State|Reason read (PENDING|Dependency| wanted)"
has "$O" '^singleton_second=.*(want PENDING|Dependency| while 10[0-9] is held)$' "...printed as singleton_second="
SI=$(grep -n -- ' -J rs-vgate-single ' "$V/sbatch.log" 2>/dev/null | cut -d: -f1 | while read -r n; do echo $((100 + n)); done)   # the stub's ids: 100 + line
[ "$(printf '%s\n' $SI | wc -l)" = 2 ] && for s in $SI; do has "$C" "^scancel $s\$" "...singleton job $s cancelled"; done || bad "singleton repro: both cancelled ($SI)"
DU=$((100 + $(grep -n -- ' -J rs-vgate-dup ' "$V/sbatch.log" 2>/dev/null | head -n 1 | cut -d: -f1)))   # R5-5: scancel's words (rsk cancel)
L0=$(printf '%s\n' "$C" | grep -n "^scancel $DU\$" | head -n 1 | cut -d: -f1)   # (not the EXIT trap's: before the unknown-id probe)
L1=$(printf '%s\n' "$C" | grep -n '^squeue -h -j 4000000000 -O JobID:0$' | head -n 1 | cut -d: -f1); L2=$(printf '%s\n' "$C" | grep -n '^scancel 4000000000$' | head -n 1 | cut -d: -f1)
[ -n "$L0" ] && [ -n "$L1" ] && [ "$L0" -lt "$L1" ] && printf '%s\n' "$C" | head -n "$L0" | grep -q "^scancel $DU 1" \
  && ok "scancel repro: the script's own dup job ($DU) cancelled again once ended" || bad "scancel repro: a second scancel of the ended dup job $DU ($L0, $L1)"
has "$O" "^scancel_ended=rc=[0-9]* err=.*(want rc!=0 and 'job id $DU: … already completing or completed', or '… Invalid job id' once purged)\$" "...printed as scancel_ended= (its exit and words)"
[ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ] && ok "scancel repro: an id no local job can have, scancel'd only after squeue -j lists none" || bad "scancel repro: squeue -j 4000000000 ($L1) before scancel 4000000000 ($L2)"
has "$O" "^scancel_invalid=rc=[0-9]* err=.*(want rc!=0 and 'job id 4000000000: Invalid job id specified')\$" "...printed as scancel_invalid="

echo "-- slurm-remote.sh: sbatch fails --"
touch "$V/sbatch-fails"; : > "$V/calls.log"
O=$(vg scratch/vg2 gpu); RC=$?
[ "$RC" = 1 ] && has "$O" '^vgate=fail sbatch (dup)' "a failed sbatch stops the gate (exit 1)" || bad "a failed sbatch stops the gate (rc=$RC)"
hasnt "$O" 'dup_time=\|requeue=' "nothing measured on an empty job id"
hasnt "$(cat "$V/calls.log")" 'scancel *$' "no scancel of an empty job id"

echo "-- slurm-remote.sh: squeue lists the unknown id --"
rm -f "$V/sbatch-fails"; : > "$V/calls.log"; cp "$V/bin/squeue" "$V/squeue.plain"
printf '#!/bin/sh\necho "squeue $*" >> "%s/calls.log"\n[ "$*" != "-h -j 4000000000 -O JobID:0" ] || echo 4000000000\n' "$V" > "$V/bin/squeue"
O=$(vg scratch/vg3 gpu); RC=$?; cp "$V/squeue.plain" "$V/bin/squeue"
[ "$RC" = 0 ] && has "$O" '^scancel_invalid=skipped (squeue -j lists 4000000000 here)$' "an id squeue lists is never scancel'd: skipped" || bad "squeue lists the id: skipped (rc=$RC)"
hasnt "$(cat "$V/calls.log")" '^scancel 4000000000' "...no scancel of it"

echo "-- launchers.sh (R5-2's flags, R6-3's configs: launcher facts read from installed copies): its plumbing, on fake modules --"
LG=$RS_HOME/tests/vgate/launchers.sh
if command -v python3 >/dev/null 2>&1; then
  FP=$T/fakepy; mkdir -p "$FP/deepspeed/launcher" "$FP/accelerate/commands/config" "$FP/accelerate/utils"
  printf '__version__ = "0.0-fake"\n' > "$FP/deepspeed/__init__.py"; : > "$FP/deepspeed/launcher/__init__.py"
  printf '%s\n' 'import argparse, os' 'def parse_args(args=None):' '    p = argparse.ArgumentParser()' \
    '    p.add_argument("-i", "--include", default=""); p.add_argument("--num_gpus", "--num_accelerators", type=int, default=-1)' \
    '    p.add_argument("--num_nodes", type=int, default=-1); p.add_argument("-H", "--hostfile", default=DLTS_HOSTFILE)' \
    '    p.add_argument("user_script"); return p.parse_args(args)' \
    'def main(args=None):' '    visible_devices_env = "CUDA_VISIBLE_DEVICES"' '    resource_pool = {}' \
    '    if not resource_pool and len(os.environ.get(visible_devices_env, "")):' '        print("but ignoring it")' '        del os.environ[visible_devices_env]' \
    "DLTS_HOSTFILE = \"$T/no-hostfile\"" > "$FP/deepspeed/launcher/runner.py"
  printf '__version__ = "0.0-fake"\n' > "$FP/accelerate/__init__.py"; : > "$FP/accelerate/commands/__init__.py"; : > "$FP/accelerate/utils/__init__.py"
  : > "$FP/accelerate/commands/config/__init__.py"
  printf '%s\n' 'import argparse' 'def launch_command_parser():' '    p = argparse.ArgumentParser(allow_abbrev=False)' \
    '    p.add_argument("--gpu_ids", "--gpu-ids"); p.add_argument("--config_file", "--config-file"); p.add_argument("training_script"); return p' \
    'def _validate_launch_command(args, defaults):' '    if args.gpu_ids is None:' '        args.gpu_ids = defaults.gpu_ids' > "$FP/accelerate/commands/launch.py"
  printf '%s\n' 'import os' 'cache_dir = os.path.join(os.path.expanduser(os.environ.get("HF_HOME", "~/.cache/huggingface")), "accelerate")' \
    'default_json_config_file = os.path.join(cache_dir, "default_config.json")' 'default_yaml_config_file = os.path.join(cache_dir, "default_config.yaml")' \
    'if os.path.isfile(default_yaml_config_file) or not os.path.isfile(default_json_config_file):' '    default_config_file = default_yaml_config_file' \
    'else:' '    default_config_file = default_json_config_file' > "$FP/accelerate/commands/config/config_args.py"
  printf '%s\n' 'def prepare_simple_launcher_cmd_env(args, current_env):' '    if args.gpu_ids != "all" and args.gpu_ids is not None:' \
    '        current_env["CUDA_VISIBLE_DEVICES"] = args.gpu_ids' > "$FP/accelerate/utils/launch.py"
  O=$(PYTHONPATH=$FP bash "$LG" python3 2>&1); RC=$?
  [ "$RC" = 0 ] && has "$O" "^ds_version=0.0-fake ds_abbrev=2 ds_short=localhost:1 ds_alias=2 ds_hostfile_flag=h1,h2,h3,h4,h5,h7 ds_ignores_cvd=yes ds_hostfile=$T/no-hostfile:absent ds_pool_cvd=yes\$" "launchers.sh: the deepspeed line (parse_args — the -H / --hostfile spellings on the real argparse, R8-5 — and runner.main's source)" \
    || { bad "launchers.sh on fakes (rc=$RC)"; printf '%s\n' "$O" | head -5 | sed 's/^/    | /'; }
  has "$O" '^acc_version=0.0-fake acc_hyphen=0,1 acc_abbrev=refused acc_sets_cvd=yes acc_all=yes acc_cfg_gpu_ids=yes acc_cfg_hyphen=c.yaml acc_cfg_default=$HF_HOME/accelerate/default_config.yaml acc_cfg_json_only=default_config.json$' \
    "launchers.sh: the accelerate line (launch_command_parser, launch.py's and utils/launch.py's source, config_args under a scratch HF_HOME holding only a .json)"
  printf 'def main(args=None):\n    pass\n' >> "$FP/deepspeed/launcher/runner.py"; printf 'def f(args, current_env):\n    pass\n' > "$FP/accelerate/utils/launch.py"
  printf '%s\n' 'import argparse' 'def launch_command_parser():' '    p = argparse.ArgumentParser(allow_abbrev=False)' \
    '    p.add_argument("--gpu_ids"); p.add_argument("training_script"); return p' > "$FP/accelerate/commands/launch.py"
  O=$(PYTHONPATH=$FP bash "$LG" python3 2>&1); has "$O" 'ds_ignores_cvd=no ds_hostfile=.* ds_pool_cvd=no$' "...a runner that keeps the variable reads no (both)"
  has "$O" 'acc_hyphen=refused acc_abbrev=refused acc_sets_cvd=no acc_all=no acc_cfg_gpu_ids=no acc_cfg_hyphen=refused ' "...and an accelerate that never sets it, nor reads a config: no, refused"
  O=$(PYTHONPATH=$T/nowhere bash "$LG" python3 2>&1); RC=$?
  [ "$RC" = 0 ] && has "$O" '^deepspeed=absent (' "launchers.sh without the packages: absent, never a guess" || bad "launchers.sh without packages (rc=$RC)"
  O=$(bash "$LG" "$T/no-python" 2>&1); RC=$?; [ "$RC" = 1 ] && has "$O" '^vgate=fail ' "...an interpreter that does not run: vgate=fail, exit 1" || bad "launchers.sh, no interpreter (rc=$RC)"
else echo "  SKIP: no python3 here: launchers.sh's plumbing not exercised"; fi

echo "-- containers.sh (R6-2's container facts, read on a box): its plumbing, on stub docker / podman / apptainer / singularity --"
CG=$RS_HOME/tests/vgate/containers.sh; CB=$T/cbin; mkdir -p "$CB"
for rt in docker podman; do   # a docker-like stub: `run` passes in no host environment, only -e NAME[=VALUE]; image bad = exit 125;
  # run -d --name N records a container N (nothing runs); `exec N CMD` runs CMD with no host environment either; rm -f N
  printf '%s\n' '#!/usr/bin/env bash' "C=$CB/ctr.$rt" 'case "$1" in' "  --version) echo '$rt version 0.0-stub' ;;" '  info) echo nvidia ;;' \
    '  run) shift; [ "$1" = --help ] && { echo "      --gpus gpu-request   GPU devices to add"; exit 0; }; e=(); d=""; n=""' \
    '    while [ $# -gt 0 ]; do case "$1" in --rm) shift ;; -d) d=1; shift ;; --name) n=$2; shift 2 ;; -e) case "$2" in *=*) e+=("$2") ;; *) [ -z "${!2+x}" ] || e+=("$2=${!2}") ;; esac; shift 2 ;; *) break ;; esac; done' \
    '    [ "$1" != bad ] || exit 125; [ -z "$d" ] || { : > "$C.$n"; echo "id-$n"; exit 0; }; shift; exec env -i ${e[@]+"${e[@]}"} "$@" ;;' \
    '  exec) shift; [ -f "$C.$1" ] || exit 1; shift; exec env -i "$@" ;;' '  rm) shift; [ "$1" != -f ] || shift; rm -f "$C.$1" ;;' 'esac' > "$CB/$rt"; done
for rt in apptainer singularity; do   # an apptainer-like stub: the host environment passes in unless --cleanenv / --containall;
  P=APPTAINERENV_; [ "$rt" = apptainer ] || P=SINGULARITYENV_   # <PREFIX>CUDA_VISIBLE_DEVICES sets it inside either way
  printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in' "  --version) echo '$rt version 0.0-stub' ;;" \
    '  exec) shift; c=0; while :; do case "$1" in --cleanenv|--containall) c=1; shift ;; -*) shift ;; *) break ;; esac; done; shift' \
    "    p=\${${P}CUDA_VISIBLE_DEVICES:-}" '    if [ "$c" = 1 ]; then exec env -i ${p:+CUDA_VISIBLE_DEVICES=$p} "$@"; else exec env ${p:+CUDA_VISIBLE_DEVICES=$p} "$@"; fi ;;' \
    'esac' > "$CB/$rt"; done
chmod +x "$CB"/*
O=$(PATH="$CB:$PATH" bash "$CG" img img.sif 2>&1); RC=$?
[ "$RC" = 0 ] && has "$O" '^docker_version=docker_version_0.0-stub docker_gpus_flag=yes docker_env=unset (want unset) docker_env_e=5 (want 5) docker_exec_env=unset (want unset) docker_default_runtime=nvidia$' \
  "containers.sh: the docker line (--gpus in run --help, the environment inside without and with a bare -e, exec into a detached one (R7-3), DefaultRuntime)" || { bad "containers.sh on stubs (rc=$RC)"; printf '%s\n' "$O" | head -5 | sed 's/^/    | /'; }
has "$O" '^podman_version=podman_version_0.0-stub podman_gpus_flag=yes podman_env=unset (want unset) podman_env_e=5 (want 5) podman_exec_env=unset (want unset)$' "containers.sh: the podman line"
[ -z "$(ls "$CB"/ctr.* 2>/dev/null)" ] && ok "...the detached container it exec'd into is removed (rm -f)" || bad "...the detached container is left ($(ls "$CB"/ctr.* 2>/dev/null))"
has "$O" '^apptainer_version=apptainer_version_0.0-stub apptainer_env=5 (want 5) apptainer_cleanenv=unset (want unset) apptainer_containall=unset (want unset) apptainer_prefix=7 (want 7)$' \
  "containers.sh: the apptainer line (passed in; --cleanenv / --containall drop it; APPTAINERENV_ sets it inside)"
has "$O" '^singularity_version=singularity_version_0.0-stub singularity_env=5 .* singularity_prefix=7 (want 7)$' "containers.sh: the singularity line (SINGULARITYENV_)"
O=$(PATH="$CB:$PATH" bash "$CG" bad - 2>&1); has "$O" '^docker_.* docker_env=fail(rc=125) ' "...a container that does not start: fail(rc=N), never read as unset"
has "$O" '^docker_.* docker_exec_env=fail(run -d) ' "...nor one it cannot start detached: fail(run -d), never read as unset"
has "$O" '^apptainer_version=[^ ]* apptainer_env=skipped (no image)$' "...'-': that kind's container checks skipped"
O=$(PATH=/usr/bin:/bin bash "$CG" img img.sif 2>&1); RC=$?; e=0
for rt in docker podman apptainer singularity; do PATH=/usr/bin:/bin command -v "$rt" >/dev/null 2>&1 || { printf '%s\n' "$O" | grep -qx "$rt=absent" || e=1; }; done
[ "$RC" = 0 ] && [ "$e" = 0 ] && ok "containers.sh: a runtime that is not installed: <rt>=absent, never a guess" || bad "containers.sh: absent runtimes (rc=$RC)"

echo "-- envdrop.sh (R7-3's facts, read on a box: tmux / screen / setpriv / systemd-run): this machine's own tmux and setpriv when installed, stubs for the plumbing --"
EG=$RS_HOME/tests/vgate/envdrop.sh
if command -v tmux >/dev/null 2>&1; then O=$(bash "$EG" tmux 2>&1)
  has "$O" '^tmux_version=[^ ]* tmux_server_env=unset (want unset) tmux_first_env=5 (want 5) tmux_session=other (want other)$' \
    "fact (this machine's tmux): a session made while a tmux server runs gets the SERVER's environment, not the client's CUDA_VISIBLE_DEVICES, in another session"
  has "$O" '^tmux_split_prefix_env=unset (want unset) tmux_prefix=' "fact (this machine's tmux, R8-6): \`tmux split -d\` (split-window named by a prefix) runs the command in the server's session: no CUDA_VISIBLE_DEVICES"
  TP=$(printf '%s\n' "$O" | sed -n 's/^tmux_split_prefix_env=.* tmux_prefix=\([^ ]*\) tmux_alias=[^ ]*$/\1/p'); TA=$(printf '%s\n' "$O" | sed -n 's/^tmux_split_prefix_env=.* tmux_alias=\([^ ]*\)$/\1/p')
  rv() { printf '%s\n' "$1" | tr ',' '\n' | sed -n "s/^$2://p"; }   # rv LIST WORD -> what this tmux runs for `tmux WORD`
  if printf '%s\n' "$TA" | tr ',' '\n' | grep -qx 'popup:display-popup'; then   # tmux 3.2+ (display-popup): the whole line, as wanted
    has "$TP" '^sp:split-window,ru:run-shell,i:if-shell,pi:pipe-pane,new:new-session,new-:new-session|new-window,new-s:new-session,new-w:new-window,resp:respawn-pane|respawn-window,display-po:display-popup,send-k:send-keys,s:ambiguous,r:ambiguous,p:ambiguous,n:ambiguous,ne:ambiguous,res:ambiguous,display-p:ambiguous,send-:ambiguous,split-p:unknown$' \
      "fact (this machine's tmux, R8-6): tmux runs a unique prefix of a command name — sp ru i pi new-s new-w display-po send-k; new- / resp only among warned ones; s r p n ne res display-p send- ambiguous, split-p unknown"
    has "$TA" '^neww:new-window,send:send-keys,splitw:split-window,splitp:split-window,split-pane:split-window,respawnp:respawn-pane,respawnw:respawn-window,run:run-shell,if:if-shell,popup:display-popup,pipep:pipe-pane$' \
      "fact (this machine's tmux, R8-6): the aliases, and the default command-aliases splitp / split-pane"
  else echo "  SKIP: this tmux has no display-popup (< 3.2): the whole-line check is for 3.2+ (the threshold checks below still run)"; fi
  LT=$(sed -n 's/^ *for o in \(new-session:[0-9][^;]*\); do$/\1/p' "$RS_HOME/remote/launch.sh"); e=""; [ -n "$LT" ] || e=" (launch.sh's tmux table not found)"
  for o in $LT; do c=${o%:*}; n=${o##*:}; w=$(printf %s "$c" | cut -c1-"$n"); r=$(rv "$TP" "$w")   # at its length: warned command(s) only
    case "$r" in ''|ambiguous|unknown|'?'*) e="$e $w=${r:-missing}" ;; *) for x in $(printf %s "$r" | tr '|' ' '); do case " $LT " in *" $x:"*) ;; *) e="$e $w=$r" ;; esac; done ;; esac
    [ "$n" -le 1 ] || { w=$(printf %s "$c" | cut -c1-$((n - 1))); r=$(rv "$TP" "$w")   # one shorter: ambiguous with another, unknown, or not a warned one
      case "$r" in ambiguous|unknown) ;; ''|*'|'*|'?'*) e="$e $w=${r:-missing}" ;; *) case " $LT " in *" $r:"*) e="$e $w=$r" ;; esac ;; esac; }
  done
  [ -z "$e" ] && ok "R8-6: each length in launch.sh's tmux table is the shortest prefix this tmux runs only as warned commands (new: new-session's alias; one shorter: ambiguous with another command, or unknown)" || bad "R8-6: launch.sh's tmux table vs this tmux:$e"
  LA=$(sed -n 's/^ *case "\$t" in \(neww|[^)]*\)) v=\$t ;; esac ;;$/\1/p' "$RS_HOME/remote/launch.sh"); e=""; [ -n "$LA" ] || e=" (launch.sh's alias list not found)"
  for w in $(printf %s "$LA" | tr '|' ' '); do r=$(rv "$TA" "$w"); case " $LT " in *" $r:"*) ;; *) [ "$w:$r" = popup:unknown ] || e="$e $w=${r:-missing}" ;; esac; done
  [ -z "$e" ] && ok "R8-6: each alias in launch.sh's tmux list is one this tmux runs as a warned command" || bad "R8-6: launch.sh's tmux aliases vs this tmux:$e"
else echo "  SKIP: no tmux here: the tmux fact is not reproduced (run envdrop.sh on a box)"; fi
TB=$T/tbin; mkdir -p "$TB"   # envdrop.sh's tmux plumbing on a stub: an older tmux's usage line, the ambiguous / unknown lines, anything else
printf '%s\n' '#!/usr/bin/env bash' '[ "$1" != -V ] || { echo "tmux 2.9-stub"; exit 0; }' 'while [ "$#" -gt 0 ]; do case "$1" in -S|-f) shift 2 ;; *) break ;; esac; done' \
  'case "$1" in kill-server) exit 0 ;; new-session|split) eval "c=\${$#}"; case "$c" in *probe*) setsid sh -c "$c" </dev/null >/dev/null 2>&1 & ;; esac; exit 0 ;; esac' \
  '[ "${2:-}" = "-~" ] || exit 1' \
  'case "$1" in sp|splitp) echo "usage: split-window [-bdhvP] [-c start-directory] [shell-command]" ;; resp) echo "ambiguous command: resp, could be: respawn-pane, respawn-window" ;;' \
  '  s) echo "ambiguous command: s, could be: send-keys, set-option" ;; display-po) echo "unknown command: display-po" ;; *) echo "server exited unexpectedly" ;; esac; exit 1' > "$TB/tmux"; chmod +x "$TB/tmux"
O=$(PATH="$TB:$PATH" bash "$EG" tmux 2>&1); RC=$?; L2=$(printf '%s\n' "$O" | sed -n '2p')
[ "$RC" = 0 ] && has "$L2" '^tmux_split_prefix_env=5 (want unset) tmux_prefix=sp:split-window,ru:?(server_exited_unexpectedly),' "envdrop.sh: the tmux R8-6 line on a stub (plumbing): an older tmux's usage line names the command; any other reply is ?(…), never a guess" \
  || { bad "envdrop.sh: tmux stub (rc=$RC)"; printf '%s\n' "$O" | head -3 | sed 's/^/    | /'; }
has "$L2" ',resp:respawn-pane|respawn-window,' "...ambiguous among the warned commands only: their names"; has "$L2" ',s:ambiguous,' "...ambiguous with another: ambiguous"
has "$L2" ',display-po:unknown,' "...unknown command: unknown"; has "$L2" ' tmux_alias=neww:?(server_exited_unexpectedly),.*,splitp:split-window,' "...the alias list asked the same way"
if command -v setpriv >/dev/null 2>&1; then O=$(bash "$EG" setpriv 2>&1)
  has "$O" '^setpriv_version=[^ ]* setpriv_reset_env=unset (want unset) setpriv_reset_prefix=unset (want unset)$' "fact (this machine's setpriv): --reset-env, and its prefix --res, clear CUDA_VISIBLE_DEVICES"
else echo "  SKIP: no setpriv here: the setpriv fact is not reproduced (run envdrop.sh on a box)"; fi
SB=$T/edbin; mkdir -p "$SB"   # a screen that detaches with setsid (environment kept), a systemd-run that starts its unit with none
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in -v) echo "Screen version 0.0-stub"; exit 1 ;; -dmS) shift 2; setsid "$@" </dev/null >/dev/null 2>&1 & exit 0 ;; -S) exit 0 ;; esac; exit 1' > "$SB/screen"
printf '%s\n' '#!/usr/bin/env bash' 'while [ "$#" -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done; exec env -i PATH=/usr/bin:/bin "$@"' > "$SB/systemd-run"; chmod +x "$SB"/*
O=$(PATH="$SB:$PATH" bash "$EG" screen systemd-run 2>&1); RC=$?
[ "$RC" = 0 ] && has "$O" '^screen_version=Screen_version_0.0-stub screen_dm_env=5 screen_session=other (want other)$' "envdrop.sh: the screen line (plumbing, on a stub)" || { bad "envdrop.sh on stubs (rc=$RC)"; printf '%s\n' "$O" | head -3 | sed 's/^/    | /'; }
has "$O" '^systemd_run_env=unset (want unset)$' "envdrop.sh: the systemd-run line (plumbing, on a stub)"
MB=$T/edmin; mkdir -p "$MB"; for c in bash sh env mktemp ps tr cat sleep rm mv chmod head mkdir timeout; do p=$(command -v "$c") && ln -s "$p" "$MB/$c"; done
O=$(PATH=$MB bash "$EG" tmux screen setpriv systemd-run 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$O" | tr '\n' ' ')" = "tmux=absent screen=absent setpriv=absent systemd-run=absent " ] && ok "envdrop.sh: a tool that is not installed: <tool>=absent, never a guess" || bad "envdrop.sh: absent tools (rc=$RC: $O)"
O=$(bash "$EG" sudo 2>&1); [ "$?" = 2 ] && has "$O" "^vgate=fail unknown check 'sudo'" "envdrop.sh: an unknown check: vgate=fail, exit 2 (sudo is never run)" || bad "envdrop.sh: unknown check"
