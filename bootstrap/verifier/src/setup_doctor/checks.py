"""The setup-doctor checks.

Each check is a pure function: it takes already-built API clients (or
resolved values) plus :class:`Config` and returns a :class:`CheckResult`.
No check performs authentication or decides the process exit code — that is
the runner's job (``cli.py``).

Permission convention: a structural check that reads an operator-only resource
returns ``SKIP`` on HTTP 403, because the least-privilege automation identity
is intentionally not granted that read. A genuinely wrong setup returns
``FAIL``.
"""

from __future__ import annotations

import logging
from typing import Any

from googleapiclient.errors import HttpError

from .config import Config
from .models import CheckResult, Status

logger = logging.getLogger(__name__)


def _http_status(error: HttpError) -> int:
    """Best-effort extraction of the HTTP status code from an HttpError."""
    status = getattr(error, "status_code", None)
    if status:
        return int(status)
    resp = getattr(error, "resp", None)
    return int(getattr(resp, "status", 0) or 0)


def check_active_identity(active_email: str, config: Config) -> CheckResult:
    """The credential resolves to the expected identity.

    In CI (``expected_identity_email`` set) the active identity must equal the
    automation service account. In a local operator run (unset) the identity is
    reported but not asserted.
    """
    name = "active-identity"
    if not active_email:
        return CheckResult(
            name,
            Status.FAIL,
            "could not determine the active identity",
            remediation="ensure Application Default Credentials are available",
        )
    if config.expected_identity_email and active_email != config.expected_identity_email:
        return CheckResult(
            name,
            Status.FAIL,
            f"authenticated as {active_email}, expected {config.expected_identity_email}",
            remediation="check the workflow's service_account input and the "
            "roles/iam.workloadIdentityUser binding on the service account",
        )
    return CheckResult(name, Status.PASS, f"authenticated as {active_email}")


def check_required_apis_enabled(serviceusage: Any, config: Config) -> CheckResult:
    """Every required API is enabled.

    Doubles as the live-connectivity proof: a successful Service Usage call
    means the credential is accepted by a real Google Cloud API end to end.
    """
    name = "required-apis-enabled"
    not_enabled: list[str] = []
    try:
        for api in config.required_apis:
            resource = f"{config.project_ref}/services/{api}"
            service = serviceusage.services().get(name=resource).execute(num_retries=3)
            if service.get("state") != "ENABLED":
                not_enabled.append(api)
    except HttpError as error:
        status = _http_status(error)
        return CheckResult(
            name,
            Status.FAIL,
            f"could not read service state (HTTP {status})",
            remediation=(
                "grant the calling identity roles/serviceusage.serviceUsageViewer on "
                f"{config.project_ref} and ensure the Service Usage API is enabled"
            ),
        )
    if not_enabled:
        return CheckResult(
            name,
            Status.FAIL,
            "APIs not enabled: " + ", ".join(not_enabled),
            remediation="gcloud services enable "
            + " ".join(not_enabled)
            + f" --project={config.project_number}",
        )
    return CheckResult(name, Status.PASS, f"all {len(config.required_apis)} required APIs enabled")


def check_wif_provider(iam: Any, config: Config) -> CheckResult:
    """The WIF pool and OIDC provider exist and the provider is pinned correctly.

    Asserts the provider's issuer is GitHub's and its attribute condition pins
    BOTH the immutable ``repository_id`` and the ``ref`` — the control that
    stops any other repository (or branch) from authenticating. Reading the
    provider is an operator-level permission, so HTTP 403 yields ``SKIP``.
    """
    name = "wif-provider-scoped"
    pool = f"{config.project_ref}/locations/global/workloadIdentityPools/{config.pool_id}"
    provider_name = f"{pool}/providers/{config.provider_id}"
    pools_api = iam.projects().locations().workloadIdentityPools()
    try:
        pool_obj = pools_api.get(name=pool).execute(num_retries=3)
        if pool_obj.get("state") == "DELETED" or pool_obj.get("disabled"):
            return CheckResult(
                name,
                Status.FAIL,
                f"workload identity pool {config.pool_id} is disabled or deleted",
                remediation="re-enable or recreate the pool (see the runbook)",
            )
        provider = pools_api.providers().get(name=provider_name).execute(num_retries=3)
    except HttpError as error:
        status = _http_status(error)
        if status == 403:
            return CheckResult(
                name,
                Status.SKIP,
                "insufficient permission to read the WIF provider; run locally as an operator",
                required=False,
            )
        if status == 404:
            return CheckResult(
                name,
                Status.FAIL,
                "WIF pool or provider not found",
                remediation="create the pool and OIDC provider (see the runbook)",
            )
        return CheckResult(name, Status.FAIL, f"error reading the WIF provider (HTTP {status})")

    if provider.get("state") == "DELETED" or provider.get("disabled"):
        return CheckResult(
            name,
            Status.FAIL,
            f"OIDC provider {config.provider_id} is disabled or deleted",
            remediation="re-enable or recreate the provider (see the runbook)",
        )

    issuer = (provider.get("oidc") or {}).get("issuerUri", "")
    if issuer != config.issuer_uri:
        return CheckResult(
            name,
            Status.FAIL,
            f"provider issuer is {issuer!r}, expected {config.issuer_uri!r}",
            remediation="recreate the provider with the correct --issuer-uri",
        )

    condition = provider.get("attributeCondition") or ""
    missing: list[str] = []
    if config.expected_repository_id not in condition:
        missing.append(f"repository_id == '{config.expected_repository_id}'")
    if config.expected_ref not in condition:
        missing.append(f"ref == '{config.expected_ref}'")
    if missing:
        return CheckResult(
            name,
            Status.FAIL,
            "attribute condition does not pin " + "; ".join(missing),
            remediation="update the provider --attribute-condition to pin the "
            "repository_id and ref (see the runbook)",
        )
    return CheckResult(name, Status.PASS, "provider pinned to the expected repository_id and ref")


def check_service_account_roles(resourcemanager: Any, iam: Any, config: Config) -> CheckResult:
    """The automation service account exists and holds EXACTLY the expected roles.

    Reports both missing roles (under-privileged, automation may break) and
    extra roles (over-privileged — a least-privilege violation, REL-4).
    Reading the project IAM policy is an operator-level permission, so HTTP 403
    yields ``SKIP``.
    """
    name = "service-account-least-privilege"
    sa_resource = f"projects/-/serviceAccounts/{config.service_account_email}"
    member = f"serviceAccount:{config.service_account_email}"
    try:
        iam.projects().serviceAccounts().get(name=sa_resource).execute(num_retries=3)
        policy = (
            resourcemanager.projects()
            .getIamPolicy(
                resource=config.project_ref,
                # Version 3 so conditional bindings are returned, not dropped.
                body={"options": {"requestedPolicyVersion": 3}},
            )
            .execute(num_retries=3)
        )
    except HttpError as error:
        status = _http_status(error)
        if status == 403:
            return CheckResult(
                name,
                Status.SKIP,
                "insufficient permission to read the IAM policy; run locally as an operator",
                required=False,
            )
        if status == 404:
            return CheckResult(
                name,
                Status.FAIL,
                f"service account {config.service_account_email} not found",
                remediation="create the automation service account (see the runbook)",
            )
        return CheckResult(name, Status.FAIL, f"error reading the IAM policy (HTTP {status})")

    actual = {
        binding.get("role", "")
        for binding in policy.get("bindings", [])
        if member in (binding.get("members") or [])
    }
    actual.discard("")
    expected = set(config.expected_roles)
    missing = expected - actual
    extra = actual - expected
    if missing or extra:
        parts: list[str] = []
        if missing:
            parts.append("missing: " + ", ".join(sorted(missing)))
        if extra:
            parts.append("extra (over-privileged): " + ", ".join(sorted(extra)))
        return CheckResult(
            name,
            Status.FAIL,
            "; ".join(parts),
            remediation="align the service account's project roles with the expected "
            "least-privilege set (see the runbook)",
        )
    return CheckResult(
        name, Status.PASS, f"service account holds exactly the expected {len(expected)} role(s)"
    )
