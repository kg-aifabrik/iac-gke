"""Regenerate the pipeline's registry-driven input enumerations (ADR-0009).

GitHub Actions ``choice`` inputs and ``matrix`` lists are static YAML — they
cannot be computed at dispatch — so the generator rewrites them from the registry
between sentinel markers::

    # >>> cluster-factory:<tag> ...
    ...generated lines...
    # <<< cluster-factory:<tag>

Only the lines *between* the markers are replaced; the block is emitted at the
indentation of the opening marker. Two tags:

- ``purposes`` — the apply/destroy ``purpose`` choice list: ``foundation`` (the
  per-project root, always offered) followed by every purpose that has an active
  cluster.
- ``matrix`` — the plan job's ``env × purpose`` include list: per environment
  that has clusters, its ``foundation`` root then each cluster.

Keeping the workflows and the Terraform roots derived from the same registry
means the dispatch menu and the roots that exist can never disagree.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from cluster_factory.registry import active_clusters

FOUNDATION = "foundation"

# Workflow file (repo-relative) -> the tags it owns.
WORKFLOW_TAGS: dict[str, tuple[str, ...]] = {
    ".github/workflows/terraform-apply.yml": ("purposes",),
    ".github/workflows/terraform-destroy.yml": ("purposes",),
    ".github/workflows/terraform-plan.yml": ("matrix",),
}


class WorkflowMarkerError(RuntimeError):
    """A workflow is missing (or has malformed) the sentinel markers for a tag."""


def _purpose_choices(data: dict[str, Any]) -> list[str]:
    """``foundation`` plus each purpose that has an active cluster, in first-seen
    order (deterministic from the registry)."""
    purposes: list[str] = []
    for _env, purpose in active_clusters(data):
        if purpose not in purposes:
            purposes.append(purpose)
    return [FOUNDATION] + purposes


def _matrix_rows(data: dict[str, Any]) -> list[tuple[str, str]]:
    """``(env, purpose)`` rows the plan job covers: per env with clusters, its
    ``foundation`` root then each of its clusters, in registry order."""
    envs: list[str] = []
    for env, _purpose in active_clusters(data):
        if env not in envs:
            envs.append(env)
    rows: list[tuple[str, str]] = []
    for env in envs:
        rows.append((env, FOUNDATION))
        rows += [(e, p) for (e, p) in active_clusters(data) if e == env]
    return rows


def _body(tag: str, data: dict[str, Any]) -> list[str]:
    """Generated lines for ``tag`` (relative indentation; caller prefixes it)."""
    if tag == "purposes":
        return ["options:"] + [f"  - {p}" for p in _purpose_choices(data)]
    if tag == "matrix":
        return ["include:"] + [
            f"  - {{ env: {env}, purpose: {purpose} }}" for env, purpose in _matrix_rows(data)
        ]
    raise WorkflowMarkerError(f"unknown tag: {tag}")


def _replace_region(text: str, tag: str, body: list[str]) -> str:
    """Replace the lines between the ``tag`` markers with ``body`` (indented to the
    opening marker). Raises :class:`WorkflowMarkerError` if the markers are absent
    or out of order."""
    marker = f"cluster-factory:{tag}"
    lines = text.splitlines()
    start = end = None
    for i, line in enumerate(lines):
        if marker in line and ">>>" in line:
            start = i
        elif marker in line and "<<<" in line:
            end = i
            break
    if start is None or end is None or end <= start:
        raise WorkflowMarkerError(f"markers for '{tag}' not found or malformed")
    open_line = lines[start]
    indent = open_line[: len(open_line) - len(open_line.lstrip())]
    rendered = [f"{indent}{bl}" for bl in body]
    new_lines = lines[: start + 1] + rendered + lines[end:]
    trailing = "\n" if text.endswith("\n") else ""
    return "\n".join(new_lines) + trailing


def update_workflows(
    repo_root: str | Path, data: dict[str, Any], *, check: bool = False
) -> list[str]:
    """Regenerate every workflow's marked regions from ``data``.

    ``check`` compares without writing and returns the repo-relative paths that
    would change (drift); otherwise the files are rewritten in place and ``[]`` is
    returned. Raises :class:`WorkflowMarkerError` if a managed workflow lacks its
    markers.
    """
    repo_root = Path(repo_root)
    drift: list[str] = []
    for rel, tags in WORKFLOW_TAGS.items():
        path = repo_root / rel
        text = path.read_text(encoding="utf-8")
        new_text = text
        for tag in tags:
            new_text = _replace_region(new_text, tag, _body(tag, data))
        if new_text != text:
            if check:
                drift.append(rel)
            else:
                path.write_text(new_text, encoding="utf-8")
    return drift
