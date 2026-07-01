#!/usr/bin/env bash
#
# verify-cluster.sh — run setup-doctor against a built cluster in one command.
#
# It installs the verifier, derives every SETUP_DOCTOR_* value for the cluster
# from config/clusters.yaml (via cluster-factory) plus your project, and runs the
# full audit. Run it AFTER signing in with your operator credentials:
#   gcloud auth application-default login
#
# Example:
#   ./bootstrap/verify-cluster.sh --project gke-poc-498602 --env dev --purpose fop

set -euo pipefail

ENV="dev"
PURPOSE="fop"
PROJECT="${PROJECT_ID:-}"
REGION="${REGION:-us-central1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFIER_DIR="${REPO_ROOT}/bootstrap/verifier"
FACTORY_DIR="${REPO_ROOT}/tools/cluster-factory"

info() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: verify-cluster.sh [options]

Runs setup-doctor (the full cluster audit) against a built cluster. Installs the
verifier and derives every SETUP_DOCTOR_* value from config/clusters.yaml + your
project, so you don't set any of them by hand.

Options:
  --project ID   Google Cloud Project ID (default: $PROJECT_ID if exported).
  --env ENV      Environment (default: dev).
  --purpose P    Cluster purpose (default: fop).
  --region R     Cluster region (default: $REGION, else us-central1).
  -h, --help     Show this help.

Prerequisite: sign in first with  gcloud auth application-default login  as your
operator account (NOT a personal one).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:?--project needs a value}"; shift 2 ;;
    --env)     ENV="${2:?--env needs a value}"; shift 2 ;;
    --purpose) PURPOSE="${2:?--purpose needs a value}"; shift 2 ;;
    --region)  REGION="${2:?--region needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)         die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Preconditions.
# ---------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die "python3 is not installed"
command -v gcloud  >/dev/null 2>&1 || die "gcloud is not installed"
command -v gh      >/dev/null 2>&1 || die "gh (GitHub CLI) is not installed"
[[ -n "${PROJECT}" ]] || die "no project — pass --project ID (or export PROJECT_ID)"
gcloud auth application-default print-access-token >/dev/null 2>&1 \
  || die "Application Default Credentials not found — run: gcloud auth application-default login (as your operator account)"

# ---------------------------------------------------------------------------
# Install the verifier + the factory into one venv (pinned deps).
# ---------------------------------------------------------------------------
info "Preparing the verifier ..."
[[ -d "${VERIFIER_DIR}/.venv" ]] || python3 -m venv "${VERIFIER_DIR}/.venv"
# shellcheck source=/dev/null
. "${VERIFIER_DIR}/.venv/bin/activate"
python -m pip install --quiet -r "${VERIFIER_DIR}/requirements.lock"
python -m pip install --quiet -e "${VERIFIER_DIR}" --no-deps
python -m pip install --quiet -r "${FACTORY_DIR}/requirements.lock"
python -m pip install --quiet -e "${FACTORY_DIR}" --no-deps

# ---------------------------------------------------------------------------
# Derive the non-registry identifiers, then let the registry supply the rest.
# ---------------------------------------------------------------------------
info "Resolving ${ENV}-${PURPOSE} in ${PROJECT} ..."
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')" \
  || die "cannot read project '${PROJECT}' (does it exist and can you access it?)"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || die "could not detect the GitHub repo"
REPOSITORY_ID="$(gh api "repos/${REPO}" --jq .id)" || die "could not read repository id for ${REPO}"

# cluster-factory reads config/clusters.yaml and prints the SETUP_DOCTOR_* exports.
doctor_exports="$(cluster-factory doctor-env \
  --env "${ENV}" --purpose "${PURPOSE}" \
  --project "${PROJECT}" --project-number "${PROJECT_NUMBER}" \
  --region "${REGION}" --repository-id "${REPOSITORY_ID}" \
  --repo-root "${REPO_ROOT}")" || die "could not derive setup-doctor values (is ${ENV}/${PURPOSE} in config/clusters.yaml?)"
eval "${doctor_exports}"

# ---------------------------------------------------------------------------
# Run the audit.
# ---------------------------------------------------------------------------
info "Running setup-doctor for ${ENV}-${PURPOSE} ..."
setup-doctor
