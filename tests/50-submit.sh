#!/usr/bin/env bash
# tests/50-submit.sh — phase A: remote/submit.sh on the fx-slurm fixture with stub sbatch/sinfo (nothing is
# submitted for real): conf defaults -> flags (generic and FXSLURM_ keys), CLI precedence, heuristics, stale-env
# guard, MaxTime cap, partition/-g validation, t_policy exit code + ACK flag, SBATCH_EXTRA scan, payload guard,
# availability warning + -y, the policy.local.sh wrapper idiom. Run by selftest.sh:  bash tests/50-submit.sh
set -u
. "$RS_HOME/tests/lib.sh"
# subo PROJ ARGS... : like sub, but stderr merged (message checks); sbatch.log truncated for nosub
subo() { local p=$1; shift; : > "$T/sbatch.log"; PATH="$T/bin:$PATH" bash "$p/.fx-slurm/submit.sh" "$@" 2>&1; }
rejects() { local rc=$1 l=$2; shift 2; local o; o=$(subo "$@"); local got=$?   # rejects RC LABEL PROJ ARGS...
  [ "$got" = "$rc" ] && ok "$l (exit $rc)" || { bad "$l (exit $rc, got $got)"; echo "$o" | head -5 | sed 's/^/    | /'; }; nosub "$l: nothing submitted"; }

echo "-- conf defaults -> flags --"
P=$(mk_proj fx-slurm 'REMOTE_DIR=/x
ENV_KIND=uv
DEFAULT_GPUS=2
FXSLURM_DEFAULT_CPUS=48
FXSLURM_DEFAULT_MEM=500G
FXSLURM_DEFAULT_TIME=12:00:00
FXSLURM_ACCOUNT=acct
FXSLURM_SBATCH_EXTRA="--qos=high --exclude=n1"
FXSLURM_JOB_NAME=jn
DEFAULT_PARTITION=forbidden') || { bad "mk_proj fx-slurm"; exit 1; }
O=$(sub "$P" fx-slurm -- echo hi); RC=$?
[ "$RC" = 0 ] && ok "submits (rc 0)" || { bad "submits (rc=$RC)"; echo "$O" | sed 's/^/    | /'; }
has "$O" 'ARG:--partition=gpu$' "T_DEFAULT_PARTITION used; generic DEFAULT_PARTITION ignored"
has "$O" 'ARG:--gres=gpu:2$' "DEFAULT_GPUS -> count-only gres (GTYPE any)"
has "$O" 'ARG:--cpus-per-task=48$' "FXSLURM_DEFAULT_CPUS"; has "$O" 'ARG:--mem=500G$' "FXSLURM_DEFAULT_MEM"
has "$O" 'ARG:--time=12:00:00$' "FXSLURM_DEFAULT_TIME"; has "$O" 'ARG:--account=acct$' "FXSLURM_ACCOUNT"
has "$O" 'ARG:--qos=high$' "SBATCH_EXTRA[0]"; has "$O" 'ARG:--exclude=n1$' "SBATCH_EXTRA[1]"; has "$O" 'ARG:--job-name=jn$' "FXSLURM_JOB_NAME"
has "$O" "ARG:--chdir=$P\$" "--chdir=\$PROJ"; has "$O" "ARG:--export=ALL,PROJ=$P,CLUSTER=fx-slurm,TARGET=fx-slurm\$" "--export carries PROJ, CLUSTER and TARGET"
has "$O" 'ARG:--requeue$' "--requeue"; has "$O" "ARG:$P/.fx-slurm/job.sbatch\$" "job.sbatch path"; has "$O" 'ARG:hi$' "payload passed through"
has "$O" 'log: .*/logs/jn_1\.out' "prints the log path (job name + id from 'Submitted batch job N')"
has "$(subo "$P" -- echo hi)" '^+ sbatch .*--partition=gpu .*job\.sbatch echo hi$' "prints the exact sbatch argv line (replaces set -x)"
has "$(subo "$P" -- sh -c 'printf x; exit 0')" 'sh -c printf\\ x\\;\\ exit\\ 0' "argv line keeps argument boundaries (printf %q)"
has "$O" "ARG:--output=$P/logs/%x_%j.out\$" "absolute --output is passed on the CLI"; has "$O" "ARG:--error=$P/logs/%x_%j.out\$" "absolute --error too (stderr stays in the one log)"
LX=$(echo "$O" | grep -n 'ARG:--exclude=n1$' | cut -d: -f1)   # the LAST SBATCH_EXTRA word; every owned option must follow it
for w in '--job-name=jn' "--output=$P/logs/%x_%j.out" "--error=$P/logs/%x_%j.out"; do
  [ "$(echo "$O" | grep -n "ARG:$w\$" | tail -1 | cut -d: -f1)" -gt "$LX" ] && ok "$w comes after the last SBATCH_EXTRA word (last one wins)" || bad "$w comes after the last SBATCH_EXTRA word"
done
[ "$(echo "$O" | grep -c 'ARG:--account')" = 1 ] && ok "exactly one --account" || bad "exactly one --account"
O=$(sub "$P" fx-slurm -p gpu -g 1 -G h100 -c 8 -m 64G -t 4:00:00 -n nm -y -- echo hi)
has "$O" 'ARG:--gres=gpu:h100:1$' "CLI -g/-G beat conf"; has "$O" 'ARG:--cpus-per-task=8$' "CLI -c beats conf"
has "$O" 'ARG:--mem=64G$' "CLI -m beats conf"; has "$O" 'ARG:--time=4:00:00$' "CLI -t beats conf"; has "$O" 'ARG:--job-name=nm$' "CLI -n beats conf"

echo "-- heuristics + stale-env guard --"
P2=$(mk_proj fx-slurm 'REMOTE_DIR=/x
ENV_KIND=uv')
: > "$T/sbatch.log"
O=$(PATH="$T/bin:$PATH" ACCOUNT=stale FXSLURM_ACCOUNT=stale SBATCH_EXTRA="--exclude=badnode" DEFAULT_MEM=999G FXSLURM_DEFAULT_MEM=999G \
    FXSLURM_DEFAULT_PARTITION=forbidden JOB_NAME=stale bash "$P2/.fx-slurm/submit.sh" -g 2 -- echo hi 2>/dev/null)
has "$O" 'ARG:--cpus-per-task=16$' "heuristic cpus (NGPU x P_CPU_PER_GPU)"; has "$O" 'ARG:--mem=80G$' "heuristic mem (stale DEFAULT_MEM ignored)"
hasnt "$O" 'ARG:--account' "stale ACCOUNT ignored"; hasnt "$O" 'badnode' "stale SBATCH_EXTRA ignored"
has "$O" 'ARG:--partition=gpu$' "stale FXSLURM_DEFAULT_PARTITION ignored"; has "$O" "ARG:--job-name=$(basename "$P2")\$" "JOB_NAME defaults to the project basename"
O=$(sub "$P2" fx-slurm -- echo hi)
has "$O" 'ARG:--gres=gpu:1$' "NGPU defaults to 1"; has "$O" 'ARG:--cpus-per-task=8$' "1-GPU cpus"; has "$O" 'ARG:--mem=40G$' "1-GPU mem"
has "$O" 'ARG:--time=1-00:00:00$' "TIME defaults to 1-00:00:00"; hasnt "$O" 'ARG:--account' "no ACCOUNT -> no --account"
P3=$(mk_proj fx-slurm 'REMOTE_DIR=/x
FXSLURM_DEFAULT_PARTITION=forbidden')
rejects 2 "FXSLURM_DEFAULT_PARTITION from the conf is honoured (forbidden is unknown to t_partition)" "$P3" -- echo hi

echo "-- validation --"
O=$(subo "$P2" -t 2-00:00:00 -- echo hi); RC=$?
[ "$RC" = 2 ] && has "$O" "ERROR: -t 2-00:00:00 exceeds 'gpu' MaxTime 1-00:00:00 on fx-slurm" "-t over T_MAXTIME rejected" || bad "-t over cap (rc=$RC)"
nosub "-t over cap: nothing submitted"
O=$(sub "$P2" fx-slurm -t 1-00:00:00 -- echo hi); has "$O" 'ARG:--time=1-00:00:00$' "-t at the cap accepted"
O=$(sub "$P2" fx-slurm -t 24:00:00 -- echo hi); has "$O" 'ARG:--time=24:00:00$' "-t 24:00:00 == cap accepted"
rejects 2 "-t 24:00:01 over cap" "$P2" -t 24:00:01 -- echo hi
O=$(subo "$P2" -p nope -- echo hi); RC=$?
[ "$RC" = 2 ] && has "$O" "ERROR: unknown fx-slurm partition 'nope' (gpu forbidden)" "unknown partition lists T_PARTITIONS" || bad "unknown partition (rc=$RC)"
rejects 2 "-p forbidden (t_partition returns 1) rejected" "$P2" -p forbidden -- echo hi
O=$(subo "$P2" -g 5 -- echo hi); RC=$?
[ "$RC" = 2 ] && has "$O" 'ERROR: gpu -g must be 1..4' "-g above P_GPUS max" || bad "-g above max (rc=$RC)"
rejects 2 "-g 0 below min" "$P2" -g 0 -- echo hi
rejects 2 "no run command" "$P2"; rejects 2 "no run command after --" "$P2" --
O=$(subo "$P2"); has "$O" 'no run command after --' "no-run-command message"
rejects 2 "unknown -x flag" "$P2" -Z -- echo hi
for w in sbatch srun salloc; do rejects 2 "payload '$w' refused" "$P2" -- "$w" job.sh; done
has "$(subo "$P2" -- sbatch job.sh)" 'sbatch/srun/salloc' "payload guard message"
has "$(sub "$P2" fx-slurm -- python train.py --sbatch-style-flag 1)" 'ARG:--sbatch-style-flag$' "payload merely mentioning sbatch is fine"

echo "-- t_policy --"
O=$(subo "$P2" -p vip -g 9 -- echo hi); RC=$?
[ "$RC" = 3 ] && ok "policy refusal exits 3" || bad "policy refusal exits 3 (got $RC)"
has "$O" 'REFUSED: vip is policy-gated' "policy message"; nosub "policy refusal submits nothing"
hasnt "$O" '-g must be\|unknown' "policy runs before partition/-g validation"
rejects 3 "-y does not clear a policy refusal" "$P2" -p vip -y -- echo hi
O=$(sub "$P2" fx-slurm --gpu-user-asked -- echo hi); has "$O" 'ARG:--comment=acked$' "--*-user-asked sets ACK; policy appends to SB_ARGS"
O=$(sub "$P2" fx-slurm --whatever -- echo hi); RC=$?
[ "$RC" = 0 ] && hasnt "$O" 'comment=acked' "other unknown --flags are collected, not ACK" || bad "unknown --flag tolerated (rc=$RC)"
hasnt "$(sub "$P2" fx-slurm -- echo hi)" 'comment=acked' "no ACK -> no --comment"
for x in --partition=gpu --gres=gpu:2 --time=1:00:00 --mem=8G; do rejects 2 "sbatch spelling $x rejected, not swallowed" "$P2" "$x" -- echo hi; done

echo "-- SBATCH_EXTRA scan --"
for x in '--partition=gpu' '-p gpu' '--partition gpu' '--qos=vip' '-q vip' '--qos vip' '--exclude=n1 --qos' '--exclude=n1 -p' \
         '--job-name=x' '-J x' '-Jx' '--output=o.txt' '-oo.txt' '-e err.txt' \
         '--array=0-3' '-a 0-3' '-W' '--wait' '--nodes=1 : --nodes=1' \
         '--arr=1-3' '-vW' '-WW' '-va1-3' '-vk' '-vq high' '-qvip' '--qo=vip' '--qo vip' '--part=gpu' '--ou=o.txt' '--er=e.txt' '--jo=x' '--wai'; do   # + prefixes, bundles (never), attached QOS
  PX=$(mk_proj fx-slurm "REMOTE_DIR=/x
FXSLURM_SBATCH_EXTRA=\"$x\"")
  rejects 2 "SBATCH_EXTRA '$x' rejected" "$PX" -- echo hi
done
PX=$(mk_proj fx-slurm 'REMOTE_DIR=/x
SBATCH_EXTRA="--comment=vip-bench --qos=high"')
O=$(sub "$PX" fx-slurm -- echo hi)
has "$O" 'ARG:--comment=vip-bench$' "non-routing flag mentioning a forbidden qos is fine"; has "$O" 'ARG:--qos=high$' "generic SBATCH_EXTRA used"
PX=$(mk_proj fx-slurm 'REMOTE_DIR=/x
SBATCH_EXTRA="--dependency=singleton --signal=B:USR1@600 --mail-type=END,FAIL"')   # the three spellings conf-keys.md advertises
O=$(sub "$PX" fx-slurm -- echo hi); RC=$?
[ "$RC" = 0 ] && has "$O" 'ARG:--dependency=singleton$' "documented SBATCH_EXTRA: --dependency=singleton accepted (segment chains)" || bad "documented SBATCH_EXTRA accepted (rc=$RC)"
has "$O" 'ARG:--signal=B:USR1@600$' "documented SBATCH_EXTRA: a longer save warning accepted"; has "$O" 'ARG:--mail-type=END,FAIL$' "documented SBATCH_EXTRA: --mail-type accepted"
PX=$(mk_proj fx-slurm 'REMOTE_DIR=/x
SBATCH_EXTRA="-qhigh -D/tmp/Work --wait-all-nodes=0 -koff -v"')   # legitimate spellings the scanner must let through
O=$(sub "$PX" fx-slurm -- echo hi); RC=$?
[ "$RC" = 0 ] && has "$O" 'ARG:-qhigh$' "attached -qNAME with an allowed QOS accepted" || bad "legitimate SBATCH_EXTRA accepted (rc=$RC)"
has "$O" 'ARG:-D/tmp/Work$' "a value containing W is not a --wait"; has "$O" 'ARG:--wait-all-nodes=0$' "--wait-all-nodes is not --wait"
has "$O" 'ARG:-koff$' "-k takes an attached value (not an -o)"; has "$O" 'ARG:-v$' "a lone no-arg short flag is accepted"
PX=$(mk_proj fx-slurm 'REMOTE_DIR=/x
SBATCH_EXTRA="--no-requeue"')
O=$(sub "$PX" fx-slurm -- echo hi)
R1=$(echo "$O" | grep -n 'ARG:--requeue$' | head -1 | cut -d: -f1); R2=$(echo "$O" | grep -n 'ARG:--no-requeue$' | head -1 | cut -d: -f1)
[ -n "$R1" ] && [ -n "$R2" ] && [ "$R2" -gt "$R1" ] && ok "SBATCH_EXTRA --no-requeue lands after the default --requeue (sbatch: last one wins)" \
  || { bad "SBATCH_EXTRA --no-requeue lands after the default --requeue"; echo "$O" | grep 'requeue' | sed 's/^/    | /'; }

echo "-- availability --"
O=$(sub "$P2" fx-slurm -g 4 -- echo hi); RC=$?
[ "$RC" = 0 ] && has "$O" 'ARG:--gres=gpu:4$' "GTYPE any: 4 free of any type -> submits" || bad "any-type availability (rc=$RC)"
stub_sinfo gpu 'nodeA   gpu:h100:4   gpu:h100:3(IDX:0-2)   mixed'
O=$(subo "$P2" -G h100 -g 2 -- echo hi); RC=$?
[ "$RC" = 1 ] && has "$O" "WARNING: only 1 free of 'h100'" "fewer free than -g -> warning, exit 1" || bad "availability warning (rc=$RC)"
has "$O" 'Re-run -y' "warning teaches -y"; nosub "availability warning submits nothing"
O=$(sub "$P2" fx-slurm -G h100 -g 2 -y -- echo hi); has "$O" 'ARG:--gres=gpu:h100:2$' "-y queues past the warning"
O=$(sub "$P2" fx-slurm -G h100 -g 1 -- echo hi); has "$O" 'ARG:--gres=gpu:h100:1$' "enough free -> submits"
rejects 1 "GTYPE any counts gres regardless of type (1 free)" "$P2" -g 2 -- echo hi
stub_sinfo gpu 'nodeA   gpu:h100:4   gpu:h100:0   drain'
rejects 1 "drained nodes do not count as free" "$P2" -G h100 -g 1 -- echo hi
rm -f "$T/sinfo.d/gpu"
stub_fail sinfo
rejects 1 "sinfo failure fails closed" "$P2" -G h100 -g 1 -- echo hi
has "$(sub "$P2" fx-slurm -G h100 -g 1 -y -- echo hi)" 'ARG:--gres=gpu:h100:1$' "-y queues past a failed probe"

echo "-- policy.local.sh wrapper (overlay extension) --"
cp -R "$RS_USER_DIR" "$T/user2"
cat > "$T/user2/targets/fx-slurm/policy.local.sh" <<'EOF'
eval "$(declare -f t_policy | sed '1s/^t_policy/t_policy_shipped/')"
t_policy() { [ "$GTYPE" = banned ] && { echo "REFUSED: banned by policy.local.sh" >&2; exit 3; }; t_policy_shipped; }
EOF
PL=$(RS_USER_DIR=$T/user2 mk_proj fx-slurm 'REMOTE_DIR=/x')
[ -f "$PL/.fx-slurm/policy.local.sh" ] && ok "policy.local.sh deployed next to policy.sh" || bad "policy.local.sh deployed"
O=$(subo "$PL" -G banned -y -- echo hi); RC=$?
[ "$RC" = 3 ] && has "$O" 'REFUSED: banned by policy.local.sh' "local policy refuses" || bad "local policy refuses (rc=$RC)"
nosub "local refusal submits nothing"
has "$(sub "$PL" fx-slurm --gpu-user-asked -y -- echo hi)" 'ARG:--comment=acked$' "wrapped shipped t_policy still runs"
rejects 3 "shipped refusal preserved by the wrapper" "$PL" -p vip -- echo hi
