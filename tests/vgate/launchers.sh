#!/usr/bin/env bash
# tests/vgate/launchers.sh — the launcher facts behind launch.sh's launcher WARNING (R5-2 flags, R6-3 configs), read back
# from an INSTALLED deepspeed / accelerate, only with the user's OK. Nothing is launched and no GPU is touched: argument
# parsing and source text only (accelerate's config module is imported with HF_HOME in a scratch dir).
#   bash tests/vgate/launchers.sh <python>      e.g. on a box, with a project venv that has them:
#   ssh <alias> 'bash -s <dir>/.venv/bin/python' < tests/vgate/launchers.sh
# Prints one line per package (or `<pkg>=absent (…)`), and NOT in selftest (tests/88-vgate.sh runs it on fake modules):
#   deepspeed: ds_version= ds_abbrev=<num_gpus from `--num_g 2`> ds_short=<include from `-ilocalhost:1`>
#     ds_alias=<num_gpus from `--num_accelerators 2`> ds_ignores_cvd=<yes: runner.main deletes the VISIBLE_DEVICES variable and
#     says "ignoring it" when --include/--exclude/--num_gpus/--num_nodes are given> ds_hostfile=<its default -H path>:present|absent
#     (present: the runner reads that hostfile and ignores CUDA_VISIBLE_DEVICES even without flags) ds_pool_cvd=<yes: main
#     turns CUDA_VISIBLE_DEVICES into --include only when no hostfile gave it a resource pool>
#   accelerate: acc_version= acc_hyphen=<gpu_ids from `--gpu-ids 0,1`> acc_abbrev=<refused|taken: `--gpu_i 0`>
#     acc_sets_cvd=<yes: accelerate/utils/launch.py assigns CUDA_VISIBLE_DEVICES from gpu_ids> acc_all=<yes: … unless it is
#     "all"> acc_cfg_gpu_ids=<yes: commands/launch.py takes the config's gpu_ids when --gpu_ids is absent>
#     acc_cfg_hyphen=<config_file from `--config-file c.yaml`> acc_cfg_default=<the default config, $HF_HOME/…>
#     acc_cfg_json_only=<the default config's name when only default_config.json is a file there>
# want: ds_abbrev=2 ds_short=localhost:1 ds_alias=2 ds_ignores_cvd=yes ds_pool_cvd=yes | acc_hyphen=0,1 acc_abbrev=refused
#   acc_sets_cvd=yes acc_all=yes acc_cfg_gpu_ids=yes acc_cfg_hyphen=c.yaml acc_cfg_default=$HF_HOME/accelerate/default_config.yaml
#   acc_cfg_json_only=default_config.json
set -u
PY=${1:?usage: bash tests/vgate/launchers.sh <python>}
W=$(mktemp -d) || exit 1; trap 'rm -rf "$W"' EXIT
cd "$W" || exit 1   # an empty cwd: `python -c` puts the cwd first on sys.path
mkdir -p "$W/hf/accelerate" && printf '{}\n' > "$W/hf/accelerate/default_config.json" || exit 1   # only the .json is a file there
C='import inspect, os, re, sys
def tryp(f, a):
    try:
        return f(a)
    except SystemExit:
        return None
try:
    import deepspeed, deepspeed.launcher.runner as r
    a, b, c = tryp(r.parse_args, ["--num_g", "2", "t.py"]), tryp(r.parse_args, ["-ilocalhost:1", "t.py"]), tryp(r.parse_args, ["--num_accelerators", "2", "t.py"])
    s = inspect.getsource(r.main)
    h = getattr(r, "DLTS_HOSTFILE", "")
    print("ds_version=%s ds_abbrev=%s ds_short=%s ds_alias=%s ds_ignores_cvd=%s ds_hostfile=%s:%s ds_pool_cvd=%s" % (getattr(deepspeed, "__version__", "?"),
          a.num_gpus if a else "refused", b.include if b else "refused", c.num_gpus if c else "refused",
          "yes" if "del os.environ[visible_devices_env]" in s and "ignoring it" in s else "no",
          h or "?", "present" if h and os.path.isfile(h) else "absent",
          "yes" if re.search(r"if not resource_pool and len\(", s) else "no"))
except Exception as e:
    print("deepspeed=absent (%s)" % type(e).__name__)
try:
    import accelerate, accelerate.utils.launch as ul, accelerate.commands.launch as cl, accelerate.commands.config.config_args as ca
    from accelerate.commands.launch import launch_command_parser
    q = launch_command_parser()
    a, b, d = tryp(q.parse_args, ["--gpu-ids", "0,1", "t.py"]), tryp(q.parse_args, ["--gpu_i", "0", "t.py"]), tryp(q.parse_args, ["--config-file", "c.yaml", "t.py"])
    s, sl, hf = inspect.getsource(ul), inspect.getsource(cl), os.environ.get("HF_HOME", "")
    rel = lambda p: "$HF_HOME" + str(p)[len(hf):] if hf and str(p).startswith(hf + os.sep) else str(p)
    print("acc_version=%s acc_hyphen=%s acc_abbrev=%s acc_sets_cvd=%s acc_all=%s acc_cfg_gpu_ids=%s acc_cfg_hyphen=%s acc_cfg_default=%s acc_cfg_json_only=%s" % (
          getattr(accelerate, "__version__", "?"), a.gpu_ids if a else "refused", "taken" if b else "refused",
          "yes" if re.search(r"\[.CUDA_VISIBLE_DEVICES.\]\s*=\s*(args\.)?gpu_ids", s) else "no",
          "yes" if re.search(r"gpu_ids\s*!=\s*[\x22\x27]all[\x22\x27]", s) else "no",   # (hex escapes: C is a single-quoted bash string)
          "yes" if re.search(r"args\.gpu_ids\s*=\s*defaults\.gpu_ids", sl) else "no", d.config_file if d else "refused",
          rel(getattr(ca, "default_yaml_config_file", "?")), os.path.basename(str(getattr(ca, "default_config_file", "?")))))
except Exception as e:
    print("accelerate=absent (%s)" % type(e).__name__)'
HF_HOME=$W/hf "$PY" -c "$C" 2>/dev/null </dev/null || { echo "vgate=fail $PY (exit $?)"; exit 1; }
