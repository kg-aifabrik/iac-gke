# iac-gke

Infrastructure, policy, and automation for **cluster-ctrl** — how the AiFabrik Site
Reliability Engineering (SRE) team builds and runs hardened **Google Kubernetes Engine
(GKE)** clusters on Google Cloud. Requirements, technology choices, the technical design, and
the Architecture Decision Records live in [`docs/`](docs/) alongside the Terraform, the
in-cluster manifests, the keyless pipeline, and the verifier — design and implementation evolve
together. (The [`cluster-ctrl`](https://github.com/kg-aifabrik/cluster-ctrl) repo is reserved
for the future Operations Console.)

This is the repository whose GitHub Actions automation is trusted to reach Google Cloud
**keylessly** — Workload Identity Federation (WIF), no stored keys. It is **private** by design.

## Status

| Milestone | Scope | State |
|---|---|---|
| **M0** — Verified keyless access | WIF + service-account impersonation + `setup-doctor` + a CI demo | ✅ closed |
| **M1** — Cluster factory | a hardened, private, regional cluster as `account × environment × purpose` configuration | ✅ closed |
| **M2** — Ingress and TLS | two gateways (internal + external), public + private (CAS) certificates, a baseline web application firewall | ✅ closed |
| **M3** — Security hardening | image supply chain / Binary Authorization enforce, posture, namespace stamps, mTLS | 🔭 planned (#17) |

Each milestone was built through the gated pipeline and proven against a real dev cluster, then
torn down. Delivery, bring-up issues, and decisions for each are recorded in a per-milestone
**retrospective** issue under its GitHub Milestone. Deferred work is tracked as open issues.

## What's built

A cluster is **chosen, not coded** — three coordinates: **account** (the project),
**environment** (dev / stage / prod), and **purpose** (Fleet Operations Plane, Management Plane,
…). One hardened recipe; sizing and options vary per (environment, purpose).

- **Cluster** — private, regional, a DNS-only control-plane endpoint (no public application
  programming interface (API) server), Dataplane V2, shielded + Container-Optimized OS nodes,
  Workload Identity, Customer-Managed Encryption Keys (CMEK) for secrets and disks, Binary
  Authorization, managed Prometheus, and fleet membership.
- **Network** — a custom Virtual Private Cloud, alias-IP Pod/Service ranges, Private Google
  Access, an optional Cloud Network Address Translation (NAT), and a proxy-only subnet for the
  internal gateway.
- **Supply chain** — Artifact Registry (a private repository + a Docker Hub pull-through proxy),
  a repository-scoped node reader, and a Binary Authorization policy.
- **Access** — no public endpoint; operators and automation reach the cluster only through
  **Connect Gateway** (Google Identity and Access Management (IAM) + in-cluster role-based access
  control).
- **Ingress + TLS** — two gateways per cluster (internal `gke-l7-rilb`, external global). Public
  endpoints use Certificate Manager managed certificates; internal endpoints use a private
  Certificate Authority in Certificate Authority Service (CAS) via cert-manager / google-cas-issuer
  / trust-manager. A baseline Cloud Armor policy fronts the external edge.

## Layout

```
terraform/
  modules/   project-foundation · network · supply-chain · gke-cluster · access ·
             private-ca · gke-gateway · cluster-stack (the per-purpose composition)
  envs/dev/  foundation (per project) · fop (the dev Fleet-Operations-Plane cluster)
k8s/platform/  pinned in-cluster TLS add-ons (cert-manager / google-cas-issuer / trust-manager)
examples/      runnable, hardened reference workloads (01–06) + validate.sh (end-user checks)
bootstrap/
  setup-keyless-access.sh     M0 one-time keyless setup (human-run)
  setup-build-foundation.sh   Terraform state bucket + build-role elevation (human-run)
  verifier/                   setup-doctor — preflight checks (keyless + cluster + ingress)
docs/
  requirements.md · security-requirements.md · technology-choices.md   the what + the how
  designs/         google-cloud-design.md — the technical design (a living document)
  adr/             Architecture Decision Records (MADR format)
  plans/           per-milestone implementation plans
  runbooks/        one-time, human-run procedures (keyless setup; cluster bring-up/teardown)
  implementation/  cluster-build.md — how the build works, operator-facing (living document)
.github/workflows/
  verify-access.yml                    keyless auth + setup-doctor (the M0 demo, kept green)
  terraform-{plan,apply,destroy}.yml   gated, keyless plan / apply / destroy
```

## How it's operated

1. **One-time bootstraps** (human-run, need project admin):
   - `bootstrap/setup-keyless-access.sh` — the WIF pool/provider, the automation service account,
     and the repository variables.
   - `bootstrap/setup-build-foundation.sh` — the versioned Terraform state bucket and the
     least-privilege build roles.
2. **GitHub setup** — a `dev` Environment whose required reviewers are the SRE approvers (the
   approval gate), plus repository variables (`GCP_*`, `WIF_*`, `SRE_OPERATOR_MEMBERS`).
3. **Build or change** — a pull request triggers `terraform-plan` (the plan is posted to the PR);
   then `terraform-apply` is dispatched per root (`foundation`, then `fop`), an SRE approves the
   `dev` Environment, the **saved** plan applies, and the in-cluster manifests are applied over
   Connect Gateway. `terraform-destroy` tears a root down (also gated).
4. **Verify** — `setup-doctor` (preflight) and `examples/validate.sh` (end-user: an HTTP 200 over
   both gateways, an encrypted volume that persists, an Artifact Registry pull, and a Workload
   Identity secret read).

Account and project values stay out of git (supplied at `init`/apply); each root keeps its own
state under a prefix (`env/dev/foundation`, `env/dev/fop`).

## Where the *why* lives

- **Design + decisions** — [`docs/designs/google-cloud-design.md`](docs/designs/google-cloud-design.md),
  [`docs/adr/`](docs/adr/), and `docs/{requirements,technology-choices,security-requirements}.md`.
- **Plans** — `docs/plans/`. **Build narrative** — `docs/implementation/cluster-build.md`.
- **Bring-up + retrospectives** — `docs/runbooks/` and the per-milestone retrospective issues.
