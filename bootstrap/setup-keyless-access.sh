#!/usr/bin/env bash
#
# setup-keyless-access.sh — one-time, interactive, idempotent setup of keyless
# GitHub Actions -> Google Cloud access (Milestone 0).
#
# It prompts for the inputs it needs (or takes them as flags), executes the
# Workload Identity Federation setup, publishes the GitHub repository variables
# the CI workflow reads, and runs setup-doctor to verify the result.
#
# The rationale for each decision (service-account impersonation, pinning the
# OIDC trust on the immutable repository_id + ref=main, least privilege) is in
# docs/runbooks/01-keyless-access-setup.md.
#
# No project-specific value is hard-coded here or committed: the project comes
# from you, and the repository details are derived from the checkout. The
# project id/number are non-secret identifiers; they are printed to stdout and
# (via --trigger-ci) to CI logs, and are written only to GitHub repository
# variables — never to a file in git.
#
# --dry-run still READS the project and repo (to render an accurate plan); it
# only skips the mutating commands. Otherwise the script is safe to re-run:
# every mutating step is guarded or idempotent.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (design constants — not instance-specific).
# ---------------------------------------------------------------------------
POOL_ID="github"
PROVIDER_ID="iac-gke"
SA_NAME="cluster-ctrl-automation"
REF="refs/heads/main"
LEAST_PRIV_ROLE="roles/serviceusage.serviceUsageViewer"
ISSUER_URI="https://token.actions.githubusercontent.com"

PROJECT_INPUT=""
REPO=""
ACCOUNT=""
ASSUME_YES="false"
DRY_RUN="false"
SKIP_VERIFY="false"
TRIGGER_CI="false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER_DIR="${SCRIPT_DIR}/verifier"

# ---------------------------------------------------------------------------
# Output helpers.
# ---------------------------------------------------------------------------
info() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: setup-keyless-access.sh [options]

Sets up keyless GitHub Actions -> Google Cloud access and verifies it.

Options:
  --project ID_OR_NUMBER   Target Google Cloud project (prompted if omitted).
  --repo OWNER/REPO        GitHub repo to trust (default: the current checkout).
  --account EMAIL          gcloud account to use (overrides the active one for this run).
  --pool-id ID             Workload Identity Pool id (default: github).
  --provider-id ID         OIDC provider id (default: iac-gke).
  --sa-name NAME           Automation service account name (default: cluster-ctrl-automation).
  --ref REF                Single fully-qualified ref allowed to authenticate
                           (default: refs/heads/main; no wildcards).
  --yes                    Do not prompt for confirmation before making changes.
  --dry-run                Resolve inputs and print the mutating commands without
                           running them (still needs read access to project + repo).
  --skip-verify            Do not run setup-doctor afterwards.
  --trigger-ci             Trigger the "Verify keyless access" workflow at the end.
  -h, --help               Show this help.

Prerequisites: gcloud and gh installed and authenticated; Owner (or the IAM/
ServiceUsage admin roles) on the project; python3 for the verification step.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)     PROJECT_INPUT="${2:?--project needs a value}"; shift 2 ;;
    --repo)        REPO="${2:?--repo needs a value}"; shift 2 ;;
    --account)     ACCOUNT="${2:?--account needs a value}"; shift 2 ;;
    --pool-id)     POOL_ID="${2:?}"; shift 2 ;;
    --provider-id) PROVIDER_ID="${2:?}"; shift 2 ;;
    --sa-name)     SA_NAME="${2:?}"; shift 2 ;;
    --ref)         REF="${2:?}"; shift 2 ;;
    --yes)         ASSUME_YES="true"; shift ;;
    --dry-run)     DRY_RUN="true"; shift ;;
    --skip-verify) SKIP_VERIFY="true"; shift ;;
    --trigger-ci)  TRIGGER_CI="true"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1 (try --help)" ;;
  esac
done

# run / run_quiet — execute a MUTATING command, or just print it under --dry-run.
# run_quiet additionally discards the command's stdout on real runs (used for
# verbose calls like add-iam-policy-binding) while preserving the dry-run echo.
# Read-only describe/lookup commands are called directly (they are always safe).
run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '   [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}
run_quiet() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '   [dry-run] %s\n' "$*"
  else
    "$@" >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Preconditions.
# ---------------------------------------------------------------------------
command -v gcloud >/dev/null 2>&1 || die "gcloud is not installed (https://cloud.google.com/sdk)"
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is not installed (https://cli.github.com)"
# --account overrides the active gcloud account for every gcloud call in this run.
[[ -n "${ACCOUNT}" ]] && export CLOUDSDK_CORE_ACCOUNT="${ACCOUNT}"
gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . \
  || die "no active gcloud account; run: gcloud auth login (or pass --account EMAIL)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"
ACTIVE_ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"

# A single, fully-qualified ref only — no wildcards that would widen the trust.
[[ "${REF}" =~ ^refs/(heads|tags)/[^[:space:]*]+$ ]] \
  || die "invalid --ref '${REF}': must be a single fully-qualified ref (e.g. refs/heads/main), no wildcards"

# ---------------------------------------------------------------------------
# Resolve inputs (prompt only when interactive and unset).
# ---------------------------------------------------------------------------
if [[ -z "${PROJECT_INPUT}" ]]; then
  [[ -t 0 ]] || die "no --project given and not interactive"
  read -rp "Google Cloud project (id or number): " PROJECT_INPUT
fi
[[ -n "${PROJECT_INPUT}" ]] || die "a project is required"

info "Resolving project ${PROJECT_INPUT} ..."
# Command substitution (not process substitution) so a gcloud failure aborts the
# parent shell via the `|| die`, even if gcloud prints noise before failing.
proj_line="$(gcloud projects describe "${PROJECT_INPUT}" --format='value(projectId, projectNumber)')" \
  || die "cannot read project '${PROJECT_INPUT}' (does it exist and do you have access?)"
read -r PROJECT_ID PROJECT_NUMBER <<<"${proj_line}"
[[ -n "${PROJECT_ID}" && -n "${PROJECT_NUMBER}" ]] || die "could not resolve project id/number"

if [[ -z "${REPO}" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
    || die "could not detect the repo; pass --repo OWNER/REPO"
fi
GITHUB_ORG="${REPO%%/*}"
info "Reading repository_id for ${REPO} ..."
REPOSITORY_ID="$(gh api "repos/${REPO}" --jq '.id')" \
  || die "could not read repository_id for ${REPO}"
[[ "${REPOSITORY_ID}" =~ ^[0-9]+$ ]] || die "unexpected repository_id: ${REPOSITORY_ID}"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"
PROVIDER_RESOURCE="${POOL_RESOURCE}/providers/${PROVIDER_ID}"
PRINCIPAL_SET="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository_id/${REPOSITORY_ID}"
ATTRIBUTE_MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.repository_id=assertion.repository_id,attribute.ref=assertion.ref"
ATTRIBUTE_CONDITION="assertion.repository_id == '${REPOSITORY_ID}' && assertion.ref == '${REF}'"

# ---------------------------------------------------------------------------
# Plan + confirmation.
# ---------------------------------------------------------------------------
plan_label=""
[[ "${DRY_RUN}" == "true" ]] && plan_label=" (dry-run)"
cat <<EOF

Plan${plan_label}:
  Active account : ${ACTIVE_ACCOUNT}
  Project        : ${PROJECT_ID} (${PROJECT_NUMBER})
  Repository     : ${REPO} (repository_id ${REPOSITORY_ID})
  Pool/Provider  : ${POOL_ID} / ${PROVIDER_ID}
  Service account: ${SA_EMAIL}
  Least-priv role: ${LEAST_PRIV_ROLE}
  Trust pinned to: repository_id == ${REPOSITORY_ID} && ref == ${REF}

This will: enable APIs; create the WIF pool + OIDC provider; create the service
account and grant it the least-privilege role; allow only this repo to
impersonate it; and set the repository variables the CI workflow reads.
EOF

if [[ "${ASSUME_YES}" != "true" && "${DRY_RUN}" != "true" ]]; then
  [[ -t 0 ]] || die "refusing to proceed non-interactively without --yes"
  read -rp "Proceed? [y/N] " reply || reply=""
  [[ "${reply}" =~ ^[Yy]$ ]] || die "aborted"
fi

# ---------------------------------------------------------------------------
# Step 1 — Enable required APIs (idempotent).
# ---------------------------------------------------------------------------
info "Enabling required APIs ..."
run gcloud services enable \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  cloudresourcemanager.googleapis.com serviceusage.googleapis.com \
  --project="${PROJECT_ID}"

# ---------------------------------------------------------------------------
# Step 2 — Workload Identity Pool (create-or-keep).
# ---------------------------------------------------------------------------
if gcloud iam workload-identity-pools describe "${POOL_ID}" \
     --project="${PROJECT_ID}" --location="global" >/dev/null 2>&1; then
  ok "pool ${POOL_ID} already exists"
else
  info "Creating workload identity pool ${POOL_ID} ..."
  run gcloud iam workload-identity-pools create "${POOL_ID}" \
    --project="${PROJECT_ID}" --location="global" \
    --display-name="GitHub Actions Pool"
fi

# ---------------------------------------------------------------------------
# Step 3 — OIDC provider, pinned to repository_id + ref (create or update).
# ---------------------------------------------------------------------------
if gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
     --project="${PROJECT_ID}" --location="global" \
     --workload-identity-pool="${POOL_ID}" >/dev/null 2>&1; then
  # The issuer is the root of the OIDC trust and cannot be changed on an existing
  # provider, so re-running cannot "fix" a wrong issuer — fail loudly instead.
  existing_issuer="$(gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" --location="global" --workload-identity-pool="${POOL_ID}" \
    --format='value(oidc.issuerUri)')"
  if [[ "${existing_issuer}" != "${ISSUER_URI}" ]]; then
    die "provider ${PROVIDER_ID} already exists with issuer '${existing_issuer}', expected '${ISSUER_URI}'. gcloud cannot change a provider's issuer; delete and recreate it (see Teardown in the runbook)."
  fi
  info "Updating OIDC provider ${PROVIDER_ID} (mapping + condition) ..."
  run gcloud iam workload-identity-pools providers update-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --attribute-mapping="${ATTRIBUTE_MAPPING}" \
    --attribute-condition="${ATTRIBUTE_CONDITION}"
else
  info "Creating OIDC provider ${PROVIDER_ID} ..."
  run gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub OIDC" \
    --issuer-uri="${ISSUER_URI}" \
    --attribute-mapping="${ATTRIBUTE_MAPPING}" \
    --attribute-condition="${ATTRIBUTE_CONDITION}"
fi

# ---------------------------------------------------------------------------
# Step 4 — Automation service account + least privilege + impersonation.
# ---------------------------------------------------------------------------
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  ok "service account ${SA_EMAIL} already exists"
else
  info "Creating service account ${SA_NAME} ..."
  run gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="cluster-ctrl automation (Milestone 0)"
fi

info "Granting least-privilege role ${LEAST_PRIV_ROLE} ..."
run_quiet gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --role="${LEAST_PRIV_ROLE}" \
  --member="serviceAccount:${SA_EMAIL}" --condition=None

info "Allowing only ${REPO} (by repository_id) to impersonate the service account ..."
run_quiet gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="${PRINCIPAL_SET}" --condition=None

# ---------------------------------------------------------------------------
# Step 5 — Publish GitHub repository variables for the CI workflow.
# ---------------------------------------------------------------------------
info "Setting GitHub repository variables on ${REPO} ..."
run gh variable set WIF_PROVIDER        --repo "${REPO}" --body "${PROVIDER_RESOURCE}"
run gh variable set WIF_SERVICE_ACCOUNT --repo "${REPO}" --body "${SA_EMAIL}"
run gh variable set GCP_PROJECT_NUMBER  --repo "${REPO}" --body "${PROJECT_NUMBER}"
run gh variable set GCP_PROJECT_ID      --repo "${REPO}" --body "${PROJECT_ID}"

ok "Setup complete."

# ---------------------------------------------------------------------------
# Step 6 — Verify with setup-doctor (full audit, operator credentials).
# ---------------------------------------------------------------------------
if [[ "${SKIP_VERIFY}" == "true" || "${DRY_RUN}" == "true" ]]; then
  warn "Skipping verification (--skip-verify or --dry-run)."
elif ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  warn "Application Default Credentials not found — skipping verification."
  warn "Run 'gcloud auth application-default login', then re-run this script."
else
  info "Verifying setup with setup-doctor ..."
  [[ -d "${VERIFIER_DIR}/.venv" ]] || python3 -m venv "${VERIFIER_DIR}/.venv"
  # shellcheck source=/dev/null
  . "${VERIFIER_DIR}/.venv/bin/activate"
  # Install from the pinned lock (same as CI) so local and CI runs match.
  python -m pip install --quiet -r "${VERIFIER_DIR}/requirements.lock"
  python -m pip install --quiet -e "${VERIFIER_DIR}" --no-deps
  verify_status=0
  SETUP_DOCTOR_PROJECT_NUMBER="${PROJECT_NUMBER}" \
  SETUP_DOCTOR_PROJECT_ID="${PROJECT_ID}" \
  SETUP_DOCTOR_POOL_ID="${POOL_ID}" \
  SETUP_DOCTOR_PROVIDER_ID="${PROVIDER_ID}" \
  SETUP_DOCTOR_SERVICE_ACCOUNT="${SA_EMAIL}" \
  SETUP_DOCTOR_REPOSITORY_ID="${REPOSITORY_ID}" \
  SETUP_DOCTOR_REF="${REF}" \
  SETUP_DOCTOR_EXPECTED_ROLES="${LEAST_PRIV_ROLE}" \
    setup-doctor || verify_status=$?
  deactivate
  [[ "${verify_status}" -eq 0 ]] \
    || die "setup-doctor reported problems (the setup itself completed; see the checks above)"
fi

# ---------------------------------------------------------------------------
# Step 7 — Demonstrate in CI.
# ---------------------------------------------------------------------------
if [[ "${TRIGGER_CI}" == "true" && "${DRY_RUN}" != "true" ]]; then
  info "Triggering the CI workflow ..."
  run gh workflow run "Verify keyless access" --repo "${REPO}"
  info "Watch it with: gh run watch --repo ${REPO}"
else
  cat <<EOF

Next: demonstrate keyless access in CI:
  gh workflow run "Verify keyless access" --repo ${REPO}
  gh run watch --repo ${REPO}
EOF
fi
