"""Run tests/py/test_*.py with unittest and print selftest lines: "  PASS: py <id>" / "  FAIL: py <id>".
Usage: python -I tests/py/run.py <dir holding remote_run>   (no venv, no network; the caller picks the interpreter)"""

import sys
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [sys.argv[1], str(HERE)]


class Lines(unittest.TestResult):
    def addSuccess(self, test):
        super().addSuccess(test)
        print(f"  PASS: py {test.id()}", flush=True)

    def _bad(self, test, err):
        print(f"  FAIL: py {test.id()}", flush=True)
        print(textwrap.indent(self._exc_info_to_string(err, test).rstrip(), "    | "), flush=True)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._bad(test, err)

    def addError(self, test, err):
        super().addError(test, err)
        self._bad(test, err)

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        print(f"  SKIP: py {test.id()}: {reason}", flush=True)


unittest.defaultTestLoader.discover(str(HERE), pattern="test_*.py", top_level_dir=str(HERE)).run(Lines())
