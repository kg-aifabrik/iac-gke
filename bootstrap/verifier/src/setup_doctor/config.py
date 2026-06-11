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

# APIs the hardened cluster and its supply chain need (checked only in cluster
# mode — when a region is configured). Mirrors the project-foundation module's
# service list, minus the keyless-access baseline already covered by
# DEFAULT_REQUIRED_APIS above — keep the two in sync when the foundation grows.
DEFAULT_CLUSTER_APIS: tuple[str, ...] = (
    "container.googleapis.com",
    "compute.googleapis.com",
    "cloudkms.googleapis.com",
    "artifactregistry.googleapis.com",
    "containeranalysis.googleapis.com",
    "binaryauthorization.googleapis.com",
    "gkehub.googleapis.com",
    "gkeconnect.googleapis.com",
    "connectgateway.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "dns.googleapis.com",
    "certificatemanager.googleapis.com",  # public gateway certs (M2, TC-7)
    "privateca.googleapis.com",  # CAS private CA for internal TLS (M2, TC-7)
    "gkebackup.googleapis.com",  # Backup for GKE (M3, ADR-0004)
)

# The role both Google-managed service agents need on the cluster key (one for
# secret/etcd encryption, one for node/disk encryption).
CMEK_ROLE = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

# Connect Gateway roles the automation needs to apply in-cluster resources.
CONNECT_GATEWAY_ROLES: frozenset[str] = frozenset(
    {"roles/gkehub.gatewayEditor", "roles/gkehub.viewer"}
)

# Default project-level role for the least-privilege node service account.
DEFAULT_NODE_SA_ROLES: frozenset[str] = frozenset({"roles/container.defaultNodeServiceAccount"})

# Ingress resource names (cluster mode), following the gke-gateway naming where
# the external gateway is named "external". Certificates are per-hostname
# (ADR-0005): external-cert-<hostname slug>.
EXTERNAL_CERT_PREFIX = "external-cert"
EXTERNAL_GATEWAY_ADDRESS = "external-gw"

# Node pool and backup-plan names follow the gke-cluster / gke-backup modules.
GENERAL_POOL_NAME = "general"
BACKUP_PLAN_SUFFIX = "-daily"


def _slug(hostname_or_domain: str) -> str:
    """Resource-name slug for a hostname/domain (Google names take [a-z0-9-])."""
    return hostname_or_domain.replace(".", "-")


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
        region: Cluster region. When set, the cluster-setup checks (CMEK grants,
            node-SA roles, cluster APIs, Connect Gateway) run; when empty they
            SKIP, so the keyless-access-only run is unchanged.
        node_service_account_email: Least-privilege node SA whose project roles
            are audited (cluster mode).
        expected_node_sa_roles: Exact project roles the node SA must hold.
        kms_key_name: Crypto key name in the ``gke-<region>`` key ring.
        cluster_required_apis: APIs the cluster/supply-chain need (cluster mode).
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
    region: str = ""
    node_service_account_email: str = ""
    expected_node_sa_roles: frozenset[str] = DEFAULT_NODE_SA_ROLES
    kms_key_name: str = "cluster"
    cluster_required_apis: tuple[str, ...] = DEFAULT_CLUSTER_APIS
    environment: str = ""
    cluster_name: str = ""
    autoscaling_min_per_zone: int | None = None
    autoscaling_max_per_zone: int | None = None
    external_hostnames: tuple[str, ...] = ()
    internal_hostnames: tuple[str, ...] = ()
    internal_zone_domain: str = ""
    public_zone_domain: str = ""

    @property
    def project_ref(self) -> str:
        """``projects/<id-or-number>`` — Google APIs accept either form."""
        return f"projects/{self.project_id or self.project_number}"

    @property
    def cluster_checks_enabled(self) -> bool:
        """Cluster-setup checks run only when a region is configured."""
        return bool(self.region)

    @property
    def gke_service_agent_member(self) -> str:
        """IAM member for the GKE service agent (secret/etcd CMEK grant)."""
        return (
            f"serviceAccount:service-{self.project_number}"
            "@container-engine-robot.iam.gserviceaccount.com"
        )

    @property
    def compute_service_agent_member(self) -> str:
        """IAM member for the Compute service agent (node/disk CMEK grant)."""
        return (
            f"serviceAccount:service-{self.project_number}@compute-system.iam.gserviceaccount.com"
        )

    @property
    def kms_crypto_key_resource(self) -> str:
        """Full resource name of the cluster encryption key."""
        return (
            f"{self.project_ref}/locations/{self.region}"
            f"/keyRings/gke-{self.region}/cryptoKeys/{self.kms_key_name}"
        )

    def external_certificate_resource(self, hostname: str) -> str:
        """Full resource name of a hostname's managed certificate (global, ADR-0005)."""
        return (
            f"{self.project_ref}/locations/global/certificates/"
            f"{EXTERNAL_CERT_PREFIX}-{_slug(hostname)}"
        )

    @property
    def node_pool_resource(self) -> str:
        """Full resource name of the general node pool (autoscaling check)."""
        return (
            f"{self.project_ref}/locations/{self.region}"
            f"/clusters/{self.cluster_name}/nodePools/{GENERAL_POOL_NAME}"
        )

    @property
    def backup_plan_resource(self) -> str:
        """Full resource name of the cluster's backup plan (gke-backup module naming)."""
        return (
            f"{self.project_ref}/locations/{self.region}"
            f"/backupPlans/{self.cluster_name}{BACKUP_PLAN_SUFFIX}"
        )

    def dns_zone_name(self, domain: str) -> str:
        """Cloud DNS managed-zone name for a domain (dns-zones module naming)."""
        return _slug(domain)

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

        node_roles_raw = _env("EXPECTED_NODE_SA_ROLES")
        node_sa_roles = (
            frozenset(r.strip() for r in node_roles_raw.split(",") if r.strip())
            if node_roles_raw
            else DEFAULT_NODE_SA_ROLES
        )

        def _csv(name: str) -> tuple[str, ...]:
            return tuple(h.strip() for h in _env(name).split(",") if h.strip())

        def _int_or_none(name: str) -> int | None:
            raw = _env(name)
            if not raw:
                return None
            try:
                return int(raw)
            except ValueError as error:
                raise ConfigError(f"{ENV_PREFIX}{name} must be an integer, got {raw!r}") from error

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
            region=_env("REGION"),
            node_service_account_email=_env("NODE_SERVICE_ACCOUNT"),
            expected_node_sa_roles=node_sa_roles,
            environment=_env("ENVIRONMENT"),
            cluster_name=_env("CLUSTER"),
            autoscaling_min_per_zone=_int_or_none("AUTOSCALING_MIN"),
            autoscaling_max_per_zone=_int_or_none("AUTOSCALING_MAX"),
            external_hostnames=_csv("EXTERNAL_HOSTNAMES"),
            internal_hostnames=_csv("INTERNAL_HOSTNAMES"),
            internal_zone_domain=_env("INTERNAL_ZONE_DOMAIN"),
            public_zone_domain=_env("PUBLIC_ZONE_DOMAIN"),
        )
