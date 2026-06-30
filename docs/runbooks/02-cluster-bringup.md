# Runbook 02 — Cluster bring-up, verify, and teardown

This runbook walks you through building a Google Kubernetes Engine (GKE) cluster
from start to finish. You build it through the pipeline, verify its security
controls and its workloads (including ingress and TLS), and then tear it all down
cleanly. Run the steps in order — each one is written to be run as-is.

The runbook is agnostic to the cluster's environment and purpose. Whether the
cluster is dev or production, and what it is for, is determined by the project you
target and its Terraform configuration — the runbook simply runs the steps
against that project.

The commands below use placeholders that you replace with your cluster's values:

- `<env>` — the environment (for example `dev`).
- `<purpose>` — the cluster's purpose, which is also its Terraform root (for
  example `fop`).
- `<PROJECT_ID>`, `<region>`, and the hostname and zone values for your cluster.

> **What the pipeline supports today:** the workflows currently accept only the
> `dev` environment and the `foundation` and `fop` roots. Other environments and
> purposes are not wired up yet — substitute the placeholders accordingly as they
> come online.

This runbook assumes the keyless access setup is already done. If you haven't run
it yet, do [`01-keyless-access-setup.md`](01-keyless-access-setup.md) first.

Two markers tell you who runs each step:

- 🧑 — you run it yourself, with a real account and `gcloud`.
- 🤖 — it runs through automation, from `gh` or the repo.

---

## Before you start — confirm the prerequisites

The keyless access setup must already be in place. The quickest way to confirm
is a green `setup-doctor` run (see [runbook 01](01-keyless-access-setup.md),
Step 6). Or just check that the repository variables it creates are set:

```bash
gh variable list --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)"
# Expect at least: WIF_PROVIDER, WIF_SERVICE_ACCOUNT, GCP_PROJECT_ID, GCP_PROJECT_NUMBER
```

Once those are there, continue.

---

## 1. Bootstrap the build foundation 🧑 (one-time, `gcloud`)

This step gives the automation the permissions it needs to build, and creates
the Terraform state bucket. You run it by hand because it elevates the very
identity the automation then uses — the automation can't grant that to itself.

```bash
./bootstrap/setup-build-foundation.sh --project <PROJECT_ID> --account <you@aifabrik.com>
# Creates gs://<PROJECT_ID>-tf-state (versioned) and elevates the automation
# service account to the least-privilege build role set. Safe to re-run (idempotent).
```

Then keep the keyless verifier in sync. This bootstrap grants the automation
service account a new set of roles, so update the verifier's expected roles to
match — otherwise its exact-match check flags the new roles as unexpected and the
`verify-access` workflow goes red. Edit `.github/workflows/verify-access.yml` and
set `SETUP_DOCTOR_EXPECTED_ROLES` to the **build roles** (listed in the bootstrap
section of [`../implementation/cluster-build.md`](../implementation/cluster-build.md)),
**plus `roles/gkehub.gatewayEditor` and `roles/gkehub.viewer`** — the access
module grants those two as well.

## 2. Set up the GitHub gate and variables 🤖 (needs your identities)

Every apply and destroy is gated behind a human approval. That gate is a GitHub
Environment named `<env>` whose **required reviewers are GitHub users** — the
people who approve each run. Set the Environment and the repository variables (you
supply the real values):

```bash
# Repo variables
gh variable set GCP_REGION --body "<region>"   # e.g. us-central1

# SRE_OPERATOR_MEMBERS is a JSON array of Google Cloud IAM members — NOT GitHub
# users or teams. Use "group:<email>" for a Google Workspace / Cloud Identity
# group, or "user:<email>" for an individual. These identities get Connect
# Gateway access and cluster-admin RBAC on the cluster.
gh variable set SRE_OPERATOR_MEMBERS --body '["group:sre@aifabrik.com"]'

# Environment '<env>' reviewers ARE GitHub users (repeat the reviewer line per approver)
reviewer_id=$(gh api users/<github-login> --jq .id)
gh api --method PUT "repos/{owner}/{repo}/environments/<env>" \
  -F "reviewers[][type]=User" -F "reviewers[][id]=${reviewer_id}"
```

Note the two are different identity systems: the Environment **reviewers** are
GitHub users (the approval gate), while **`SRE_OPERATOR_MEMBERS`** are Google
Cloud IAM members (who can operate the cluster). They are set independently.

The other variables — `GCP_PROJECT_ID`, `GCP_PROJECT_NUMBER`, `WIF_PROVIDER`, and
`WIF_SERVICE_ACCOUNT` — already exist from the keyless access setup.

## 3. Build the foundation root 🤖 (dispatch, gated)

Build the per-project foundation first.

```bash
gh workflow run terraform-apply.yml -f root=foundation
# Approve the run in the '<env>' Environment when prompted. Creates the enabled
# services, the KMS key and its two CMEK grants, and the node service account.
```

## 4. Build the cluster 🤖 (PR for the plan, then a gated apply)

First open a pull request that touches `terraform/`. The plan is posted on the
PR — review it. Then dispatch the apply:

```bash
gh workflow run terraform-apply.yml -f root=<purpose>
# Approve in '<env>'. It applies the saved plan, then connects over Connect Gateway
# to Helm-install the pinned TLS controllers (cert-manager, trust-manager,
# google-cas-issuer) and apply the in-cluster platform manifests — operator RBAC,
# the encrypted StorageClass, the CAS issuer + root trust bundle, and the two
# gateways (external + internal) with their routes.
```

> **A note on ingress DNS.** Internal hostnames need no public DNS — the Cloud
> DNS **private zone** resolves them to the private VIP inside the VPC
> automatically. Public hostnames depend on the `manage_public_dns` mode
> (ADR-0006):
>
> - **Managed (`manage_public_dns` on).** Terraform creates the public zone and
>   every per-host record (the A records *and* the certificate-validation CNAMEs).
>   One thing you must do by hand (🧑): **delegate the subdomain at the
>   registrar.** Add NS records for your public subdomain pointing at the four
>   names from
>   `terraform -chdir=terraform/envs/<env>/<purpose> output public_zone_name_servers`.
>   Certificates then validate on their own (`PROVISIONING` → `ACTIVE` in a few
>   minutes). **After a destroy and re-create**, check that the NS records still
>   match that output — a re-created zone may get a different nameserver set.
>   Verify with `dig NS <public-zone-domain>` (expect Google nameservers) and
>   `dig <hostname>` (expect the gateway IP).
> - **Manual.** An SRE creates each hostname's **DNS-authorization CNAME** and **A
>   record** at the registrar, exactly as printed by `terraform output dns_records`.
>   Certificates stay `PROVISIONING` until the CNAME resolves.

## 5. Verify the controls 🧑/🤖 (`gcloud` / `kubectl` + setup-doctor)

Run `setup-doctor` in cluster mode, with your operator credentials, for a full
audit. Set the values to match the cluster you just built:

```bash
# setup-doctor in cluster mode (operator credentials, full audit)
export SETUP_DOCTOR_PROJECT_NUMBER=<num> SETUP_DOCTOR_PROJECT_ID=<PROJECT_ID>
export SETUP_DOCTOR_SERVICE_ACCOUNT=<automation-sa-email> SETUP_DOCTOR_POOL_ID=github
export SETUP_DOCTOR_PROVIDER_ID=iac-gke SETUP_DOCTOR_REPOSITORY_ID=1260827836 SETUP_DOCTOR_REF=refs/heads/main
export SETUP_DOCTOR_REGION=<region> SETUP_DOCTOR_NODE_SERVICE_ACCOUNT=<node-sa-email>
export SETUP_DOCTOR_ENVIRONMENT=<env>                     # CAS hierarchy checks
# High-availability checks — values mirror your cluster's root:
export SETUP_DOCTOR_CLUSTER=<env>-<purpose>              # the cluster name, e.g. dev-fop
export SETUP_DOCTOR_AUTOSCALING_MIN=<min> SETUP_DOCTOR_AUTOSCALING_MAX=<max>
export SETUP_DOCTOR_EXTERNAL_HOSTNAMES=<external-hostnames>   # comma-separated
export SETUP_DOCTOR_INTERNAL_HOSTNAMES=<internal-hostnames>   # comma-separated
export SETUP_DOCTOR_INTERNAL_ZONE_DOMAIN=<internal-zone-domain>
export SETUP_DOCTOR_PUBLIC_ZONE_DOMAIN=<public-zone-domain>   # only while manage_public_dns is on
( cd bootstrap/verifier && pip install -r requirements.lock && pip install -e . --no-deps && setup-doctor )
```

`SETUP_DOCTOR_REPOSITORY_ID=1260827836` is the current id of this repository.

Then spot-check the rest in the console, or with `gcloud container clusters
describe`: a private endpoint (no public one), `databaseEncryption: ENCRYPTED`,
shielded nodes, Workload Identity, Dataplane V2, Binary Authorization in audit
mode, and a least-privilege node service account.

## 6. Validate the workloads 🧑 (`kubectl`)

This deploys real workloads and checks them end to end.

```bash
examples/validate.sh          # deploys 13 cases and asserts the end-to-end outcomes
```

The full list of cases — and what each one proves — is in
[`examples/README.md`](../../examples/README.md): serving on every hostname over
both gateways (internal ones by name, via the private zone); drain survival and a
rolling deploy with zero failed requests; node autoscaling; horizontal pod
autoscaling; regional-PD zone failover; preemption; and backup→restore (which
runs last and bounces the workload namespaces). The ingress cases need the
managed certificates to be `ACTIVE` (see the DNS note above). The drain and
failover cases cordon nodes, then uncordon them automatically. Expect about
30–40 minutes.

## 7. Record the results and close out 🤖

Paste the evidence — the `setup-doctor` output and the `validate.sh` summary —
into the relevant GitHub issues. Check off only the acceptance boxes that a test
actually confirmed, then close the issues.

## 8. Tear down 🤖 (dispatch, gated)

```bash
examples/validate.sh --cleanup   # 🧑 first: remove the throwaway Workload Identity scaffolding (GSA + secret)
gh workflow run terraform-destroy.yml -f root=<purpose> -f confirm=<purpose>   # confirm must match root
# Approve in '<env>'. The destroy workflow deletes the in-cluster Gateways first,
# so the GKE Gateway controller releases its load balancers before Terraform
# removes the edge resources (#31). The CAS hierarchy uses per-cluster,
# random-suffixed names, so this destroy removes it and the next apply generates
# fresh ids (no burned-id or soft-deleted-SA collision). The foundation is
# normally left in place; if you do tear it down, the KMS key ring and key REMAIN
# (Cloud KMS forbids deleting them) and are reused on the next apply.
```

After teardown, remove the ingress DNS records you added — the external A record
now points to a released IP, and the DNS-authorization CNAME no longer matters.

**Cost while the cluster is up:** 3–6 × `e2-medium` nodes (autoscaling), two load
balancers, backups, and the DEVOPS CAS pair — all short-lived. **A cluster
(`<purpose>`) teardown leaves zero billable resources;** only the free,
undeletable foundation singletons remain (the enabled APIs, the node service
account, and the KMS key shell).
