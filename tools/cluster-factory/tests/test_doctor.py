"""Tests for the registry -> setup-doctor environment bridge."""

from __future__ import annotations

from pathlib import Path

from cluster_factory import doctor
from cluster_factory.registry import load

REPO_ROOT = Path(__file__).resolve().parents[3]
REGISTRY_PATH = REPO_ROOT / "config" / "clusters.yaml"


def _env_for_dev_fop():
    return doctor.doctor_env(
        load(REGISTRY_PATH), "dev", "fop",
        project_id="gke-poc-498602",
        project_number="248272574639",
        region="us-central1",
        repository_id="1260827836",
    )


def test_dev_fop_maps_registry_values_to_setup_doctor_vars():
    env = _env_for_dev_fop()
    assert env["SETUP_DOCTOR_PROJECT_ID"] == "gke-poc-498602"
    assert env["SETUP_DOCTOR_PROJECT_NUMBER"] == "248272574639"
    assert env["SETUP_DOCTOR_CLUSTER"] == "dev-fop"
    assert env["SETUP_DOCTOR_ENVIRONMENT"] == "dev"
    assert env["SETUP_DOCTOR_AUTOSCALING_MIN"] == "1"
    assert env["SETUP_DOCTOR_AUTOSCALING_MAX"] == "2"
    assert env["SETUP_DOCTOR_EXTERNAL_HOSTNAMES"] == "sd1.dev.arthos.app,sd2.dev.arthos.app,sd3.dev.arthos.app"
    assert env["SETUP_DOCTOR_INTERNAL_ZONE_DOMAIN"] == "dev.aifabrik.com"
    assert env["SETUP_DOCTOR_PUBLIC_ZONE_DOMAIN"] == "dev.arthos.app"


def test_service_account_emails_follow_the_conventions():
    env = _env_for_dev_fop()
    assert env["SETUP_DOCTOR_SERVICE_ACCOUNT"] == "cluster-ctrl-automation@gke-poc-498602.iam.gserviceaccount.com"
    assert env["SETUP_DOCTOR_NODE_SERVICE_ACCOUNT"] == "gke-node@gke-poc-498602.iam.gserviceaccount.com"


def test_constants_are_set():
    env = _env_for_dev_fop()
    assert env["SETUP_DOCTOR_POOL_ID"] == "github"
    assert env["SETUP_DOCTOR_PROVIDER_ID"] == "iac-gke"
    assert env["SETUP_DOCTOR_REF"] == "refs/heads/main"
    assert env["SETUP_DOCTOR_REPOSITORY_ID"] == "1260827836"


def test_lists_are_comma_joined():
    assert doctor._csv(["a", "b", "c"]) == "a,b,c"
    assert doctor._csv("scalar") == "scalar"
    assert doctor._csv(None) == ""


def test_as_shell_exports_is_evalable_and_quotes_values():
    lines = doctor.as_shell_exports({"SETUP_DOCTOR_CLUSTER": "dev-fop", "X": "a b"})
    assert "export SETUP_DOCTOR_CLUSTER='dev-fop'" in lines
    assert "export X='a b'" in lines  # spaces survive single-quoting


def test_as_shell_exports_escapes_single_quotes():
    # A value with a single quote must not break out of the quoting.
    line = doctor.as_shell_exports({"X": "a'b"})
    assert line == "export X='a'\\''b'"


def test_expected_cluster_roles_is_build_roles_plus_access_module_roles():
    roles = doctor.expected_cluster_roles(REPO_ROOT).split(",")
    # Single-sourced from verify-access.yml ...
    assert "roles/container.admin" in roles
    assert "roles/serviceusage.serviceUsageAdmin" in roles
    # ... plus the roles the access module grants at cluster-apply.
    assert "roles/gkehub.gatewayEditor" in roles
    assert "roles/gkehub.viewer" in roles
    # Sorted + de-duplicated.
    assert roles == sorted(set(roles))


def test_doctor_env_includes_expected_roles_only_when_provided():
    data = load(REGISTRY_PATH)
    kwargs = dict(project_id="p", project_number="1", region="r", repository_id="9")
    with_roles = doctor.doctor_env(data, "dev", "fop", expected_roles="roles/a,roles/b", **kwargs)
    without = doctor.doctor_env(data, "dev", "fop", **kwargs)
    assert with_roles["SETUP_DOCTOR_EXPECTED_ROLES"] == "roles/a,roles/b"
    assert "SETUP_DOCTOR_EXPECTED_ROLES" not in without
