"""Configuration for setup-doctor, loaded from environment variables.

All project-specific values come from the environment so that nothing is
hard-coded and the same code runs unchanged both locally and in GitHub
Actions. The GitHub Actions workflow sources these from repository variables
that the one-time setup runbook writes; an operator sets them in their shell
for a local run.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

ENV_PREFIX = "SETUP_DOCTOR_"

# APIs that must be enabled for keyless automation to function (see the runbook).
DEFAULT_REQUIRED_APIS: tuple[str, ...] = (
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
)

GITHUB_ISSUER_URI = "https://token.actions.githubusercontent.com"

# Maps required environment variable (without prefix) -> Config attribute.
_REQUIRED_VARS: dict[str, str] = {
    "PROJECT_NUMBER": "project_number",
    "POOL_ID": "pool_id",
    "PROVIDER_ID": "provider_id",
    "SERVICE_ACCOUNT": "service_account_email",
    "REPOSITORY_ID": "expected_repository_id",
    "REF": "expected_ref",
}


class ConfigError(ValueError):
    """Raised when required configuration is missing or malformed."""


def _env(name: str, default: str = "") -> str:
    return os.environ.get(ENV_PREFIX + name, default)


@dataclass(frozen=True)
class Config:
    """Resolved verifier configuration.

    Attributes:
        project_number: Numeric GCP project number (used in resource names).
        pool_id: Workload Identity Pool id (for example ``github``).
        provider_id: OIDC provider id (for example ``iac-gke``).
        service_account_email: Automation service account whose roles are audited.
        expected_repository_id: Immutable GitHub ``repository_id`` the provider
            must pin (survives repo rename/transfer).
        expected_ref: Git ref the provider must pin (for example
            ``refs/heads/main``).
        expected_roles: Exact set of project IAM roles the service account must
            hold — no more (over-privilege), no less (under-privilege).
        project_id: Alphanumeric project id; defaults to ``project_number``,
            which Google APIs accept in ``projects/<id-or-number>`` names.
        expected_identity_email: When set (CI), the active identity must equal
            it; when empty (local operator run) the identity check is
            informational.
        issuer_uri: Expected OIDC issuer (defaults to GitHub's).
        required_apis: APIs that must be enabled.
    """

    project_number: str
    pool_id: str
    provider_id: str
    service_account_email: str
    expected_repository_id: str
    expected_ref: str
    expected_roles: frozenset[str]
    project_id: str = ""
    expected_identity_email: str = ""
    issuer_uri: str = GITHUB_ISSUER_URI
    required_apis: tuple[str, ...] = DEFAULT_REQUIRED_APIS

    @property
    def project_ref(self) -> str:
        """``projects/<id-or-number>`` — Google APIs accept either form."""
        return f"projects/{self.project_id or self.project_number}"

    @classmethod
    def from_env(cls) -> Config:
        """Build a :class:`Config` from ``SETUP_DOCTOR_*`` environment variables.

        Returns:
            A populated, immutable Config.

        Raises:
            ConfigError: if any required variable is missing or empty.
        """
        values = {attr: _env(var) for var, attr in _REQUIRED_VARS.items()}
        missing = sorted(var for var, attr in _REQUIRED_VARS.items() if not values[attr])
        if missing:
            raise ConfigError(
                "missing required environment variables: "
                + ", ".join(ENV_PREFIX + name for name in missing)
            )

        roles_raw = _env("EXPECTED_ROLES")
        expected_roles = frozenset(r.strip() for r in roles_raw.split(",") if r.strip())

        return cls(
            project_number=values["project_number"],
            pool_id=values["pool_id"],
            provider_id=values["provider_id"],
            service_account_email=values["service_account_email"],
            expected_repository_id=values["expected_repository_id"],
            expected_ref=values["expected_ref"],
            expected_roles=expected_roles,
            project_id=_env("PROJECT_ID"),
            expected_identity_email=_env("EXPECTED_IDENTITY"),
            issuer_uri=_env("ISSUER_URI", GITHUB_ISSUER_URI),
        )
