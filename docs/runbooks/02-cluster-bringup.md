# Runbook 02 — Build, verify, and tear down a cluster

This runbook takes you through a Google Kubernetes Engine (GKE) cluster end to
end: build it through the pipeline, verify its security controls and workloads,
then tear it down cleanly. It is written for the common case — the **`dev` `fop`**
cluster — with concrete, copy-paste commands.

Each step is laid out the same way: **what it does**, the **commands to run**,
**what success looks like**, **what failures mean**, and a collapsible
**Technical details** block you only need when you're curious or debugging.

Two markers show who runs each step:

- 🧑 — you run it yourself (a real account with `gcloud` / `gh`).
- 🤖 — it runs through the gated pipeline (you dispatch it and approve it).

This runbook assumes the keyless access setup is already done. If not, do
[`01-keyless-access-setup.md`](01-keyless-access-setup.md) first.

---

## Set your values once

Every step uses these. Export them in your shell before you start:

```bash
export PROJECT_ID=gke-poc-498602      # your dev Google Cloud project
export REGION=us-central1             # cluster region
export ACCOUNT=you@aifabrik.com       # your operator Google account (NOT a personal one)
```

These are account-specific and never committed. The cluster's coordinates are
shown concretely as `env=dev` and `purpose=fop`; to build a different cluster,
substitute your own `env`/`purpose`.

> **What the pipeline offers today:** `env` is wired only for `dev` (stage/prod
> are modeled but not built). `purpose` is `foundation`, `fop`, or `mgmt` — the
> list is generated from `config/clusters.yaml`. To add a **new** purpose, edit
> the registry and run
> [`bootstrap/add-cluster-purpose.sh`](../../bootstrap/add-cluster-purpose.sh),
> then come back here.

---

## Before you start — confirm the keyless setup

**What this does:** confirms the keyless access setup produced the repository
variables the pipeline needs.

**Run:**

```bash
gh variable list --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)"
```

**Success looks like:** the list includes `WIF_PROVIDER`, `WIF_SERVICE_ACCOUNT`,
`GCP_PROJECT_ID`, and `GCP_PROJECT_NUMBER`. If it does, continue.

**If it's missing those:** run [`01-keyless-access-setup.md`](01-keyless-access-setup.md)
first — the cluster build can't authenticate without them.

---

## 1. Bootstrap the build foundation 🧑 (one-time)

**What this does:** gives the automation the permissions it needs to build, and
creates the Terraform state bucket. You run it by hand because it elevates the
very identity the automation then uses — the automation can't grant that to
itself. Safe to re-run.

**Run:**

```bash
./bootstrap/setup-build-foundation.sh --project "$PROJECT_ID" --account "$ACCOUNT"
```

**Success looks like:** the script prints ` ok` lines and finishes without error.
It creates `gs://${PROJECT_ID}-tf-state` (versioned) and grants the automation
service account the least-privilege **build** role set. Re-running reports items
already in place and changes nothing.

**If it fails:**

- `PERMISSION_DENIED` / "not authorized" → your `$ACCOUNT` isn't **Owner** (or
  lacks the admin roles) on `$PROJECT_ID`.
- `billing … is not enabled` → enable billing on the project, then re-run.
- `gcloud: command not found` → install the gcloud CLI.

<details><summary>Technical details</summary>

Creates the versioned GCS state bucket and elevates the automation service
account (`cluster-ctrl-automation@${PROJECT_ID}.iam.gserviceaccount.com`) from
its single Milestone-0 read role to the build role set (listed in the bootstrap
section of [`../implementation/cluster-build.md`](../implementation/cluster-build.md)),
plus `roles/gkehub.gatewayEditor` and `roles/gkehub.viewer` (the access module
grants those too). After running, keep the keyless verifier green by re-syncing
its expected roles: edit `.github/workflows/verify-access.yml` →
`SETUP_DOCTOR_EXPECTED_ROLES` to the build role set **plus** those two gkehub
roles, so its exact-match check doesn't flag them as unexpected.
</details>

---

## 2. Set up the GitHub gate and variables 🤖 (one-time)

**What this does:** creates the human-approval gate (a GitHub Environment named
`dev`) and the repository variables the pipeline reads. Every apply and destroy
waits on this gate.

**Run:**

```bash
# Repo variables
gh variable set GCP_REGION --body "$REGION"

# Who may operate the cluster (Google Cloud IAM members — NOT GitHub users).
# Use "group:<email>" for a group, or list individuals as "user:<email>".
gh variable set SRE_OPERATOR_MEMBERS --body '["group:sre@aifabrik.com"]'

# The approval gate: add each approver as a required reviewer (a GitHub user).
reviewer_id=$(gh api users/<github-login> --jq .id)
gh api --method PUT "repos/{owner}/{repo}/environments/dev" \
  -F "reviewers[][type]=User" -F "reviewers[][id]=${reviewer_id}"
```

**Success looks like:** `gh variable list` shows `GCP_REGION` and
`SRE_OPERATOR_MEMBERS`; `gh api repos/{owner}/{repo}/environments/dev` returns
the `dev` environment with your reviewer(s) listed.

**If it fails:**

- `Must have admin rights to Repository` → you need admin on the repo to set
  variables / create the environment.
- Later, an apply that never pauses for approval → the `dev` environment has **no
  required reviewers**; anyone's dispatch would apply unreviewed. Add reviewers.

<details><summary>Technical details</summary>

Two different identity systems meet here: the Environment **reviewers** are
**GitHub users** (the approval gate), while **`SRE_OPERATOR_MEMBERS`** are
**Google Cloud IAM members** who get Connect Gateway access + `cluster-admin`
RBAC on the cluster. `GCP_PROJECT_ID`, `GCP_PROJECT_NUMBER`, `WIF_PROVIDER`, and
`WIF_SERVICE_ACCOUNT` already exist from the keyless setup; the automation member
is derived from `WIF_SERVICE_ACCOUNT`.
</details>

---

## 3. Build the foundation 🤖 (gated)

**What this does:** builds the per-project foundation — the singletons every
cluster in the project shares (enabled services, the KMS key + its two CMEK
grants, the node service account). **This must succeed before step 4**, because
the cluster reads the foundation's outputs.

**Run:**

```bash
gh workflow run terraform-apply.yml -f env=dev -f purpose=foundation
gh run watch                                  # then approve in the dev Environment
```

**Success looks like:** the run's `plan` job succeeds, the `apply` job **pauses
for approval** (approve it in the Actions UI — the run page shows *Review
deployments*), then applies green. `gh run view <id>` shows both jobs ✓.

**If it fails:**

- `HTTP 422: Unexpected inputs provided: ["root"]` → you used the old `-f root=`
  flag; use `-f env=dev -f purpose=foundation`.
- `PERMISSION_DENIED` during plan/apply → the automation SA doesn't have the
  build roles yet; re-run step 1.
- The run finishes the `plan` job but never applies → it's **waiting for
  approval**, not failed. Approve it.

<details><summary>Technical details</summary>

`TF_ROOT=terraform/envs/dev/foundation`. The run plans, waits on the `dev`
Environment gate, then applies the **saved plan** so what applies is exactly what
was reviewed. Concurrency serializes runs per `(env, purpose)`. The KMS key ring
and key are created here and, once created, are never deleted (Cloud KMS forbids
it) — a later teardown/rebuild reuses them.
</details>

---

## 4. Build the cluster 🤖 (gated)

**What this does:** builds the `dev-fop` cluster itself, then (over Connect
Gateway) installs the TLS controllers and applies the in-cluster platform
manifests (operator RBAC, encrypted StorageClass, the CAS issuer + trust bundle,
and the two gateways).

**Run:**

```bash
# Recommended: open a PR touching terraform/ first to preview the plan on the PR.
gh workflow run terraform-apply.yml -f env=dev -f purpose=fop
gh run watch                                  # then approve in the dev Environment
```

**Success looks like:** the run applies green, including the final "Install TLS
add-ons and apply in-cluster manifests" step. The cluster `dev-fop` exists and
both gateways get IP addresses.

**If it fails:**

- `data.terraform_remote_state.foundation.outputs is object with no attributes`
  → **the foundation isn't built** (step 3 didn't complete). Build foundation
  first, then re-run this.
- Public certificates stuck in `PROVISIONING` (not a run failure, but nothing
  serves over HTTPS externally) → you still need the **one-time DNS delegation**
  below.

**One-time DNS delegation (🧑, required for public HTTPS):** dev has
`manage_public_dns = true`, so Terraform created a public zone but the domain
must be delegated to it at your registrar:

```bash
terraform -chdir=terraform/envs/dev/fop output public_zone_name_servers
# Add NS records for the public subdomain (host `dev` in `arthos.app`) pointing at
# those four nameservers. Certificates then go PROVISIONING → ACTIVE in minutes.
dig NS dev.arthos.app        # expect the Google nameservers
```

<details><summary>Technical details</summary>

`TF_ROOT=terraform/envs/dev/fop`. After the Terraform apply, the workflow (for
any `purpose != foundation`) authenticates through Connect Gateway and: applies
the platform PriorityClasses; Helm-installs the pinned cert-manager (HA),
trust-manager, and google-cas-issuer (its KSA annotated for Workload Identity);
then applies the rendered in-cluster manifests with a short retry for gateway-IAM
propagation. Internal hostnames resolve via the Cloud DNS **private zone** with
no registrar action; only **public** hostnames need the NS delegation above
(ADR-0006). After a destroy + re-create, re-check the NS set — a re-created zone
can get different nameservers.
</details>

---

## 5. Verify the controls 🧑 (setup-doctor)

**What this does:** audits the live cluster against the hardening the design
promises — private endpoint, CMEK grants, least-privilege node SA, Connect
Gateway, the CAS hierarchy, autoscaling bounds, backup plan, DNS zones, and
active certificates. Run it with **your operator credentials** so every check
runs in full.

**Run:**

```bash
gcloud auth application-default login   # sign in as $ACCOUNT — NOT a personal account

cd bootstrap/verifier
python3 -m venv .venv && . .venv/bin/activate
pip install -q -r requirements.lock && pip install -q -e . --no-deps

# identity / keyless
export SETUP_DOCTOR_PROJECT_ID="$PROJECT_ID"
export SETUP_DOCTOR_PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export SETUP_DOCTOR_POOL_ID=github SETUP_DOCTOR_PROVIDER_ID=iac-gke
export SETUP_DOCTOR_REPOSITORY_ID="$(gh api repos/kg-aifabrik/iac-gke --jq .id)"
export SETUP_DOCTOR_REF=refs/heads/main
export SETUP_DOCTOR_SERVICE_ACCOUNT="cluster-ctrl-automation@${PROJECT_ID}.iam.gserviceaccount.com"
# cluster mode (REGION set = cluster checks on)
export SETUP_DOCTOR_REGION="$REGION"
export SETUP_DOCTOR_ENVIRONMENT=dev
export SETUP_DOCTOR_CLUSTER=dev-fop
export SETUP_DOCTOR_NODE_SERVICE_ACCOUNT="gke-node@${PROJECT_ID}.iam.gserviceaccount.com"
export SETUP_DOCTOR_AUTOSCALING_MIN=1 SETUP_DOCTOR_AUTOSCALING_MAX=2
export SETUP_DOCTOR_EXTERNAL_HOSTNAMES=app.dev.arthos.app,hello.dev.arthos.app
export SETUP_DOCTOR_INTERNAL_HOSTNAMES=hello.dev.aifabrik.com,tools.dev.aifabrik.com
export SETUP_DOCTOR_INTERNAL_ZONE_DOMAIN=dev.aifabrik.com
export SETUP_DOCTOR_PUBLIC_ZONE_DOMAIN=dev.arthos.app

setup-doctor
```

**Success looks like:** every check reports `[PASS]`; the run ends
`PASSED`. With operator credentials the structural checks (WIF provider, IAM
policy, CMEK grants, CAS) run in full rather than `[SKIP]`.

**If it fails:**

- Repeated `403 PERMISSION_DENIED` / `active-identity` shows a personal account →
  your Application Default Credentials are the wrong account. Re-run
  `gcloud auth application-default login` as `$ACCOUNT`.
- `[FAIL] external-certs-active` (and maybe `public-dns-zone`) → the public certs
  are still `PROVISIONING` because the **DNS delegation in step 4 isn't done**.
  Expected until you delegate; the internal/CAS side still passes.
- A `[FAIL]` on a specific control → read its `fix:` hint; it names the exact
  grant/setting that's missing.

<details><summary>Technical details</summary>

`setup-doctor` uses Google APIs only (no `kubectl`). Setting `SETUP_DOCTOR_REGION`
turns on the cluster-mode checks; leaving it unset runs only the keyless checks.
It reads identity from Application Default Credentials — the same mechanism that
caused the early-session 403 when ADC pointed at a personal Gmail. Values here are
derived from `$PROJECT_ID` and the `dev-fop` entry in `config/clusters.yaml`
(node SA defaults to `gke-node`, automation SA is `cluster-ctrl-automation`). In
CI the automation SA is least-privilege, so the operator-only checks `[SKIP]`
there by design — which is why this step is run locally.
</details>

---

## 6. Validate the workloads 🧑 (`kubectl`)

**What this does:** deploys real workloads and asserts the end-to-end behavior —
serving over both gateways, drain survival, a zero-failed-request rolling deploy,
autoscaling, HPA, regional-PD zone failover, preemption, and backup→restore.

**Run:**

```bash
examples/validate.sh          # deploys 13 cases and asserts the outcomes
```

**Success looks like:** the summary reports all cases passing (13/13). Expect
~30–40 minutes; drain/failover cases cordon nodes and auto-uncordon them.

**If it fails:**

- Ingress cases fail on HTTPS → the managed certs aren't `ACTIVE` yet (finish the
  step-4 DNS delegation; internal-only cases still pass).
- `kubectl` can't reach the cluster / auth errors → you need
  `gke-gcloud-auth-plugin` and Connect Gateway credentials
  (`gcloud container fleet memberships get-credentials dev-fop --project "$PROJECT_ID"`).

<details><summary>Technical details</summary>

The full case matrix (what each asserts) is in
[`examples/README.md`](../../examples/README.md). Ingress cases need the managed
certs `ACTIVE`; the backup→restore case runs last and bounces the workload
namespaces. The cluster has no public endpoint, so `kubectl` reaches it only over
Connect Gateway.
</details>

---

## 7. Record the results 🤖

**What this does:** captures the evidence so the build is traceable.

**Run:** paste the `setup-doctor` output and the `validate.sh` summary into the
relevant GitHub issue(s); check off only the acceptance boxes a test actually
confirmed; close the issue(s).

**Success looks like:** the issue shows the evidence and the checked criteria.

---

## 8. Tear down 🤖 (gated)

**What this does:** destroys the cluster and leaves zero billable resources.
Normally you tear down the cluster (`fop`), not the foundation.

**Run:**

```bash
examples/validate.sh --cleanup                # 🧑 first: remove throwaway test scaffolding
gh workflow run terraform-destroy.yml -f env=dev -f purpose=fop -f confirm=fop
gh run watch                                  # then approve in the dev Environment
```

**Success looks like:** the destroy run applies green; `gcloud container clusters
list --project "$PROJECT_ID"` no longer shows `dev-fop`. Only the free foundation
singletons remain (enabled APIs, the node SA, the KMS key shell).

**If it fails:**

- `confirm` mismatch / job skipped → the `confirm` value must equal `purpose`
  (here, `fop`).
- Leftover load balancers or a stuck destroy → the workflow deletes the
  in-cluster Gateways first to release them; if a partial run left orphans, re-run
  the destroy (it's idempotent).

**After teardown:** remove the ingress DNS records you added — the external A
record now points at a released IP and the DNS-authorization CNAME is moot.

<details><summary>Technical details</summary>

`TF_ROOT=terraform/envs/dev/fop`. The destroy deletes the in-cluster Gateways
before Terraform removes edge resources, so the GKE Gateway controller releases
its load balancers first (#31). The CAS hierarchy is per-cluster with
random-suffixed names, so it's removed cleanly and the next apply regenerates
fresh ids. **Cost while up:** 3–6 × `e2-medium` (autoscaling), two load
balancers, backups, and the DEVOPS CAS pair — all short-lived.
</details>
