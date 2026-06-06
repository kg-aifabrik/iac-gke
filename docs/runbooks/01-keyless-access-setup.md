# Runbook 01 — One-time keyless access setup

**Goal:** let this repository's GitHub Actions automation authenticate to a
specific Google Cloud project **with no downloadable keys**, using Workload
Identity Federation (WIF), and prove it with `setup-doctor`.

This is **Milestone 0** of cluster-ctrl: the trust anchor every later milestone
builds on. It is a *one-time, human-run* setup — by design it creates the
identities the automation later uses, so it cannot be automated by that
automation.

> Run each step once, in order. Every command is **idempotent** — re-running the
> whole runbook is safe and makes no changes if everything is already in place.
>
> **Recommended:** run [`bootstrap/setup-keyless-access.sh`](../../bootstrap/setup-keyless-access.sh)
> instead of copy-pasting. It prompts for the inputs, runs every step below
> idempotently, publishes the GitHub repository variables, and verifies with
> `setup-doctor`. The steps below document exactly what the script does.

---

## Decisions baked into this runbook (the *why*)

- **Service-account impersonation, not direct WIF.** Google's default is
  "direct" WIF (roles bound straight to the repo). We impersonate a
  least-privilege **automation service account** instead, because (a) federated
  tokens cap at ~10 minutes — too short for real Terraform cluster builds —
  while an impersonated SA token lasts up to an hour, and (b) a per-environment
  SA is the natural "identity" requirement **FND-4** calls for.
- **Pin the OIDC trust on the immutable `repository_id`, plus the `ref`.** The
  attribute condition trusts `repository_id == 1260827836` **and**
  `ref == refs/heads/main`. `repository_id` is globally unique and immutable
  (survives repo rename/transfer — so moving this repo to an organization later
  needs **no** Google Cloud change), which is stronger than the mutable,
  reclaimable repo *name*. The `ref` condition means only the `main` branch can
  authenticate.
- **Least privilege.** The automation SA gets exactly one benign read role for
  Milestone 0 (`roles/serviceusage.serviceUsageViewer`) — never Owner/Editor.
- **No secrets anywhere.** WIF means there is no key to download, store, or
  rotate.

---

## Prerequisites

- The [`gcloud` CLI](https://cloud.google.com/sdk/docs/install) and the
  [`gh` CLI](https://cli.github.com/), both authenticated
  (`gcloud auth login`, `gh auth login`).
- On the target project, your user needs **Owner**, or these admin roles:
  `roles/serviceusage.serviceUsageAdmin`, `roles/iam.workloadIdentityPoolAdmin`,
  `roles/iam.serviceAccountAdmin`, `roles/resourcemanager.projectIamAdmin`.
- Billing is enabled on the project.

---

## Step 0 — Set parameters

```bash
# Provide your dev project (id or number); everything else is derived.
read -rp "Google Cloud project (id or number): " PROJECT
read -r PROJECT_ID PROJECT_NUMBER < <(
  gcloud projects describe "${PROJECT}" --format='value(projectId, projectNumber)')

# Repository details, derived from the checkout — no hard-coded ids.
export REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
export GITHUB_ORG="${REPO%%/*}"
export REPOSITORY_ID="$(gh api "repos/${REPO}" --jq .id)"  # immutable; survives rename/transfer

export POOL_ID="github"
export PROVIDER_ID="iac-gke"
export SA_NAME="cluster-ctrl-automation"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
export REF="refs/heads/main"

echo "Project: ${PROJECT_ID} (${PROJECT_NUMBER}) | Repo: ${REPO} (id ${REPOSITORY_ID})"
```

## Step 1 — Enable required APIs (idempotent)

```bash
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  --project="${PROJECT_ID}"
```

## Step 2 — Create the Workload Identity Pool (idempotent)

```bash
if ! gcloud iam workload-identity-pools describe "${POOL_ID}" \
      --project="${PROJECT_ID}" --location="global" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --project="${PROJECT_ID}" --location="global" \
    --display-name="GitHub Actions Pool"
fi

# Fully-qualified pool name, used in the principalSet member below.
export WORKLOAD_IDENTITY_POOL_ID="$(gcloud iam workload-identity-pools describe "${POOL_ID}" \
  --project="${PROJECT_ID}" --location="global" --format='value(name)')"
# -> projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github
```

## Step 3 — Create the OIDC provider, pinned to this repo and branch (idempotent)

> **This is the security-critical step.** The attribute condition is the trust
> boundary: GitHub uses one OIDC issuer for *every* repository on github.com, so
> without a condition any repository could authenticate. We pin the immutable
> `repository_id` **and** the `ref`. Every claim used in the condition must also
> be in the attribute mapping.

```bash
ATTRIBUTE_MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.repository_id=assertion.repository_id,attribute.ref=assertion.ref"
ATTRIBUTE_CONDITION="assertion.repository_id == '${REPOSITORY_ID}' && assertion.ref == '${REF}'"

if ! gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
      --project="${PROJECT_ID}" --location="global" \
      --workload-identity-pool="${POOL_ID}" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub OIDC (${REPO})" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="${ATTRIBUTE_MAPPING}" \
    --attribute-condition="${ATTRIBUTE_CONDITION}"
else
  # Keep an existing provider's mapping/condition in sync (idempotent update).
  gcloud iam workload-identity-pools providers update-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --attribute-mapping="${ATTRIBUTE_MAPPING}" \
    --attribute-condition="${ATTRIBUTE_CONDITION}"
fi
```

## Step 4 — Create the automation service account and grant least privilege (idempotent)

```bash
# Create the SA (ignore "already exists").
gcloud iam service-accounts create "${SA_NAME}" \
  --project="${PROJECT_ID}" \
  --display-name="cluster-ctrl automation (Milestone 0)" 2>/dev/null || true

# Milestone 0 needs only a benign read role to prove connectivity.
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --role="roles/serviceusage.serviceUsageViewer" \
  --member="serviceAccount:${SA_EMAIL}" >/dev/null

# Allow ONLY tokens from this repo (by immutable repository_id) to impersonate the SA.
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${WORKLOAD_IDENTITY_POOL_ID}/attribute.repository_id/${REPOSITORY_ID}" >/dev/null
```

## Step 5 — Publish the values to GitHub repository variables (idempotent)

The CI workflow reads these (no project-specific values are hard-coded in the repo).

```bash
gh variable set WIF_PROVIDER       --repo "${REPO}" --body "${WORKLOAD_IDENTITY_POOL_ID}/providers/${PROVIDER_ID}"
gh variable set WIF_SERVICE_ACCOUNT --repo "${REPO}" --body "${SA_EMAIL}"
gh variable set GCP_PROJECT_NUMBER  --repo "${REPO}" --body "${PROJECT_NUMBER}"
gh variable set GCP_PROJECT_ID      --repo "${REPO}" --body "${PROJECT_ID}"
```

## Step 6 — Verify locally (full audit, with your operator credentials)

```bash
gcloud auth application-default login   # if not already done

cd bootstrap/verifier
python3 -m venv .venv && . .venv/bin/activate
pip install -e .

export SETUP_DOCTOR_PROJECT_NUMBER="${PROJECT_NUMBER}"
export SETUP_DOCTOR_PROJECT_ID="${PROJECT_ID}"
export SETUP_DOCTOR_POOL_ID="${POOL_ID}"
export SETUP_DOCTOR_PROVIDER_ID="${PROVIDER_ID}"
export SETUP_DOCTOR_SERVICE_ACCOUNT="${SA_EMAIL}"
export SETUP_DOCTOR_REPOSITORY_ID="${REPOSITORY_ID}"
export SETUP_DOCTOR_REF="${REF}"
export SETUP_DOCTOR_EXPECTED_ROLES="roles/serviceusage.serviceUsageViewer"
# (Leave SETUP_DOCTOR_EXPECTED_IDENTITY unset locally — your operator identity
#  is reported, not asserted.)

setup-doctor
```

Expect every check **PASS** (your operator credentials can read the WIF provider
and IAM policy, so the structural checks run in full).

## Step 7 — Demonstrate keyless access in CI

Trigger the workflow (or push a change under `bootstrap/verifier/`):

```bash
gh workflow run "Verify keyless access" --repo "${REPO}"
gh run watch --repo "${REPO}"
```

A **green run** is Milestone 0 done: GitHub Actions authenticated to the project
with no stored secret, and `setup-doctor` confirmed identity + live API access.
In CI the SA is least-privilege, so the operator-only structural checks report
**SKIP** while identity and live-API checks **PASS** — that is the expected,
correct result.

---

## Teardown (to re-test from scratch)

```bash
gcloud iam workload-identity-pools providers delete "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" --location="global" --workload-identity-pool="${POOL_ID}" --quiet
gcloud iam workload-identity-pools delete "${POOL_ID}" \
  --project="${PROJECT_ID}" --location="global" --quiet
gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet
```

> Pools/providers are *soft-deleted* (recoverable for ~30 days); re-creating
> with the same id within that window restores rather than duplicates.

## If you move this repo to an organization later

Because the trust is pinned on the immutable `repository_id` (not the name),
the transfer needs **no Google Cloud change**. After transferring: update your
local git remote, and re-set the `WIF_*`/`GCP_*` repository variables on the
new location (Step 5). That's it.
