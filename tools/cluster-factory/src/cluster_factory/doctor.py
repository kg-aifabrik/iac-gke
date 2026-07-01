"""Emit the ``SETUP_DOCTOR_*`` environment for a registry-defined cluster.

Bridges the cluster registry to the verifier: given a cluster's coordinates and
the account identifiers, it produces the exact ``SETUP_DOCTOR_*`` variables that
``setup-doctor`` reads, so the verify step audits the cluster against the same
source of truth it was built from (ADR-0009).

Pure — no gcloud/gh calls. The caller supplies the project id/number and the
repository id (the wrapper script fetches those); the per-cluster values
(hostnames, DNS zones, autoscaling bounds) come from the registry's
:func:`effective_config`. Service-account emails follow the naming conventions
from the keyless (`cluster-ctrl-automation`) and foundation (`gke-node`) setups.
"""

from __future__ import annotations

from typing import Any

from cluster_factory.registry import effective_config

# Design constants (see the keyless-access setup and ADR-0009).
POOL_ID = "github"
PROVIDER_ID = "iac-gke"
REF = "refs/heads/main"
AUTOMATION_SA_ID = "cluster-ctrl-automation"
NODE_SA_ID = "gke-node"


def _csv(value: Any) -> str:
    """A comma-joined string for a list, or the value itself (empty if None)."""
    if isinstance(value, list):
        return ",".join(str(v) for v in value)
    return "" if value is None else str(value)


def doctor_env(
    data: dict[str, Any],
    env: str,
    purpose: str,
    *,
    project_id: str,
    project_number: str,
    region: str,
    repository_id: str,
) -> dict[str, str]:
    """Return the ``SETUP_DOCTOR_*`` variables for one cluster as a mapping.

    Per-cluster values are resolved from the registry; identity/account values are
    taken from the arguments and the naming conventions. Raises
    :class:`cluster_factory.registry.RegistryError` via ``effective_config`` if the
    cluster is malformed.
    """
    cfg = effective_config(data, env, purpose)
    asg = cfg.get("general_autoscaling") or {}
    return {
        "SETUP_DOCTOR_PROJECT_ID": project_id,
        "SETUP_DOCTOR_PROJECT_NUMBER": str(project_number),
        "SETUP_DOCTOR_POOL_ID": POOL_ID,
        "SETUP_DOCTOR_PROVIDER_ID": PROVIDER_ID,
        "SETUP_DOCTOR_REPOSITORY_ID": str(repository_id),
        "SETUP_DOCTOR_REF": REF,
        "SETUP_DOCTOR_SERVICE_ACCOUNT": f"{AUTOMATION_SA_ID}@{project_id}.iam.gserviceaccount.com",
        "SETUP_DOCTOR_REGION": region,
        "SETUP_DOCTOR_ENVIRONMENT": env,
        "SETUP_DOCTOR_CLUSTER": f"{env}-{purpose}",
        "SETUP_DOCTOR_NODE_SERVICE_ACCOUNT": f"{NODE_SA_ID}@{project_id}.iam.gserviceaccount.com",
        "SETUP_DOCTOR_AUTOSCALING_MIN": str(asg.get("min_per_zone", "")),
        "SETUP_DOCTOR_AUTOSCALING_MAX": str(asg.get("max_per_zone", "")),
        "SETUP_DOCTOR_EXTERNAL_HOSTNAMES": _csv(cfg.get("external_hostnames")),
        "SETUP_DOCTOR_INTERNAL_HOSTNAMES": _csv(cfg.get("internal_hostnames")),
        "SETUP_DOCTOR_INTERNAL_ZONE_DOMAIN": _csv(cfg.get("internal_zone_domain")),
        "SETUP_DOCTOR_PUBLIC_ZONE_DOMAIN": _csv(cfg.get("public_zone_domain")),
    }


def as_shell_exports(env_map: dict[str, str]) -> str:
    """Render the mapping as ``export KEY='value'`` lines, single-quote-escaped so
    the output is safe to ``eval`` in bash."""
    lines = []
    for key, value in env_map.items():
        safe = value.replace("'", "'\\''")
        lines.append(f"export {key}='{safe}'")
    return "\n".join(lines)
