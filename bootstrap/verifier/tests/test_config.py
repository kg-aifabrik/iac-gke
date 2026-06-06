"""Tests for environment-driven configuration loading."""

from __future__ import annotations

import pytest

from setup_doctor.config import ENV_PREFIX, Config, ConfigError

_REQUIRED_ENV = {
    "PROJECT_NUMBER": "123456789012",
    "POOL_ID": "github",
    "PROVIDER_ID": "iac-gke",
    "SERVICE_ACCOUNT": "auto@example.iam.gserviceaccount.com",
    "REPOSITORY_ID": "1260827836",
    "REF": "refs/heads/main",
}


def _set_env(monkeypatch: pytest.MonkeyPatch, values: dict[str, str]) -> None:
    for key, value in values.items():
        monkeypatch.setenv(ENV_PREFIX + key, value)


def test_from_env_builds_config(monkeypatch):
    _set_env(monkeypatch, _REQUIRED_ENV)
    monkeypatch.setenv(ENV_PREFIX + "EXPECTED_ROLES", "roles/a, roles/b")
    config = Config.from_env()
    assert config.project_number == "123456789012"
    assert config.expected_repository_id == "1260827836"
    assert config.expected_roles == frozenset({"roles/a", "roles/b"})


def test_from_env_missing_required_raises(monkeypatch):
    partial = dict(_REQUIRED_ENV)
    del partial["REPOSITORY_ID"]
    _set_env(monkeypatch, partial)
    with pytest.raises(ConfigError) as exc:
        Config.from_env()
    assert "REPOSITORY_ID" in str(exc.value)


def test_project_ref_prefers_project_id(monkeypatch):
    _set_env(monkeypatch, _REQUIRED_ENV)
    monkeypatch.setenv(ENV_PREFIX + "PROJECT_ID", "aifabrik-dev")
    config = Config.from_env()
    assert config.project_ref == "projects/aifabrik-dev"


def test_project_ref_falls_back_to_number(monkeypatch):
    _set_env(monkeypatch, _REQUIRED_ENV)
    config = Config.from_env()
    assert config.project_ref == "projects/123456789012"


def test_cluster_mode_off_by_default(monkeypatch):
    # Without a region, the keyless-only run leaves cluster checks disabled.
    _set_env(monkeypatch, _REQUIRED_ENV)
    config = Config.from_env()
    assert config.region == ""
    assert config.cluster_checks_enabled is False


def test_cluster_mode_enabled_by_region(monkeypatch):
    _set_env(monkeypatch, _REQUIRED_ENV)
    monkeypatch.setenv(ENV_PREFIX + "REGION", "us-central1")
    monkeypatch.setenv(
        ENV_PREFIX + "NODE_SERVICE_ACCOUNT", "gke-node@example.iam.gserviceaccount.com"
    )
    config = Config.from_env()
    assert config.cluster_checks_enabled is True
    assert config.node_service_account_email == "gke-node@example.iam.gserviceaccount.com"
    # Service-agent members are derived from the project number.
    assert config.gke_service_agent_member == (
        "serviceAccount:service-123456789012@container-engine-robot.iam.gserviceaccount.com"
    )
    assert config.compute_service_agent_member == (
        "serviceAccount:service-123456789012@compute-system.iam.gserviceaccount.com"
    )
    assert config.kms_crypto_key_resource == (
        "projects/123456789012/locations/us-central1/keyRings/gke-us-central1/cryptoKeys/cluster"
    )


def test_node_sa_roles_default_when_unset(monkeypatch):
    _set_env(monkeypatch, _REQUIRED_ENV)
    config = Config.from_env()
    assert config.expected_node_sa_roles == frozenset({"roles/container.defaultNodeServiceAccount"})
