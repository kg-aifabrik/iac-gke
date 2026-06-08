# Milestone 2 — Ingress and TLS (implementation plan)

*Status: draft for review · Date: 2026-06-08*
*Design (the why): [cluster-ctrl `docs/designs/google-cloud-design.md` §8](https://github.com/kg-aifabrik/cluster-ctrl/blob/main/docs/designs/google-cloud-design.md). Decisions: ADR-0001 (two gateways per cluster), ADR-0002 (internal TLS via CAS), ADR-0003 (mesh deferred). Issues for this milestone link back to this plan.*

---

## 1. Goal and definition of done

Give a built cluster a complete, hardened **ingress** capability: two gateways (internal +
external), TLS on every endpoint (public certs external, a private CAS-issued CA internal),
and a baseline web application firewall (WAF) on the public edge — proven by deploying a test
ingress and getting an end-to-end HTTPS 200 through each gateway.

**Done when:** an operator builds the dev cluster, the pipeline provisions both gateways and
their certificates, the validate test deploys a test route to each gateway and a client gets
**HTTPS 200** with the expected body — over the **public** gateway against a real hostname
(`app.dev.arthos.app`, publicly-trusted cert) and over the **internal** gateway against a
private hostname (CAS-issued cert that chains to the CAS root) — evidence recorded, torn down.

## 2. Scope

- **In:** the proxy-only subnet; the private CA (CAS) module; the reusable gateway module
  (Google edge resources + rendered in-cluster manifests); the in-cluster TLS add-ons
  (cert-manager, google-cas-issuer, trust-manager); dev wiring + pipeline; the setup verifier
  extension; a runnable ingress validate test.
- **Out:** east-west service-to-service mTLS / service mesh (security phase, ADR-0003); full
  WAF rule enablement and tuning (tracked separately); the on-prem ingress implementation
  (the on-prem cluster track); autoscaling.

## 3. Repository layout

```
terraform/modules/
  network/        + proxy-only subnet
  private-ca/     CAS: CA pool + root + per-env subordinate; cert-manager WI grant   (new)
  gke-gateway/    per-gateway Google edge resources + rendered Gateway/HTTPRoute/ReferenceGrant  (new)
terraform/envs/dev/fop/   + the two gateways, CAS, and add-on wiring
k8s/platform/     pinned manifests for cert-manager / google-cas-issuer / trust-manager  (new)
examples/         + an ingress test case (HTTPRoute fronting hello-web on each gateway)
.github/workflows/  apply extended to install add-ons + apply gateway manifests over Connect Gateway
```

## 4. Issues

Seven issues under the Milestone. Each is green on `terraform validate` + `plan` +
`tflint`/`tfsec` + assertions (no cloud cost), or tests green for `setup-doctor`, follows the
coding standards, and links to this plan and the ADRs.

### Issue 1 — Network: proxy-only subnet
- **Goal:** the prerequisite for the regional internal Application Load Balancer.
- **Acceptance:** the `network` module adds a **proxy-only** subnet (regional, correct purpose);
  `validate`/`plan`/lint clean; output documented; no change to existing node/Pod/Service ranges.

### Issue 2 — `private-ca` module (CAS)
- **Goal:** the private certificate authority for internal endpoints (ADR-0002).
- **Acceptance:** a CAS **CA pool**, a long-lived **root** CA, and a **per-environment
  subordinate** CA; a Workload-Identity grant (`roles/privateca.certificateRequester`) for the
  cert-manager service account; `validate`/`plan`/lint clean; assertions for the hierarchy and
  the grant. **(Confirm-at-build:** the CAS root chains correctly through the subordinate.)

### Issue 3 — `gke-gateway` module
- **Goal:** one reusable module that stands up a gateway of either exposure.
- **Acceptance:** parameterized by `(exposure = internal|external, hostname, …)` it creates the
  Google edge resources — reserved IP, the SSL policy (minimum TLS 1.2), the HTTP→HTTPS
  redirect, and (external) the Certificate Manager managed cert + cert-map + baseline Cloud
  Armor policy — and **renders** the in-cluster `Gateway` (`gke-l7-rilb` internal /
  `gke-l7-global-external-managed` external), a sample `HTTPRoute`, and the `ReferenceGrant`.
  Internal certs come from a CAS-issued Secret; external from Certificate Manager.
  `validate`/lint clean; assertions per exposure.

### Issue 4 — In-cluster TLS add-ons (`k8s/platform/`)
- **Goal:** the controllers that issue and distribute certificates in-cluster.
- **Acceptance:** **pinned** manifests for **cert-manager**, **google-cas-issuer**, and
  **trust-manager**; a `ClusterIssuer` backed by CAS; a trust-manager **Bundle** that
  distributes the CAS root to namespaces; manifests `kubeconform`/lint clean (no live cluster
  needed). Versions pinned for reproducibility.

### Issue 5 — `envs/dev` wiring + pipeline
- **Goal:** instantiate ingress for dev and apply it through the gated pipeline.
- **Acceptance:** dev wires the proxy-only subnet, `private-ca`, and **two** `gke-gateway`
  instances (the `internal-tools` and `public-services` namespaces), with hostnames under
  `dev.arthos.app`; the apply workflow installs the `k8s/platform` add-ons and applies the
  rendered gateway/HTTPRoute/ReferenceGrant + trust Bundle over Connect Gateway; `terraform
  plan` for dev produces the full ingress; documented.

### Issue 6 — Extend `setup-doctor`
- **Goal:** keep the preflight current for ingress.
- **Acceptance:** checks that the CAS CA pool + CAs exist and are enabled, the external managed
  certificate reaches **ACTIVE**, the static IP is reserved, and the gateways are programmed;
  mocked unit tests cover pass + each failure; `ruff`/`mypy` clean; runs locally and in CI.

### Issue 7 — `examples/` ingress validate test (end-user)
- **Goal:** prove ingress works end to end from a user's point of view.
- **Acceptance:** a test **HTTPRoute** fronts the existing `hello-web` example on **each**
  gateway; the validate run asserts **HTTPS 200** with the expected body over the **external**
  gateway against `app.dev.arthos.app` (publicly-trusted cert) and over the **internal** gateway
  against its private hostname (CAS cert verified against the CAS root via the trust bundle);
  HTTP→HTTPS redirect confirmed; results documented in the issue.

## 5. Cross-cutting requirements

- **Coding standards:** module/file headers; described variables/outputs; comments explain
  *why*; declarative documentation voice; pinned add-on versions.
- **Per-issue gate:** `validate`/`plan`/`tflint`/`tfsec`/assertions green (no cost), or tests
  green for `setup-doctor`/manifests, before commit; commit references the issue; close when green.
- **Boundary:** Terraform owns Google Cloud resources; in-cluster objects (gateways, routes,
  ReferenceGrants, add-ons, trust bundle) are rendered/pinned manifests the pipeline applies
  over Connect Gateway — the M1 split.

## 6. Milestone verification (real Google Cloud, then teardown)

- **Operator prerequisites:** in GoDaddy for `dev.arthos.app` — the Certificate Manager
  **DNS-authorization** CNAME and an **A record** for `app.dev.arthos.app` → the external
  gateway's static IP; the CAS root pushed to browser trust via **MDM** for human access (the
  automated internal test verifies against the CAS root via the trust bundle, so it needs no MDM).
- Build dev through the pipeline; confirm both gateways program, the public cert reaches ACTIVE,
  the internal cert issues from CAS; run the **Issue 7** validate test for HTTPS 200 on both
  gateways; run `setup-doctor`. Record evidence in the Milestone, then `destroy`.
- **Cost:** two load balancers + a static IP + the CAS CA, short-lived. (The public cert is free.)

## 7. Deferred — tracked as open issues

- **Full WAF enablement** — enable and tune the OWASP rule set in enforce mode + rate-limiting on
  the external gateway (the build ships a baseline policy only). *(New tracking issue.)*
- **MDM CAS-root distribution** — an operator runbook step (not code): push the CAS root to
  browser trust stores. *(Documented; tracked.)*
- **East-west mTLS / service mesh** — the security phase (ADR-0003, #15).

## 8. Related

[google-cloud-design.md §8](https://github.com/kg-aifabrik/cluster-ctrl/blob/main/docs/designs/google-cloud-design.md) · ADR-0001/0002/0003 · cluster-ctrl `technology-choices.md` (TC-6/7/8) · `security-requirements.md` (SEC-10).
