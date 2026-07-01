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
export PROJECT_ID=gke-poc-498602      # your Google Cloud Project ID (alphanumeric)
export PROJECT_NUMBER=248272574639    # your Google Cloud Project Number (all numeric — a different identifier from the ID)
export REGION=us-central1             # cluster region
export ACCOUNT=you@aifabrik.com       # your operator Google account (NOT a personal one)
```

The **Project ID** (alphanumeric, e.g. `gke-poc-498602`) and the **Project
Number** (all numeric, e.g. `248272574639`) are two *different* Google Cloud
identifiers, and the automation needs both — the service-account emails and
`--project` flags use the **ID**, while `setup-doctor` and the Workload Identity
provider use the **Number**. Find both on the Google Cloud console home page, or
run `gcloud projects describe "$PROJECT_ID" --format='value(projectId, projectNumber)'`.

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

This step does two things, both of which need elevated (human) privileges the
automation deliberately lacks:

- **Creates the Terraform state bucket** — `gs://${PROJECT_ID}-tf-state`, with
  object versioning enabled so state history is recoverable. Every root stores
  its state in this one bucket under a distinct prefix (`env/dev/foundation`,
  `env/dev/fop`, and so on), which is why the bucket must exist before any apply.
- **Elevates the automation service account** —
  `cluster-ctrl-automation@${PROJECT_ID}.iam.gserviceaccount.com` is promoted
  from the single read-only role it got at keyless setup to the least-privilege
  **build** role set it needs to create clusters, networks, KMS grants, and the
  rest (the exact roles are in the bootstrap section of
  [`../implementation/cluster-build.md`](../implementation/cluster-build.md)). It
  also receives `roles/gkehub.gatewayEditor` and `roles/gkehub.viewer`, which the
  access module relies on for Connect Gateway.

After running it once, reconcile the keyless verifier so it stays green. The
`verify-access` workflow checks that the service account holds *exactly* an
expected set of roles, so the newly-granted build roles read as "unexpected"
until you declare them:

- Edit `.github/workflows/verify-access.yml`.
- Set `SETUP_DOCTOR_EXPECTED_ROLES` to the build role set **plus**
  `roles/gkehub.gatewayEditor` and `roles/gkehub.viewer`.

This is a one-time reconciliation — you won't touch it again unless the build
role set itself changes.
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

**Success looks like:** `gh api repos/{owner}/{repo}/environments/dev` returns the
`dev` environment with your reviewer(s) listed, and `gh variable list` shows the
full set of six variables — for example:

```text
NAME                  VALUE                                                            UPDATED
GCP_PROJECT_ID        gke-poc-498602                                                   about 23 hours ago
GCP_PROJECT_NUMBER    248272574639                                                     about 23 hours ago
GCP_REGION            us-central1                                                      about 23 hours ago
SRE_OPERATOR_MEMBERS  ["user:ag@aifabrik.com","user:kg@aifabrik.com"]                  about 13 hours ago
WIF_PROVIDER          projects/248272574639/locations/global/workloadIdentityPools/…   about 23 hours ago
WIF_SERVICE_ACCOUNT   cluster-ctrl-automation@gke-poc-498602.iam.gserviceaccount.com   about 23 hours ago
```

(`GCP_PROJECT_*` and `WIF_*` come from the keyless setup; `GCP_REGION` and
`SRE_OPERATOR_MEMBERS` are the two you set in this step.)

**If it fails:**

- `Must have admin rights to Repository` → you need admin on the repo to set
  variables / create the environment.
- Later, an apply that never pauses for approval → the `dev` environment has **no
  required reviewers**; anyone's dispatch would apply unreviewed. Add reviewers.

<details><summary>Technical details</summary>

Two different identity systems meet in this step; keeping them straight avoids a
lot of confusion:

- **Environment reviewers are GitHub users.** They are the approval gate — the
  people GitHub blocks each apply/destroy on until one of them opens the run and
  clicks *Review deployments → Approve*. You register them with the
  `reviewers[][id]` call, using each person's numeric GitHub user id (from
  `gh api users/<login> --jq .id`).
- **`SRE_OPERATOR_MEMBERS` are Google Cloud IAM members.** They are who may
  *operate the cluster* — each entry is granted Connect Gateway access and
  `cluster-admin` Kubernetes RBAC. Entries are `group:<email>` (a Google
  Workspace / Cloud Identity group) or `user:<email>` (an individual), and you
  can mix them. A group is easier to run long-term — you change its membership in
  Google without re-applying Terraform — whereas an explicit user list requires a
  Terraform apply every time it changes.

The remaining variables — `GCP_PROJECT_ID`, `GCP_PROJECT_NUMBER`, `WIF_PROVIDER`,
and `WIF_SERVICE_ACCOUNT` — already exist from the keyless setup (runbook 01), and
the pipeline derives its automation member from `WIF_SERVICE_ACCOUNT`. Nothing
project-specific is committed to git: the workflows read all of it from these
repository variables at run time.
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

`TF_ROOT=terraform/envs/dev/foundation`. The run is deliberately two-phase and
gated:

- **Plan** runs first and uploads the result as a build artifact.
- **Apply** is held on the `dev` Environment until a required reviewer approves,
  then it applies that **saved** plan — so what applies is exactly what was
  reviewed, with no window for drift between the two.

A couple of safety properties come from the workflow itself:

- **Concurrency** serializes runs per `(env, purpose)` and never cancels one in
  flight, because a cancelled apply can corrupt state.
- **The KMS key ring and key are permanent.** They are created here and never
  deleted afterwards — Cloud KMS forbids key deletion — so a later teardown and
  rebuild reuses the same key rather than creating a new one.
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
- `Backend initialization required` when you run the `terraform output` below →
  this root isn't initialized locally; run the `terraform … init
  -backend-config="bucket=${PROJECT_ID}-tf-state"` line first (add `-reconfigure`
  if it says the backend configuration changed).

**One-time DNS delegation (🧑, required for public HTTPS):** dev has
`manage_public_dns = true`, so Terraform created a public zone but the domain
must be delegated to it at your registrar:

```bash
# The state lives in GCS, so initialize this root against the backend once
# (needs your operator ADC — gcloud auth application-default login). Add
# -reconfigure if a previous local init complains that the backend changed.
terraform -chdir=terraform/envs/dev/fop init -backend-config="bucket=${PROJECT_ID}-tf-state"
terraform -chdir=terraform/envs/dev/fop output public_zone_name_servers
# Add NS records for the public subdomain (host `dev` in `arthos.app`) pointing at
# those four nameservers. Certificates then go PROVISIONING → ACTIVE in minutes.
dig NS dev.arthos.app        # expect the Google nameservers
```

<details><summary>Technical details</summary>

`TF_ROOT=terraform/envs/dev/fop`. The Terraform apply builds the cluster and its
Google-side resources. Then, because the cluster has no public endpoint, the
workflow reaches it over Connect Gateway and finishes the platform setup in a
specific order (this whole phase runs for any `purpose != foundation`):

- **PriorityClasses first** — the Helm charts below reference them, and admission
  rejects pods whose priority class doesn't exist yet.
- **TLS controllers next**, Helm-installed at pinned versions: cert-manager
  (highly available — two replicas per component with PodDisruptionBudgets),
  trust-manager, and google-cas-issuer (its Kubernetes service account annotated
  for Workload Identity, so it needs no keys).
- **In-cluster manifests last** — operator RBAC, the encrypted StorageClass, the
  CAS issuer + root trust bundle, and the two gateways with their routes —
  applied with a short retry loop to absorb gateway-IAM propagation delay.

DNS behaves differently per exposure class (ADR-0006):

- **Internal** hostnames resolve automatically through the Cloud DNS **private
  zone** inside the VPC — no registrar action needed.
- **Public** hostnames need the one-time NS delegation shown above; until the
  registrar points the subdomain at Cloud DNS, the managed certificates stay
  `PROVISIONING`. After a destroy + re-create, re-check the nameserver set — a
  re-created zone can be assigned a different one.
</details>

---

## 5. Verify the controls 🧑 (setup-doctor)

**What this does:** audits the live cluster against the hardening the design
promises — private endpoint, CMEK grants, least-privilege node SA, Connect
Gateway, the CAS hierarchy, autoscaling bounds, backup plan, DNS zones, and
active certificates. Run it with **your operator credentials** so every check
runs in full.

**Run:** two sub-steps — sign in, then run one script.

**5a — Sign in with your operator credentials** (interactive; opens a browser —
finish the sign-in, then return to the terminal):

```bash
gcloud auth application-default login   # sign in as your $ACCOUNT — NOT a personal account
```

**5b — Run the audit.** One script installs the verifier, derives every
`SETUP_DOCTOR_*` value from `config/clusters.yaml` plus your project, and runs the
full audit — no variables to set by hand:

```bash
./bootstrap/verify-cluster.sh --project "$PROJECT_ID" --env dev --purpose fop
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

**What `verify-cluster.sh` does.** It is a thin wrapper that removes the manual
setup; in order it:

- Checks the prerequisites — `python3`, `gcloud`, `gh`, and that Application
  Default Credentials exist (it stops with a clear message if you haven't run
  `gcloud auth application-default login`).
- Installs the verifier and the factory into a local virtual environment
  (`bootstrap/verifier/.venv`) from their pinned lockfiles.
- Resolves the two non-registry identifiers — the **project number** (via
  `gcloud projects describe`) and the **repository id** (via `gh`).
- Asks the factory to derive the rest from the registry:
  `cluster-factory doctor-env` reads the cluster's entry in
  `config/clusters.yaml` and prints the `SETUP_DOCTOR_*` values (cluster name,
  autoscaling bounds, ingress hostnames, DNS zones), which the script evaluates.
- Runs `setup-doctor` with all of that in the environment.

Because the per-cluster values come from the same registry the cluster was built
from, the audit can't drift from the build.

**How `setup-doctor` itself behaves.** It talks only to Google APIs (no
`kubectl`), so it audits the cloud-side posture from your laptop. Two things worth
knowing:

- **Cluster mode is opt-in via `SETUP_DOCTOR_REGION`.** With it set, the cluster
  checks run (CMEK grants, node SA, autoscaling, backup plan, DNS zones,
  certificates, CAS hierarchy); without it, only the keyless/identity checks run.
- **Identity comes from Application Default Credentials.** That's the same
  mechanism behind the 403 earlier in setup — if ADC points at a personal account
  with no project access, every check 403s. Always run it as your operator
  account. In CI the automation service account is intentionally least-privilege,
  so the operator-only structural checks report `[SKIP]` there — which is exactly
  why this full audit is run locally under your credentials.

**Running it by hand (debugging, or a one-off check).** If you'd rather set the
variables yourself — for instance to tweak one and re-run a single check — install
the verifier and export the values `verify-cluster.sh` would have derived, then
run `setup-doctor` directly:

```bash
cd bootstrap/verifier
python3 -m venv .venv && . .venv/bin/activate
pip install -q -r requirements.lock && pip install -q -e . --no-deps

# Print the exact exports for this cluster, then eval them (needs cluster-factory
# installed too: pip install -q -e ../../tools/cluster-factory):
eval "$(cluster-factory doctor-env --env dev --purpose fop \
  --project "$PROJECT_ID" --project-number "$PROJECT_NUMBER" \
  --region "$REGION" --repository-id "$(gh api repos/kg-aifabrik/iac-gke --jq .id)")"

setup-doctor
```

Everything must be in one shell — the virtual environment and the `export`s only
apply to the shell you set them in.
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

The full case matrix — what each case asserts — is in
[`examples/README.md`](../../examples/README.md). A few things to expect while it
runs:

- **Ingress cases need the managed certificates `ACTIVE`**, so finish the step-4
  DNS delegation first or those cases fail on HTTPS (the internal cases still
  pass, since the private CA doesn't depend on the registrar).
- **The backup→restore case runs last** and deliberately bounces the workload
  namespaces, so the churn near the end is expected, not a failure.
- **Access is over Connect Gateway only** — the cluster has no public endpoint, so
  `kubectl` needs `gke-gcloud-auth-plugin` plus fleet credentials
  (`gcloud container fleet memberships get-credentials dev-fop --project "$PROJECT_ID"`).
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

`TF_ROOT=terraform/envs/dev/fop`. Order matters on teardown, and the workflow
handles it for you:

- **In-cluster Gateways are deleted first**, so the GKE Gateway controller
  releases the Google load balancers it created before Terraform removes the edge
  resources those depend on. Deleting the cluster first would strand the load
  balancers and block the destroy (#31); this phase is idempotent, so a re-run
  after a partial destroy is safe.
- **The CAS hierarchy is per-cluster** with random-suffixed names, so it's removed
  cleanly and the next apply generates fresh ids — no name collisions on rebuild.
- **The foundation is left in place.** A `fop` teardown removes only the cluster;
  the free, undeletable foundation singletons remain (enabled APIs, the node
  service account, and the KMS key shell), ready for the next build.

**Cost while the cluster is up:** roughly 3–6 × `e2-medium` nodes (autoscaling),
two load balancers, backups, and the DEVOPS CAS pair — all short-lived, so a
prompt teardown keeps dev cheap.
</details>
