"""Structured logging for setup-doctor.

Emits one JSON object per log line, tagged with a per-run correlation id so a
verifier run can be followed end to end (requirement REL-1). Credentials and
tokens are never logged.
"""

from __future__ import annotations

import json
import logging
import sys
import uuid


class _JsonFormatter(logging.Formatter):
    """Formats log records as single-line JSON including the correlation id."""

    def __init__(self, correlation_id: str) -> None:
        super().__init__()
        self._correlation_id = correlation_id

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "correlation_id": self._correlation_id,
        }
        if record.exc_info:
            # Include the traceback text, never the credential object.
            payload["error"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def configure_logging(level: int = logging.INFO) -> str:
    """Configure root logging to emit JSON to stderr.

    Returns:
        The generated correlation id (also attached to every log line).
    """
    correlation_id = uuid.uuid4().hex
    handler = logging.StreamHandler(stream=sys.stderr)
    handler.setFormatter(_JsonFormatter(correlation_id))
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(level)
    return correlation_id
