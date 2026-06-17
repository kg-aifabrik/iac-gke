# Milestone 4 — Security hardening (implementation plan)

*Status: draft for review · Date: 2026-06-17*
*Design (the why): [`docs/designs/google-cloud-design.md`](../designs/google-cloud-design.md) and the milestone Technical Design Record (TDR) [`docs/designs/security-hardening.md`](../designs/security-hardening.md) (authored with this milestone). Decisions: ADR-0009 (namespace stamp), ADR-0010 (admission guardrails), ADR-0011 (supply-chain verification), ADR-0012 (closed-loop reconciliation), ADR-0013 (tamper-evident evidence), and ADR-0003 amended (east-west mutual TLS stays deferred). Requirements: [`docs/security-requirements.md`](../security-requirements.md) SEC-1..SEC-10. Overview issue: [#17](https://github.com/kg-aifabrik/iac-gke/issues/17).*
*Note: this plan is the iteration surface. The Architecture Decision Records (ADRs), the TDR, and the GitHub issues are written **after** the plan is approved — approval is the gate (CLAUDE.md).*

---

## 1. Goal and definition of done

Milestones 1–3 built and proved the **cloud and cluster half** of the security standard: a
private control-plane endpoint, verified-boot (shielded) nodes, Workload Identity, a
Customer-Managed Encryption Key (CMEK) over both etcd secrets and node disks, Dataplane V2
(Cilium / extended Berkeley Packet Filter — eBPF), Binary Authorization in **audit**, and
Transport Layer Security (TLS) at the public edge and from the edge into the cluster.

Milestone 4 builds the **in-cluster half, the closed loop, and the supply-chain admission
gate** — the parts of [`security-requirements.md`](../security-requirements.md) (SEC-1..SEC-10)
that are not yet built:

- **Per-namespace security stamp** (SEC-3): one identical template on every tenant namespace —
  Pod Security Standards (PSS) at *restricted*, a default-deny network policy, scoped
  role-based access control (RBAC) with no wildcards, a namespace service account with token
  automounting off, a resource quota and limit range, and an ownership label.
- **Admission guardrails** (SEC-2): native policies that reject privileged / host-access /
  privilege-escalating pods and pods with no resource limits.
- **Secret runtime** (SEC-9): workloads read Google Secret Manager secrets mounted at runtime
  through Workload Identity — no standing Kubernetes `Secret` objects by default.
- **Supply-chain admission** (SEC-2, [#12](https://github.com/kg-aifabrik/iac-gke/issues/12)):
  Binary Authorization **verifies an attestation produced by an external, trusted
  Continuous-Integration / Continuous-Delivery (CI/CD) system** — the platform does not sign or
  scan; it trusts and verifies. Dev stays audit; staging / production are enforce-ready.
- **The closed loop** (SEC-5): **Argo CD** continuously reconciles the committed security
  configuration and self-heals drift — no person in the steady-state loop.
- **Posture, baseline, and evidence** (SEC-4/6/7): `kube-bench` (the Center for Internet
  Security — CIS — benchmark checker) and `kubescape` run on a schedule and on demand, a
  baseline report is archived at build, and all evidence is kept append-only and
  tamper-evident.
- **Alerting** (SEC-8): a Slack alert on anomalies (corrected drift, benchmark regression) and
  on silence (a scan that fails to run, unhealthy enforcement).
- **The floor** (SEC-2): the cluster is proven against the **CIS Kubernetes Benchmark, Level 2**.

**Done when:** an operator builds the dev Fleet-Operations-Plane (FOP) cluster through the
gated pipeline; every control above is provisioned; `setup-doctor` confirms the Google-Cloud
side and the extended `validate.sh` proves the in-cluster behaviour on a live cluster —
a privileged pod is **rejected**, cross-namespace traffic is **denied**, a workload **mounts a
secret with no standing `Secret`**, an externally-attested image is **admitted** while an
unattested one is **logged as would-block**, Argo CD **reverts manual drift**, a scan **writes
a report to the locked evidence bucket**, a missed scan **raises a Slack alert**, and
`kube-bench` is **clean at Level 2** (or every exception is documented) — evidence recorded,
then torn down with **zero billable resources** left behind. East-west mutual TLS (mTLS) is
**explicitly out** (Milestone 5).

## 2. Scope

- **In:** the per-namespace security stamp; native admission guardrails (PSS + Kubernetes
  `ValidatingAdmissionPolicy`); scoped operator RBAC (retiring `cluster-admin`); the runtime
  secret path (GKE-managed Secret Manager add-on); the Binary Authorization **attestor + verify
  policy** that trusts an external signer; Artifact Analysis vulnerability scanning kept as
  independent evidence; Argo CD as the platform GitOps reconciler (self-heal, SEC-5);
  `kube-bench` + `kubescape` posture scanning with a baseline report; a tamper-evident evidence
  bucket; Slack alerting on anomaly and on silence; the CIS Level 2 proof; the verifier and
  validation extensions; the live bring-up and retrospective.
- **Out:** **east-west / service-to-service mTLS and any service mesh** — re-affirmed deferred
  (ADR-0003), sequenced as Milestone 5 ([#15](https://github.com/kg-aifabrik/iac-gke/issues/15)),
  with the stamp built mesh-agnostic so adopting Cloud Service Mesh later is non-breaking;
  **image signing / scanning / quality gates** — owned by the external CI/CD team, the platform
  only verifies; the **enforce flip** in staging / production (gated on those clusters existing,
  [#14](https://github.com/kg-aifabrik/iac-gke/issues/14)); the **Cloud Armor web-application-firewall
  enforce pass** ([#26](https://github.com/kg-aifabrik/iac-gke/issues/26)); **mirroring the
  platform add-on images** through Artifact Registry ([#27](https://github.com/kg-aifabrik/iac-gke/issues/27));
  **observability / service-level objectives** ([#33](https://github.com/kg-aifabrik/iac-gke/issues/33)).

## 3. Repository layout

```
terraform/modules/
  namespace-stamp/   the SEC-3 stamp as a reusable render (PSS labels, default-deny +       (new)
                     allow NetworkPolicies, scoped Role/RoleBinding, SA w/ automount off,
                     ResourceQuota + LimitRange by named size, owner label)
  supply-chain/      + Binary Authorization attestor + Container Analysis Note; default rule
                     REQUIRE_ATTESTATION (dev DRYRUN, stage/prod enforce-ready); external-signer
                     key + Note attach-grant as inputs; Artifact Analysis kept for evidence
  gke-cluster/       + secret_manager_config (the GKE-managed Secret Manager CSI add-on, SEC-9)
  access/            + scoped platform-operator ClusterRole replacing cluster-admin (no wildcards)
  evidence-bucket/   versioned, retention-locked GCS bucket (WORM) + append-only writer grant   (new)
  project-foundation/  + the evidence bucket (project singleton); any new service-agent grants
  cluster-stack/     + composes namespace-stamp, evidence wiring; renders Argo CD bootstrap inputs
  monitoring-alerts/ Cloud Monitoring notification channel (Slack) + alert policies (SEC-8)       (new)
terraform/envs/dev/{foundation,fop}/   + stamp namespace list, attestor inputs, evidence + alert wiring
k8s/security/         the Argo-reconciled security config (GitOps source of truth):              (new)
  namespace-stamp/    kustomize/Helm base for the stamp + an Argo ApplicationSet per tenant ns
  admission/          ValidatingAdmissionPolicy + bindings (privileged/host/privesc/limits)
  scanners/           kube-bench + kubescape CronJobs (scheduled) + on-demand Job, evidence upload
  argocd/             the platform-security AppProject + the security Application(set)
k8s/platform/         + Argo CD pinned-version note (installed by the apply workflow)
bootstrap/verifier/   + setup-doctor checks for the Google-Cloud-side controls (attestor, policy,
                        Secret Manager add-on, evidence bucket lock, alert policies)
examples/             + security cases (privileged-rejected, cross-ns-denied, secret-CSI-mount,
                        attested-admitted, drift-self-heal, scan-evidence); validate.sh extended
.github/workflows/    terraform-apply: + install Argo CD (pinned) before applying manifests
docs/                 ADR-0009..0013 + ADR-0003 amendment; TDR security-hardening.md; living-doc
                        updates (google-cloud-design.md, cluster-build.md, security-requirements.md)
```

## 4. Milestones and chunks

M4 is split into **three native GitHub Milestones**, each independently demoable (consistent
with how M1–M3 were each one milestone). Feature chunks are green on `terraform validate` +
`plan` + `tflint` + `tfsec` + plan-output assertions (no cloud cost), or on mocked unit tests
for `setup-doctor` / manifest lint — *before* commit; the single **live bring-up** that proves
the in-cluster behaviour end to end is **Milestone 4c**, as Milestone 3 did at HA-8.

**A note on the two verifiers.** `setup-doctor` reads **Google Cloud control-plane** state
(Identity and Access Management, Key Management Service, Binary Authorization, Cloud Storage,
Cloud Monitoring) — it does not talk to the Kubernetes Application Programming Interface (API).
So Google-side security config (attestor, policy, Secret Manager add-on, evidence-bucket lock,
alert policies) is verified by `setup-doctor`, and **in-cluster behaviour** (PSS rejection,
network-policy isolation, secret mount, Argo self-heal, scan output) is verified by
`validate.sh` over Connect Gateway. The acceptance criteria below place each check accordingly.

---

### Milestone 4a — In-cluster guardrails & tenancy

*Goal: every tenant namespace carries the identical security stamp; unsafe pods are rejected
at admission; operators are scoped to least privilege; workloads read secrets at runtime.*
*Demo: deploy a compliant workload into a freshly stamped namespace (admitted, served); a
privileged / host / no-limits pod (rejected); a pod in namespace A cannot reach namespace B but
can reach cluster Domain Name System (DNS) and Google APIs; a workload mounts a Secret Manager
secret with no standing `Secret`.*

#### A1 — Namespace security stamp (SEC-3) — *ADR-0009*
- **Goal:** one identical, parameterised stamp on every tenant namespace, substituting only the
  namespace name, the owner label, and the quota size — the single template SEC-3 requires.
- **Work:** author the stamp as a `kustomize`/Helm **base** under `k8s/security/namespace-stamp/`
  and a thin Terraform render (`terraform/modules/namespace-stamp/`) so the stamp's *contents*
  have one source of truth. The stamp is one multi-document manifest per namespace containing:
  the `Namespace` itself with the three PSS labels (`pod-security.kubernetes.io/enforce`,
  `audit`, and `warn` all set to `restricted`, pinned to a benchmark version); a **default-deny
  ingress *and* egress** `NetworkPolicy`; the explicit **allow** policies the design names
  (cluster DNS, the Kubernetes API server, same-namespace traffic, the named platform services,
  and Google APIs / Artifact Registry — Dataplane V2 enforces these in-kernel); a scoped
  namespace `Role` + `RoleBinding` **with no wildcard verbs or resources**; a namespace
  `ServiceAccount` with `automountServiceAccountToken: false`; a `ResourceQuota` and a
  `LimitRange` (named **small / medium / large** sizes, with default requests / limits injected
  so a pod that omits them still gets bounded); and an `owner`/`team` label for audit. External
  egress is **deny-by-default with explicit opt-in** (a namespace adds named egress allows when
  a workload genuinely needs an external destination); the rationale and the rejected
  "allow-with-logging" alternative are recorded in ADR-0009. In Milestone 4a the stamp is
  authored, committed to `k8s/security/`, and applied by the pipeline (as today's in-cluster
  manifests are); Argo CD **adopts it for continuous self-heal in Milestone 4b** (B2). The two
  existing workload namespaces (the external- and internal-ingress namespaces) migrate from
  bare `Namespace` objects to **stamped** tenant namespaces; the platform namespaces
  (`cert-manager`, `gateway-system`, the Google Managed Prometheus namespace, and later
  `argocd`) are a **documented exception set** that cannot run at *restricted* and are governed
  by the cluster-wide guardrails (A2) instead.
- **Touches:** `terraform/modules/namespace-stamp/` (new), `k8s/security/namespace-stamp/` (new),
  `cluster-stack` (replace the bare workload-namespace render with the stamp), the design + build
  docs.
- **Depends on:** none.
- **Acceptance:**
  - [ ] One template renders an identical stamp for N namespaces, differing only by name, owner
        label, and quota size (asserted by rendering two and diffing only those fields).
  - [ ] The stamp contains every element above; PSS labels are `restricted` (enforce/audit/warn);
        the `NetworkPolicy` set is default-deny ingress + egress with exactly the named allows;
        the namespace `ServiceAccount` has `automountServiceAccountToken: false`; a `ResourceQuota`
        and `LimitRange` exist with default requests/limits.
  - [ ] The named quota sizes (small/medium/large) are defined once and selected per namespace.
  - [ ] Manifests lint clean (`kubeconform`); `terraform validate` / `plan` / `tflint` / `tfsec`
        green with plan assertions on the rendered set.
  - [ ] The platform-namespace exception set is documented (which namespaces, why, and how they
        are governed instead).

#### A2 — Admission guardrails: `ValidatingAdmissionPolicy` (SEC-2) — *ADR-0010*
- **Goal:** reject unsafe pod settings cluster-wide, in addition to PSS — defence in depth, and
  the controls PSS does not give (notably *required* resource limits and rules that apply even
  in the relaxed platform namespaces).
- **Work:** author native Kubernetes `ValidatingAdmissionPolicy` objects (Common Expression
  Language — CEL, Generally Available since Kubernetes 1.30; the cluster runs 1.35) with their
  `ValidatingAdmissionPolicyBinding`s under `k8s/security/admission/`. Policies reject:
  privileged containers; `hostNetwork` / `hostPID` / `hostIPC` and `hostPath` volumes; privilege
  escalation (`allowPrivilegeEscalation: true`); added Linux capabilities beyond a drop-all
  baseline; containers not running as non-root; and pods **without CPU/memory requests and
  limits**. A further policy restricts images to the trusted Artifact Registry path (belt-and-
  suspenders alongside Binary Authorization). PSS gives the standard *restricted* bundle by
  namespace label (A1); `ValidatingAdmissionPolicy` adds required-limits, the registry-path rule,
  and cluster-wide coverage — the rationale for running *both*, and why no third-party admission
  controller (Policy Controller / Gatekeeper / Kyverno) is introduced, is recorded in ADR-0010.
  These are cluster-scoped objects, so they live in `k8s/security/` and are applied by the
  pipeline, then reconciled by Argo CD (B2).
- **Touches:** `k8s/security/admission/` (new), the apply workflow (apply before workloads),
  docs.
- **Depends on:** A1 (namespaces exist to bind against).
- **Acceptance:**
  - [ ] `ValidatingAdmissionPolicy` + bindings reject: privileged, host-namespace/`hostPath`,
        privilege-escalation, extra-capability, run-as-root, and **no-resource-limit** pods.
  - [ ] A compliant reference pod is admitted.
  - [ ] An image outside the trusted registry path is rejected by policy.
  - [ ] Manifests validate (`kubeconform`); the rejection/admission matrix is asserted in
        `validate.sh` (run live in M4c); the rationale for PSS + `ValidatingAdmissionPolicy` is
        documented.

#### A3 — Scoped operator RBAC (SEC-2) — *ADR-0009*
- **Goal:** retire the broad operator `cluster-admin` binding for a wildcard-free role —
  the "per-namespace RBAC with no broad wildcards" SEC-2 requires.
- **Work:** the `access` module today renders a `ClusterRoleBinding` putting the Site Reliability
  Engineering (SRE) operators on `cluster-admin`. Replace it with a `platform-operator`
  `ClusterRole` that enumerates the verbs and resources operators actually need for day-2 work
  (read across the cluster; manage tenant-namespace workloads; run the validation scaffolding)
  with **no `*` verbs or resources**, bound to the same operator list. The automation path is
  unchanged — it authorises as cluster-admin through the GKE Identity-and-Access-Management
  authoriser (it holds `roles/container.admin`), which is also how it applies this binding.
  Deliberately excluded capabilities (for example, deleting the Argo-managed security stamp, or
  reading secrets cluster-wide) are documented, because the boundary must still cover what
  `validate.sh` does (it creates the `examples` namespace and throwaway Workload-Identity
  scaffolding) or `validate.sh` is run by the automation identity instead — this is called out
  as a risk (§7).
- **Touches:** `terraform/modules/access` (`rbac_manifest`), `cluster-build.md`.
- **Depends on:** A1.
- **Acceptance:**
  - [ ] The operator binding is a wildcard-free `ClusterRole`; no `*` in verbs or resources.
  - [ ] The role covers the documented day-2 operations (and either `validate.sh`'s needs or a
        documented decision to run it as automation).
  - [ ] The rendered manifest lints clean; `setup-doctor` still passes; the capability boundary
        (what operators can and cannot do) is documented.

#### A4 — Secret runtime (SEC-9, [TC-13](../technology-choices.md))
- **Goal:** workloads read Secret Manager secrets mounted at runtime via Workload Identity, with
  **no standing Kubernetes `Secret` object** by default.
- **Work:** enable the **GKE-managed Secret Manager add-on** on the cluster
  (`secret_manager_config { enabled = true }` on `google_container_cluster`) — Google operates
  the Secrets Store Container Storage Interface (CSI) driver and its provider, so we add no
  self-managed Helm controller. Establish the reference pattern: a `SecretProviderClass` names
  the Secret Manager secrets; a pod mounts a CSI volume; the pod's Kubernetes service account is
  Workload-Identity-bound to a Google service account holding
  `roles/secretmanager.secretAccessor` on **those specific secrets**. The manifest in Git carries
  only the *reference*, never a value. The External Secrets Operator (ESO) is documented as the
  allowed exception where a synced `Secret` is genuinely required. Platform and automation
  credentials — the Slack webhook (B5) and the future console GitHub App key — are stored in
  Secret Manager and read the same way (TC-13). Add a reference example (a new case extending the
  existing Workload-Identity example, which today reads a secret via the API — this proves the
  *mount* path).
- **Touches:** `gke-cluster` (the add-on field), a reference `SecretProviderClass` + example
  workload under `examples/`, `k8s/platform/README.md`, the design + build docs.
- **Depends on:** none (Workload Identity already built).
- **Acceptance:**
  - [ ] The GKE-managed Secret Manager add-on is enabled on the cluster (Terraform field; `plan`
        assertion).
  - [ ] A reference `SecretProviderClass` + workload demonstrates a runtime mount via Workload
        Identity **with no standing `Secret`**; the manifest carries only a reference.
  - [ ] ESO is documented as the synced-`Secret` exception; `terraform validate`/`plan`/lint green.
  - [ ] The live mount is asserted by `validate.sh` (run in M4c).

#### A5 — Verifier + validation for M4a
- **Goal:** keep the preflight and the end-to-end suite current for the M4a controls.
- **Work:** add a `setup-doctor` check that the Secret Manager add-on is enabled (read via the
  GKE API), with mocked pass + failure unit tests. Author the in-cluster `validate.sh` cases —
  **privileged pod rejected**, **cross-namespace traffic denied** (and DNS / API / Google reach
  allowed), and **secret CSI mount with no standing `Secret`** — extending the case matrix in
  `examples/README.md`. The cases are authored here and run live at the M4c bring-up.
- **Touches:** `bootstrap/verifier` (+ tests), `examples/` + `validate.sh`, `examples/README.md`.
- **Depends on:** A1–A4.
- **Acceptance:**
  - [ ] `setup-doctor` confirms the Secret Manager add-on; mocked pass + failure tests; `ruff` /
        `mypy` clean; runs locally and in Continuous Integration (CI).
  - [ ] New `validate.sh` cases authored (privileged-rejected, cross-namespace-denied,
        secret-CSI-mount) and documented in the matrix.

#### Milestone 4a integration scenarios
A compliant workload deploys into a freshly stamped namespace and serves; a privileged / host /
no-limits pod is rejected at admission; a pod in one tenant namespace cannot reach another but
resolves DNS, reaches the API server, and reaches Google APIs; a workload mounts a Secret
Manager secret via the CSI driver with no standing `Secret`.

---

### Milestone 4b — Supply chain, posture & the closed loop

*Goal: only externally-attested images are admissible (audit in dev, enforce-ready); the
security configuration is continuously reconciled and self-heals; posture is scanned and
reported; evidence is tamper-evident; anomalies and silence raise a Slack alert.*
*Demo: an attested image is admitted while an unattested one is logged as would-block; Argo CD
reverts a manual edit to a NetworkPolicy; a scheduled and an on-demand scan write reports to the
locked bucket; a missed scan and a drift event each raise a Slack alert.*

#### B1 — Binary Authorization: attestor + verify policy (SEC-2, [#12](https://github.com/kg-aifabrik/iac-gke/issues/12)) — *ADR-0011*
- **Goal:** admit only images carrying a valid attestation from the **external, trusted CI/CD
  system** — the platform verifies, it does not sign or scan.
- **Work:** in the `supply-chain` module, create a Binary Authorization **attestor**
  (`google_binary_authorization_attestor`) backed by a Container Analysis **attestation Note**
  (`google_container_analysis_note`), registering the **external signer's public key** — ideally
  a *reference* to their Cloud KMS asymmetric key version's public key, so no private key
  material is held or exchanged on our side. Change the policy's default admission rule from
  today's `ALWAYS_ALLOW` to **`REQUIRE_ATTESTATION`** by that attestor, keeping dev's evaluation
  in **`DRYRUN_AUDIT_LOG_ONLY`** (audit: log the would-block decision, block nothing) and
  parameterising the enforcement mode so staging / production are **`ENFORCED_BLOCK_AND_AUDIT_LOG`**
  (enforce-ready; the actual flip is gated on those clusters existing,
  [#14](https://github.com/kg-aifabrik/iac-gke/issues/14)). Keep the `admission_whitelist_patterns`
  for Google system images and our two registries. Establish the **one cross-team trust grant**:
  the external signer's identity gets permission to attach attestations to our Note
  (`roles/containeranalysis.notes.attacher`). The signer identity, the public-key reference, and
  the attestation format are **inputs**, supplied per environment; in dev they may be a
  throwaway test key so the gate is exercised before the real CI/CD integration exists (the
  inter-team contract is a tracked dependency — §7). **Artifact Analysis** vulnerability scanning
  stays enabled on the repositories as cheap, independent platform-side evidence feeding the
  posture record (SEC-7); it does **not** gate admission — the blocking quality gate is the CI/CD
  team's, asserted by the attestation. The "platform verifies, does not sign" boundary and the
  rejected alternatives (a platform-owned signing pipeline; registry-path-only trust) are
  recorded in ADR-0011.
- **Touches:** `terraform/modules/supply-chain`, the foundation if a new service-agent grant is
  needed, the design + build docs.
- **Depends on:** none.
- **Acceptance:**
  - [ ] An attestor + Container Analysis Note exist; the attestor registers the external signer's
        public-key reference (parameterised).
  - [ ] The policy default rule is `REQUIRE_ATTESTATION` by the attestor; dev evaluation is
        `DRYRUN_AUDIT_LOG_ONLY`; the enforcement mode is parameterised so stage/prod are
        enforce-ready; the system + own-registry whitelist is intact.
  - [ ] The external signer's identity holds the Note attach-grant (parameterised).
  - [ ] Artifact Analysis scanning is enabled on the repositories (independent evidence, non-gating).
  - [ ] `terraform validate` / `plan` / `tflint` / `tfsec` green with assertions on the policy
        contents; the inter-team attestation contract (key + format) is documented as a dependency.

#### B2 — Argo CD: the closed-loop reconciler (SEC-5) — *ADR-0012*
- **Goal:** continuously reconcile the committed security configuration and **self-heal drift**,
  with no person in the steady-state loop — using **Argo CD**, the same reconciler the team will
  use for workload delivery, so the cluster runs **one** GitOps controller, not two.
- **Work:** install Argo CD as a **pinned platform add-on** from the apply workflow (the same
  pattern as cert-manager: `helm upgrade --install` at a pinned chart version, documented in
  `k8s/platform/README.md`). Harden it: **no public endpoint** — the Argo CD server is exposed
  only through the **internal gateway** (an `HTTPRoute` on `gke-l7-rilb`, an internal hostname
  resolved by the private zone), single-sign-on to the Google Workspace identity
  ([TC-5](../technology-choices.md)) via Argo's OpenID Connect, scoped RBAC, and the
  `platform-critical` priority tier; the built-in admin is disabled. Create a locked-down
  **`platform-security` `AppProject`** whose only permitted source is this repository's
  `k8s/security/` path and whose only destination is this cluster — **isolated from the (future)
  workload `AppProject`** so a workload-delivery problem cannot disable the guardrails. Define the
  security `Application` (an `ApplicationSet` instantiating the stamp per tenant namespace from a
  single list — name + owner + size — which gives SEC-3 "one template applied identically", plus
  the admission policies and the scanners from B4) with `syncPolicy.automated: { selfHeal: true,
  prune: true }` and **sync waves** so the guardrails reconcile before any workload. Argo CD
  **adopts** the M4a manifests (stamp, admission policies), moving them from pipeline-applied to
  continuously reconciled. Argo CD itself is a privileged, always-on component and is therefore
  covered by the posture scan (B4) and runs under the hardening above; the tension with TC-1
  (which rejected always-on reconcilers for *cloud* resources) is recorded in ADR-0012 — this is
  in-cluster security only, and the reconciler is hardened and scanned.
- **Touches:** the apply workflow (pinned install), `k8s/platform/README.md`, `k8s/security/argocd/`
  (AppProject + Application(set)), an internal `HTTPRoute`, the design + build docs.
- **Depends on:** A1–A2 (a security config to reconcile).
- **Acceptance:**
  - [ ] Argo CD is installed at a pinned version (workflow + `k8s/platform/README.md` agree).
  - [ ] The server is reachable **only via the internal gateway** (no public IP), single-sign-on
        enabled, RBAC scoped, `platform-critical` priority, admin disabled.
  - [ ] A `platform-security` `AppProject` restricts source to `k8s/security/` and destination to
        this cluster, isolated from the workload project.
  - [ ] The security `Application(set)` syncs `k8s/security/` with `selfHeal` + `prune` and sync
        waves; manifests validate. Drift-revert is proven live in M4c (delete a NetworkPolicy →
        restored).

#### B3 — Tamper-evident evidence store (SEC-7) — *ADR-0013*
- **Goal:** archived posture reports are append-only and cannot be silently overwritten or
  removed.
- **Work:** a new `evidence-bucket` module (instantiated in the **foundation**, a project
  singleton that persists across cluster rebuilds like the KMS key) creates a Cloud Storage
  bucket with **object versioning**, a **retention policy**, uniform bucket-level access, public-
  access prevention, and CMEK encryption with the cluster key. A writer identity (the scanner's
  Google service account, bound via Workload Identity) gets `roles/storage.objectCreator` —
  **create, not delete** — so reports are append-only. The retention **lock** (Bucket Lock —
  irreversible write-once-read-many, WORM) is parameterised: **off in dev with short retention**
  (a locked bucket cannot be emptied or deleted until retention expires, which would strand a dev
  teardown — the teardown-hygiene lesson of [#31](https://github.com/kg-aifabrik/iac-gke/issues/31)),
  **on with longer retention in staging / production**. Rejected alternatives (a plain mutable
  bucket; BigQuery, which is not WORM; an external service) are recorded in ADR-0013.
- **Touches:** `terraform/modules/evidence-bucket/` (new), `project-foundation` (instantiate),
  the design + build docs.
- **Depends on:** none.
- **Acceptance:**
  - [ ] A versioned bucket with a retention policy, uniform access, public-access prevention, and
        CMEK exists.
  - [ ] The writer identity has create-not-delete (append-only); a delete/overwrite of an archived
        object is denied (assertion).
  - [ ] The retention lock is parameterised (off in dev, on in stage/prod); the dev-teardown
        behaviour is documented; `terraform validate`/`plan`/`tfsec` green.

#### B4 — Posture scanning + baseline report (SEC-4/6)
- **Goal:** measure posture on a schedule and on demand, and archive a baseline at build.
- **Work:** author `kube-bench` (the CIS GKE benchmark checker) and `kubescape` (posture scanner,
  National Security Agency / CIS frameworks) as **CronJobs** (scheduled) plus an **on-demand Job**
  template under `k8s/security/scanners/`, pinned to specific image digests, reconciled by Argo CD.
  Each run writes its report to the evidence bucket (B3) through the writer service account
  (Workload Identity). On GKE the control plane is Google-managed, so `kube-bench` targets the
  node and policy checks and the managed control-plane items are marked **not-applicable** with a
  documented justification. The **baseline report** is the first run at (or immediately after)
  build — the cluster's starting evidence (SEC-4); subsequent scheduled and on-demand runs are the
  day-2 reports (SEC-6).
- **Touches:** `k8s/security/scanners/` (new), the apply workflow / Argo bootstrap, the design +
  build docs.
- **Depends on:** B3 (the evidence sink), B2 (Argo reconciles the scanners).
- **Acceptance:**
  - [ ] `kube-bench` (CIS GKE Level 2) + `kubescape` run on a schedule and on demand; images
        pinned by digest; manifests validate.
  - [ ] Each run writes a report to the evidence bucket via the append-only writer.
  - [ ] A baseline report is produced at build and archived. Live runs proven in M4c.

#### B5 — Alerting on anomaly and on silence (SEC-8)
- **Goal:** a Slack alert on anomalies (corrected drift, benchmark regression) **and** on silence
  (a scheduled scan that fails to run, or unhealthy enforcement) — the dead-man's-switch SEC-8
  requires.
- **Work:** a new `monitoring-alerts` module creates a Cloud Monitoring **Slack notification
  channel** (the webhook read from Secret Manager — never committed or logged) and the alert
  **policies**: *anomaly* — Argo CD drift corrected (a self-heal / `OutOfSync`→`Synced`
  transition) and a benchmark regression (a scan result worse than the baseline, surfaced as a
  log-based metric the scan job emits); *silence* — a **missing fresh scan report** in the
  evidence bucket within the expected window (an absence-of-metric alert — the dead-man's-switch)
  and unhealthy enforcement (the Argo security `Application` `Degraded`/`Unknown`, or the Binary
  Authorization policy missing). Validating that an alert *fires* end to end is hard inside a
  short bring-up, so the acceptance asserts the channel + policies exist and the dead-man's-switch
  is wired; an optional forced test is run at the bring-up.
- **Touches:** `terraform/modules/monitoring-alerts/` (new), Secret Manager (the webhook secret),
  the scanners (emit the metrics), the design + build docs.
- **Depends on:** B4 (scan signals), B2 (Argo drift signals).
- **Acceptance:**
  - [ ] A Slack notification channel exists with the webhook read from Secret Manager (not in Git
        or logs).
  - [ ] Alert policies exist for: corrected drift, benchmark regression, a missed scheduled scan
        (dead-man's-switch), and unhealthy enforcement.
  - [ ] `terraform validate` / `plan` / `tfsec` green with assertions on the policy set.

#### B6 — Verifier + validation for M4b
- **Goal:** keep the preflight and the suite current for the supply-chain, closed-loop, evidence,
  and alerting controls.
- **Work:** add `setup-doctor` checks (Google-Cloud side) — the attestor exists and the policy
  requires attestation with dev in `DRYRUN`; Artifact Analysis is enabled; the evidence bucket is
  versioned, retained, locked (in non-dev), and has the append-only writer; the alert policies and
  notification channel exist — each with mocked pass + failure tests. Author the in-cluster
  `validate.sh` cases — an **attested image is admitted** while an **unattested one is logged as
  would-block** (audit), Argo CD **reverts a manual NetworkPolicy edit**, and an **on-demand scan
  writes a report to the bucket**.
- **Touches:** `bootstrap/verifier` (+ tests), `examples/` + `validate.sh`, `examples/README.md`.
- **Depends on:** B1–B5.
- **Acceptance:**
  - [ ] `setup-doctor` checks for the attestor + policy, Artifact Analysis, the evidence bucket
        (versioning + retention + lock-in-non-dev + writer), and the alert policies; mocked pass +
        failure tests; `ruff` / `mypy` clean.
  - [ ] `validate.sh` cases authored (attested-admitted / unattested-logged-block, drift self-heal,
        scan-produces-evidence) and documented in the matrix.

#### Milestone 4b integration scenarios
Argo CD reconciles `k8s/security/` and reverts a manual drift; an externally-attested image is
admitted while an unattested one is audit-logged as would-block; a scheduled and an on-demand
scan write reports to the locked evidence bucket; a missed scan, a corrected drift, and a
benchmark regression each raise a Slack alert.

---

### Milestone 4c — CIS Level 2 proof, validation & live bring-up

*Goal: prove the floor, finish the living docs, and validate the whole stack on a real cluster.*

#### C1 — CIS Kubernetes Benchmark Level 2 proof (SEC-2 floor)
- **Goal:** demonstrate the cluster clears the CIS Kubernetes Benchmark at Level 2.
- **Work:** run `kube-bench` at Level 2 against the live cluster; remediate failures, or document
  each as a justified exception (managed control-plane items are not-applicable on GKE). Record
  the clean (or annotated) result as the cluster's floor evidence.
- **Acceptance:**
  - [ ] `kube-bench` Level 2 is clean, or every remaining item is documented with a justification.
  - [ ] The result is archived in the evidence bucket.

#### C2 — Living docs + consolidated validation matrix
- **Goal:** the living documents and the requirement record are current as part of the change.
- **Work:** add a **Security** section to `google-cloud-design.md` (the stamp, the guardrails,
  supply-chain verification, the closed loop, evidence, alerting, the secret runtime) and update
  the network-egress (§4) and supply-chain (§7) sections to match the as-built behaviour
  ("verify external attestation", default-deny egress); document each new layer in
  `cluster-build.md`; **resolve the open questions** in `security-requirements.md` (egress =
  deny-with-opt-in; quota = named sizes; attestation = external / verify-only; the closed-loop
  reconciler = Argo CD; mTLS = deferred to Milestone 5); refresh `examples/README.md`,
  `progress-report.md`, and the `README.md` security bullets.
- **Acceptance:**
  - [ ] `google-cloud-design.md`, `cluster-build.md`, and `security-requirements.md` reflect the
        as-built design with the open questions resolved; cross-links correct.
  - [ ] `examples/README.md`, `progress-report.md`, and `README.md` updated.

#### C3 — Live bring-up, integration validation, retrospective
- **Goal:** build dev for real, run the full suite, record the milestone.
- **Work:** the gated pipeline builds the dev FOP cluster end to end — now also installing Argo CD,
  the scanners, the Secret Manager add-on, the attestor, the evidence bucket, and the alert
  policies. Run `setup-doctor` and the extended `validate.sh` (~18–20 cases) against the live
  cluster; capture the evidence (the baseline posture report, the CIS Level 2 result, a
  drift-self-heal demonstration, the audit-log would-block decision). Tear down, confirming **zero
  billable resources** remain (the foundation evidence bucket is unlocked in dev, so it can be
  emptied and deleted or deliberately retained — documented). Write the retrospective. East-west
  mTLS is **explicitly deferred** to Milestone 5.
- **Acceptance:**
  - [ ] The gated pipeline builds the dev cluster end to end.
  - [ ] `setup-doctor` and the extended `validate.sh` pass against the live cluster; evidence
        recorded.
  - [ ] Teardown leaves zero billable resources; the evidence-bucket dev behaviour is confirmed.
  - [ ] The retrospective is written; mTLS / mesh is recorded as Milestone 5.

#### Milestone 4c integration scenarios
The whole stack stands up from the gated pipeline on a live cluster; CIS Level 2 is clean or
annotated; the full `validate.sh` is green; teardown is clean.

Each milestone also gets a **tracking issue** and a **retrospective issue**, grouped under its
native GitHub Milestone (repo convention).

## 5. Decisions to record (ADRs)

Authored on approval, continuing the sequence after ADR-0008 (MADR format: context → options →
decision → consequences):

- **ADR-0009 — Per-namespace security stamp + scoped operator RBAC.** One identical stamp per
  tenant namespace; **egress deny-with-opt-in** (rejected: allow-with-logging); **named quota
  sizes** (rejected: one fixed size); operators **scoped, no wildcards** (rejected: standing
  `cluster-admin`). Platform namespaces are a documented exception to *restricted* PSS.
- **ADR-0010 — Admission guardrails via Pod Security Admission + `ValidatingAdmissionPolicy`.**
  Native and free; rejected: Policy Controller (GKE Enterprise licence + always-on Gatekeeper),
  Kyverno / Open Policy Agent Gatekeeper (another admission controller to harden and upgrade).
- **ADR-0011 — Binary Authorization verifies externally-produced attestations.** The platform
  owns the attestor, Note, trust-key registration, and admission policy (audit → enforce-ready);
  the external CI/CD system owns scanning, quality gates, and signing. Rejected: a platform-owned
  signing pipeline (duplicates the team's gates, splits ownership); registry-path-only trust
  (does not prove scans / gates passed).
- **ADR-0012 — Closed-loop reconciliation via Argo CD (one reconciler for security and
  workloads).** Self-heal via `automated.selfHeal` + `prune`, `platform-security` `AppProject`
  isolation, internal-only and single-sign-on. Rejected: Flux (a second controller alongside the
  workload Argo CD), Config Sync (GKE Enterprise licence), pipeline-only re-apply (not continuous,
  no self-heal). Records the TC-1 tension (always-on reconcilers were rejected for *cloud*
  resources; this is in-cluster security only, hardened and scanned).
- **ADR-0013 — Tamper-evident evidence retention via a retention-locked Cloud Storage bucket.**
  WORM via retention policy + Bucket Lock, append-only writer, versioning. Rejected: a plain
  mutable bucket; BigQuery (not WORM); an external service.
- **ADR-0003 amended** — re-affirm that east-west mTLS / service mesh stays deferred for M4; the
  stamp is built mesh-agnostic so adopting Cloud Service Mesh later (reusing the CAS root, the
  gateway staying north-south) is non-breaking.

The runtime secret choice is already settled in [TC-13](../technology-choices.md); no new ADR.

## 6. Technical Design Record (TDR)

`docs/designs/security-hardening.md` (matching the un-numbered convention of
`google-cloud-design.md`): goal & scope; **the closed-loop architecture** (Git → Argo CD →
cluster; scan → evidence bucket → Cloud Monitoring → Slack); the **stamp template** interfaces
and the platform-namespace exception set; the **supply-chain verification** data flow (external
CI/CD signs → our attestor + Note verify → Binary Authorization admits) and the inter-team trust
contract; the in-cluster object-ownership split (Terraform-for-Google; the pipeline applies the
Terraform-output-coupled manifests; **Argo CD owns the pure-Git security config**); alternatives
considered; risks and open questions; related ADRs.

## 7. Cross-cutting requirements

- **Coding standards (CLAUDE.md):** module/file headers; described variables/outputs; comments
  explain *why* and what was rejected; declarative documentation voice; acronyms expanded on
  first use; pinned add-on versions (in the apply workflow **and** `k8s/platform/README.md` — bump
  together); committed lockfiles.
- **Per-issue gate:** `terraform validate` / `plan` / `tflint` / `tfsec` / plan-output assertions
  green (no cloud cost), or mocked tests green for `setup-doctor` (`ruff` / `mypy`) and
  `kubeconform` for manifests, before commit; the commit references the issue; close when green.
- **Verifier split:** `setup-doctor` verifies Google-Cloud-side config; `validate.sh` verifies
  in-cluster behaviour over Connect Gateway. New checks go to whichever can actually observe the
  control.
- **Living documents** updated as part of each change, not after:
  [`google-cloud-design.md`](../designs/google-cloud-design.md) and
  [`cluster-build.md`](../implementation/cluster-build.md).
- **Secrets** are never committed or logged; the Slack webhook and any platform credential live in
  Secret Manager and are read via Workload Identity.

## 8. Risks & open items

1. **The external-attestation contract** (key + format) — Binary Authorization needs the CI/CD
   team's attestation format (Container Analysis occurrence + a Cloud KMS / Public-Key-
   Infrastructure-X.509 key, versus cosign / sigstore signatures) and a public-key reference.
   **Not a blocker for dev-audit wiring** (a throwaway test key proves the gate); it **is** a
   prerequisite for any enforce. Tracked as a dependency.
2. **Argo CD is a new privileged, always-on component with a web surface** (Flux had none).
   Mitigated: internal-gateway-only, single-sign-on, scoped RBAC, `platform-security` `AppProject`
   isolation, and covered by the posture scan. Confirm the hardening posture is acceptable.
3. **PSS *restricted* would break the platform components** (cert-manager, Argo CD, the CSI
   driver, the scanners). The stamp applies to **tenant** namespaces; platform namespaces are a
   documented exception governed by the cluster-wide guardrails. Confirm this reading of SEC-3
   ("every namespace" → every tenant namespace).
4. **Default-deny egress** on tenant namespaces is independent of the platform controllers pulling
   their images (those run in the exception namespaces); image mirroring
   ([#27](https://github.com/kg-aifabrik/iac-gke/issues/27)) stays separate and is **not** a
   blocker. If platform-namespace egress is later locked down, #27 becomes a prerequisite.
5. **Scoped operator RBAC vs `validate.sh`** — the suite creates throwaway scaffolding; the scoped
   role must cover that, or the suite runs as the automation identity. Decide in A3.
6. **Evidence-bucket retention lock in dev** — a locked bucket cannot be torn down until retention
   expires; dev stays **unlocked / short-retention**, stage/prod locked. Confirm.
7. **The two reconciliation paths** — Terraform-output-coupled manifests stay pipeline-applied;
   the pure-Git security config moves to Argo CD. Security-critical objects (stamp, policies,
   scanners) are Argo-managed so they self-heal (SEC-5); the operator RBAC render's ownership
   (pipeline vs Argo) is resolved in A3 / the TDR.

## 9. Deferred / related issues

- **East-west mTLS / service mesh** → Milestone 5
  ([#15](https://github.com/kg-aifabrik/iac-gke/issues/15)); stamp built mesh-agnostic.
- **Binary Authorization enforce flip** in staging / production
  ([#12](https://github.com/kg-aifabrik/iac-gke/issues/12) machinery here;
  [#14](https://github.com/kg-aifabrik/iac-gke/issues/14) flips it when those clusters exist).
- **Cloud Armor web-application-firewall enforce + tuning**
  ([#26](https://github.com/kg-aifabrik/iac-gke/issues/26)).
- **Mirror platform add-on images through Artifact Registry**
  ([#27](https://github.com/kg-aifabrik/iac-gke/issues/27)).
- **Observability — alerting, dashboards, service-level objectives**
  ([#33](https://github.com/kg-aifabrik/iac-gke/issues/33)); distinct from the SEC-8 security
  alerting built here.

## 10. Related

[google-cloud-design.md](../designs/google-cloud-design.md) ·
[security-requirements.md](../security-requirements.md) ·
[technology-choices.md](../technology-choices.md) (TC-12 supply chain, TC-13 secrets, TC-7 TLS) ·
[ADR-0003](../adr/0003-service-mesh-deferred.md) · [cluster-build.md](../implementation/cluster-build.md) ·
[progress report](../progress-report.md) · overview issue
[#17](https://github.com/kg-aifabrik/iac-gke/issues/17).
