#!/usr/bin/env bash
# tests/90-py.sh — phase A: the rsk Python package under unittest (tests/py/test_*.py), offline and without a venv:
# an isolated interpreter (RS_PYTHON, else python3; >= 3.11) imports remote_run from the clone's src/ or, in rsk's
# packaged harness, from the package around it. A bash-only harness copy has neither: skipped, and said. RS_SKIP_PY=1 skips.
# A python3 older than 3.11 is a SKIP in a clone (stock macOS / EL9 / Ubuntu 22.04: `bash install.sh` must not fail on
# it) and a FAIL only in rsk's packaged harness (rsk runs on >= 3.11 and passes itself as RS_PYTHON).
set -u
. "$RS_HOME/tests/lib.sh"
PY=${RS_PYTHON:-python3}
if [ -d "$RS_HOME/src/remote_run" ]; then SRC=$RS_HOME/src
elif [ -f "$RS_HOME/../__init__.py" ] && [ -f "$RS_HOME/../cli.py" ]; then SRC=$(cd "$RS_HOME/../.." && pwd)
else SRC=""; fi
if [ -n "$SRC" ] && [ -z "${RS_PY_GATE:-}" ]; then   # the version gate itself, against a fake python 3.10 (no python needed)
  printf '#!/bin/sh\ncase "$1" in -V) echo "Python 3.10.12" ;; *) exit 1 ;; esac\n' > "$T/py310"; chmod +x "$T/py310"
  O=$(RS_PY_GATE=1 RS_SKIP_PY=0 RS_PYTHON="$T/py310" RS_PACKAGED=0 bash "$RS_HOME/tests/90-py.sh" 2>&1)
  has "$O" "^  SKIP: python tests (needs python >= 3.11; '$T/py310' is Python 3.10.12" "python 3.10 in a clone: python tests SKIP"
  hasnt "$O" 'FAIL' "python 3.10 in a clone: no FAIL (install.sh runs the selftest under set -e)"
  O=$(RS_PY_GATE=1 RS_SKIP_PY=0 RS_PYTHON="$T/py310" RS_PACKAGED=1 bash "$RS_HOME/tests/90-py.sh" 2>&1)
  has "$O" '^  FAIL: python >= 3.11 for the rsk tests' "python 3.10 in rsk's packaged harness: FAIL"
fi
if [ "${RS_SKIP_PY:-0}" = 1 ]; then echo "  SKIP: python tests (RS_SKIP_PY=1)"
elif [ -z "$SRC" ]; then echo "  SKIP: python tests ($RS_HOME carries no remote_run package)"
elif ! "$PY" -I -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
  V=$("$PY" -V 2>/dev/null) || V=missing
  if [ "${RS_PACKAGED:-0}" = 1 ]; then bad "python >= 3.11 for the rsk tests: '$PY' is $V (set RS_PYTHON=..., or RS_SKIP_PY=1 to skip)"
  else echo "  SKIP: python tests (needs python >= 3.11; '$PY' is $V — set RS_PYTHON=... to run them)"; fi
else
  O=$(cd "$T" && "$PY" -I "$RS_HOME/tests/py/run.py" "$SRC" 2>&1); echo "$O"
  echo "$O" | grep -q '^  PASS: py ' && ok "python tests ran ($(echo "$O" | grep -c '^  PASS: py ') passed)" || bad "python tests ran"
fi
