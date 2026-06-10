# Runbook — cluster bring-up, verify, and teardown

Ordered, copy-paste steps to build a dev Fleet-Operations-Plane (FOP) cluster through the
pipeline, verify its controls and workloads (including ingress + TLS), and tear it down
cleanly — the living procedure we follow as the implementation grows. Assumes the keyless
access setup is done: [`01-keyless-access-setup.md`](01-keyless-access-setup.md).

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
# Approve in 'dev'. Applies the saved plan, then over Connect Gateway: Helm-installs the
# pinned TLS controllers (cert-manager, trust-manager, google-cas-issuer) and applies the
# in-cluster platform manifests — operator RBAC, the encrypted StorageClass, the CAS issuer
# + root trust bundle, and the two gateways (external + internal) with their routes.
```

> **Ingress DNS.** Internal hostnames need no public DNS — the Cloud DNS **private zone**
> resolves them to the private VIP inside the VPC automatically. Public hostnames depend on
> the `manage_public_dns` mode (ADR-0006):
>
> - **Managed (dev's default)** — Terraform creates the public zone and every per-host record
>   (the A records *and* the cert-validation CNAMEs). One-time 🧑 step: **delegate the
>   subdomain at the registrar** — add NS records for it (host `dev` in `arthos.app`) pointing
>   at the four names from
>   `terraform -chdir=terraform/envs/dev/fop output public_zone_name_servers`. Certificates
>   then validate unattended (`PROVISIONING` → `ACTIVE` in minutes). **After a destroy +
>   re-create**, confirm the NS records still match that output — a re-created zone may be
>   assigned a different nameserver set. Verify with `dig NS dev.arthos.app` (Google
>   nameservers) and `dig <hostname>` (the gateway IP).
> - **Manual** — an SRE creates each hostname's **DNS-authorization CNAME** and **A record**
>   at the registrar, exactly as emitted by `terraform output dns_records`. Certs stay
>   `PROVISIONING` until the CNAME resolves.

## 5. Verify the controls 🧑/🤖 (`gcloud`/`kubectl` + setup-doctor)

```bash
# setup-doctor in cluster mode (operator credentials, full audit)
export SETUP_DOCTOR_PROJECT_NUMBER=<num> SETUP_DOCTOR_PROJECT_ID=<DEV_PROJECT_ID>
export SETUP_DOCTOR_SERVICE_ACCOUNT=<automation-sa-email> SETUP_DOCTOR_POOL_ID=github
export SETUP_DOCTOR_PROVIDER_ID=iac-gke SETUP_DOCTOR_REPOSITORY_ID=1260827836 SETUP_DOCTOR_REF=refs/heads/main
export SETUP_DOCTOR_REGION=us-central1 SETUP_DOCTOR_NODE_SERVICE_ACCOUNT=<node-sa-email>
export SETUP_DOCTOR_ENVIRONMENT=dev                       # CAS hierarchy checks
# High-availability checks (Milestone 3) — values mirror the fop root:
export SETUP_DOCTOR_CLUSTER=dev-fop
export SETUP_DOCTOR_AUTOSCALING_MIN=1 SETUP_DOCTOR_AUTOSCALING_MAX=2
export SETUP_DOCTOR_EXTERNAL_HOSTNAMES=app.dev.arthos.app,hello.dev.arthos.app
export SETUP_DOCTOR_INTERNAL_HOSTNAMES=hello.dev.aifabrik.com,tools.dev.aifabrik.com
export SETUP_DOCTOR_INTERNAL_ZONE_DOMAIN=dev.aifabrik.com
export SETUP_DOCTOR_PUBLIC_ZONE_DOMAIN=dev.arthos.app     # only while manage_public_dns is on
( cd bootstrap/verifier && pip install -r requirements.lock && pip install -e . --no-deps && setup-doctor )
```

Spot-check the rest in the console / `gcloud container clusters describe`: private endpoint
(no public), `databaseEncryption: ENCRYPTED`, shielded nodes, Workload Identity, Dataplane V2,
Binary Authorization audit, least-privilege node SA.

## 6. Validate workloads (end-user) 🧑 (`kubectl`)

```bash
examples/validate.sh          # deploys 13 cases and asserts the end-to-end outcomes
```

The full case matrix (what each asserts) is in [`examples/README.md`](../../examples/README.md):
serving on every hostname over both gateways (internal by NAME via the private zone), drain
survival and a rolling deploy with zero failed requests, node autoscaling, HPA, regional-PD
zone failover, preemption, and backup→restore (which runs last and bounces the workload
namespaces). Ingress cases need the managed certs `ACTIVE` (see the DNS note above); the
drain/failover cases cordon nodes (auto-uncordoned). Expect ~30–40 minutes. Paste the summary
block into the milestone's verification issue.

## 7. Record + close 🤖

Paste the evidence (setup-doctor output + validate.sh summary) into the milestone's issues;
check off only the runtime acceptance boxes a test confirmed; close the milestone's chunk
issues and its tracking issue.

## 8. Tear down 🤖 (dispatch, gated)

```bash
examples/validate.sh --cleanup   # 🧑 first: remove the throwaway WI scaffolding (GSA + secret)
gh workflow run terraform-destroy.yml -f root=fop -f confirm=fop   # then destroy the cluster
# Approve in 'dev'. The destroy workflow deletes the in-cluster Gateways first, so the GKE
# Gateway controller releases its load balancers before Terraform removes the edge resources
# (#31). The CAS hierarchy is per-cluster with random-suffixed names, so this destroy removes
# it and the next apply regenerates fresh ids (no burned-id or soft-deleted-SA collision).
# foundation is normally left in place; if torn down, the KMS key ring/key REMAIN (Cloud KMS
# forbids deletion) and are reused on the next apply.
```

After teardown, remove the ingress DNS records you added — the external A record now points to a
released IP and the DNS-authorization CNAME is moot.

Cost while up: 3–6 × `e2-medium` (autoscaling), two load balancers, backups, the DEVOPS CAS pair — all short-lived. **A `fop` teardown leaves zero billable resources**; only the free/undeletable foundation singletons remain (enabled APIs, node SA, the KMS key shell).
