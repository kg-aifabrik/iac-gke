"""Load, validate, and merge the cluster registry (``config/clusters.yaml``).

The registry is the single source of truth for which clusters exist and their
shape per ``(environment, purpose)``. The effective config for one cluster is the
ordered merge ``defaults -> environments[env] -> purposes[purpose] -> cluster
overrides`` (later layers win). ``env`` is a fixed set; ``purpose`` is open.

This module is the foundation of the generator (ADR-0009): the renderer asks for
:func:`effective_config` per active cluster and emits a Terraform root from it.
Keeping load/validate/merge here — pure, no I/O beyond reading the file — makes
the rules testable in isolation.
"""

from __future__ import annotations

import copy
from pathlib import Path
from typing import Any

import yaml

# The environment axis is intentionally closed: posture (CA tier, deletion
# protection, release channel) is defined per env, and new envs mean new
# projects/approval gates — a deliberate, human step, not a config edit (ADR-0009).
VALID_ENVS: tuple[str, ...] = ("dev", "stage", "prod")

# Fields the generated root must resolve (after merge) to call the cluster-stack
# module correctly. This mirrors the inputs today's fop root sets explicitly; the
# rest of cluster-stack's inputs have module defaults. ``general_autoscaling`` is
# a mapping; the others are scalars or lists. Booleans are allowed to be False, so
# membership — not truthiness — decides "present".
REQUIRED_FIELDS: tuple[str, ...] = (
    "cas_tier",
    "release_channel",
    "deletion_protection",
    "enable_cloud_nat",
    "manage_public_dns",
    "general_machine_type",
    "general_autoscaling",
    "external_hostnames",
    "internal_hostnames",
    "internal_zone_domain",
    "public_zone_domain",
)

# Keys that identify a cluster entry rather than contribute to its merged config.
_CLUSTER_KEYS = ("env", "purpose")


class RegistryError(ValueError):
    """The registry is malformed or a cluster is under-specified.

    Carries a human-readable message naming the offending env/purpose or field so
    the generator and CI fail loudly with an actionable error, never silently.
    """


def load(path: str | Path) -> dict[str, Any]:
    """Parse and validate the registry file, returning the raw data.

    Raises :class:`RegistryError` on malformed YAML structure or any validation
    failure (see :func:`validate`).
    """
    raw = Path(path).read_text(encoding="utf-8")
    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError as exc:  # pragma: no cover - passthrough with context
        raise RegistryError(f"{path}: invalid YAML: {exc}") from exc
    data = data or {}
    validate(data)
    return data


def validate(data: dict[str, Any]) -> None:
    """Enforce the registry's invariants, raising :class:`RegistryError` on any.

    Checks: root is a mapping; every declared environment is one of
    :data:`VALID_ENVS`; every cluster names a valid+declared env and a defined
    purpose; no duplicate ``(env, purpose)``; and every cluster resolves all
    :data:`REQUIRED_FIELDS` after the merge.
    """
    if not isinstance(data, dict):
        raise RegistryError("registry root must be a mapping")

    environments = data.get("environments") or {}
    purposes = data.get("purposes") or {}
    clusters = data.get("clusters") or []

    if not isinstance(environments, dict) or not isinstance(purposes, dict):
        raise RegistryError("'environments' and 'purposes' must be mappings")
    if not isinstance(clusters, list):
        raise RegistryError("'clusters' must be a list")

    for env in environments:
        if env not in VALID_ENVS:
            raise RegistryError(
                f"unknown environment '{env}' (allowed: {', '.join(VALID_ENVS)})"
            )

    seen: set[tuple[str, str]] = set()
    for i, cluster in enumerate(clusters):
        if not isinstance(cluster, dict):
            raise RegistryError(f"clusters[{i}] must be a mapping")
        env = cluster.get("env")
        purpose = cluster.get("purpose")
        if env not in VALID_ENVS:
            raise RegistryError(
                f"clusters[{i}]: unknown env '{env}' (allowed: {', '.join(VALID_ENVS)})"
            )
        if env not in environments:
            raise RegistryError(
                f"clusters[{i}]: env '{env}' is not defined under 'environments'"
            )
        if purpose not in purposes:
            raise RegistryError(
                f"clusters[{i}]: purpose '{purpose}' is not defined under 'purposes'"
            )
        key = (env, purpose)
        if key in seen:
            raise RegistryError(f"duplicate cluster (env={env}, purpose={purpose})")
        seen.add(key)

        eff = effective_config(data, env, purpose)
        missing = [f for f in REQUIRED_FIELDS if f not in eff or eff[f] in (None, "", [])]
        if missing:
            raise RegistryError(
                f"cluster (env={env}, purpose={purpose}) is missing required "
                f"field(s): {', '.join(missing)}"
            )


def _deep_merge(base: dict[str, Any], over: dict[str, Any] | None) -> dict[str, Any]:
    """Return ``base`` deep-merged with ``over`` (``over`` wins), without mutating
    either. Nested mappings merge recursively; everything else replaces."""
    out = copy.deepcopy(base)
    for key, value in (over or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = copy.deepcopy(value)
    return out


def effective_config(data: dict[str, Any], env: str, purpose: str) -> dict[str, Any]:
    """Merge the layers for one cluster into its effective config.

    Order (later wins): ``defaults`` -> ``environments[env]`` ->
    ``purposes[purpose]`` -> the matching ``clusters[]`` entry's overrides. The
    returned mapping always carries the resolved ``environment`` and ``purpose``.
    Does not enforce required fields — that is :func:`validate`'s job — so the
    renderer can introspect partial configs too.
    """
    cfg: dict[str, Any] = {}
    cfg = _deep_merge(cfg, data.get("defaults") or {})
    cfg = _deep_merge(cfg, (data.get("environments") or {}).get(env) or {})
    cfg = _deep_merge(cfg, (data.get("purposes") or {}).get(purpose) or {})
    for cluster in data.get("clusters") or []:
        if cluster.get("env") == env and cluster.get("purpose") == purpose:
            override = {k: v for k, v in cluster.items() if k not in _CLUSTER_KEYS}
            cfg = _deep_merge(cfg, override)
            break
    cfg["environment"] = env
    cfg["purpose"] = purpose
    return cfg


def active_clusters(data: dict[str, Any]) -> list[tuple[str, str]]:
    """Return the ``(env, purpose)`` pairs declared under ``clusters`` in order."""
    return [(c["env"], c["purpose"]) for c in data.get("clusters") or []]
