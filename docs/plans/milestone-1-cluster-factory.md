# Milestone 1 — Cluster factory (implementation plan)

*Status: draft for review · Date: 2026-06-06*
*Design (the why): [cluster-ctrl `docs/designs/google-cloud-design.md`](https://github.com/kg-aifabrik/cluster-ctrl/blob/main/docs/designs/google-cloud-design.md). Requirements and technology choices live in cluster-ctrl too. Issues for this milestone point back to this plan.*

---

## 1. Goal and definition of done

Build a hardened, private, regional **Google Kubernetes Engine (GKE)** cluster in dev
through the reviewed-change pipeline, and prove it runs real workloads.

**Done when:** an operator opens a pull request adding the dev cluster → `plan` posts to
the PR → an SRE approver approves → `apply` builds the cluster → it is reachable only
over Connect Gateway → the controls verify → the `examples/` workloads deploy and come
up correctly → evidence recorded → torn down.

## 2. Scope

- **In:** the Terraform cluster factory, the dev cluster, the approval-gated pipeline,
  the setup verifier extension, and runnable workload examples for validation.
- **Out:** the operator console; the in-cluster security closed loop, posture scanning,
  and namespace stamps (their own milestone); stage/prod and their controlled upgrades;
  node-pool day-2 operations; autoscaling.

## 3. The three dimensions

The factory is parameterized so building a cluster is choosing coordinates, not writing code:

- **Account** (personal now → company later) — never hard-coded; it is the project,
  billing, and state-backend context, so moving accounts is a config change.
- **Environment** (dev/stage/prod) — one folder per environment under `terraform/envs/`.
- **Purpose** (Fleet Operations Plane, Management Plane, **+ new**) — a parameter. One
  cluster per purpose within an environment. **Adding a purpose is a config entry**, not
  new code. Sizing/pools are **per environment per purpose** (dev-FOP and dev-MGMT may
  differ); the hardening recipe is identical for all.

## 4. Repository layout

```
terraform/
  modules/   project-foundation · network · gke-cluster · supply-chain · access
  envs/      dev/ (per-purpose config; stage/, prod/ later)
examples/    runnable workload test cases (post-build validation; seeds workload recipes)
docs/
  plans/           this plan
  implementation/  operator-facing "how it was built" (meaningful topics)
  runbooks/        operator procedures (Milestone 0 setup lives here)
.github/workflows/ plan · apply · destroy
```

## 5. Issues

Nine issues under the Milestone. Each is green on `terraform validate` + `plan` +
`tflint`/`tfsec` + plan-output assertions with **no cloud cost**, follows the coding
standards (§6), and links to this plan.

### Issue 1 — Foundation and bootstrap
- **Goal:** the per-environment foundation, plus the two bootstrap prerequisites.
- **Scope:** extend the Milestone 0 bootstrap (script) + `modules/project-foundation`.
- **Acceptance:**
  - [ ] Versioned Cloud Storage **state bucket**; per-environment state prefixes documented.
  - [ ] Automation identity **elevated** to a least-but-sufficient build role set (documented); `setup-doctor` expected roles updated and green.
  - [ ] `project-foundation`: enables required services, force-creates the service agents, creates the KMS key ring + key, grants the **two CMEK roles** (GKE agent → secrets, Compute agent → disks), creates the least-privilege node service account.
  - [ ] `validate`/`plan`/`tflint`/`tfsec` clean; plan assertions for the two grants, node-SA roles, and enabled services.

### Issue 2 — `network` module
- **Goal:** the private-cluster network.
- **Acceptance:**
  - [ ] Custom VPC; one regional subnet with named Pod and Service secondary ranges (sized, non-overlapping, documented).
  - [ ] Private Google Access + private DNS for Google's restricted endpoint; Cloud NAT behind a flag (off by default).
  - [ ] `validate`/`plan`/lint clean; outputs (network, subnet, ranges) documented.

### Issue 3 — `gke-cluster` module
- **Goal:** the hardened, private, regional cluster + node pools, parameterized per (env, purpose).
- **Acceptance:**
  - [ ] Regional control plane + nodes across **3 zones**; default pool removed.
  - [ ] **DNS-based private endpoint**, external access off; shielded nodes; Container-Optimized OS.
  - [ ] Secret encryption with our key; Dataplane V2 + default-deny; Workload Identity (pool + node metadata).
  - [ ] Logging/monitoring + managed Prometheus; release channel + maintenance window as parameters; Gateway API; deletion protection; fleet membership.
  - [ ] General node pool; optional Confidential pool (on-demand only).
  - [ ] `validate`/`plan`/lint clean; plan assertions for every hardening attribute.

### Issue 4 — `supply-chain` module
- **Goal:** trusted images.
- **Acceptance:**
  - [ ] Artifact Registry private repo + remote proxy for public images; node SA reader (repo-scoped).
  - [ ] Binary Authorization policy in **audit**; `validate`/`plan`/lint clean; assertions.

### Issue 5 — `access` module
- **Goal:** reach the private cluster via Connect Gateway.
- **Acceptance:**
  - [ ] Connect Gateway IAM (the SRE approver group + automation) and the in-cluster role-based access mapping.
  - [ ] Documented "how an operator connects"; `validate`/`plan`/lint clean.

### Issue 6 — `envs/dev` wiring
- **Goal:** instantiate the dev Fleet-Operations-Plane cluster.
- **Acceptance:**
  - [ ] Instantiates the modules for dev-FOP; per-(env, purpose) config laid out so adding a purpose/env is config-only.
  - [ ] `env/dev` state prefix; smallest-node sizing (default `e2-medium`, 1 node/zone × 3 zones, general pool only).
  - [ ] `terraform plan` for dev produces the full cluster; documented.

### Issue 7 — Approval-gated workflows
- **Goal:** PR → preview → approve → apply, gated and serialized.
- **Acceptance:**
  - [ ] `plan` (PR-triggered, keyless auth, `plan -out`, posts the plan to the PR + uploads the artifact).
  - [ ] `apply` (GitHub Environment with the **SRE approver list**, applies the **saved** plan, concurrency-serialized).
  - [ ] `destroy` (gated). `actionlint` clean; secrets masked.

### Issue 8 — Extend `setup-doctor`
- **Goal:** keep the preflight current.
- **Acceptance:**
  - [ ] Adds checks: the two CMEK grants present; node-SA build roles exact; required cluster services enabled; fleet/Connect Gateway access.
  - [ ] Unit tests (mocked) cover pass + each failure; `ruff`/`mypy` clean; runs locally and in CI.

### Issue 9 — `examples/` and post-build validation (end-user)
- **Goal:** prove the cluster is genuinely ready for workloads (WLD-2).
- **Acceptance:**
  - [ ] `examples/` at the repo root with workload test cases: a non-root Deployment + Service; a PersistentVolumeClaim on the encrypted storage class; an image pulled from Artifact Registry (passing Binary Auth audit); a pod using Workload Identity to read a Secret Manager secret.
  - [ ] Each is deployed to the built dev cluster over Connect Gateway and verified to come up correctly.
  - [ ] Results recorded as part of the milestone's post-build verification.

## 6. Cross-cutting requirements

- **Coding standards (CLAUDE.md):** every module has a header stating its purpose; all
  variables/outputs are described; comments explain *why* for non-obvious choices; clear
  module boundaries; simplicity over cleverness (YAGNI).
- **Per-issue gate:** `validate`/`plan`/`tflint`/`tfsec`/assertions green (no cost), or
  tests green for `setup-doctor`, before commit; commit references the issue; close when green.
- **Implementation doc:** `docs/implementation/cluster-build.md` captures the meaningful
  build choices and actions (not per-issue). Future topics (e.g. end-to-end TLS) are added
  as they're built. Linked from the issues that produce them.

## 7. Milestone verification (real Google Cloud, then teardown)

- Run the full PR → plan → approve → apply against the dev project.
- Verify controls: private endpoint, secret encryption ENCRYPTED, shielded nodes,
  Workload Identity, Dataplane V2 default-deny, Binary Authorization audit, least-privilege
  node SA. Reach the cluster over Connect Gateway; run `setup-doctor`.
- Run **Issue 9** examples and confirm they come up.
- Record evidence in the Milestone, then `destroy`.
- **Cost:** 3 zones, 1 small node each (`e2-medium`), general pool only, short-lived.
- **KMS on teardown:** the key ring/key are created by Terraform and **remain** after
  teardown (KMS resources can't be deleted instantly); the module reuses them on re-runs.

## 8. Deferred — tracked as open issues

Filed as standalone open issues (not under Milestone 1):

- **Flip Binary Authorization to enforce** (once an image-signing pipeline exists).
- Build the dev **Management Plane** cluster (config-only follow-on).
- **Stage and production** clusters + their controlled-upgrade day-2 operation.
- **Service-to-service mutual TLS / service mesh** decision (requirements §8).
- Node-pool **day-2 operations** and **autoscaling** baseline.

## 9. Related

[google-cloud-design.md](https://github.com/kg-aifabrik/cluster-ctrl/blob/main/docs/designs/google-cloud-design.md) · cluster-ctrl `requirements.md` · `technology-choices.md` · `security-requirements.md`.
