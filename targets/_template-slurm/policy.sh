# Target policy (slurm kind): bash, sourced ONLY by submit.sh on the login node — after profile.sh, before the
# user's policy.local.sh. Two hooks:
#  t_partition NAME  (required) sets per-partition limits; submit.sh resets every P_* to '' before calling it:
#     P_GPUS=min-max  P_CPU_PER_GPU=N  P_MEM_PER_GPU=G (numeric GB)  P_GTYPE=<gres type, forced>
#     P_GTYPE_DEFAULT=<gres type used when -G was not given>  P_PREEMPT=1  P_MAXTIME=D-HH:MM:SS
#     P_CPU_ONLY=1 (no gres; -c defaults 8, -m 4G per cpu)  P_NOTE='printed before submitting'
#     It may append sbatch flags (SB_ARGS+=(--nodelist=n1)) and must `return 1` for an unknown partition.
#  t_policy          (optional) runs right after arg parsing, before t_partition, limits, MaxTime and sinfo.
#     Reads PART PART_FROM_CLI NGPU GTYPE GTYPE_FROM_CLI TIME FORCE ACK T_FLAGS SB_ARGS SB_EXTRA NAME PROJ CLUSTER TAG;
#     may rewrite SB_ARGS/PART/GTYPE or exit — its exit code propagates verbatim (use 3 for a policy refusal).
#     Must end with `return 0`: its status is the verdict, so a trailing failed `&&` test would abort the submit.
#     ACK=1 when an unknown --*-user-asked flag was passed; other unknown --flags are collected in T_FLAGS.
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
t_policy() { :; }   # nothing gated by default; kept so an overlay can always wrap t_policy_shipped
