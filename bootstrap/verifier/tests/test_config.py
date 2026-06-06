"""Tests for environment-driven configuration loading."""

from __future__ import annotations

import pytest

from setup_doctor.config import ENV_PREFIX, Config, ConfigError

_REQUIRED_ENV = {
    "PROJECT_NUMBER": "152743400949",
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
    assert config.project_number == "152743400949"
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
    assert config.project_ref == "projects/152743400949"
