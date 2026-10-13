#!/usr/bin/env bash
# tests/85-probe.sh — phase A: bin/run-probe (the INSTALL.md discovery helper). hosts: Include followed, patterns
# and code hosts skipped, placeholders and registered targets flagged; <alias>: the remote script runs (stub ssh
# executes it locally against stub sinfo/sacctmgr/nvidia-smi) and stays read-only; wandb: never prints the key,
# imports from ~/.netrc only into an empty slot, mode 600.   bash tests/85-probe.sh
set -u
. "$RS_HOME/tests/lib.sh"
P=$RS_HOME/bin/run-probe
mkdir -p "$T/pbin" "$T/remote-slurm" "$T/remote-ws" "$T/home/.ssh/conf.d"
cat > "$T/pbin/ssh" <<'EOS'
#!/usr/bin/env bash
# stub ssh: -G answers from the alias name; anything else runs the piped script locally (bash -s) on a stub PATH
G=""; while [ "$#" -gt 0 ]; do case "$1" in -F|-o) shift 2 ;; -G) G=1; shift ;; *) break ;; esac; done
a=$1
if [ -n "$G" ]; then
  case "$a" in gh) printf 'hostname github.com\nuser git\n' ;; ph) printf 'hostname ph.example.org\nuser <user>\n' ;;
    *) printf 'hostname %s.example.org\nuser me\n' "$a" ;; esac; exit 0
fi
[ "$a" = down ] && { echo "ssh: connect to host down port 22: Connection timed out" >&2; exit 255; }
case "$a" in ws*) R=$STUB_WS ;; *) R=$STUB_SLURM ;; esac
PATH="$R:$PATH" exec bash -s
EOS
printf '#!/usr/bin/env bash\ncase "$*" in *--version*) echo "slurm 99.1" ;; *) echo "gpu*|up|2-00:00:00|4|gpu:a100:8|64|512000" ;; esac\n' > "$T/remote-slurm/sinfo"
printf '#!/usr/bin/env bash\ncase "$*" in *assoc*) echo "lab-acct|gpu|normal" ;; *) echo "lab-acct" ;; esac\n' > "$T/remote-slurm/sacctmgr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/remote-slurm/squeue"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/remote-slurm/sbatch"
printf '#!/usr/bin/env bash\ncase "$*" in *compute_cap*) echo 8.6 ;; *compute-apps*) ;; *) echo "0, Fake GPU, 49140 MiB, 999.1" ;; esac\n' > "$T/remote-ws/nvidia-smi"
chmod +x "$T/pbin/ssh" "$T"/remote-*/*
export STUB_SLURM=$T/remote-slurm STUB_WS=$T/remote-ws

echo "-- hosts --"
cat > "$T/home/.ssh/config" <<'EOS'
# Host commented-out
Host fx wsbox   # two aliases on one line
    User me
Host *
    ServerAliveInterval 60
Host !nope
Host=gh
Host ph
Include conf.d/*
Host fx
EOS
printf 'host fromincl\n  Hostname x\n' > "$T/home/.ssh/conf.d/extra"
H=$(PATH="$T/pbin:$PATH" RS_SSH_CONFIG="$T/home/.ssh/config" bash "$P" hosts); rc=$?
[ "$rc" = 0 ] && ok "hosts exits 0" || bad "hosts exits 0 (rc $rc)"
has "$H" '^fx  *fx.example.org  *me  *registered: fx-home' "hosts: alias + hostname + user, registered target flagged"
has "$H" '^wsbox .*registered: ws-box' "hosts: second alias of a Host line"
has "$H" '^fromincl ' "hosts: Include files followed (glob, relative to the ssh dir)"
has "$H" '^gh .*skip: code host' "hosts: 'Host=' form parsed, code host skipped"
has "$H" '^ph .*placeholder user' "hosts: <user> placeholder flagged"
hasnt "$H" '^\*\|^!nope\|^commented' "hosts: patterns, negations and comments are not machines"
[ "$(echo "$H" | grep -c '^fx ')" = 1 ] && ok "hosts: an alias is listed once" || bad "hosts: an alias is listed once"

echo "-- probe <alias> --"
O=$(PATH="$T/pbin:$PATH" bash "$P" cl 2>&1); rc=$?
[ "$rc" = 0 ] && ok "probe exits 0" || bad "probe exits 0 (rc $rc)"
for s in host 'gpu (this node)' tools slurm storage; do has "$O" "^== $s ==" "probe section: $s"; done
has "$O" '^version: slurm 99.1' "probe: slurm version"; has "$O" '^gpu\*|up|2-00:00:00|4|gpu:a100:8|64|512000' "probe: sinfo partition line"
has "$O" '^lab-acct|gpu|normal' "probe: associations"; has "$O" '^default account: lab-acct' "probe: default account"
has "$O" '^sbatch: .*remote-slurm/sbatch' "probe: sbatch located"
O=$(PATH="$T/pbin:$PATH" bash "$P" wsbox 2>&1)
has "$O" '^0, Fake GPU, 49140 MiB' "probe ws: GPU list"; has "$O" '^compute capability: 8.6' "probe ws: compute capability"
has "$O" '^none: no sinfo' "probe ws: no Slurm said so"
O=$(PATH="$T/pbin:$PATH" bash "$P" down 2>&1); rc=$?
[ "$rc" = 4 ] && ok "probe: unreachable host exits 4" || bad "probe: unreachable host exits 4 (rc $rc)"
has "$O" '^UNREACHABLE: .*Connection timed out' "probe: unreachable reason shown"; has "$O" "run 'ssh down'" "probe: interactive login hint"
R=$(sed -n '/^remote_script()/,/^REMOTE$/p' "$P" | grep -v '^ *#' | sed -e 's|[0-9]*>/dev/null||g' -e 's|2>&1||g')
hasnt "$R" 'mkdir\|rm -\|touch \|chmod \|scancel\|sbatch -\|srun \|>' "remote probe script is read-only (no writes, no redirections, no jobs)"
has "$(sed -n '/^probe()/,/^}/p' "$P")" 'BatchMode=yes' "probe never waits on a password prompt (BatchMode)"

echo "-- wandb --"
W=$T/wb; mkdir -p "$W/user" "$W/home"
O=$(HOME="$W/home" RS_USER_DIR="$W/user" bash "$P" wandb)
has "$O" '^key: empty' "wandb: missing file = empty key"; has "$O" '^~/.netrc: no wandb entry' "wandb: no netrc entry"
printf 'machine api.wandb.ai\n  login user\n  password SECRETKEY0123\nmachine other password nope\n' > "$W/home/.netrc"
O=$(HOME="$W/home" RS_USER_DIR="$W/user" bash "$P" wandb --import-netrc); rc=$?
[ "$rc" = 0 ] && ok "wandb --import-netrc exits 0" || bad "wandb --import-netrc exits 0 (rc $rc)"
hasnt "$O" 'SECRETKEY' "wandb: the key is never printed"; has "$O" '^key: set' "wandb: key reported as set"
grep -qx "export WANDB_API_KEY='SECRETKEY0123'" "$W/user/wandb_env" && ok "wandb: key written" || bad "wandb: key written"
[ "$(ls -l "$W/user/wandb_env" | cut -c1-10)" = "-rw-------" ] && ok "wandb: file mode 600" || bad "wandb: file mode 600"
has "$(cat "$W/user/wandb_env")" '^export WANDB_ENTITY=' "wandb: template lines kept"
printf 'machine api.wandb.ai login u password OTHERKEY\n' > "$W/home/.netrc"
HOME="$W/home" RS_USER_DIR="$W/user" bash "$P" wandb --import-netrc >/dev/null 2>&1 && bad "wandb: never overwrites a set key" || ok "wandb: never overwrites a set key"
grep -q OTHERKEY "$W/user/wandb_env" && bad "wandb: old key kept" || ok "wandb: old key kept"
O=$(HOME="$W/home" RS_USER_DIR="$W/user" bash "$P" wandb); hasnt "$O" 'SECRETKEY\|OTHERKEY' "wandb status never prints a key"

echo "-- usage --"
bash "$P" >/dev/null 2>&1; [ "$?" = 2 ] && ok "no arguments = usage, exit 2" || bad "no arguments = usage, exit 2"
bash "$P" wandb --bogus >/dev/null 2>&1; [ "$?" = 2 ] && ok "bad wandb flag = usage, exit 2" || bad "bad wandb flag = usage, exit 2"
echo "RESULT: $PASS pass, $FAIL fail"
