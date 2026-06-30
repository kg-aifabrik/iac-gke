# Runbook 01 — One-time keyless access setup

This runbook walks you through a one-time setup. By the end, this repository's
GitHub Actions automation can sign in to one Google Cloud project and run
commands there — without any downloadable keys. It uses Workload Identity
Federation (WIF), and `setup-doctor` is used to verify the WIF is set up
correctly.

You run this by hand, once. It has to be human-run: it creates the very identity
the automation uses later, so the automation can't create it for itself.
Everything that follows depends on the trust it sets up here.

Each step is **idempotent** — running it again changes nothing if everything is
already in place. So it is safe to re-run the whole runbook at any time.

> **The easy path:** run [`bootstrap/setup-keyless-access.sh`](../../bootstrap/setup-keyless-access.sh)
> instead of copy-pasting the steps. It asks for your inputs, runs every step
> below, publishes the GitHub repository variables, and finishes by verifying
> with `setup-doctor`. The steps below explain exactly what that script does, so
> read on if you want to understand it or run it by hand.

---

## Before you start — confirm the prerequisites

You need a few things in place first. Please run the commands below to confirm
each one before you go any further.

**1. The `gcloud` and `gh` command-line tools, both signed in.**

```bash
gcloud auth login            # sign in with your aifabrik.com account
gh auth status               # should say you are logged in to github.com
```

Don't have them installed yet? On macOS the quickest way is Homebrew:

```bash
brew install --cask google-cloud-sdk   # the gcloud CLI
brew install gh                         # the GitHub CLI
```

For other platforms, follow the official guides —
[install gcloud](https://cloud.google.com/sdk/docs/install) and
[install gh](https://github.com/cli/cli#installation) — then run the two sign-in
commands above.

**2. The right roles on the target project.** Your user needs **Owner**, or all
of these admin roles:

- `roles/serviceusage.serviceUsageAdmin` — turn Google Cloud APIs on and off
  (used in Step 1).
- `roles/iam.workloadIdentityPoolAdmin` — create the Workload Identity Pool and
  the OIDC provider (Steps 2–3).
- `roles/iam.serviceAccountAdmin` — create the automation service account and set
  who is allowed to impersonate it (Step 4).
- `roles/resourcemanager.projectIamAdmin` — grant that service account its role
  on the project (Step 4).

Check what you already have:

```bash
# Replace <PROJECT_ID> and <you@aifabrik.com> with your values.
gcloud projects get-iam-policy <PROJECT_ID> \
  --flatten="bindings[].members" \
  --filter="bindings.members:<you@aifabrik.com>" \
  --format="table(bindings.role)"
```

**3. Billing is enabled on the project.**

```bash
gcloud beta billing projects describe <PROJECT_ID> \
  --format='value(billingEnabled)'        # should print: True
```

Once all three check out, continue.

---

## The decisions behind this runbook (the *why*)

A few choices are baked into the steps below. Here is the reasoning, so the
commands aren't a black box.

- **We impersonate a service account instead of using direct WIF.** Google's
  default is "direct" WIF, where roles are bound straight to the repository. We
  don't do that. Instead the repository impersonates a least-privilege
  **automation service account**. Two reasons: federated tokens expire in about
  10 minutes, which is too short for a real Terraform cluster build, while an
  impersonated service-account token lasts up to an hour; and a per-environment
  service account gives the automation a clear, dedicated identity of its own.
- **We pin trust to the immutable `repository_id`, plus the branch.** The trust
  condition requires `repository_id == 1260827836` (the current id of this
  repository) **and** `ref == refs/heads/main`. The `repository_id` is globally
  unique and never
  changes — it survives a repo rename or transfer, so moving this repo into an
  organization later needs no change on the Google Cloud side. That is stronger
  than trusting the repo *name*, which can change and be reclaimed. The `ref`
  condition means only the `main` branch can sign in.
- **Least privilege.** To start, the automation service account gets exactly one
  harmless read-only role (`roles/serviceusage.serviceUsageViewer`). Never Owner
  or Editor.
- **No secrets anywhere.** With WIF there is no key to download, store, or
  rotate.

---

## Step 0 — Set your parameters

Give it your dev project; everything else is worked out from there.

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

## Step 1 — Enable the required APIs

This turns on the Google Cloud services the later steps depend on. Safe to
re-run.

```bash
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  --project="${PROJECT_ID}"
```

## Step 2 — Create the Workload Identity Pool

The pool is the container that will hold the trust relationship with GitHub. We
create it only if it isn't there already.

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

## Step 3 — Create the OIDC provider, pinned to this repo and branch

This is the security-critical step. GitHub uses one OIDC issuer for *every*
repository on github.com. Without a condition, any repository on github.com
could sign in to your project. The attribute condition is the trust boundary
that stops that: we pin it to the immutable `repository_id` **and** the `ref`.
Every claim used in the condition must also appear in the attribute mapping.

We create the provider if it's missing, or update an existing one so its mapping
and condition stay in sync.

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

## Step 4 — Create the automation service account and grant least privilege

Now create the identity the automation will impersonate, give it the one read-only
role it needs to start, and allow only this repository to impersonate it.

```bash
# Create the SA (ignore "already exists").
gcloud iam service-accounts create "${SA_NAME}" \
  --project="${PROJECT_ID}" \
  --display-name="cluster-ctrl automation (Milestone 0)" 2>/dev/null || true

# A benign read-only role — just enough to prove connectivity.
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --role="roles/serviceusage.serviceUsageViewer" \
  --member="serviceAccount:${SA_EMAIL}" >/dev/null

# Allow ONLY tokens from this repo (by immutable repository_id) to impersonate the SA.
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${WORKLOAD_IDENTITY_POOL_ID}/attribute.repository_id/${REPOSITORY_ID}" >/dev/null
```

## Step 5 — Publish the values to GitHub repository variables

The CI workflow reads these variables at run time, so no project-specific values
are hard-coded in the repo.

```bash
gh variable set WIF_PROVIDER       --repo "${REPO}" --body "${WORKLOAD_IDENTITY_POOL_ID}/providers/${PROVIDER_ID}"
gh variable set WIF_SERVICE_ACCOUNT --repo "${REPO}" --body "${SA_EMAIL}"
gh variable set GCP_PROJECT_NUMBER  --repo "${REPO}" --body "${PROJECT_NUMBER}"
gh variable set GCP_PROJECT_ID      --repo "${REPO}" --body "${PROJECT_ID}"
```

## Step 6 — Verify locally with your operator credentials

Run `setup-doctor` yourself, signed in as the operator. Because your account can
read the WIF provider and the IAM policy, the structural checks run in full.

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

Every check should report **PASS**. If `setup-doctor` shows a 403 instead, it is
almost always because your local Application Default Credentials point at the
wrong account — re-run `gcloud auth application-default login` and sign in as the
operator that has access to the project.

## Step 7 — Demonstrate keyless access in CI

Now prove it works from GitHub Actions. Trigger the workflow (or push a change
under `bootstrap/verifier/`):

```bash
gh workflow run "Verify keyless access" --repo "${REPO}"
gh run watch --repo "${REPO}"
```

A **green run** means the setup is complete: GitHub Actions signed in to the
project with no stored secret, and `setup-doctor` confirmed both the identity and
live API access. In CI the service account is least-privilege, so the
operator-only structural checks report **SKIP** while the identity and live-API
checks **PASS**. That mix is the correct, expected result.

---

## Teardown (to re-test from scratch, or to revoke access)

**The easy path:** run [`bootstrap/teardown-keyless-access.sh`](../../bootstrap/teardown-keyless-access.sh).
It deletes the OIDC provider, the pool, and the service account (removing its
role binding first). It is idempotent — anything already gone is skipped — and it
prompts before deleting.

```bash
./bootstrap/teardown-keyless-access.sh --project <PROJECT_ID>
# --clear-variables  also remove the WIF_PROVIDER and WIF_SERVICE_ACCOUNT repo variables
# --dry-run          preview the commands without running them
# --yes              skip the confirmation prompt
```

It never disables APIs (other work depends on them) and leaves `GCP_PROJECT_ID`
and `GCP_PROJECT_NUMBER` in place, since later steps reuse them.

To do it by hand instead:

```bash
gcloud iam workload-identity-pools providers delete "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" --location="global" --workload-identity-pool="${POOL_ID}" --quiet
gcloud iam workload-identity-pools delete "${POOL_ID}" \
  --project="${PROJECT_ID}" --location="global" --quiet
gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet
```

> Pools and providers are *soft-deleted* — recoverable for about 30 days.
> Re-creating one with the same id inside that window restores it rather than
> making a duplicate.

## If you move this repo to an organization later

The trust is pinned to the immutable `repository_id`, not the repo name, so the
transfer needs **no change on Google Cloud**. After transferring: update your
local git remote, and re-set the `WIF_*` and `GCP_*` repository variables on the
new location (Step 5). That's all.
