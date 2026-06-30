"""Behavioural tests for the root generator.

Pure tests cover HCL formatting and the module-block emitter. The terraform-gated
tests prove the committed roots match the registry (golden + idempotency) and that
a hand-edit is detected as drift — these need ``terraform`` on PATH because the
generator runs ``terraform fmt`` and the committed roots are canonically
formatted.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

from cluster_factory import render
from cluster_factory.registry import effective_config, load

REPO_ROOT = Path(__file__).resolve().parents[3]
REGISTRY_PATH = REPO_ROOT / "config" / "clusters.yaml"

needs_terraform = pytest.mark.skipif(
    shutil.which("terraform") is None, reason="terraform not on PATH"
)


# --- pure: HCL formatting ----------------------------------------------------

def test_hcl_formats_each_type():
    assert render._hcl(True) == "true"
    assert render._hcl(False) == "false"
    assert render._hcl(7) == "7"
    assert render._hcl("e2-medium") == '"e2-medium"'
    assert render._hcl(["a", "b"]) == '["a", "b"]'


def test_hcl_escapes_quotes_and_backslashes():
    assert render._hcl('a"b') == '"a\\"b"'


def test_hcl_bool_not_treated_as_int():
    # bool is an int subclass; ensure it renders as a keyword, not 1/0.
    assert render._hcl(True) == "true" and render._hcl(1) == "1"


# --- pure: main.tf emitter ---------------------------------------------------

def test_render_main_carries_registry_values():
    cfg = effective_config(load(REGISTRY_PATH), "dev", "mgmt")
    main = render._render_main(cfg)
    assert 'purpose     = "mgmt"' in main
    assert 'environment = "dev"' in main
    assert 'cas_tier             = "DEVOPS"' in main
    assert '"app.mgmt.dev.arthos.app"' in main
    assert 'prefix = "env/dev/foundation"' in main  # reads the per-project foundation
    assert "DO NOT EDIT BY HAND" in main


def test_render_main_omits_maintenance_window_when_absent():
    cfg = effective_config(load(REGISTRY_PATH), "dev", "fop")
    cfg.pop("maintenance_recurring_window", None)
    assert "maintenance_recurring_window" not in render._render_main(cfg)


# --- terraform-gated: golden / idempotency / drift ---------------------------

@needs_terraform
def test_committed_roots_match_the_registry():
    """generate --check is clean: every committed root already matches what the
    registry would render (golden output + idempotency guard)."""
    assert render.generate(REGISTRY_PATH, REPO_ROOT, check=True) == []


@needs_terraform
def test_check_detects_a_hand_edited_root():
    target = render.cluster_dir(REPO_ROOT, "dev", "mgmt") / "backend.tf"
    original = target.read_text(encoding="utf-8")
    try:
        target.write_text(original + "\n# stray hand edit\n", encoding="utf-8")
        drift = render.generate(REGISTRY_PATH, REPO_ROOT, check=True)
        assert str(target.relative_to(REPO_ROOT)) in drift
    finally:
        target.write_text(original, encoding="utf-8")


# --- escaping (regression for the C2 review findings) ------------------------

def test_hcl_escapes_control_characters():
    assert render._hcl("a\nb") == '"a\\nb"'
    assert render._hcl("a\tb") == '"a\\tb"'
    assert render._hcl("a\rb") == '"a\\rb"'


def test_hcl_escapes_template_sequences_to_literals():
    # ${...} and %{...} must not become live interpolation/directives.
    assert render._hcl("${path.module}") == '"$${path.module}"'
    assert render._hcl("%{if true}") == '"%%{if true}"'


# --- terraform required ------------------------------------------------------

def test_generate_requires_terraform_on_path(monkeypatch):
    monkeypatch.setattr(render.shutil, "which", lambda _name: None)
    with pytest.raises(render.TerraformMissingError):
        render.generate(REGISTRY_PATH, REPO_ROOT, check=True)


# --- orphan detection / pruning ---------------------------------------------

@needs_terraform
def test_orphan_source_file_is_flagged_then_pruned():
    extra = render.cluster_dir(REPO_ROOT, "dev", "mgmt") / "zzz_orphan.tf"
    extra.write_text("# stray resource file\n", encoding="utf-8")
    try:
        drift = render.generate(REGISTRY_PATH, REPO_ROOT, check=True)
        assert str(extra.relative_to(REPO_ROOT)) in drift
        render.generate(REGISTRY_PATH, REPO_ROOT)  # write mode prunes it
        assert not extra.exists()
    finally:
        if extra.exists():
            extra.unlink()


@needs_terraform
def test_orphan_root_directory_is_flagged(tmp_path):
    data = load(REGISTRY_PATH)
    data["clusters"] = [
        c for c in data["clusters"] if not (c["env"] == "dev" and c["purpose"] == "mgmt")
    ]
    reg = tmp_path / "clusters.yaml"
    reg.write_text(yaml.safe_dump(data), encoding="utf-8")
    # dev/mgmt still exists on disk but is no longer in the registry → orphan root.
    drift = render.generate(reg, REPO_ROOT, check=True)
    assert "terraform/envs/dev/mgmt" in drift


@needs_terraform
def test_write_is_atomic_when_fmt_fails(tmp_path, monkeypatch):
    data = load(REGISTRY_PATH)
    data["purposes"]["probe"] = {
        "general_machine_type": "e2-medium",
        "general_autoscaling": {"min_per_zone": 1, "max_per_zone": 2},
    }
    data["clusters"] = [{
        "env": "dev", "purpose": "probe",
        "external_hostnames": ["a.example.com"], "internal_hostnames": ["b.internal"],
        "internal_zone_domain": "internal", "public_zone_domain": "example.com",
    }]
    reg = tmp_path / "clusters.yaml"
    reg.write_text(yaml.safe_dump(data), encoding="utf-8")

    def boom(_directory):
        raise subprocess.CalledProcessError(2, ["terraform", "fmt"], stderr="boom")

    monkeypatch.setattr(render, "_terraform_fmt", boom)
    target = render.cluster_dir(REPO_ROOT, "dev", "probe")
    with pytest.raises(subprocess.CalledProcessError):
        render.generate(reg, REPO_ROOT)  # write mode
    assert not target.exists()  # fmt failed in the temp dir; target never created
