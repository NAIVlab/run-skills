#!/usr/bin/env bash
# tests/46-avail.sh — phase A: bin/run-avail. The ssh stub RUNS the real remote command string under bash, with fake
# sinfo / squeue / nvidia-smi (rows in the real formats) first on PATH: free-GPU counting per partition and gres type
# (usable states, node flags, no idle CPU, planned nodes, commas inside Gres parentheses, MIG types, CPU-only
# partitions hidden), max/node, --type / --min, the workstation free rule, the project column, per-target errors,
# failing queries / [N/A] readings reported as unknown (never free or zero), and the whole-call deadline.
set -u
. "$RS_HOME/tests/lib.sh"
mkdir -p "$T/rbin"
cat > "$T/rbin/sinfo" <<'ROWS'
#!/usr/bin/env bash
[ -n "${AVAIL_BROKEN:-}" ] && { echo "sinfo: error: Unable to contact slurm controller" >&2; exit 1; }
cat <<'END'
n1   gpu       mixed       8/8/0/16    gpu:A100:4(S:0-1)                       gpu:A100:1(IDX:0)
n1   gpu-long  mixed       8/8/0/16    gpu:A100:4(S:0-1)                       gpu:A100:1(IDX:0)
n2   gpu       mixed-      8/8/0/16    gpu:A100:4(S:0,1)                       gpu:A100:2(IDX:0,2)
n3   gpu       allocated   16/0/0/16   gpu:A100:4                              gpu:A100:2(IDX:0-1)
n4   gpu       idle*       0/16/0/16   gpu:A100:4                              gpu:A100:0(IDX:N/A)
n5   gpu       drained     0/16/0/16   gpu:A100:4                              gpu:A100:0(IDX:N/A)
n6   gpu       mixed       4/12/0/16   gpu:a100_3g.20gb:2(S:0),gpu:A100:1(S:1) gpu:a100_3g.20gb:0(IDX:N/A),gpu:A100:1(IDX:0)
n7   cpu       idle        0/32/0/32   (null)                                  (null)
END
ROWS
cat > "$T/rbin/squeue" <<'ROWS'
#!/usr/bin/env bash
[ -n "${AVAIL_BROKEN:-}" ] && exit 1
printf 'R\nR\nPD\nR\n'
ROWS
cat > "$T/rbin/nvidia-smi" <<'ROWS'
#!/usr/bin/env bash
case "$*" in
  *query-gpu=*) if [ -n "${AVAIL_BROKEN:-}" ]; then echo "0, GPU-aaa, NVIDIA RTX A6000, [N/A], [N/A], [N/A]"; exit 0; fi
    printf '%s\n' "0, GPU-aaa, NVIDIA RTX A6000, 9000, 49140, 80" "1, GPU-bbb, NVIDIA RTX A6000, 1, 49140, 0" \
      "2, GPU-ccc, NVIDIA RTX A6000, 2000, 49140, 0" "3, GPU-ddd, NVIDIA RTX A6000, 3, 49140, 50" ;;
  *compute-apps*) echo GPU-aaa ;;
esac
ROWS
cat > "$T/bin/ssh" <<EOS
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do case "\$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
h=\$1; shift; echo "\$h \$*" >> "$T/avail-ssh.log"
case "\$h" in
  fxp) [ -n "\${AVAIL_SLOW:-}" ] && sleep 20; echo "ssh: connect to host fxp: Connection refused" >&2; exit 255 ;;
esac
PATH="$T/rbin:\$PATH" bash -c "\$*"
EOS
chmod +x "$T/bin/ssh" "$T/rbin/"*
P=$T/ap; mkdir -p "$P"; printf 'REMOTE_DIR=/x\n' > "$P/.hpc.conf"
av() { ( cd "$P" && : > "$T/avail-ssh.log" && PATH="$T/bin:$PATH" bash "$RS_HOME/bin/run-avail" "$@" 2>&1 ); }

echo "-- run-avail: every target, both kinds, one read-only ssh each --"
O=$(av); RC=$?
for t in fx-slurm fx-home ws-box fx-packed; do has "$O" "^$t  " "lists $t (no TARGET needed)"; done
[ "$RC" = 1 ] && ok "exit 1 when a target did not answer (fx-packed)" || bad "exit 1 on a failed target (rc=$RC)"
has "$O" 'ERROR (rc=255: ssh: connect to host fxp' "ssh error shown"
has "$O" 'state unknown, not zero' "a failed probe is never read as zero free GPUs"
hasnt "$(cut -d' ' -f2- "$T/avail-ssh.log")" 'mkdir\|rm \|kill\|sbatch\|scancel\|nohup' "remote commands are read-only"
has "$(cat "$T/avail-ssh.log")" "^fx sinfo -h -N -p 'gpu,forbidden' " "sinfo limited to the profile's T_PARTITIONS"
has "$(cat "$T/avail-ssh.log")" "^fx sinfo -h -N -O " "no T_PARTITIONS (fx-home): every partition"

echo "-- slurm counting (RunFleet's rule) --"
S=$(echo "$O" | sed -n '/^fx-slurm /,/^[a-z]/p')
has "$S" '^  gpu  7/23 free$' "partition total: free 7 of 23 (A100 5 + 3g 2)"
has "$S" '^    A100  *5/21  *max/node 3  (2 planned)$' "A100: n1 3 + n2 2 (planned); allocated-no-idle-cpu, idle*, drained count 0"
has "$S" '^    a100_3g.20gb  *2/2  *max/node 2$' "MIG type kept apart; commas inside Gres parentheses parsed"
has "$S" '^  gpu-long  3/4 free$' "a node in two partitions counts in each"
hasnt "$S" '^  cpu ' "CPU-only partition hidden"
has "$S" '^  mine: PD 1, R 3$' "my running / pending jobs (the real remote squeue | sort | uniq -c)"
has "$S" 'project: set' "project column: this conf resolves a remote dir for the target"

echo "-- workstation: free = no process, < 1 GiB, < 5 % util --"
W=$(echo "$O" | sed -n '/^ws-box /,/^[a-z]/p')
has "$W" '^  1/4 free$' "1 of 4 free"; has "$W" 'GPU1 .*free .*procs 0' "GPU1 free"
has "$W" 'GPU0 .*busy .*procs 1' "GPU0 busy (a process)"; has "$W" 'GPU2 .*busy' "GPU2 busy (2 GB used)"; has "$W" 'GPU3 .*busy' "GPU3 busy (50 % util)"
has "$W" 'project: no .ws.conf here' "project column names the missing conf"

echo "-- filters --"
O=$(av --type 3g fx-slurm)
has "$O" 'a100_3g.20gb' "--type keeps matching gres types"; hasnt "$O" '^    A100 ' "--type drops the others"
O=$(av --min 3 fx-slurm ws-box)
has "$O" '^    A100 ' "--min 3: A100 has 3 free on one node"; hasnt "$O" '3g.20gb' "--min 3: the 3g type (2 per node) is dropped"
hasnt "$O" 'GPU1' "--min 3: the box with 1 free GPU is left out"
O=$(av --min x); [ "$?" = 2 ] && ok "bad --min -> usage, exit 2" || bad "bad --min -> exit 2"
O=$(av nope); [ "$?" = 1 ] && has "$O" "^nope  ERROR: .*unknown target 'nope'" "unknown target reported" || bad "unknown target -> exit 1"

echo "-- a failing query or an unreadable GPU is unknown, never free --"
O=$(AVAIL_BROKEN=1 av fx-slurm ws-box); RC=$?
[ "$RC" = 1 ] && ok "exit 1 when a remote query failed" || bad "exit 1 on a failed query (rc=$RC)"
has "$O" 'ERROR: sinfo failed — free GPUs unknown, not zero' "sinfo failure reported, no partition rows"
has "$O" 'mine: unknown (squeue failed)' "squeue failure is not 'none queued'"
hasnt "$O" '1/1 free' "[N/A] readings never count as free"; has "$O" 'GPU0 .*unknown' "[N/A] reading shown as unknown"

echo "-- one deadline for the whole call --"
s0=$(date +%s); O=$(AVAIL_SLOW=1 av --timeout 2); s1=$(date +%s)
[ $((s1 - s0)) -lt 10 ] && ok "a hung host is cut at the deadline ($((s1 - s0)) s)" || bad "deadline enforced ($((s1 - s0)) s)"
has "$O" 'no answer within 2s' "the hung host is reported"; has "$O" '^  gpu  7/23 free$' "the other targets still answer"
