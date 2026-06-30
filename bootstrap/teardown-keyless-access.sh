#!/usr/bin/env bash
#
# teardown-keyless-access.sh — idempotent teardown of the keyless GitHub Actions
# -> Google Cloud access created by setup-keyless-access.sh.
#
# It removes the Workload Identity Federation (WIF) pool + OIDC provider and the
# automation service account, so the repository can no longer authenticate to
# the project. Use it to re-test the setup from scratch, or to revoke access.
#
# What it deliberately does NOT do:
#   * It never disables Google Cloud APIs (Step 1 of setup). Other resources and
#     later milestones depend on them and re-enabling is free, so leaving them
#     enabled is the safe choice — mirrors the runbook's documented teardown.
#   * It leaves the GitHub repository variables in place unless you pass
#     --clear-variables. GCP_PROJECT_ID / GCP_PROJECT_NUMBER are reused by later
#     work; only WIF_PROVIDER and WIF_SERVICE_ACCOUNT are access-specific, and
#     those two are what --clear-variables removes.
#
# Every step is idempotent: a resource that is already gone (or already
# soft-deleted) is skipped, not treated as an error — so the script is safe to
# re-run. --dry-run still READS the project (to render an accurate plan); it only
# skips the mutating commands.
#
# The matching setup and the rationale for each resource are documented in
# docs/runbooks/01-keyless-access-setup.md.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (design constants — must match setup-keyless-access.sh).
# ---------------------------------------------------------------------------
POOL_ID="github"
PROVIDER_ID="iac-gke"
SA_NAME="cluster-ctrl-automation"
LEAST_PRIV_ROLE="roles/serviceusage.serviceUsageViewer"

PROJECT_INPUT=""
REPO=""
ACCOUNT=""
ASSUME_YES="false"
DRY_RUN="false"
CLEAR_VARIABLES="false"

# ---------------------------------------------------------------------------
# Output helpers.
# ---------------------------------------------------------------------------
info() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: teardown-keyless-access.sh [options]

Removes the keyless GitHub Actions -> Google Cloud access (WIF pool + provider
and the automation service account). Idempotent and safe to re-run.

Options:
  --project ID_OR_NUMBER   Target Google Cloud project (prompted if omitted).
  --repo OWNER/REPO        GitHub repo whose variables to clear (only needed with
                           --clear-variables; default: the current checkout).
  --account EMAIL          gcloud account to use (overrides the active one for this run).
  --pool-id ID             Workload Identity Pool id (default: github).
  --provider-id ID         OIDC provider id (default: iac-gke).
  --sa-name NAME           Automation service account name (default: cluster-ctrl-automation).
  --clear-variables        Also remove the access-specific repo variables
                           (WIF_PROVIDER, WIF_SERVICE_ACCOUNT). Leaves
                           GCP_PROJECT_ID / GCP_PROJECT_NUMBER untouched.
  --yes                    Do not prompt for confirmation before deleting.
  --dry-run                Resolve inputs and print the mutating commands without
                           running them (still needs read access to the project).
  -h, --help               Show this help.

Note: enabled APIs are never disabled. WIF pools and providers are soft-deleted
and recoverable for ~30 days; re-creating with the same id restores them.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)         PROJECT_INPUT="${2:?--project needs a value}"; shift 2 ;;
    --repo)            REPO="${2:?--repo needs a value}"; shift 2 ;;
    --account)         ACCOUNT="${2:?--account needs a value}"; shift 2 ;;
    --pool-id)         POOL_ID="${2:?}"; shift 2 ;;
    --provider-id)     PROVIDER_ID="${2:?}"; shift 2 ;;
    --sa-name)         SA_NAME="${2:?}"; shift 2 ;;
    --clear-variables) CLEAR_VARIABLES="true"; shift ;;
    --yes)             ASSUME_YES="true"; shift ;;
    --dry-run)         DRY_RUN="true"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "unknown option: $1 (try --help)" ;;
  esac
done

# run / run_quiet — execute a MUTATING command, or just print it under --dry-run.
# run_quiet additionally discards stdout on real runs (for verbose IAM calls).
# Read-only describe/lookup commands are called directly (always safe).
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
# --account overrides the active gcloud account for every gcloud call in this run.
[[ -n "${ACCOUNT}" ]] && export CLOUDSDK_CORE_ACCOUNT="${ACCOUNT}"
gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . \
  || die "no active gcloud account; run: gcloud auth login (or pass --account EMAIL)"
ACTIVE_ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"

# gh is needed only when we are clearing repository variables.
if [[ "${CLEAR_VARIABLES}" == "true" ]]; then
  command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is not installed (https://cli.github.com)"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"
fi

# ---------------------------------------------------------------------------
# Resolve inputs (prompt only when interactive and unset).
# ---------------------------------------------------------------------------
if [[ -z "${PROJECT_INPUT}" ]]; then
  [[ -t 0 ]] || die "no --project given and not interactive"
  read -rp "Google Cloud project (id or number): " PROJECT_INPUT
fi
[[ -n "${PROJECT_INPUT}" ]] || die "a project is required"

info "Resolving project ${PROJECT_INPUT} ..."
proj_line="$(gcloud projects describe "${PROJECT_INPUT}" --format='value(projectId, projectNumber)')" \
  || die "cannot read project '${PROJECT_INPUT}' (does it exist and do you have access?)"
read -r PROJECT_ID PROJECT_NUMBER <<<"${proj_line}"
[[ -n "${PROJECT_ID}" ]] || die "could not resolve project id"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Only need the repo (for --clear-variables); teardown otherwise deletes by name.
if [[ "${CLEAR_VARIABLES}" == "true" && -z "${REPO}" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
    || die "could not detect the repo for --clear-variables; pass --repo OWNER/REPO"
fi

# ---------------------------------------------------------------------------
# Plan + confirmation.
# ---------------------------------------------------------------------------
plan_label=""
[[ "${DRY_RUN}" == "true" ]] && plan_label=" (dry-run)"
clear_vars_line="no"
[[ "${CLEAR_VARIABLES}" == "true" ]] && clear_vars_line="yes — WIF_PROVIDER, WIF_SERVICE_ACCOUNT on ${REPO}"
cat <<EOF

Plan${plan_label}:
  Active account : ${ACTIVE_ACCOUNT}
  Project        : ${PROJECT_ID} (${PROJECT_NUMBER})
  Pool/Provider  : ${POOL_ID} / ${PROVIDER_ID}
  Service account: ${SA_EMAIL}
  Clear variables: ${clear_vars_line}

This will DELETE the WIF OIDC provider, the WIF pool, and the automation service
account (first removing its project role binding). Enabled APIs are left
untouched. WIF pools and providers are soft-deleted and recoverable for ~30 days.
EOF

if [[ "${ASSUME_YES}" != "true" && "${DRY_RUN}" != "true" ]]; then
  [[ -t 0 ]] || die "refusing to proceed non-interactively without --yes"
  read -rp "Proceed with teardown? [y/N] " reply || reply=""
  [[ "${reply}" =~ ^[Yy]$ ]] || die "aborted"
fi

# ---------------------------------------------------------------------------
# Step 1 — Clear access-specific repository variables (opt-in).
# ---------------------------------------------------------------------------
if [[ "${CLEAR_VARIABLES}" == "true" ]]; then
  info "Removing access-specific repository variables on ${REPO} ..."
  # `gh variable list` prints the name in column 1 (no header in non-TTY/script
  # use), so this existence check is robust across gh versions — no `get`/`--json`.
  existing_vars="$(gh variable list --repo "${REPO}" 2>/dev/null | awk '{print $1}' || true)"
  for var in WIF_PROVIDER WIF_SERVICE_ACCOUNT; do
    if grep -qx "${var}" <<<"${existing_vars}"; then
      run gh variable delete "${var}" --repo "${REPO}"
    else
      ok "variable ${var} not set"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Step 2 — Delete the OIDC provider (before the pool that contains it).
# A soft-deleted provider reports state DELETED, so we gate on the state rather
# than mere existence to stay idempotent across the ~30-day recovery window.
# ---------------------------------------------------------------------------
provider_state="$(gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" --location="global" --workload-identity-pool="${POOL_ID}" \
  --format='value(state)' 2>/dev/null || true)"
case "${provider_state}" in
  ACTIVE)
    info "Deleting OIDC provider ${PROVIDER_ID} ..."
    run gcloud iam workload-identity-pools providers delete "${PROVIDER_ID}" \
      --project="${PROJECT_ID}" --location="global" \
      --workload-identity-pool="${POOL_ID}" --quiet ;;
  DELETED) ok "provider ${PROVIDER_ID} already soft-deleted" ;;
  *)       ok "provider ${PROVIDER_ID} not found" ;;
esac

# ---------------------------------------------------------------------------
# Step 3 — Delete the Workload Identity Pool.
# ---------------------------------------------------------------------------
pool_state="$(gcloud iam workload-identity-pools describe "${POOL_ID}" \
  --project="${PROJECT_ID}" --location="global" \
  --format='value(state)' 2>/dev/null || true)"
case "${pool_state}" in
  ACTIVE)
    info "Deleting workload identity pool ${POOL_ID} ..."
    run gcloud iam workload-identity-pools delete "${POOL_ID}" \
      --project="${PROJECT_ID}" --location="global" --quiet ;;
  DELETED) ok "pool ${POOL_ID} already soft-deleted" ;;
  *)       ok "pool ${POOL_ID} not found" ;;
esac

# ---------------------------------------------------------------------------
# Step 4 — Automation service account (remove its role binding, then delete it).
# Deleting the SA also drops the workloadIdentityUser binding on the SA itself,
# so only the project-level role binding needs explicit removal — and we do that
# while the member still resolves to the live SA, to avoid leaving a dangling
# `deleted:serviceAccount:...?uid=...` binding in the project policy.
# ---------------------------------------------------------------------------
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  if gcloud projects get-iam-policy "${PROJECT_ID}" \
       --flatten="bindings[].members" \
       --filter="bindings.role=${LEAST_PRIV_ROLE} AND bindings.members:serviceAccount:${SA_EMAIL}" \
       --format='value(bindings.role)' 2>/dev/null | grep -q .; then
    info "Removing ${LEAST_PRIV_ROLE} from ${SA_EMAIL} ..."
    run_quiet gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
      --role="${LEAST_PRIV_ROLE}" \
      --member="serviceAccount:${SA_EMAIL}" --condition=None
  else
    ok "no ${LEAST_PRIV_ROLE} binding for ${SA_EMAIL}"
  fi
  info "Deleting service account ${SA_EMAIL} ..."
  run gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet
else
  ok "service account ${SA_EMAIL} not found"
fi

ok "Teardown complete."
cat <<EOF

The repository can no longer authenticate to ${PROJECT_ID}.
Re-run bootstrap/setup-keyless-access.sh to set the access back up.
EOF
