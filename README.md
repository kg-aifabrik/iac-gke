# iac-gke

Infrastructure, policy, and automation for the AiFabrik Site Reliability Engineering (SRE) team:
how we build and run hardened, private, regional **Google Kubernetes Engine (GKE)** clusters on
Google Cloud. The Terraform, the in-cluster manifests, the keyless pipeline, the verifier, and
the design/decision records all live here and evolve together.

This is the repository whose GitHub Actions automation is trusted to reach Google Cloud
**keylessly** — Workload Identity Federation (WIF), no stored keys — so it is **private** by
design. (The [`cluster-ctrl`](https://github.com/kg-aifabrik/cluster-ctrl) repo is reserved for
the future Operations Console.)

> **Audience:** operators who set up their environment to drive this automation — to build a new
> cluster, change an existing one, and run day-2 operations against it.

---

## What this project does

It turns a hardened cluster recipe into something you **choose, not code**. A cluster is named by
three coordinates:

- **account** — the Google Cloud project,
- **environment** — `dev` / `stage` / `prod`,
- **purpose** — Fleet Operations Plane (FOP), Management Plane (MGMT), …

One recipe; sizing and options vary per `(environment, purpose)`. Driving the automation through
the gated pipeline gives you:

- **Cluster** — private, regional, a Domain Name System (DNS)-only control-plane endpoint (no
  public application programming interface (API) server), Dataplane V2, shielded +
  Container-Optimized OS nodes, Workload Identity, Customer-Managed Encryption Keys (CMEK) for
  secrets and disks, Binary Authorization, managed Prometheus, and fleet membership.
- **Network** — a custom Virtual Private Cloud, alias-IP Pod/Service ranges, Private Google
  Access, an optional Cloud Network Address Translation (NAT), and a proxy-only subnet for the
  internal gateway.
- **Supply chain** — Artifact Registry (a private repository + a Docker Hub pull-through proxy), a
  repository-scoped node reader, and a Binary Authorization policy.
- **Access** — no public endpoint; operators and automation reach the cluster only through
  **Connect Gateway** (Google Identity and Access Management (IAM) + in-cluster role-based access
  control).
- **Ingress + TLS** — two gateways per cluster (internal `gke-l7-rilb`, external global). Public
  endpoints use Certificate Manager managed certificates; internal endpoints use a private
  Certificate Authority in Certificate Authority Service (CAS) via cert-manager /
  google-cas-issuer / trust-manager. A baseline Cloud Armor policy is provisioned for the
  external edge — attaching and enforcing it is future work
  ([#26](https://github.com/kg-aifabrik/iac-gke/issues/26)).
- **High availability** — per-zone node autoscaling with pinned upgrade surge, Backup for GKE +
  restore, a regional persistent-disk StorageClass, multi-host ingress with Cloud DNS, and
  platform scheduling tiers.

Everything is keyless, every change is gated behind a human approval, and the *why* behind each
choice is recorded as an Architecture Decision Record (ADR) — see
[Where the *why* lives](#where-the-why-lives).

---

## Set up your environment to contribute

Operators run two one-time, human-run bootstraps (they elevate the identity the automation then
uses, so the automation can't grant them to itself), wire up the GitHub approval gate, and verify.

**Prerequisites**

- The [`gcloud` CLI](https://cloud.google.com/sdk/docs/install) and the
  [`gh` CLI](https://cli.github.com/), both authenticated (`gcloud auth login`, `gh auth login`).
- [Terraform](https://developer.hashicorp.com/terraform/install) **1.15.5** (the version the CI
  pins), and Python 3 for `setup-doctor`.
- On the target project: **Owner**, or the admin roles listed in
  [runbook 01](docs/runbooks/01-keyless-access-setup.md#prerequisites). Billing enabled.

**Steps**

1. **Keyless access** (one-time) — create the WIF pool/provider, the least-privilege automation
   service account, and the repository variables. Recommended: run the idempotent script; the
   runbook documents exactly what it does.
   ```bash
   ./bootstrap/setup-keyless-access.sh    # see docs/runbooks/01-keyless-access-setup.md
   ```
2. **Build foundation** (one-time) — create the versioned Terraform state bucket and elevate the
   automation service account to the least-privilege **build** role set.
   ```bash
   ./bootstrap/setup-build-foundation.sh --project <DEV_PROJECT_ID> --account <you@aifabrik.com>
   ```
3. **GitHub gate + variables** — a `dev` Environment whose **required reviewers** are the SRE
   approvers (this is the approval gate on every apply/destroy), plus the repository variables
   (`GCP_*`, `WIF_*`, `SRE_OPERATOR_MEMBERS`). Step-by-step in
   [runbook 02 §2](docs/runbooks/02-cluster-bringup.md).
4. **Verify** — run `setup-doctor` locally (full audit with your operator credentials), then
   trigger the **Verify keyless access** workflow for a green CI run. Both are in
   [runbook 01 §6–7](docs/runbooks/01-keyless-access-setup.md).

Account and project values stay **out of git** — they're supplied at `init`/apply time and via
repository variables, never committed. The working conventions for changes in this repo (commit
discipline, documentation, the chunk/milestone workflow) are in [`CLAUDE.md`](CLAUDE.md).

---

## Build a cluster and run day-2 operations

Everything flows through the same keyless, gated pipeline. **You never apply from your laptop** —
you open a pull request (PR) to preview the plan, then dispatch the apply, and an SRE approves the
`dev` Environment before anything changes.

```
edit terraform/  →  PR  →  terraform-plan posts the plan on the PR  →  review
                 →  dispatch terraform-apply (per root)  →  SRE approves `dev`
                 →  saved plan applies  →  in-cluster manifests applied over Connect Gateway
```

**Build a new cluster (bring-up).** Apply the roots in order, approving each in the `dev`
Environment. The full ordered, copy-paste procedure — including the one-time DNS delegation step
and what to verify — is [runbook 02](docs/runbooks/02-cluster-bringup.md).

```bash
gh workflow run terraform-apply.yml -f root=foundation   # services, KMS key + CMEK grants, node SA
gh workflow run terraform-apply.yml -f root=fop          # the cluster, then the TLS add-ons + gateways
```

**Change an existing cluster (day-2 operations).** Day-2 changes use the *same* path — edit the
relevant Terraform (or in-cluster manifest), open a PR to review the plan, then dispatch
`terraform-apply -f root=fop` and approve. Because the plan is **saved** and re-applied, what you
reviewed is exactly what runs. Typical day-2 operations: resize or retune **node-pool
autoscaling** and upgrade surge, add an **ingress hostname**, run a **Backup for GKE** restore,
adjust **Cloud DNS** records, or perform a **controlled version upgrade**. How each works is in
the living build doc, [`docs/implementation/cluster-build.md`](docs/implementation/cluster-build.md).

**Verify.**

```bash
setup-doctor              # preflight: identity, controls, ingress, and HA posture
examples/validate.sh      # end-user: deploys 13 cases and asserts the end-to-end outcomes
```

`setup-doctor` audits the live cluster's controls (private endpoint, CMEK, shielded nodes,
Workload Identity, autoscaling, backup plan, DNS zones, active certs); `validate.sh` proves
serving over both gateways, drain survival and a zero-failed-request rolling deploy, autoscaling,
HPA, regional-PD zone failover, preemption, and backup→restore. The case matrix is in
[`examples/README.md`](examples/README.md); the verify/record steps are in
[runbook 02 §5–7](docs/runbooks/02-cluster-bringup.md).

**Tear down (dev is ephemeral).** A `fop` teardown leaves **zero billable resources** — only the
free, undeletable foundation singletons remain (enabled APIs, the node service account, the KMS
key shell).

```bash
examples/validate.sh --cleanup                                   # remove throwaway test scaffolding first
gh workflow run terraform-destroy.yml -f root=fop -f confirm=fop # gated; deletes gateways before edge resources
```

---

## Project status

**Completed**

- **[Milestone 0 — Verified keyless access](https://github.com/kg-aifabrik/iac-gke/milestone/1):**
  WIF + impersonation proven by a green CI run.
- **[Milestone 1 — Cluster factory](https://github.com/kg-aifabrik/iac-gke/milestone/2):** the
  hardened private regional cluster as `account × environment × purpose` configuration, plus the
  gated pipeline.
- **[Milestone 2 — Ingress and TLS](https://github.com/kg-aifabrik/iac-gke/milestone/3):** the two
  gateways, public + private (CAS) certificates, and a baseline WAF.
- **[Milestone 3 — High availability](https://github.com/kg-aifabrik/iac-gke/milestone/4):**
  autoscaling, Backup for GKE + restore, regional-PD storage, multi-host ingress + Cloud DNS, and
  scheduling tiers — **validated 13/13 on a live cluster**, then torn down.

**Pending**

- **[Milestone 3](https://github.com/kg-aifabrik/iac-gke/milestone/4)** is held open for one
  cold-start assertion (node-pool growth under load) that can only be observed on the next
  bring-up — [#46](https://github.com/kg-aifabrik/iac-gke/issues/46).
- **Milestone 4 — Security hardening** is planned (Binary Authorization enforce, posture,
  namespace stamps, mTLS) — [#17](https://github.com/kg-aifabrik/iac-gke/issues/17).
- Deferred follow-ups (observability, MDM trust distribution, image mirroring, …) are tracked as
  open issues.

👉 **Full detail — every milestone, chunk, and issue, linked to its GitHub Milestone ticket — is in
[`docs/progress-report.md`](docs/progress-report.md).**

---

## Layout

```
terraform/
  modules/   project-foundation · network · supply-chain · gke-cluster · access · private-ca ·
             gke-gateway · gke-backup · dns-zones · cluster-stack (the per-purpose composition)
  envs/dev/  foundation (per project) · fop (the dev Fleet-Operations-Plane cluster)
k8s/platform/  pinned in-cluster TLS add-ons (cert-manager / google-cas-issuer / trust-manager)
examples/      runnable, hardened reference workloads + validate.sh (end-user checks)
bootstrap/
  setup-keyless-access.sh     one-time keyless setup (human-run)
  setup-build-foundation.sh   Terraform state bucket + build-role elevation (human-run)
  verifier/                   setup-doctor — preflight checks (keyless + cluster + ingress + HA)
docs/
  requirements.md · security-requirements.md · technology-choices.md   the what + the how
  designs/         google-cloud-design.md — the technical design (a living document)
  implementation/  cluster-build.md — how the build works, operator-facing (living document)
  adr/             Architecture Decision Records (MADR format)
  plans/           per-milestone implementation plans
  runbooks/        one-time, human-run procedures (keyless setup; cluster bring-up/teardown)
  progress-report.md   detailed delivery status, linked to GitHub Milestones + issues
.github/workflows/
  verify-access.yml                    keyless auth + setup-doctor (the M0 demo, kept green)
  terraform-{plan,apply,destroy}.yml   gated, keyless plan / apply / destroy
```

## Where the *why* lives

- **Design + decisions** — [`docs/designs/google-cloud-design.md`](docs/designs/google-cloud-design.md),
  [`docs/adr/`](docs/adr/), and `docs/{requirements,technology-choices,security-requirements}.md`.
- **Plans** — [`docs/plans/`](docs/plans/). **Build narrative** —
  [`docs/implementation/cluster-build.md`](docs/implementation/cluster-build.md).
- **Bring-up + teardown** — [`docs/runbooks/`](docs/runbooks/). **Delivery status** —
  [`docs/progress-report.md`](docs/progress-report.md) and the per-milestone retrospective issues.
