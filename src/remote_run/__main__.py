"""`python -m remote_run` = `rsk` (the isolated re-exec in cli.main uses this)."""

import sys

from remote_run.cli import main

sys.exit(main())
