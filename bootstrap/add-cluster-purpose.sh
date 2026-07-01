#!/usr/bin/env bash
#
# add-cluster-purpose.sh — "prime the automation" after adding a cluster to the
# registry. Idempotent wrapper around the cluster-factory generator (ADR-0009).
#
# Adding a cluster purpose is two steps:
#   1. Edit config/clusters.yaml — add the purpose under `purposes:` and a cluster
#      under `clusters:` (see the file's header and docs/designs/cluster-purpose-expansion.md).
#   2. Run this script. It renders the per-(env,purpose) Terraform root(s) and
#      regenerates the pipeline's env/purpose input lists from the registry, then
#      prints the next steps (review the diff, open a PR, dispatch the build).
#
# The generator is idempotent: re-running with no registry change makes no change.
# terraform must be on PATH (the generator formats and the roots must be valid).

set -euo pipefail

# ---------------------------------------------------------------------------
DRY_RUN="false"
CHECK="false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FACTORY_DIR="${REPO_ROOT}/tools/cluster-factory"

# ---------------------------------------------------------------------------
# Output helpers (match the other bootstrap scripts).
# ---------------------------------------------------------------------------
info() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: add-cluster-purpose.sh [options]

Primes the automation from config/clusters.yaml: renders the per-(env,purpose)
Terraform roots and regenerates the pipeline's env/purpose input lists. Run it
after editing the registry. Idempotent.

Options:
  --dry-run   Show what would change without writing anything.
  --check     Fail (exit 1) if any generated file is out of date; writes nothing.
              For CI — proves the committed roots/workflows match the registry.
  -h, --help  Show this help.

Prerequisites: python3 and terraform on PATH. Edit config/clusters.yaml first.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --check)   CHECK="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Preconditions.
# ---------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die "python3 is not installed"
command -v terraform >/dev/null 2>&1 \
  || die "terraform is not on PATH (needed to format and validate generated roots)"
[[ -f "${REPO_ROOT}/config/clusters.yaml" ]] || die "config/clusters.yaml not found"
[[ -d "${FACTORY_DIR}" ]] || die "tools/cluster-factory not found"

# ---------------------------------------------------------------------------
# Install the generator into a local venv (pinned deps), same pattern as the
# verifier bootstrap. Kept out of git (.venv is ignored).
# ---------------------------------------------------------------------------
info "Preparing the cluster-factory generator ..."
[[ -d "${FACTORY_DIR}/.venv" ]] || python3 -m venv "${FACTORY_DIR}/.venv"
# shellcheck source=/dev/null
. "${FACTORY_DIR}/.venv/bin/activate"
python -m pip install --quiet -r "${FACTORY_DIR}/requirements.lock"
python -m pip install --quiet -e "${FACTORY_DIR}" --no-deps

# ---------------------------------------------------------------------------
# Generate (or check / dry-run).
# ---------------------------------------------------------------------------
if [[ "${CHECK}" == "true" ]]; then
  info "Checking generated roots + workflows against config/clusters.yaml ..."
  if cluster-factory generate --check --repo-root "${REPO_ROOT}"; then
    ok "Everything is up to date."
  else
    die "generated files are out of date — run this script without --check to update them"
  fi
  exit 0
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  info "Dry run — showing what would change ..."
  cluster-factory generate --dry-run --repo-root "${REPO_ROOT}"
  exit 0
fi

info "Rendering roots and regenerating pipeline inputs from config/clusters.yaml ..."
cluster-factory generate --repo-root "${REPO_ROOT}"
ok "Automation primed."

cat <<EOF

Next:
  1. Review the changes:      git status && git diff
  2. Open a PR — terraform-plan will preview every (env, purpose) root.
  3. After merge, build it:   gh workflow run terraform-apply.yml -f env=<env> -f purpose=<purpose>
     (an external, customer-facing cluster also needs its public subdomain
      delegated at the registrar before certificates go ACTIVE — see runbook 02.)
EOF
