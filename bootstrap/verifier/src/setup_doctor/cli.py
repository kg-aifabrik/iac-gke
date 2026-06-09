"""Command-line entry point for setup-doctor.

Resolves configuration and credentials, runs the checks in a fixed order,
prints a human-readable table (default) or JSON (``--json``), and exits
non-zero if any *required* check FAILED. A SKIP never fails the run.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys

from google.auth import exceptions as auth_exceptions

from . import checks
from . import clients as clients_mod
from .config import Config, ConfigError
from .logging_setup import configure_logging
from .models import CheckResult, Status

logger = logging.getLogger("setup_doctor")

# Process exit codes.
_EXIT_OK = 0
_EXIT_CHECKS_FAILED = 1
_EXIT_ERROR = 2


def run_checks(clients: clients_mod.Clients, config: Config) -> list[CheckResult]:
    """Run all checks in a fixed order and return their results.

    Order matters for readability: identity and connectivity first (they
    explain later failures), then the structural audits.
    """
    # Resolve identity first — this forces a token refresh, so an impersonation
    # or credential failure surfaces here as one clear FAIL instead of crashing
    # every subsequent check with a traceback.
    try:
        active_email = clients_mod.resolve_active_identity(clients)
    except auth_exceptions.GoogleAuthError as error:
        return [
            CheckResult(
                "active-identity",
                Status.FAIL,
                f"could not obtain credentials for the expected identity: {error}",
                remediation=(
                    "confirm the service account has a roles/iam.workloadIdentityUser "
                    "binding for this repo's principalSet (allow 1-2 minutes for IAM "
                    "propagation after setup), and that the WIF provider's attribute "
                    "condition matches this repository_id and ref"
                ),
            )
        ]
    return [
        checks.check_active_identity(active_email, config),
        checks.check_required_apis_enabled(clients.serviceusage, config),
        checks.check_wif_provider(clients.iam, config),
        checks.check_service_account_roles(clients.resourcemanager, clients.iam, config),
        # Cluster-setup checks — SKIP unless a region is configured (cluster mode).
        checks.check_cluster_apis_enabled(clients.serviceusage, config),
        checks.check_cmek_grants(clients.cloudkms, config),
        checks.check_node_sa_roles(clients.resourcemanager, clients.iam, config),
        checks.check_connect_gateway_access(clients.resourcemanager, config),
        # Ingress-setup checks — also SKIP unless a region is configured.
        checks.check_cas_cas_enabled(clients.privateca, config),
        checks.check_external_cert_active(clients.certificatemanager, config),
        checks.check_gateway_ip_reserved(clients.compute, config),
    ]


def _result_to_dict(result: CheckResult) -> dict[str, object]:
    return {
        "name": result.name,
        "status": result.status.value,
        "detail": result.detail,
        "remediation": result.remediation,
        "required": result.required,
    }


def _render_text(results: list[CheckResult]) -> str:
    lines: list[str] = []
    for result in results:
        lines.append(f"[{result.status.value:<4}] {result.name}: {result.detail}")
        if result.status is Status.FAIL and result.remediation:
            lines.append(f"        fix: {result.remediation}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    """Entry point. Returns the process exit code."""
    parser = argparse.ArgumentParser(
        prog="setup-doctor",
        description="Verify the keyless GitHub Actions -> Google Cloud setup.",
    )
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args(argv)

    correlation_id = configure_logging()

    try:
        config = Config.from_env()
    except ConfigError as error:
        print(f"configuration error: {error}", file=sys.stderr)
        return _EXIT_ERROR

    try:
        clients = clients_mod.build_clients()
        results = run_checks(clients, config)
    except Exception as error:  # noqa: BLE001 - top-level guard: report cleanly, no traceback dump
        logger.error("verifier failed before completing checks", exc_info=error)
        print(f"error: could not complete checks: {error}", file=sys.stderr)
        return _EXIT_ERROR

    failed = [r for r in results if r.status is Status.FAIL and r.required]
    passed = sum(1 for r in results if r.status is Status.PASS)
    skipped = sum(1 for r in results if r.status is Status.SKIP)

    if args.json:
        print(
            json.dumps(
                {
                    "correlation_id": correlation_id,
                    "ok": not failed,
                    "results": [_result_to_dict(r) for r in results],
                },
                indent=2,
            )
        )
    else:
        print(_render_text(results))
        verdict = "FAILED" if failed else "OK"
        print(f"\n{verdict} — {len(failed)} failed, {skipped} skipped, {passed} passed")

    return _EXIT_CHECKS_FAILED if failed else _EXIT_OK


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
