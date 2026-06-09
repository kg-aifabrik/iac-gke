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

from .config import CMEK_ROLE, CONNECT_GATEWAY_ROLES, EXTERNAL_GATEWAY_ADDRESS, Config
from .models import CheckResult, Status

logger = logging.getLogger(__name__)


def _http_status(error: HttpError) -> int:
    """Best-effort extraction of the HTTP status code from an HttpError."""
    status = getattr(error, "status_code", None)
    if status:
        return int(status)
    resp = getattr(error, "resp", None)
    return int(getattr(resp, "status", 0) or 0)


def _roles_in_policy(policy: dict[str, Any], member: str) -> set[str]:
    """The set of roles a member holds in an IAM policy (pure, no I/O)."""
    roles = {
        binding.get("role", "")
        for binding in policy.get("bindings", [])
        if member in (binding.get("members") or [])
    }
    roles.discard("")
    return roles


def _find_disabled_apis(serviceusage: Any, project_ref: str, apis: tuple[str, ...]) -> list[str]:
    """Return the subset of ``apis`` not in state ENABLED. May raise HttpError."""
    disabled: list[str] = []
    for api in apis:
        service = (
            serviceusage.services().get(name=f"{project_ref}/services/{api}").execute(num_retries=3)
        )
        if service.get("state") != "ENABLED":
            disabled.append(api)
    return disabled


def _get_project_iam_policy(resourcemanager: Any, project_ref: str) -> dict[str, Any]:
    """Fetch the project IAM policy (v3, so conditional bindings survive). May raise HttpError."""
    result = (
        resourcemanager.projects()
        .getIamPolicy(resource=project_ref, body={"options": {"requestedPolicyVersion": 3}})
        .execute(num_retries=3)
    )
    return dict(result)


def _skip_if_no_cluster_mode(name: str, config: Config) -> CheckResult | None:
    """SKIP a cluster-setup check when no region is configured (keyless-only run)."""
    if not config.cluster_checks_enabled:
        return CheckResult(
            name,
            Status.SKIP,
            "cluster checks not configured (set SETUP_DOCTOR_REGION to enable)",
            required=False,
        )
    return None


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
    try:
        not_enabled = _find_disabled_apis(serviceusage, config.project_ref, config.required_apis)
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
    # Match whitespace-insensitively and on the QUOTED value, so a longer id/ref
    # that merely contains the expected one as a substring cannot satisfy the pin
    # (e.g. '1260827836' must not match a provider pinned to '11260827836').
    compact = condition.replace(" ", "")
    if "||" in compact:
        return CheckResult(
            name,
            Status.FAIL,
            "attribute condition uses '||' (too permissive); the pins must be combined with '&&'",
            remediation="rewrite the provider --attribute-condition to AND the repository_id "
            "and ref pins (see the runbook)",
        )
    repo_clause = f"assertion.repository_id=='{config.expected_repository_id}'"
    ref_clause = f"assertion.ref=='{config.expected_ref}'"
    missing: list[str] = []
    if repo_clause not in compact:
        missing.append(f"repository_id == '{config.expected_repository_id}'")
    if ref_clause not in compact:
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

    actual = _roles_in_policy(policy, member)
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


# --- Cluster-setup checks (run only when a region is configured) ------------


def check_cmek_grants(cloudkms: Any, config: Config) -> CheckResult:
    """Both CMEK grants exist on the cluster encryption key.

    The GKE service agent must hold the encrypter/decrypter role (application-
    layer secret/etcd encryption) AND the Compute service agent must hold it
    (node boot/attached-disk encryption). Missing either breaks the cluster.
    Reading the key IAM policy is an operator-level permission, so HTTP 403
    yields ``SKIP``.
    """
    name = "cmek-grants"
    if skip := _skip_if_no_cluster_mode(name, config):
        return skip
    try:
        policy = (
            cloudkms.projects()
            .locations()
            .keyRings()
            .cryptoKeys()
            .getIamPolicy(resource=config.kms_crypto_key_resource)
            .execute(num_retries=3)
        )
    except HttpError as error:
        status = _http_status(error)
        if status == 403:
            return CheckResult(
                name,
                Status.SKIP,
                "insufficient permission to read the key IAM policy; run locally as an operator",
                required=False,
            )
        if status == 404:
            return CheckResult(
                name,
                Status.FAIL,
                f"cluster encryption key not found ({config.kms_crypto_key_resource})",
                remediation="apply the foundation root to create the KMS key (see the runbook)",
            )
        return CheckResult(name, Status.FAIL, f"error reading the key IAM policy (HTTP {status})")

    missing: list[str] = []
    if CMEK_ROLE not in _roles_in_policy(policy, config.gke_service_agent_member):
        missing.append("GKE service agent (secret/etcd encryption)")
    if CMEK_ROLE not in _roles_in_policy(policy, config.compute_service_agent_member):
        missing.append("Compute service agent (node/disk encryption)")
    if missing:
        return CheckResult(
            name,
            Status.FAIL,
            "missing CMEK grant for: " + "; ".join(missing),
            remediation=f"grant {CMEK_ROLE} to the service agent(s) on the cluster key",
        )
    return CheckResult(name, Status.PASS, "both CMEK grants present (GKE secrets + Compute disks)")


def check_node_sa_roles(resourcemanager: Any, iam: Any, config: Config) -> CheckResult:
    """The node service account exists and holds EXACTLY its expected project roles.

    Image pull (``roles/artifactregistry.reader``) is granted repository-scoped,
    not at the project level, so the project policy should show only the node's
    base role. Extra project roles are an over-privilege violation. Reading the
    IAM policy is operator-level, so HTTP 403 yields ``SKIP``.
    """
    name = "node-sa-least-privilege"
    if skip := _skip_if_no_cluster_mode(name, config):
        return skip
    if not config.node_service_account_email:
        return CheckResult(
            name,
            Status.SKIP,
            "node service account not configured (set SETUP_DOCTOR_NODE_SERVICE_ACCOUNT)",
            required=False,
        )
    sa_resource = f"projects/-/serviceAccounts/{config.node_service_account_email}"
    member = f"serviceAccount:{config.node_service_account_email}"
    try:
        iam.projects().serviceAccounts().get(name=sa_resource).execute(num_retries=3)
        policy = _get_project_iam_policy(resourcemanager, config.project_ref)
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
                f"node service account {config.node_service_account_email} not found",
                remediation="apply the foundation root to create the node service account",
            )
        return CheckResult(name, Status.FAIL, f"error reading the IAM policy (HTTP {status})")

    actual = _roles_in_policy(policy, member)
    expected = set(config.expected_node_sa_roles)
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
            remediation="align the node service account's project roles with the expected set",
        )
    return CheckResult(
        name, Status.PASS, f"node SA holds exactly the expected {len(expected)} role(s)"
    )


def check_connect_gateway_access(resourcemanager: Any, config: Config) -> CheckResult:
    """The automation can reach the cluster over Connect Gateway.

    Verifies the automation service account holds the gateway roles
    (``gkehub.gatewayEditor`` + ``gkehub.viewer``) it needs to apply in-cluster
    resources after a build. (Operator identities are environment-specific and
    not asserted here.) Reading the IAM policy is operator-level → 403 ``SKIP``.
    """
    name = "connect-gateway-access"
    if skip := _skip_if_no_cluster_mode(name, config):
        return skip
    member = f"serviceAccount:{config.service_account_email}"
    try:
        policy = _get_project_iam_policy(resourcemanager, config.project_ref)
    except HttpError as error:
        status = _http_status(error)
        if status == 403:
            return CheckResult(
                name,
                Status.SKIP,
                "insufficient permission to read the IAM policy; run locally as an operator",
                required=False,
            )
        return CheckResult(name, Status.FAIL, f"error reading the IAM policy (HTTP {status})")

    roles = _roles_in_policy(policy, member)
    missing = CONNECT_GATEWAY_ROLES - roles
    if missing:
        return CheckResult(
            name,
            Status.FAIL,
            "automation missing Connect Gateway roles: " + ", ".join(sorted(missing)),
            remediation="apply the access module so the automation gets the gateway roles",
        )
    return CheckResult(name, Status.PASS, "automation has Connect Gateway access")


def check_cluster_apis_enabled(serviceusage: Any, config: Config) -> CheckResult:
    """Every API the cluster and its supply chain need is enabled."""
    name = "cluster-apis-enabled"
    if skip := _skip_if_no_cluster_mode(name, config):
        return skip
    try:
        not_enabled = _find_disabled_apis(
            serviceusage, config.project_ref, config.cluster_required_apis
        )
    except HttpError as error:
        status = _http_status(error)
        return CheckResult(
            name,
            Status.FAIL,
            f"could not read service state (HTTP {status})",
            remediation="grant roles/serviceusage.serviceUsageViewer and enable Service Usage",
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
    return CheckResult(
        name, Status.PASS, f"all {len(config.cluster_required_apis)} cluster APIs enabled"
    )


# --- Ingress-setup checks (cluster mode) ------------------------------------


def check_cas_cas_enabled(privateca: Any, config: Config) -> CheckResult:
    """The CAS root and subordinate certificate authorities exist and are ENABLED.

    Without an enabled subordinate CA, cert-manager cannot issue the internal
    gateway's certificate. Reading CAS is operator-level, so HTTP 403 → SKIP.
    """
    name = "cas-cas-enabled"
    if skip := _skip_if_no_cluster_mode(name, config):
        return skip
    if not config.environment:
        return CheckResult(
            name,
            Status.SKIP,
            "environment not set (SETUP_DOCTOR_ENVIRONMENT)",
            required=False,
        )
    cas_api = privateca.projects().locations().caPools().certificateAuthorities()
    not_enabled: list[str] = []
    try:
        for tier in ("root", "subordinate"):
            ca = cas_api.get(name=config.cas_ca_resource(tier)).execute(num_retries=3)
            if ca.get("state") != "ENABLED":
                not_enabled.append(f"{config.environment}-{tier}")
    except HttpError as error:
        status = _http_status(error)
        if status == 403:
            return CheckResult(
                name,
                Status.SKIP,
                "insufficient permission to read CAS; run locally as an operator",
                required=False,
            )
        if status == 404:
            return CheckResult(
                name,
                Status.FAIL,
                "CAS certificate authority not found",
                remediation="apply the private-ca module (the fop root) to create the CAs",
            )
        return CheckResult(name, Status.FAIL, f"error reading CAS (HTTP {status})")

    if not_enabled:
        return CheckResult(
            name,
            Status.FAIL,
            "CAs not ENABLED: " + ", ".join(not_enabled),
            remediation="enable the certificate authorities in CAS",
        )
    return CheckResult(name, Status.PASS, "root and subordinate CAs are ENABLED")


def check_external_cert_active(certificatemanager: Any, config: Config) -> CheckResult:
    """Every external hostname's managed certificate is ACTIVE (per-host, ADR-0005).

    A non-ACTIVE state almost always means the hostname's DNS records (the
    DNS-authorization CNAME, or the NS delegation when Cloud DNS manages the
    public zone) are not in place or have not propagated. Operator-level read →
    HTTP 403 SKIP.
    """
    name = "external-certs-active"
    if skip := _skip_if_no_cluster_mode(name, config):
        return skip
    if not config.external_hostnames:
        return CheckResult(
            name,
            Status.SKIP,
            "external hostnames not set (SETUP_DOCTOR_EXTERNAL_HOSTNAMES)",
            required=False,
        )
    certs_api = certificatemanager.projects().locations().certificates()
    not_active: list[str] = []
    for hostname in config.external_hostnames:
        try:
            cert = certs_api.get(name=config.external_certificate_resource(hostname)).execute(
                num_retries=3
            )
        except HttpError as error:
            status = _http_status(error)
            if status == 403:
                return CheckResult(
                    name,
                    Status.SKIP,
                    "insufficient permission to read Certificate Manager; "
                    "run locally as an operator",
                    required=False,
                )
            if status == 404:
                return CheckResult(
                    name,
                    Status.FAIL,
                    f"managed certificate for {hostname} not found",
                    remediation="apply the fop root to create the per-hostname certificates",
                )
            return CheckResult(name, Status.FAIL, f"error reading certificates (HTTP {status})")
        state = (cert.get("managed") or {}).get("state", "")
        if state != "ACTIVE":
            not_active.append(f"{hostname}={state or 'unknown'}")

    if not_active:
        return CheckResult(
            name,
            Status.FAIL,
            "certificates not ACTIVE: " + ", ".join(not_active),
            remediation=(
                "create the hostname's DNS records (or the one-time NS delegation when "
                "manage_public_dns is on) and allow time to validate"
            ),
        )
    return CheckResult(
        name,
        Status.PASS,
        f"all {len(config.external_hostnames)} external managed certificates are ACTIVE",
    )


def check_gateway_ip_reserved(compute: Any, config: Config) -> CheckResult:
    """The external gateway's global static IP is reserved."""
    name = "external-gateway-ip"
    if skip := _skip_if_no_cluster_mode(name, config):
        return skip
    project = config.project_id or config.project_number
    try:
        address = (
            compute.globalAddresses()
            .get(project=project, address=EXTERNAL_GATEWAY_ADDRESS)
            .execute(num_retries=3)
        )
    except HttpError as error:
        status = _http_status(error)
        if status == 403:
            return CheckResult(
                name,
                Status.SKIP,
                "insufficient permission to read Compute addresses; run locally as an operator",
                required=False,
            )
        if status == 404:
            return CheckResult(
                name,
                Status.FAIL,
                f"global address {EXTERNAL_GATEWAY_ADDRESS} not reserved",
                remediation="apply the fop root to reserve the external gateway IP",
            )
        return CheckResult(name, Status.FAIL, f"error reading the address (HTTP {status})")

    status = address.get("status", "")
    if status in ("RESERVED", "IN_USE"):
        return CheckResult(name, Status.PASS, f"external gateway IP reserved ({status})")
    return CheckResult(name, Status.FAIL, f"external gateway IP status is {status or 'unknown'!r}")


def check_node_pool_autoscaling(container: Any, config: Config) -> CheckResult:
    """The general pool autoscales with the expected per-zone bounds (ADR-0007).

    Verifies enabled + min/max per zone + BALANCED location policy — the
    high-availability contract: capacity follows demand within reviewed bounds,
    spread evenly across zones.
    """
    name = "node-pool-autoscaling"
    if skip := _skip_if_no_cluster_mode(name, config):
        return skip
    if not config.cluster_name or config.autoscaling_min_per_zone is None:
        return CheckResult(
            name,
            Status.SKIP,
            "cluster/autoscaling expectations not set "
            "(SETUP_DOCTOR_CLUSTER, SETUP_DOCTOR_AUTOSCALING_MIN/MAX)",
            required=False,
        )
    pools_api = container.projects().locations().clusters().nodePools()
    try:
        pool = pools_api.get(name=config.node_pool_resource).execute(num_retries=3)
    except HttpError as error:
        status = _http_status(error)
        if status == 403:
            return CheckResult(
                name,
                Status.SKIP,
                "insufficient permission to read the node pool; run locally as an operator",
                required=False,
            )
        if status == 404:
            return CheckResult(
                name,
                Status.FAIL,
                "general node pool not found",
                remediation="apply the fop root to create the cluster and its pools",
            )
        return CheckResult(name, Status.FAIL, f"error reading the node pool (HTTP {status})")

    autoscaling = pool.get("autoscaling") or {}
    problems: list[str] = []
    if not autoscaling.get("enabled"):
        problems.append("autoscaling disabled")
    else:
        if autoscaling.get("minNodeCount") != config.autoscaling_min_per_zone:
            problems.append(
                f"min {autoscaling.get('minNodeCount')} != {config.autoscaling_min_per_zone}"
            )
        if autoscaling.get("maxNodeCount") != config.autoscaling_max_per_zone:
            problems.append(
                f"max {autoscaling.get('maxNodeCount')} != {config.autoscaling_max_per_zone}"
            )
        if autoscaling.get("locationPolicy") != "BALANCED":
            problems.append(f"locationPolicy {autoscaling.get('locationPolicy')!r} != BALANCED")
    if problems:
        return CheckResult(
            name,
            Status.FAIL,
            "; ".join(problems),
            remediation="set general_autoscaling on the fop root and apply (ADR-0007)",
        )
    return CheckResult(
        name,
        Status.PASS,
        f"general pool autoscales {config.autoscaling_min_per_zone}-"
        f"{config.autoscaling_max_per_zone}/zone, BALANCED",
    )


def check_backup_plan(gkebackup: Any, config: Config) -> CheckResult:
    """The cluster's Backup for GKE plan exists and is READY (ADR-0004)."""
    name = "backup-plan"
    if skip := _skip_if_no_cluster_mode(name, config):
        return skip
    if not config.cluster_name:
        return CheckResult(
            name, Status.SKIP, "cluster not set (SETUP_DOCTOR_CLUSTER)", required=False
        )
    plans_api = gkebackup.projects().locations().backupPlans()
    try:
        plan = plans_api.get(name=config.backup_plan_resource).execute(num_retries=3)
    except HttpError as error:
        status = _http_status(error)
        if status == 403:
            return CheckResult(
                name,
                Status.SKIP,
                "insufficient permission to read Backup for GKE; run locally as an operator",
                required=False,
            )
        if status == 404:
            return CheckResult(
                name,
                Status.FAIL,
                "backup plan not found",
                remediation="apply the fop root (gke-backup module) to create the plan",
            )
        return CheckResult(name, Status.FAIL, f"error reading the backup plan (HTTP {status})")

    state = plan.get("state", "")
    if state != "READY":
        return CheckResult(
            name,
            Status.FAIL,
            f"backup plan state is {state or 'unknown'!r} (not READY)",
            remediation="check the Backup for GKE agent on the cluster and the plan config",
        )
    cron = (plan.get("backupSchedule") or {}).get("cronSchedule", "?")
    retain = (plan.get("retentionPolicy") or {}).get("backupRetainDays", "?")
    return CheckResult(
        name, Status.PASS, f"backup plan READY (schedule {cron!r}, retain {retain}d)"
    )


def _check_dns_zone(
    dns: Any,
    config: Config,
    *,
    name: str,
    domain: str,
    expected_visibility: str,
    hostnames: tuple[str, ...],
) -> CheckResult:
    """Shared zone + per-hostname A-record verification (ADR-0006)."""
    zones_api = dns.managedZones()
    project = config.project_id or config.project_number
    zone_name = config.dns_zone_name(domain)
    try:
        zone = zones_api.get(project=project, managedZone=zone_name).execute(num_retries=3)
    except HttpError as error:
        status = _http_status(error)
        if status == 403:
            return CheckResult(
                name,
                Status.SKIP,
                "insufficient permission to read Cloud DNS; run locally as an operator",
                required=False,
            )
        if status == 404:
            return CheckResult(
                name,
                Status.FAIL,
                f"managed zone {zone_name} not found",
                remediation="apply the fop root (dns-zones module) to create the zone",
            )
        return CheckResult(name, Status.FAIL, f"error reading the zone (HTTP {status})")

    if zone.get("visibility") != expected_visibility:
        return CheckResult(
            name,
            Status.FAIL,
            f"zone visibility is {zone.get('visibility')!r}, expected {expected_visibility!r}",
        )

    missing: list[str] = []
    rrsets_api = dns.resourceRecordSets()
    for hostname in hostnames:
        try:
            rrsets_api.get(
                project=project, managedZone=zone_name, name=f"{hostname}.", type="A"
            ).execute(num_retries=3)
        except HttpError as error:
            if _http_status(error) == 404:
                missing.append(hostname)
            else:
                return CheckResult(
                    name,
                    Status.FAIL,
                    f"error reading records (HTTP {_http_status(error)})",
                )
    if missing:
        return CheckResult(
            name,
            Status.FAIL,
            "A records missing for: " + ", ".join(missing),
            remediation="apply the fop root — the dns-zones module renders one A record per host",
        )
    detail = f"{expected_visibility} zone {domain} serves {len(hostnames)} A record(s)"
    if expected_visibility == "public":
        # Surface the nameservers — the operator needs them for the one-time
        # registrar delegation (and to re-check after a destroy + re-create).
        detail += "; delegate NS to: " + ", ".join(zone.get("nameServers", []) or ["?"])
    return CheckResult(name, Status.PASS, detail)


def check_private_dns_zone(dns: Any, config: Config) -> CheckResult:
    """The private zone resolves every internal hostname to the internal VIP's record."""
    name = "private-dns-zone"
    if skip := _skip_if_no_cluster_mode(name, config):
        return skip
    if not config.internal_zone_domain:
        return CheckResult(
            name,
            Status.SKIP,
            "internal zone not set (SETUP_DOCTOR_INTERNAL_ZONE_DOMAIN)",
            required=False,
        )
    return _check_dns_zone(
        dns,
        config,
        name=name,
        domain=config.internal_zone_domain,
        expected_visibility="private",
        hostnames=config.internal_hostnames,
    )


def check_public_dns_zone(dns: Any, config: Config) -> CheckResult:
    """The opt-in public zone exists and serves every external hostname's A record.

    Runs only when manage_public_dns is on (the zone domain is configured);
    NS delegation itself is verified by the operator with dig (runbook).
    """
    name = "public-dns-zone"
    if skip := _skip_if_no_cluster_mode(name, config):
        return skip
    if not config.public_zone_domain:
        return CheckResult(
            name,
            Status.SKIP,
            "public zone not managed (SETUP_DOCTOR_PUBLIC_ZONE_DOMAIN unset)",
            required=False,
        )
    return _check_dns_zone(
        dns,
        config,
        name=name,
        domain=config.public_zone_domain,
        expected_visibility="public",
        hostnames=config.external_hostnames,
    )
