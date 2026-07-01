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

from pathlib import Path
from typing import Any

import yaml

from cluster_factory.registry import effective_config

# Design constants (see the keyless-access setup and ADR-0009).
POOL_ID = "github"
PROVIDER_ID = "iac-gke"
REF = "refs/heads/main"
AUTOMATION_SA_ID = "cluster-ctrl-automation"
NODE_SA_ID = "gke-node"

# Roles the access module grants the automation SA at cluster-apply time (so a
# BUILT cluster's SA holds these on top of the build roles). Kept here because
# they're only present once a cluster exists — see runbook 02 step 1.
ACCESS_MODULE_ROLES = ("roles/gkehub.gatewayEditor", "roles/gkehub.viewer")

# The build-role set is single-sourced from the keyless verifier workflow, so we
# don't maintain a second copy that could drift.
_VERIFY_WORKFLOW = ".github/workflows/verify-access.yml"
_EXPECTED_ROLES_KEY = "SETUP_DOCTOR_EXPECTED_ROLES"


def _find_key(obj: Any, key: str) -> Any:
    """Depth-first search for ``key`` anywhere in a nested dict/list; None if absent."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                return v
            found = _find_key(v, key)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = _find_key(item, key)
            if found is not None:
                return found
    return None


def expected_cluster_roles(repo_root: str | Path) -> str:
    """The automation SA's expected project roles for a **built** cluster.

    Reads the build-role set from ``verify-access.yml`` (its
    ``SETUP_DOCTOR_EXPECTED_ROLES`` — the single source of truth) and adds the
    roles the access module grants at cluster-apply. Returns a sorted,
    comma-joined string, or ``""`` if the workflow can't be read (so callers can
    simply omit the variable rather than assert a wrong set).
    """
    path = Path(repo_root) / _VERIFY_WORKFLOW
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError):
        return ""
    raw = _find_key(data, _EXPECTED_ROLES_KEY)
    if not raw:
        return ""
    roles = {r.strip() for r in str(raw).split(",") if r.strip()}
    roles.update(ACCESS_MODULE_ROLES)
    return ",".join(sorted(roles))


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
    expected_roles: str = "",
) -> dict[str, str]:
    """Return the ``SETUP_DOCTOR_*`` variables for one cluster as a mapping.

    Per-cluster values are resolved from the registry; identity/account values are
    taken from the arguments and the naming conventions. ``expected_roles`` (from
    :func:`expected_cluster_roles`) drives the least-privilege check and is
    included only when non-empty. Raises
    :class:`cluster_factory.registry.RegistryError` via ``effective_config`` if the
    cluster is malformed.
    """
    cfg = effective_config(data, env, purpose)
    asg = cfg.get("general_autoscaling") or {}
    env_map = {
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
    if expected_roles:
        env_map["SETUP_DOCTOR_EXPECTED_ROLES"] = expected_roles
    return env_map


def as_shell_exports(env_map: dict[str, str]) -> str:
    """Render the mapping as ``export KEY='value'`` lines, single-quote-escaped so
    the output is safe to ``eval`` in bash."""
    lines = []
    for key, value in env_map.items():
        safe = value.replace("'", "'\\''")
        lines.append(f"export {key}='{safe}'")
    return "\n".join(lines)
