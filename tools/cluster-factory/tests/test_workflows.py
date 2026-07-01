"""Tests for regenerating the pipeline's env/purpose enumerations.

These need no terraform: they exercise the marker-replacement logic and assert the
committed workflows already match the registry (the drift guard) and stay valid
YAML.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from cluster_factory import workflows
from cluster_factory.registry import load

REPO_ROOT = Path(__file__).resolve().parents[3]
REGISTRY_PATH = REPO_ROOT / "config" / "clusters.yaml"
WORKFLOW_FILES = list(workflows.WORKFLOW_TAGS)


def test_committed_workflows_match_the_registry():
    data = load(REGISTRY_PATH)
    assert workflows.update_workflows(REPO_ROOT, data, check=True) == []


@pytest.mark.parametrize("rel", WORKFLOW_FILES)
def test_workflow_is_valid_yaml(rel):
    # yaml.safe_load raises on malformed YAML; enough to prove the rewrite kept the
    # file parseable (GitHub's `on:` key parses as True under YAML — that's fine).
    yaml.safe_load((REPO_ROOT / rel).read_text(encoding="utf-8"))


def test_apply_purpose_choices_list_foundation_and_registry_purposes():
    text = (REPO_ROOT / ".github/workflows/terraform-apply.yml").read_text(encoding="utf-8")
    for expected in ("- foundation", "- fop", "- mgmt"):
        assert expected in text


def test_plan_matrix_includes_foundation_and_each_cluster():
    text = (REPO_ROOT / ".github/workflows/terraform-plan.yml").read_text(encoding="utf-8")
    assert "{ env: dev, purpose: foundation }" in text
    assert "{ env: dev, purpose: fop }" in text
    assert "{ env: dev, purpose: mgmt }" in text


def test_check_detects_a_hand_edited_workflow_region(tmp_path):
    # Copy a workflow into a temp repo layout, corrupt inside the markers, and
    # confirm update_workflows(check=True) reports it.
    rel = ".github/workflows/terraform-apply.yml"
    dest = tmp_path / rel
    dest.parent.mkdir(parents=True)
    original = (REPO_ROOT / rel).read_text(encoding="utf-8")
    # Also copy plan + destroy so update_workflows finds all managed files.
    for other in WORKFLOW_FILES:
        d = tmp_path / other
        d.parent.mkdir(parents=True, exist_ok=True)
        d.write_text((REPO_ROOT / other).read_text(encoding="utf-8"), encoding="utf-8")
    corrupted = original.replace("          - mgmt\n", "")  # drop a purpose inside the markers
    dest.write_text(corrupted, encoding="utf-8")
    drift = workflows.update_workflows(tmp_path, load(REGISTRY_PATH), check=True)
    assert rel in drift


def test_replace_region_raises_without_markers():
    with pytest.raises(workflows.WorkflowMarkerError):
        workflows._replace_region("no markers here\n", "purposes", ["options:"])
