"""Behavioural tests for the cluster registry loader/validator/merger.

Each test is named for the rule it proves. They run against both synthetic
registries (to exercise the rules in isolation) and the repo's real
``config/clusters.yaml`` (to prove dev-fop's effective config still matches the
hand-written fop root, the contract that keeps regeneration a no-op).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from cluster_factory import registry

REPO_ROOT = Path(__file__).resolve().parents[3]
REGISTRY_PATH = REPO_ROOT / "config" / "clusters.yaml"


def _minimal(**overrides):
    """A smallest valid registry (one dev/fop cluster), with optional overrides
    merged shallowly onto the top-level mapping for negative-case tests."""
    data = {
        "environments": {"dev": {"cas_tier": "DEVOPS", "release_channel": "REGULAR",
                                 "deletion_protection": False, "enable_cloud_nat": True,
                                 "manage_public_dns": True}},
        "purposes": {"fop": {"general_machine_type": "e2-medium",
                             "general_autoscaling": {"min_per_zone": 1, "max_per_zone": 2}}},
        "clusters": [{
            "env": "dev", "purpose": "fop",
            "external_hostnames": ["a.example.com"],
            "internal_hostnames": ["b.internal"],
            "internal_zone_domain": "internal",
            "public_zone_domain": "example.com",
        }],
    }
    data.update(overrides)
    return data


# --- the real registry -------------------------------------------------------

def test_repo_registry_loads_and_lists_dev_fop_and_dev_mgmt():
    data = registry.load(REGISTRY_PATH)
    assert ("dev", "fop") in registry.active_clusters(data)
    assert ("dev", "mgmt") in registry.active_clusters(data)


def test_dev_fop_effective_config_matches_the_handwritten_fop_root():
    """The dev-fop merge must reproduce the values fop's main.tf sets today, so
    the generated root is a plan-level no-op."""
    eff = registry.effective_config(registry.load(REGISTRY_PATH), "dev", "fop")
    assert eff["cas_tier"] == "DEVOPS"
    assert eff["general_machine_type"] == "e2-medium"
    assert eff["general_autoscaling"] == {"min_per_zone": 1, "max_per_zone": 2}
    assert eff["release_channel"] == "REGULAR"
    assert eff["deletion_protection"] is False
    assert eff["enable_cloud_nat"] is True
    assert eff["manage_public_dns"] is True
    assert eff["enable_cloud_sql"] is True
    assert eff["cloud_sql_tier"] == "db-custom-1-3840"
    assert eff["external_hostnames"] == ["sd1.dev.arthos.app", "sd2.dev.arthos.app", "sd3.dev.arthos.app"]
    assert eff["internal_hostnames"] == ["hello.dev.aifabrik.com", "tools.dev.aifabrik.com"]
    assert eff["internal_zone_domain"] == "dev.aifabrik.com"
    assert eff["public_zone_domain"] == "dev.arthos.app"
    assert eff["maintenance_recurring_window"]["recurrence"] == "FREQ=WEEKLY;BYDAY=SA,SU"
    assert eff["environment"] == "dev" and eff["purpose"] == "fop"


# --- merge semantics ---------------------------------------------------------

def test_merge_order_cluster_override_beats_purpose_beats_env():
    data = {
        "defaults": {"cas_tier": "DEVOPS"},
        "environments": {"dev": {"cas_tier": "FROM_ENV", "release_channel": "REGULAR",
                                 "deletion_protection": False, "enable_cloud_nat": True,
                                 "manage_public_dns": True}},
        "purposes": {"fop": {"cas_tier": "FROM_PURPOSE",
                             "general_machine_type": "e2-medium",
                             "general_autoscaling": {"min_per_zone": 1, "max_per_zone": 2}}},
        "clusters": [{
            "env": "dev", "purpose": "fop", "cas_tier": "FROM_CLUSTER",
            "external_hostnames": ["a"], "internal_hostnames": ["b"],
            "internal_zone_domain": "i", "public_zone_domain": "p",
        }],
    }
    eff = registry.effective_config(data, "dev", "fop")
    assert eff["cas_tier"] == "FROM_CLUSTER"  # cluster wins over purpose/env/defaults


def test_nested_mapping_merges_rather_than_replaces():
    data = _minimal()
    data["environments"]["dev"]["maintenance_recurring_window"] = {"recurrence": "R", "start_time": "s"}
    data["clusters"][0]["maintenance_recurring_window"] = {"start_time": "OVERRIDE"}
    eff = registry.effective_config(data, "dev", "fop")
    assert eff["maintenance_recurring_window"] == {"recurrence": "R", "start_time": "OVERRIDE"}


# --- validation: rejections --------------------------------------------------

def test_rejects_unknown_environment_key():
    data = _minimal()
    data["environments"]["qa"] = {}
    with pytest.raises(registry.RegistryError, match="unknown environment 'qa'"):
        registry.validate(data)


def test_rejects_cluster_with_undefined_purpose():
    data = _minimal()
    data["clusters"][0]["purpose"] = "ghost"
    with pytest.raises(registry.RegistryError, match="purpose 'ghost' is not defined"):
        registry.validate(data)


def test_rejects_cluster_env_not_declared_under_environments():
    data = _minimal()
    data["clusters"][0]["env"] = "prod"  # valid name, but no environments.prod here
    with pytest.raises(registry.RegistryError, match="not defined under 'environments'"):
        registry.validate(data)


def test_rejects_duplicate_env_purpose():
    data = _minimal()
    data["clusters"].append(dict(data["clusters"][0]))
    with pytest.raises(registry.RegistryError, match="duplicate cluster"):
        registry.validate(data)


def test_rejects_cluster_missing_required_field():
    data = _minimal()
    del data["clusters"][0]["internal_hostnames"]
    with pytest.raises(registry.RegistryError, match="missing required field"):
        registry.validate(data)


def test_rejects_non_mapping_root():
    with pytest.raises(registry.RegistryError, match="must be a mapping"):
        registry.validate([])  # type: ignore[arg-type]


def test_false_boolean_counts_as_present_not_missing():
    """deletion_protection: false must satisfy the required-field check."""
    data = _minimal()  # dev sets deletion_protection False already
    registry.validate(data)  # must not raise
