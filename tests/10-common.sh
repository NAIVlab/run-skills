#!/usr/bin/env bash
# tests/10-common.sh — phase A: lib/common.sh helpers against the fixture overlay (RS_USER_DIR=$T_A/user):
# rs_tag, discovery (overlay > pack > shipped precedence, extension dirs, _* skipped), ovr precedence, conf loading, remote-dir
# resolution, deploy file list, the conf linter on real-conf shapes, wandb_env lookup, rs_gen_index rows.
# Run by selftest.sh with RS_HOME set:  bash tests/10-common.sh
set -u
. "$RS_HOME/tests/lib.sh"
RH=$RS_HOME   # the real lib; some checks point RS_HOME at a fake targets tree
C() { ( . "$RH/lib/common.sh"; eval "$1" ) 2>&1; }   # snippet with common.sh loaded, in a subshell

echo "-- rs_tag / rs_path --"
has "$(C 'rs_tag box2')" '^BOX2$' "rs_tag box2 -> BOX2"
has "$(C 'rs_tag ws-box')" '^WSBOX$' "rs_tag strips the dash and uppercases"
has "$(C 'rs_tag fx_home-2')" '^FXHOME2$' "rs_tag keeps only alnum"
has "$(HOME=/h USER=u C 'rs_path "\$HOME/x/\${USER}/\$OTHER"')" '^/h/x/u/\$OTHER$' "rs_path expands only HOME/USER"

echo "-- discovery --"
O=$(C 'rs_targets')
has "$O" '^fx-slurm$' "rs_targets lists fx-slurm"; has "$O" '^fx-home$' "rs_targets lists fx-home"
has "$O" '^ws-box$' "rs_targets lists ws-box"; hasnt "$O" '^_template' "rs_targets skips _* dirs"
has "$O" '^fx-packed$' "rs_targets lists a pack's target"
has "$(C 'rs_target_dir fx-packed')" "^$RS_PACKS_DIR/fx-pack/targets/fx-packed$" "a pack target resolves to the pack dir"
[ "$(echo "$O" | sort -u | wc -l)" = "$(echo "$O" | wc -l)" ] && ok "rs_targets is unique" || bad "rs_targets is unique"
# overlay precedence + extension dirs, with a fake RS_HOME so the check is independent of shipped targets
FH=$T/fakehome; OV=$T/ovl
mkdir -p "$FH/targets/dup" "$FH/targets/_template-x" "$OV/targets/dup" "$OV/targets/ext" "$OV/targets/mine"
printf 'T_KIND=slurm\nT_HOST=shipped\n' > "$FH/targets/dup/profile.sh"; : > "$FH/targets/_template-x/profile.sh"
printf 'T_KIND=slurm\nT_HOST=overlay\n' > "$OV/targets/dup/profile.sh"
printf 'T_KIND=nohup\nT_HOST=box\n' > "$OV/targets/mine/profile.sh"; : > "$OV/targets/ext/policy.local.sh"
O=$(RS_HOME=$FH RS_USER_DIR=$OV C 'rs_targets')
has "$O" '^dup$' "shipped+overlay target listed once"; [ "$(echo "$O" | grep -c '^dup$')" = 1 ] && ok "dup not duplicated" || bad "dup not duplicated"
has "$O" '^mine$' "overlay-only target listed"; hasnt "$O" '^ext$' "extension dir (no profile.sh) is not a target"
hasnt "$O" '_template' "fake _template skipped"
has "$(RS_HOME=$FH RS_USER_DIR=$OV C 'rs_target_dir dup')" "^$OV/targets/dup$" "overlay profile.sh wins"
has "$(RS_HOME=$FH RS_USER_DIR=$OV C 'rs_load_target dup; echo host=$T_HOST tag=$T_TAG dir=$T_DIR local=$T_LOCAL_DIR')" \
  "host=overlay tag=DUP dir=$OV/targets/dup local=$OV/targets/dup" "rs_load_target uses the overlay copy"
has "$(RS_HOME=$FH RS_USER_DIR=$OV C 'rs_target_local_dir ext')" "^$OV/targets/ext$" "rs_target_local_dir finds an extension dir"
# packs sit between the overlay and the shipped tree
PD=$T/packs; mkdir -p "$PD/a/targets/dup" "$PD/a/targets/packonly" "$PD/b/targets/packonly" "$FH/targets/shiponly" "$PD/c/targets/shiponly"
printf 'T_KIND=slurm\nT_HOST=pack\n' > "$PD/a/targets/dup/profile.sh"
printf 'T_KIND=slurm\nT_HOST=packa\n' > "$PD/a/targets/packonly/profile.sh"; printf 'T_KIND=slurm\nT_HOST=packb\n' > "$PD/b/targets/packonly/profile.sh"
printf 'T_KIND=slurm\nT_HOST=shipped\n' > "$FH/targets/shiponly/profile.sh"; printf 'T_KIND=slurm\nT_HOST=pack\n' > "$PD/c/targets/shiponly/profile.sh"
PC() { RS_HOME=$FH RS_USER_DIR=$OV RS_PACKS_DIR=$PD C "$1"; }
has "$(PC 'rs_target_dir dup')" "^$OV/targets/dup$" "overlay beats a pack"
has "$(PC 'rs_target_dir shiponly')" "^$PD/c/targets/shiponly$" "a pack beats the shipped tree"
has "$(PC 'rs_target_dir packonly')" "^$PD/a/targets/packonly$" "between packs, the first in glob order wins"
[ "$(PC 'rs_targets' | grep -c '^packonly$')" = 1 ] && ok "a target in two packs is listed once" || bad "a target in two packs is listed once"
has "$(PC 'rs_load_target shiponly; echo host=$T_HOST local=[$T_LOCAL_DIR]')" 'host=pack local=\[\]' "rs_load_target reads the pack profile"
mkdir -p "$OV/targets/shiponly"; : > "$OV/targets/shiponly/policy.local.sh"
has "$(PC 'rs_load_target shiponly; rs_deploy_files')" "^$OV/targets/shiponly/policy.local.sh$" "an overlay dir extends a pack target"
[ -z "$(C 'rs_target_local_dir fx-nope')" ] && ok "rs_target_local_dir empty when absent" || bad "rs_target_local_dir empty when absent"
O=$(C 'rs_target_dir nope'); RC=$?
[ "$RC" = 2 ] && ok "unknown target exits 2" || bad "unknown target exits 2 (got $RC)"
has "$O" "ERROR: unknown target 'nope' (known: .*fx-slurm" "unknown target lists the known ones"
mkdir -p "$OV/targets/badkind" "$OV/targets/nohost"; printf 'T_KIND=bogus\nT_HOST=x\n' > "$OV/targets/badkind/profile.sh"
O=$(RS_HOME=$FH RS_USER_DIR=$OV C 'rs_load_target badkind'); RC=$?
[ "$RC" = 2 ] && has "$O" 'T_KIND must be slurm|nohup' "bad T_KIND rejected" || bad "bad T_KIND rejected (rc=$RC)"
printf 'T_KIND=slurm\n' > "$OV/targets/nohost/profile.sh"
O=$(RS_HOME=$FH RS_USER_DIR=$OV C 'rs_load_target nohost'); RC=$?
[ "$RC" = 2 ] && has "$O" 'T_HOST is empty' "empty T_HOST rejected" || bad "empty T_HOST rejected (rc=$RC)"
O=$(C 'rs_load_target fx-slurm; echo kind=$T_KIND conf=$(rs_conf_file) dep=$(rs_deploy_dir); rs_load_target ws-box; echo kind=$T_KIND conf=$(rs_conf_file) dep=$(rs_deploy_dir) part=${T_DEFAULT_PARTITION:-unset}')
has "$O" 'kind=slurm conf=.hpc.conf dep=.fx-slurm' "slurm: conf + deploy dir"
has "$O" 'kind=nohup conf=.ws.conf dep=.ws part=unset' "nohup: conf + deploy dir; earlier T_* cleared"

echo "-- ovr / rs_load_conf / rs_remote_dir --"
O=$(C 'T_TAG=FXSLURM; FXSLURM_X=tag; X=gen; echo a=$(ovr X) b=$(FXSLURM_X= ovr X) c=$(X= FXSLURM_X= ovr X def) d=$(X= FXSLURM_X= ovr X)')
has "$O" 'a=tag ' "ovr: <TAG>_KEY beats KEY"; has "$O" 'b=gen ' "ovr: KEY when tag empty"
has "$O" 'c=def ' "ovr: DEFAULT when both empty"; has "$O" 'd=$' "ovr: empty without DEFAULT"
mkdir -p "$T/c1"; printf 'REMOTE_DIR=/conf\nFXSLURM_REMOTE_DIR=/tagged\n' > "$T/c1/.hpc.conf"
O=$(cd "$T/c1" && REMOTE_DIR=/stale FXSLURM_REMOTE_DIR=/stale C 'rs_load_target fx-slurm; rs_load_conf REMOTE_DIR; echo r=$(rs_remote_dir)')
has "$O" 'r=/tagged' "rs_load_conf drops stale exports; tagged REMOTE_DIR wins"
O=$(cd "$T/c1" && C 'rs_load_target fx-slurm; rs_load_conf REMOTE_DIR; echo r=$(FXSLURM_REMOTE_DIR= rs_remote_dir)')
has "$O" 'r=/conf' "generic REMOTE_DIR used when no tagged one"
O=$(cd "$T" && C 'rs_load_target fx-slurm; rs_load_conf REMOTE_DIR'); RC=$?
[ "$RC" = 2 ] && has "$O" 'no .hpc.conf in' "missing conf dies with the cd hint" || bad "missing conf dies (rc=$RC)"
printf 'REMOTE_DIR=/a b\n' > "$T/c1/.hpc.conf"
O=$(cd "$T/c1" && C 'rs_load_target fx-slurm; rs_load_conf REMOTE_DIR'); RC=$?
[ "$RC" = 2 ] && has "$O" 'unquoted spaces' "conf that fails to source dies" || bad "conf that fails to source dies (rc=$RC)"
O=$(C 'rs_load_target fx-slurm; REMOTE_DIR=; rs_remote_dir'); RC=$?
[ "$RC" = 2 ] && has "$O" 'never guess it' "slurm: no REMOTE_DIR -> die" || bad "slurm: no REMOTE_DIR -> die (rc=$RC)"
O=$(C 'rs_load_target fx-slurm; T_REMOTE_DIR_REQUIRED=1; REMOTE_DIR=/x; rs_remote_dir'); RC=$?
[ "$RC" = 2 ] && has "$O" 'does not share a filesystem' "T_REMOTE_DIR_REQUIRED=1 without FXSLURM_REMOTE_DIR -> die" || bad "T_REMOTE_DIR_REQUIRED enforced (rc=$RC)"
has "$(C 'rs_load_target fx-slurm; T_REMOTE_DIR_REQUIRED=1; REMOTE_DIR=/x; FXSLURM_REMOTE_DIR=/own; rs_remote_dir')" '^/own$' "T_REMOTE_DIR_REQUIRED=1 with the tagged key -> ok"
has "$(C 'rs_load_target ws-box; WS_REMOTE_DIR=projects/x; WSBOX_REMOTE_DIR=projects/y; rs_remote_dir')" '^projects/y$' "nohup: WSBOX_REMOTE_DIR beats WS_REMOTE_DIR"
has "$(C 'rs_load_target ws-box; WS_REMOTE_DIR=projects/x; rs_remote_dir')" '^projects/x$' "nohup: WS_REMOTE_DIR fallback"
O=$(C 'rs_load_target ws-box; rs_remote_dir'); RC=$?
[ "$RC" = 2 ] && has "$O" 'WS_REMOTE_DIR (or WSBOX_REMOTE_DIR)' "nohup: no remote dir -> die" || bad "nohup: no remote dir -> die (rc=$RC)"

echo "-- rs_deploy_files --"
O=$(C 'rs_load_target fx-slurm; rs_deploy_files')
has "$O" '^/.*/remote/env.sh$' "slurm deploys env.sh (absolute)"; has "$O" '/remote/submit.sh$' "slurm deploys submit.sh"
has "$O" '/remote/job.sbatch$' "slurm deploys job.sbatch"; has "$O" '/remote/bootstrap.sh$' "slurm deploys bootstrap.sh"
has "$O" '/remote/status.sh$' "slurm deploys status.sh"
has "$O" "^$RS_USER_DIR/targets/fx-slurm/policy.sh$" "slurm deploys the target's policy.sh"; hasnt "$O" 'profile.sh' "profile.sh is deployed separately"
O=$(C 'rs_load_target ws-box; rs_deploy_files')
has "$O" '/remote/env.sh$' "nohup deploys env.sh"; has "$O" '/remote/bootstrap.sh$' "nohup deploys bootstrap.sh"
has "$O" '/remote/status.sh$' "nohup deploys status.sh"
hasnt "$O" 'submit.sh\|job.sbatch\|policy' "nohup deploys nothing slurm-ish"
cp -R "$RS_USER_DIR" "$T/user2"; : > "$T/user2/targets/fx-slurm/policy.local.sh"
has "$(RS_USER_DIR=$T/user2 C 'rs_load_target fx-slurm; rs_deploy_files')" "^$T/user2/targets/fx-slurm/policy.local.sh$" "policy.local.sh deployed when present"

echo "-- rs_lint_conf --"
cat > "$T/lint.hpc" <<'EOF'
REMOTE_DIR=/x
DEFAULT_CLUSTER=fx-home
export FXHOME_ENV_KIND=uv
# FXHOME_ENV_KIND=uv
FXHOME_ENV_KIND=uv
FXPACKED_SBATCH_EXTRA="$(echo --qos=high)"
FXHOME_REMOTE_DIR=/y
FXPACKED_ENV_KIND=uv
FXSLURM_DEFAULT_GPUS=2
FXSLURM_ENV_HOOK=hook.sh
FXSLURM_GPU_ACCOUNT=acct
MY_OWN_KEY=1
EOF
O=$(C 'rs_load_target fx-slurm; rs_lint_conf "$T/lint.hpc"; echo rc=$?')
has "$O" 'rc=0' "linter always rc 0"
has "$O" 'WARN: .*lint.hpc:5: FXHOME_ENV_KIND is not honoured (ENV_KIND not prefixable for slurm)' "FXHOME_ENV_KIND warns with file:line"
has "$O" 'FXPACKED_ENV_KIND is not honoured' "a pack target's tag is linted too"
has "$O" 'FXSLURM_ENV_HOOK is not honoured' "<TAG>_ENV_HOOK warns"
has "$O" 'FXSLURM_GPU_ACCOUNT is not honoured' "unknown tagged key warns (no T_CONF_KEYS)"
hasnt "$O" 'FXPACKED_SBATCH_EXTRA' "FXPACKED_SBATCH_EXTRA=\"\$(...)\" never warns"
hasnt "$O" ':1:\|:2:\|:3:\|:4:' "REMOTE_DIR / DEFAULT_CLUSTER / export / comment lines never warn"
hasnt "$O" 'FXHOME_REMOTE_DIR\|FXSLURM_DEFAULT_GPUS\|MY_OWN_KEY' "prefixable and non-target prefixes never warn"
O=$(C 'rs_load_target fx-slurm; T_CONF_KEYS=GPU_ACCOUNT; rs_lint_conf "$T/lint.hpc"')
hasnt "$O" 'GPU_ACCOUNT' "T_CONF_KEYS makes a key prefixable"
cp -R "$RS_USER_DIR" "$T/user3"; mkdir -p "$T/user3/targets/hpc-x"   # a multi-target conf: another target's private key
printf "T_KIND=slurm\nT_HOST=h\nT_CONF_KEYS='GPU_ACCOUNT CPU_ACCOUNT'\n" > "$T/user3/targets/hpc-x/profile.sh"
printf 'REMOTE_DIR=/x\nHPCX_GPU_ACCOUNT=lab\nHPCX_ENV_KIND=uv\n' > "$T/lint.multi"
O=$(RS_USER_DIR=$T/user3 C 'rs_load_target fx-slurm; rs_lint_conf "$T/lint.multi"')
hasnt "$O" 'HPCX_GPU_ACCOUNT' "another target's T_CONF_KEYS key never warns when syncing elsewhere"
has "$O" 'HPCX_ENV_KIND is not honoured' "that target's tag still warns on a generic-only key"
printf 'WS_REMOTE_DIR=projects/x\nWSBOX_ENV_KIND=uv\nWSBOX_NICE=5\nWSBOX_DEFAULT_GPUS=2\nDEFAULT_STATION=ws-box\n' > "$T/lint.ws"
O=$(C 'rs_load_target ws-box; rs_lint_conf "$T/lint.ws"')
has "$O" 'WSBOX_ENV_KIND is not honoured' "<TAG>_ENV_KIND warns (ENV_KIND is generic-only)"
has "$O" 'WSBOX_DEFAULT_GPUS is not honoured (DEFAULT_GPUS not prefixable for nohup)' "slurm-only key under a nohup tag warns"
hasnt "$O" 'WS_REMOTE_DIR\|WSBOX_NICE\|DEFAULT_STATION' "WS_REMOTE_DIR / WSBOX_NICE / DEFAULT_STATION never warn"

echo "-- rs_wandb_env_file / rs_gen_index --"
mkdir -p "$T/w1" "$T/home2"; : > "$T/w1/.wandb_env"
has "$(cd "$T/w1" && HOME=$T/home2 C 'rs_wandb_env_file')" '^\./\.wandb_env$' "project .wandb_env wins"
[ -z "$(cd "$T" && HOME=$T/home2 C 'rs_wandb_env_file')" ] && ok "no wandb_env anywhere -> empty" || bad "no wandb_env anywhere -> empty"
: > "$T/user2/wandb_env"
has "$(cd "$T" && HOME=$T/home2 RS_USER_DIR=$T/user2 C 'rs_wandb_env_file')" "^$T/user2/wandb_env$" "RS_USER_DIR/wandb_env is the second choice"
: > "$T/user2/targets/fx-slurm/reference.local.md"
RS_USER_DIR=$T/user2 C 'rs_gen_index slurm "$T/idx-slurm.md" /root' >/dev/null; I=$(cat "$T/idx-slurm.md")
has "$(head -1 "$T/idx-slurm.md")" '^root: /root$' "index line 1 is root:"
has "$I" '^| target | host | GPUs | default | max time | description | reference |$' "index table header"
has "$I" "^| fx-slurm | fx | 4x fake | gpu / any | 1-00:00:00 | fixture slurm cluster | $T/user2/targets/fx-slurm/reference.md + $T/user2/targets/fx-slurm/reference.local.md |$" "overlay row: absolute reference + reference.local.md"
has "$I" '^| fx-home | fx | - | gpu / any | 1-00:00:00 | ' "row with '-' for missing T_GPUS"
hasnt "$I" 'ws-box' "slurm index has no nohup rows"
has "$I" "^| fx-packed | fxp | - | gpu / any | 1-00:00:00 | fixture pack cluster | $RS_PACKS_DIR/fx-pack/targets/fx-packed/reference.md |$" "pack row: absolute reference"
has "$(sed -n '/^## Routing/,$p' "$T/idx-slurm.md")" '^- fixture pack routing rule$' "a pack's routing/hpc-run.md lands in the Routing section"
C 'rs_gen_index nohup "$T/idx-nohup.md" /root' >/dev/null; I=$(cat "$T/idx-nohup.md")
has "$I" "^| ws-box | wsbox | 4x fake | - | - | fixture workstation | $RS_USER_DIR/targets/ws-box/reference.md |$" "nohup row"
hasnt "$I" 'no workstation registered yet' "no placeholder sentence when a nohup target exists"
RS_USER_DIR=/nonexistent RS_PACKS_DIR=/nonexistent RS_HOME=$FH C 'rs_gen_index nohup "$T/idx-empty.md" /root' >/dev/null
has "$(cat "$T/idx-empty.md")" 'no workstation registered yet: register one with the user (/root/INSTALL.md, Steps 2-6: run-probe, then ~/.config/run-skills/targets/<name>/ from /root/targets/_template-nohup/) or install a target pack' "empty nohup index prints the placeholder sentence"
RS_USER_DIR=/nonexistent RS_PACKS_DIR=/nonexistent RS_HOME=$FH C 'rs_gen_index slurm "$T/idx-empty.md" /root' >/dev/null
hasnt "$(cat "$T/idx-empty.md")" 'registered yet' "slurm index with a target has no placeholder"
mkdir -p "$T/emptyhome/targets"; RS_USER_DIR=/nonexistent RS_PACKS_DIR=/nonexistent RS_HOME=$T/emptyhome C 'rs_gen_index slurm "$T/idx-empty.md" /root' >/dev/null
has "$(cat "$T/idx-empty.md")" 'no cluster registered yet: register one with the user (/root/INSTALL.md.*_template-slurm/) or install a target pack' "empty slurm index prints the placeholder sentence"
