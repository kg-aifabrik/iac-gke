"""Tests for the CLI runner's handling of credential/impersonation failures."""

from __future__ import annotations

from google.auth import exceptions as auth_exceptions

from setup_doctor import cli
from setup_doctor import clients as clients_mod
from setup_doctor.models import Status


def test_run_checks_reports_auth_failure_as_single_fail(config, monkeypatch):
    # Simulate an impersonation 403 (RefreshError) when resolving identity: the
    # runner must return one clear FAIL, not propagate the exception.
    def boom(_clients: object) -> str:
        raise auth_exceptions.RefreshError("Unable to acquire impersonated credentials")

    monkeypatch.setattr(clients_mod, "resolve_active_identity", boom)

    results = cli.run_checks(clients=object(), config=config)

    assert len(results) == 1
    assert results[0].name == "active-identity"
    assert results[0].status is Status.FAIL
    assert "credentials" in results[0].detail
    assert results[0].remediation  # actionable hint present
