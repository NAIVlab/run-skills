# Target profile (slurm kind): POSIX data only, sourced locally (run-sync, install, tests) AND on the cluster
# (env.sh, submit.sh). Copy to ~/.config/run-skills/targets/<name>/profile.sh and fill in; <name> is the target
# name and its conf tag (my-hpc -> MYHPC_REMOTE_DIR in .hpc.conf). Paths single-quoted; only $HOME/$USER expand.
T_KIND=slurm
T_HOST=mycluster                 # ssh alias; ~/.ssh/config owns user/ProxyJump/keys
T_XFER_HOST=''                   # ssh alias of the site's data-transfer node, if copies must go there ('' = the ssh host)
T_DESC='My University cluster — gpu partition, 4x A100 per node'   # one line, no < >
T_TRIGGERS='mycluster'           # verbatim words that route a request here (merged into the skill description)
T_GPUS='4x A100 80GB per node'
T_CUDA_ARCH='8.0'                # exported as RS_CUDA_ARCH for hooks (may be empty)
T_SUFFIX=''                      # '' or '-<tag>': tags the venv + compiled caches when targets share a filesystem
T_CONDA_INIT='source $HOME/miniconda3/etc/profile.d/conda.sh'   # ENV_KIND=conda only (a shared lab install works too)
T_CUDA_HOME=''                   # '' = unset any inherited CUDA_HOME (wheels bundle CUDA)
T_ENV_ROOT=''                    # '' = $PROJ; e.g. '$HOME/.run-skills' when the project fs is slow on small files
T_TMPDIR=project                 # project ($PROJ/tmp) | inherit (the job's $TMPDIR, else /tmp/$USER/run-skills)
T_COMPILE_CACHE=project          # project | tmp | '<path>'  (triton/torch_ext/inductor/vllm/flashinfer/nv)
T_REMOTE_DIR_REQUIRED=0          # 1 = <TAG>_REMOTE_DIR mandatory (no filesystem shared with other targets)
T_CONF_KEYS=''                   # extra <TAG>_-prefixable conf keys that policy.sh reads, e.g. 'GPU_ACCOUNT'
T_DEFAULT_PARTITION=gpu
T_DEFAULT_GPU_TYPE=any           # gres type name, or 'any' (count-only availability check)
T_MAXTIME=7-00:00:00             # cluster-wide walltime cap; policy.sh lowers it per partition (P_MAXTIME)
T_FORBIDDEN_QOS=''               # QOS names rejected when found in SBATCH_EXTRA
T_PARTITIONS='gpu cpu'           # listed in error messages/docs; policy.sh is the authority
T_WATCH_RECOVER=1                # 0 = run-watch never resubmits here (reports needs-ok); 1 = within a table's approved budget
