"""cluster-factory — turn config/clusters.yaml into Terraform roots + pipeline inputs.

The registry is the single source of truth for which clusters exist and their
shape per (environment, purpose); this package loads and validates it
(:mod:`cluster_factory.registry`) and, in later chunks, renders the per-cluster
Terraform roots and regenerates the workflow input lists. See
docs/adr/0009-cluster-purpose-expansion.md.
"""

from cluster_factory.registry import (
    RegistryError,
    VALID_ENVS,
    active_clusters,
    effective_config,
    load,
    validate,
)

__all__ = [
    "RegistryError",
    "VALID_ENVS",
    "active_clusters",
    "effective_config",
    "load",
    "validate",
]
