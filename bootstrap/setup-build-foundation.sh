#!/usr/bin/env bash
#
# setup-build-foundation.sh — one-time, idempotent bootstrap that makes a project
# ready for Terraform-driven cluster builds (Milestone 1). It:
#   * creates a versioned Cloud Storage bucket for Terraform state, and
#   * elevates the automation service account (from Milestone 0) from its
#     read-only role to a least-privilege BUILD role set, scoped to this project.
#
# Like the keyless-access setup, this is human-run (it grants the automation its
# powers, so the automation can't grant them to itself). Safe to re-run.
#
# Rationale and the role list are in docs/implementation/cluster-build.md.

set -euo pipefail

SA_NAME="cluster-ctrl-automation"
STATE_BUCKET_LOCATION="us"
PROJECT_INPUT=""
ACCOUNT=""
ASSUME_YES="false"
DRY_RUN="false"

# Least-privilege build roles (predefined, per resource type — no Owner/Editor),
# scoped to this one project. See the implementation doc for why each is needed.
BUILD_ROLES=(
  roles/serviceusage.serviceUsageAdmin
  roles/compute.networkAdmin
  roles/compute.securityAdmin
  roles/dns.admin
  roles/container.admin
  roles/cloudkms.admin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountUser
  roles/resourcemanager.projectIamAdmin
  roles/artifactregistry.admin
  roles/binaryauthorization.policyEditor
  roles/gkehub.admin
)
# Superseded by serviceUsageAdmin; removed so the identity's role set stays exact.
SUPERSEDED_ROLE="roles/serviceusage.serviceUsageViewer"

info() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: setup-build-foundation.sh [options]

Makes a project ready for Terraform-driven cluster builds (state bucket + build roles).

Options:
  --project ID_OR_NUMBER   Target Google Cloud project (prompted if omitted).
  --sa-name NAME           Automation service account name (default: cluster-ctrl-automation).
  --account EMAIL          gcloud account to use (overrides the active one for this run).
  --yes                    Do not prompt for confirmation.
  --dry-run                Print the mutating commands without running them.
  -h, --help               Show this help.

Prerequisites: gcloud authenticated; Owner (or project IAM / storage admin) on the project.
EOF
}

run() { if [[ "${DRY_RUN}" == "true" ]]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }
run_quiet() { if [[ "${DRY_RUN}" == "true" ]]; then printf '   [dry-run] %s\n' "$*"; else "$@" >/dev/null; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_INPUT="${2:?--project needs a value}"; shift 2 ;;
    --sa-name) SA_NAME="${2:?}"; shift 2 ;;
    --account) ACCOUNT="${2:?--account needs a value}"; shift 2 ;;
    --yes)     ASSUME_YES="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         die "unknown option: $1 (try --help)" ;;
  esac
done

command -v gcloud >/dev/null 2>&1 || die "gcloud is not installed"
[[ -n "${ACCOUNT}" ]] && export CLOUDSDK_CORE_ACCOUNT="${ACCOUNT}"
gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . \
  || die "no active gcloud account; run: gcloud auth login (or pass --account EMAIL)"

if [[ -z "${PROJECT_INPUT}" ]]; then
  [[ -t 0 ]] || die "no --project given and not interactive"
  read -rp "Google Cloud project (id or number): " PROJECT_INPUT
fi

info "Resolving project ${PROJECT_INPUT} ..."
proj_line="$(gcloud projects describe "${PROJECT_INPUT}" --format='value(projectId, projectNumber)')" \
  || die "cannot read project '${PROJECT_INPUT}'"
read -r PROJECT_ID PROJECT_NUMBER <<<"${proj_line}"
[[ -n "${PROJECT_ID}" ]] || die "could not resolve project id"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
STATE_BUCKET="${PROJECT_ID}-tf-state"
ACTIVE_ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"

plan_label=""
[[ "${DRY_RUN}" == "true" ]] && plan_label=" (dry-run)"
cat <<EOF

Plan${plan_label}:
  Active account : ${ACTIVE_ACCOUNT}
  Project        : ${PROJECT_ID} (${PROJECT_NUMBER})
  Service account: ${SA_EMAIL}
  State bucket   : gs://${STATE_BUCKET} (versioned, uniform access, public access blocked)
  Build roles    : ${#BUILD_ROLES[@]} predefined roles (project-scoped); removes ${SUPERSEDED_ROLE}

This grants the automation identity the privileges to build clusters in THIS project.
EOF

if [[ "${ASSUME_YES}" != "true" && "${DRY_RUN}" != "true" ]]; then
  [[ -t 0 ]] || die "refusing to proceed non-interactively without --yes"
  read -rp "Proceed? [y/N] " reply || reply=""
  [[ "${reply}" =~ ^[Yy]$ ]] || die "aborted"
fi

# --- Terraform state bucket (idempotent) -----------------------------------
if gcloud storage buckets describe "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
  ok "state bucket gs://${STATE_BUCKET} already exists"
else
  info "Creating state bucket gs://${STATE_BUCKET} ..."
  run gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="${PROJECT_ID}" --location="${STATE_BUCKET_LOCATION}" \
    --uniform-bucket-level-access --public-access-prevention
fi
info "Enabling versioning and locking down the bucket ..."
run gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning --public-access-prevention
run_quiet gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/storage.objectAdmin"

# --- Build roles on the automation identity (idempotent) -------------------
info "Granting ${#BUILD_ROLES[@]} build roles to ${SA_EMAIL} ..."
for role in "${BUILD_ROLES[@]}"; do
  run_quiet gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" --role="${role}" --condition=None
done
info "Removing the superseded read-only role ..."
run gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" --role="${SUPERSEDED_ROLE}" --condition=None >/dev/null 2>&1 || true

ok "Build foundation ready. Terraform backend: bucket=${STATE_BUCKET}, prefix=env/<environment>."
