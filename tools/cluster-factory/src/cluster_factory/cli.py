"""Command-line entry point for the cluster factory.

``cluster-factory generate`` renders the per-(env,purpose) Terraform roots from
``config/clusters.yaml``. ``--check`` reports drift without writing (the CI
guard, exit 1 on drift); ``--dry-run`` reports the same for humans (exit 0).
Workflow-enumeration regeneration is added in a later chunk.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from cluster_factory.render import TerraformMissingError, generate
from cluster_factory.registry import RegistryError


def _default_repo_root() -> Path:
    """Nearest ancestor of the cwd that contains ``config/clusters.yaml``."""
    cur = Path.cwd()
    for d in (cur, *cur.parents):
        if (d / "config" / "clusters.yaml").exists():
            return d
    return cur


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="cluster-factory",
        description="Render Terraform roots from config/clusters.yaml (ADR-0009).",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    gen = sub.add_parser("generate", help="Render per-(env,purpose) roots from the registry.")
    mode = gen.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="Report drift without writing; exit 1 if any root is out of date.",
    )
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would change without writing; always exit 0.",
    )
    gen.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="Repo root (default: auto-detected from config/clusters.yaml).",
    )
    gen.add_argument(
        "--registry",
        type=Path,
        default=None,
        help="Registry path (default: <repo-root>/config/clusters.yaml).",
    )
    args = parser.parse_args(argv)

    repo_root = args.repo_root or _default_repo_root()
    registry = args.registry or (repo_root / "config" / "clusters.yaml")

    try:
        result = generate(registry, repo_root, check=args.check, dry_run=args.dry_run)
    except (RegistryError, FileNotFoundError, TerraformMissingError) as exc:
        print(f"cluster-factory: {exc}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        print("cluster-factory: terraform fmt rejected the generated output:", file=sys.stderr)
        if exc.stderr:
            print(exc.stderr.strip(), file=sys.stderr)
        return 2

    if args.check or args.dry_run:
        if result:
            print("Out-of-date roots:" if args.check else "Would update:")
            for path in result:
                print(f"  {path}")
            return 1 if args.check else 0
        print("All roots are up to date.")
        return 0

    # Write mode: result holds orphan root dirs (registry entry removed) — warn,
    # don't fail; the operator destroys the cluster, then removes the directory.
    print(f"Generated roots from {registry}.")
    if result:
        print(
            "warning: these cluster roots have no registry entry; destroy the "
            "cluster, then remove the directory:",
            file=sys.stderr,
        )
        for path in result:
            print(f"  {path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
