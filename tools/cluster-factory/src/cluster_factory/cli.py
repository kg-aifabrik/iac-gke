"""Command-line entry point for the cluster factory.

``cluster-factory generate`` renders the per-(env,purpose) Terraform roots and
regenerates the pipeline's input lists from ``config/clusters.yaml``. ``--check``
reports drift without writing (the CI guard, exit 1 on drift); ``--dry-run``
reports the same for humans (exit 0).

``cluster-factory doctor-env`` prints the ``SETUP_DOCTOR_*`` exports for a cluster
(derived from the registry), so the verify step audits against the same source of
truth the cluster was built from.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from cluster_factory.doctor import as_shell_exports, doctor_env
from cluster_factory.registry import RegistryError, load
from cluster_factory.render import TerraformMissingError, generate
from cluster_factory.workflows import WorkflowMarkerError


def _default_repo_root() -> Path:
    """Nearest ancestor of the cwd that contains ``config/clusters.yaml``."""
    cur = Path.cwd()
    for d in (cur, *cur.parents):
        if (d / "config" / "clusters.yaml").exists():
            return d
    return cur


def _registry_path(args: argparse.Namespace) -> tuple[Path, Path]:
    """Resolve (repo_root, registry_path) from the shared --repo-root/--registry."""
    repo_root = args.repo_root or _default_repo_root()
    registry = args.registry or (repo_root / "config" / "clusters.yaml")
    return repo_root, registry


def _add_registry_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--repo-root", type=Path, default=None,
                   help="Repo root (default: auto-detected from config/clusters.yaml).")
    p.add_argument("--registry", type=Path, default=None,
                   help="Registry path (default: <repo-root>/config/clusters.yaml).")


def _cmd_generate(args: argparse.Namespace) -> int:
    repo_root, registry = _registry_path(args)
    try:
        result = generate(registry, repo_root, check=args.check, dry_run=args.dry_run)
    except (RegistryError, FileNotFoundError, TerraformMissingError, WorkflowMarkerError) as exc:
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


def _cmd_doctor_env(args: argparse.Namespace) -> int:
    _, registry = _registry_path(args)
    try:
        data = load(registry)
        env_map = doctor_env(
            data, args.env, args.purpose,
            project_id=args.project,
            project_number=args.project_number,
            region=args.region,
            repository_id=args.repository_id,
        )
    except (RegistryError, FileNotFoundError) as exc:
        print(f"cluster-factory: {exc}", file=sys.stderr)
        return 2
    print(as_shell_exports(env_map))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="cluster-factory",
        description="Cluster factory tooling for config/clusters.yaml (ADR-0009).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="Render per-(env,purpose) roots + pipeline inputs.")
    mode = gen.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="Report drift without writing; exit 1 if anything is out of date.")
    mode.add_argument("--dry-run", action="store_true",
                      help="Report what would change without writing; always exit 0.")
    _add_registry_args(gen)
    gen.set_defaults(func=_cmd_generate)

    doc = sub.add_parser(
        "doctor-env",
        help="Print SETUP_DOCTOR_* exports for a cluster (derived from the registry).",
    )
    doc.add_argument("--env", required=True, help="Environment, e.g. dev.")
    doc.add_argument("--purpose", required=True, help="Cluster purpose, e.g. fop.")
    doc.add_argument("--project", required=True, help="Google Cloud Project ID (alphanumeric).")
    doc.add_argument("--project-number", required=True, help="Google Cloud Project Number (numeric).")
    doc.add_argument("--region", required=True, help="Cluster region, e.g. us-central1.")
    doc.add_argument("--repository-id", required=True, help="GitHub repository id (numeric).")
    _add_registry_args(doc)
    doc.set_defaults(func=_cmd_doctor_env)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
