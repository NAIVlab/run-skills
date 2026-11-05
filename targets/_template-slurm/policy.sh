# Target policy (slurm kind): bash, sourced ONLY by submit.sh on the login node — after profile.sh, before the
# user's policy.local.sh. Two hooks:
#  t_partition NAME  (required) sets per-partition limits; submit.sh resets every P_* to '' before calling it:
#     P_GPUS=min-max  P_CPU_PER_GPU=N  P_MEM_PER_GPU=G (numeric GB)  P_GTYPE=<gres type, forced>
#     P_GTYPE_DEFAULT=<gres type used when -G was not given>  P_PREEMPT=1  P_MAXTIME=D-HH:MM:SS
#     P_CPU_ONLY=1 (no gres; -c defaults 8, -m P_MEM_PER_CPU GB per cpu, default 4 — keep it <= the partition's
#     MaxMemPerCPU)  P_NOTE='printed before submitting'
#     It may append sbatch flags (SB_ARGS+=(--nodelist=n1)) and must `return 1` for an unknown partition.
#  t_policy          (optional) runs right after arg parsing, before t_partition, limits, MaxTime and sinfo.
#     Reads PART PART_FROM_CLI NGPU GTYPE GTYPE_FROM_CLI TIME FORCE ACK T_FLAGS SB_ARGS SB_EXTRA NAME PROJ CLUSTER TAG PLAN;
#     may rewrite SB_ARGS/PART/GTYPE or exit — its exit code propagates verbatim (use 3 for a policy refusal).
#     Must end with `return 0`: its status is the verdict, so a trailing failed `&&` test would abort the submit.
#     ACK=1 when an unknown --*-user-asked flag was passed; every unknown --flag (that one too) is collected in T_FLAGS, which
#     rsk binds into its plan (flags=): no standing grant covers a plan with one, only the user's approval of the card.
#  The probe: for a plan (PLAN=1, FORCE=1) and an approved submit (--rs-expect) submit.sh first runs `( FORCE=0; t_policy )`
#     in a subshell — as a submit without -y sees it, so a -y gate silent under FORCE=1 still reaches the card — then the real
#     one, and probes t_partition the same way right before its real call, with the PART that is submitted (its `return 1`
#     is an unknown partition, not a gate). So BOTH may run twice and must have no side effects (no files, nothing sent).
#     Inside the probe every `exit 1` is a -y gate that is noted and passed — the function goes on, so a first gate hides none
#     after it, and code after a gate must not assume the gate stopped the run; any other exit code is the verdict.
#  The gate idiom (a rule, not a style): print the WARNING, THEN test FORCE —
#       echo "WARNING: … Re-run -y …" >&2; [ "$FORCE" = 1 ] || exit 1
#     — one WARNING: line, printed with -y too, so a plan (FORCE=1) shows every gate on the card and a -y submit logs it.
#     Never the P2 form `[ "$FORCE" = 1 ] || { echo "WARNING: …" >&2; exit 1; }`: silent under -y, only the probe finds it.
#     A gate that prints no WARNING: line gets a generic one, and all the probe printed (digit runs masked) joins the card's
#     warnings_id. (The probe passes a gate by defining a function named exit; a policy that turns on `set -o posix`, where
#     bash refuses such a function, makes every plan and approved submit fail closed with exit 2.)
# submit.sh runs this code in a subshell after its journal claim: an EXIT trap or fds set here stay there (3/4 are closed).
# An overlay ~/.config/run-skills/targets/<name>/policy.local.sh extends the shipped policy by wrapping t_policy:
#   eval "$(declare -f t_policy | sed '1s/^t_policy/t_policy_shipped/')"
#   t_policy() { [ "$PART" = vip ] && { echo "REFUSED: vip is policy-gated" >&2; exit 3; }; t_policy_shipped; }
t_partition() {
  case "$1" in
    gpu) P_GPUS=1-4 P_CPU_PER_GPU=8 P_MEM_PER_GPU=40 ;;
    cpu) P_CPU_ONLY=1 P_MAXTIME=2-00:00:00 ;;
    *) return 1 ;;
  esac
}
t_policy() {   # nothing gated by default; kept so an overlay can always wrap t_policy_shipped. A -y gate, in the idiom:
  # [ "$PART" != paid ] || { echo "WARNING: '$PART' is charged to the group's account. Re-run -y to submit there." >&2; [ "$FORCE" = 1 ] || exit 1; }
  return 0
}
