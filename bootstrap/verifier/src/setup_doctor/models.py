"""Result types shared by every setup-doctor check.

A check is a pure function that inspects one aspect of the keyless-access
setup and returns a ``CheckResult``. Keeping the result type small and
immutable lets the runner aggregate and format results without knowing any
check's internals.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class Status(StrEnum):
    """Outcome of a single check.

    ``PASS`` — the checked condition holds.
    ``FAIL`` — the condition is violated; the setup is wrong and must be fixed.
    ``SKIP`` — the check could not run for the current identity (for example
               the least-privilege automation service account intentionally
               lacks the read permission); this is not a failure.
    """

    PASS = "PASS"
    FAIL = "FAIL"
    SKIP = "SKIP"


@dataclass(frozen=True)
class CheckResult:
    """The outcome of one check.

    Attributes:
        name: Stable, human-readable check identifier.
        status: One of :class:`Status`.
        detail: One-line description of what was observed.
        remediation: Operator-facing hint to fix a ``FAIL`` (empty otherwise).
        required: When ``True``, a ``FAIL`` makes the overall run fail
            (non-zero exit). A ``SKIP`` never fails the run.
    """

    name: str
    status: Status
    detail: str
    remediation: str = ""
    required: bool = True
