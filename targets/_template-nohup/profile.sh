# Target profile (nohup workstation kind): POSIX data only, sourced locally AND on the box (env.sh).
# Copy to ~/.config/run-skills/targets/<alias>/profile.sh; the dir name is the target name and its conf tag
# (ws-box -> WSBOX_NICE in .ws.conf). Paths single-quoted; only $HOME/$USER expand (on the remote).
T_KIND=nohup
T_HOST=mybox                     # ssh alias; ~/.ssh/config owns user/ProxyJump/keys
T_XFER_HOST=''                   # rare on a box: a separate alias for file copies ('' = T_HOST)
T_DESC='Lab workstation — 4x RTX A6000, no scheduler'   # one line, no < >
T_TRIGGERS='mybox'               # verbatim words that route a request here
T_GPUS='4x RTX A6000 48GB'
T_CUDA_ARCH='8.6'
T_SUFFIX=''
T_CONDA_INIT='source $HOME/miniconda3/etc/profile.d/conda.sh'   # ENV_KIND=conda only
T_CUDA_HOME=''                   # '' = env.sh unsets an inherited CUDA_HOME; set '/usr/local/cuda' if the box's builds need it
T_ENV_ROOT=''                    # '' = $PROJ (WS_REMOTE_DIR is $HOME-relative on workstations)
T_TMPDIR=project                 # workstation /tmp is often tiny: keep tmp in-project
T_COMPILE_CACHE=project
T_REMOTE_DIR_REQUIRED=0
T_CONF_KEYS=''
