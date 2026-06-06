# Runbook — Milestone 1 bring-up (build, verify, tear down the dev cluster)

Ordered, copy-paste steps to build the dev Fleet-Operations-Plane (FOP) cluster through
the pipeline, verify its controls and workloads, and tear it down. Assumes Milestone 0
(keyless access) is done: [`01-keyless-access-setup.md`](01-keyless-access-setup.md).

Legend: 🧑 = needs you (a real account / `gcloud`); 🤖 = Claude can do it from `gh`/repo.

---

## 1. Bootstrap the build foundation 🧑 (one-time, `gcloud`)

Grants the automation its build powers and creates the Terraform state bucket. Human-run
because it elevates the identity that the automation then uses (it can't grant itself).

```bash
./bootstrap/setup-build-foundation.sh --project <DEV_PROJECT_ID> --account <you@aifabrik.com>
# Creates gs://<DEV_PROJECT_ID>-tf-state (versioned) and elevates the M0 automation SA
# to the least-privilege build role set. Re-run safe (idempotent).
```

Then re-sync the M0 verifier's expected roles to the new set (so `verify-access` stays green):
edit `.github/workflows/verify-access.yml` → `SETUP_DOCTOR_EXPECTED_ROLES` to the **build
roles** (see the bootstrap section of [`../implementation/cluster-build.md`](../implementation/cluster-build.md))
**plus `roles/gkehub.gatewayEditor` and `roles/gkehub.viewer`** — the access module also grants
those to the automation SA, so the exact-match check would otherwise flag them as extra.

## 2. GitHub gate + variables 🤖 (needs your identities)

The approval gate is a GitHub Environment named `dev` whose required reviewers are the SRE
approvers. Set it and the repo variables (Claude can run these once you provide the values):

```bash
# Repo variables
gh variable set GCP_REGION --body "us-central1"
gh variable set SRE_OPERATOR_MEMBERS --body '["group:sre@aifabrik.com"]'   # real members

# Environment 'dev' with required reviewers (repeat the reviewer line per approver)
reviewer_id=$(gh api users/<github-login> --jq .id)
gh api --method PUT "repos/{owner}/{repo}/environments/dev" \
  -F "reviewers[][type]=User" -F "reviewers[][id]=${reviewer_id}"
```

`GCP_PROJECT_ID`, `GCP_PROJECT_NUMBER`, `WIF_PROVIDER`, `WIF_SERVICE_ACCOUNT` already exist
from Milestone 0.

## 3. Build the foundation root 🤖 (dispatch, gated)

```bash
gh workflow run terraform-apply.yml -f root=foundation
# Approve the run in the 'dev' Environment when prompted. Creates services, the KMS key +
# the two CMEK grants, and the node service account.
```

## 4. Build the cluster 🤖 (PR for the plan preview, then gated apply)

Open a PR touching `terraform/` to see the plan posted on the PR (review it), then:

```bash
gh workflow run terraform-apply.yml -f root=fop
# Approve in 'dev'. Applies the saved plan, then applies the in-cluster platform manifests
# (operator RBAC + encrypted StorageClass) over Connect Gateway.
```

## 5. Verify the controls 🧑/🤖 (`gcloud`/`kubectl` + setup-doctor)

```bash
# setup-doctor in cluster mode (operator credentials, full audit)
export SETUP_DOCTOR_PROJECT_NUMBER=<num> SETUP_DOCTOR_PROJECT_ID=<DEV_PROJECT_ID>
export SETUP_DOCTOR_SERVICE_ACCOUNT=<automation-sa-email> SETUP_DOCTOR_POOL_ID=github
export SETUP_DOCTOR_PROVIDER_ID=iac-gke SETUP_DOCTOR_REPOSITORY_ID=1260827836 SETUP_DOCTOR_REF=refs/heads/main
export SETUP_DOCTOR_REGION=us-central1 SETUP_DOCTOR_NODE_SERVICE_ACCOUNT=<node-sa-email>
( cd bootstrap/verifier && pip install -r requirements.lock && pip install -e . --no-deps && setup-doctor )
```

Spot-check the rest in the console / `gcloud container clusters describe`: private endpoint
(no public), `databaseEncryption: ENCRYPTED`, shielded nodes, Workload Identity, Dataplane V2,
Binary Authorization audit, least-privilege node SA.

## 6. Validate workloads (end-user) 🧑 (`kubectl`)

```bash
examples/validate.sh          # deploys 4 cases over the gateway and asserts the outcomes
```

Expect: hello-web → HTTP 200 + "Hello World"; encrypted-pvc → data persists; artifact-registry
→ pull admitted + runs; workload-identity → secret read. Paste the summary block into issue #11.

## 7. Record + close 🤖

Paste the evidence (setup-doctor output + validate.sh summary) into the Milestone 1 issues;
check off the runtime acceptance boxes confirmed; close #6–#9 and #11.

## 8. Tear down 🤖 (dispatch, gated)

```bash
gh workflow run terraform-destroy.yml -f root=fop -f confirm=fop      # destroy the cluster
# foundation is normally left in place; if torn down, the KMS key ring/key REMAIN
# (Cloud KMS forbids deletion) and are reused on the next apply.
```

Cost while up: 3 × `e2-medium`, general pool only, short-lived.
