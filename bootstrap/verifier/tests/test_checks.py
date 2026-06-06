"""Behavior tests for the setup-doctor checks.

Each test is named after the behavior it proves and exercises one check with
injected fakes (see ``conftest.py``). These tests double as the executable
specification of the keyless-access setup contract.
"""

from __future__ import annotations

import dataclasses

from conftest import FakeIam, FakeResourceManager, FakeServiceUsage, http_error
from setup_doctor import checks
from setup_doctor.models import Status

# A provider object whose attribute condition correctly pins both repo and ref.
GOOD_PROVIDER = {
    "state": "ACTIVE",
    "oidc": {"issuerUri": "https://token.actions.githubusercontent.com"},
    "attributeCondition": (
        "assertion.repository_id == '1260827836' && assertion.ref == 'refs/heads/main'"
    ),
}
GOOD_POOL = {"state": "ACTIVE"}


# --- active identity -------------------------------------------------------


def test_active_identity_matches_expected_passes(config):
    result = checks.check_active_identity(config.expected_identity_email, config)
    assert result.status is Status.PASS


def test_active_identity_mismatch_fails(config):
    result = checks.check_active_identity("intruder@evil.iam.gserviceaccount.com", config)
    assert result.status is Status.FAIL
    assert "expected" in result.detail


def test_active_identity_local_run_is_informational(config):
    # No expected identity (local operator run) -> report, don't assert.
    local_config = dataclasses.replace(config, expected_identity_email="")
    result = checks.check_active_identity("operator@example.com", local_config)
    assert result.status is Status.PASS


def test_active_identity_unknown_fails(config):
    result = checks.check_active_identity("", config)
    assert result.status is Status.FAIL


# --- required APIs ---------------------------------------------------------


def test_required_apis_all_enabled_passes(config):
    result = checks.check_required_apis_enabled(FakeServiceUsage(), config)
    assert result.status is Status.PASS


def test_required_apis_missing_one_fails(config):
    su = FakeServiceUsage(states={"sts.googleapis.com": "DISABLED"})
    result = checks.check_required_apis_enabled(su, config)
    assert result.status is Status.FAIL
    assert "sts.googleapis.com" in result.detail


def test_required_apis_permission_error_fails(config):
    su = FakeServiceUsage(error=http_error(403))
    result = checks.check_required_apis_enabled(su, config)
    # The automation identity is expected to be able to read service state, so
    # a 403 here is a real misconfiguration, not a skip.
    assert result.status is Status.FAIL


# --- WIF provider ----------------------------------------------------------


def test_wif_provider_scoped_to_repo_and_ref_passes(config):
    iam = FakeIam(pool=GOOD_POOL, provider=GOOD_PROVIDER)
    result = checks.check_wif_provider(iam, config)
    assert result.status is Status.PASS


def test_wif_provider_missing_repository_id_fails(config):
    provider = dict(GOOD_PROVIDER, attributeCondition="assertion.ref == 'refs/heads/main'")
    iam = FakeIam(pool=GOOD_POOL, provider=provider)
    result = checks.check_wif_provider(iam, config)
    assert result.status is Status.FAIL
    assert "repository_id" in result.detail


def test_wif_provider_missing_ref_fails(config):
    provider = dict(GOOD_PROVIDER, attributeCondition="assertion.repository_id == '1260827836'")
    iam = FakeIam(pool=GOOD_POOL, provider=provider)
    result = checks.check_wif_provider(iam, config)
    assert result.status is Status.FAIL
    assert "ref" in result.detail


def test_wif_provider_wrong_issuer_fails(config):
    provider = dict(GOOD_PROVIDER, oidc={"issuerUri": "https://evil.example/"})
    iam = FakeIam(pool=GOOD_POOL, provider=provider)
    result = checks.check_wif_provider(iam, config)
    assert result.status is Status.FAIL
    assert "issuer" in result.detail


def test_wif_provider_not_found_fails(config):
    iam = FakeIam(pool_error=http_error(404))
    result = checks.check_wif_provider(iam, config)
    assert result.status is Status.FAIL


def test_wif_provider_permission_denied_skips(config):
    iam = FakeIam(pool_error=http_error(403))
    result = checks.check_wif_provider(iam, config)
    assert result.status is Status.SKIP
    assert result.required is False


# --- service account least privilege --------------------------------------


def _policy_for(sa_email: str, roles: list[str]) -> dict:
    member = f"serviceAccount:{sa_email}"
    return {"bindings": [{"role": role, "members": [member]} for role in roles]}


def test_sa_roles_exact_match_passes(config):
    policy = _policy_for(config.service_account_email, ["roles/serviceusage.serviceUsageViewer"])
    result = checks.check_service_account_roles(FakeResourceManager(policy), FakeIam(), config)
    assert result.status is Status.PASS


def test_sa_roles_extra_role_fails_least_privilege(config):
    policy = _policy_for(
        config.service_account_email,
        ["roles/serviceusage.serviceUsageViewer", "roles/owner"],
    )
    result = checks.check_service_account_roles(FakeResourceManager(policy), FakeIam(), config)
    assert result.status is Status.FAIL
    assert "roles/owner" in result.detail
    assert "over-privileged" in result.detail


def test_sa_roles_missing_role_fails(config):
    policy = _policy_for(config.service_account_email, [])
    result = checks.check_service_account_roles(FakeResourceManager(policy), FakeIam(), config)
    assert result.status is Status.FAIL
    assert "missing" in result.detail


def test_sa_not_found_fails(config):
    iam = FakeIam(sa_error=http_error(404))
    result = checks.check_service_account_roles(FakeResourceManager(), iam, config)
    assert result.status is Status.FAIL


def test_sa_roles_permission_denied_skips(config):
    iam = FakeIam(sa_error=http_error(403))
    result = checks.check_service_account_roles(FakeResourceManager(), iam, config)
    assert result.status is Status.SKIP
    assert result.required is False
