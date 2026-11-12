"""Exit codes (one meaning each) and the error type every command raises."""

from __future__ import annotations

OK = 0
FAILED = 1         # the command ran on the target and exited non-zero (its own code is printed)
USAGE = 2          # usage, config or a fixable setup problem
REFUSED = 3        # a site policy or a deny (the user's, or another user's job) refused: final
NEEDS_USER = 4     # a decision only the user can make (`needs:` says which)
UNKNOWN = 5        # the outcome or the remote state is unknown / unreachable
CONFLICT = 6       # an existing run, lock, drift or stale deploy blocks the action
LEASE_ENDED = 7    # a watch lease ended while runs were still moving
PLACEMENT = 8      # placement undecided

EXIT_CODES = {
    OK: "ok",
    FAILED: "the remote command ran and failed (its exit code is printed)",
    USAGE: "usage, config or setup problem",
    REFUSED: "refused: a site policy or a deny (final)",
    NEEDS_USER: "needs the user's decision",
    UNKNOWN: "unknown or unreachable",
    CONFLICT: "conflict with existing state",
    LEASE_ENDED: "watch lease ended with runs still moving",
    PLACEMENT: "placement undecided",
}


class RskError(Exception):
    """A failure with a message for the user and an exit code from EXIT_CODES."""

    def __init__(self, message: str, code: int = USAGE) -> None:
        super().__init__(message)
        self.code = code
