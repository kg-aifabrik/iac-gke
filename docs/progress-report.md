# Progress report

Detailed, milestone-by-milestone delivery status for `iac-gke` — the platform automation that
builds and operates hardened Google Kubernetes Engine (GKE) clusters. The [README](../README.md)
carries only the high-level summary; this is the living detail, kept current at each milestone
close-out.

Each milestone was planned into independently testable **chunks** (one GitHub issue each),
grouped under a native **GitHub Milestone**, built green through the gated pipeline, proven
against a real dev cluster, and closed with a **retrospective** issue. Deferred work is tracked
as standalone open issues (bottom of this page).

_Last updated: 2026-06-10._

## At a glance

| Milestone | Scope | State | GitHub Milestone |
|---|---|---|---|
| **M0** — Verified keyless access | Workload Identity Federation (WIF) + service-account impersonation + `setup-doctor` + a continuous-integration (CI) demo | ✅ **closed** | [Milestone 1](https://github.com/kg-aifabrik/iac-gke/milestone/1) |
| **M1** — Cluster factory | a hardened, private, regional cluster as `account × environment × purpose` configuration | ✅ **closed** | [Milestone 2](https://github.com/kg-aifabrik/iac-gke/milestone/2) |
| **M2** — Ingress and TLS | two gateways (internal + external), public + private (Certificate Authority Service, CAS) certificates, a baseline web application firewall (WAF) | ✅ **closed** | [Milestone 3](https://github.com/kg-aifabrik/iac-gke/milestone/3) |
| **M3** — High availability | node autoscaling, Backup for GKE + restore, regional-persistent-disk storage, multi-host ingress + Cloud DNS, scheduling tiers | 🟢 **built & validated** (13/13 live); open for one cold-start check | [Milestone 4](https://github.com/kg-aifabrik/iac-gke/milestone/4) |
| **M4** — Security hardening | image supply chain / Binary Authorization enforce, posture, namespace stamps, mutual TLS (mTLS) | 🔭 **planned** | overview issue [#17](https://github.com/kg-aifabrik/iac-gke/issues/17) |

## M0 — Verified keyless access ✅

GitHub Milestone: [Milestone 1](https://github.com/kg-aifabrik/iac-gke/milestone/1) — closed.

The trust anchor every later milestone builds on: GitHub Actions authenticates to the project
with **no downloadable keys** (WIF + impersonation of a least-privilege automation service
account), pinned to this repository's immutable `repository_id` and the `main` ref. Proven by a
green CI run of `setup-doctor`.

| Issue | Chunk |
|---|---|
| [#1](https://github.com/kg-aifabrik/iac-gke/issues/1) | Keyless access: setup runbook + verifier + CI demo |

## M1 — Cluster factory ✅

GitHub Milestone: [Milestone 2](https://github.com/kg-aifabrik/iac-gke/milestone/2) — closed.

A cluster is **chosen, not coded** — one hardened recipe parameterized by `account × environment
× purpose`. Delivered the private, regional cluster (DNS-only control plane, Dataplane V2,
shielded + Container-Optimized OS nodes, Workload Identity, Customer-Managed Encryption Keys),
its network, its supply chain (Artifact Registry + Binary Authorization), Connect-Gateway access,
and the gated plan/apply/destroy pipeline.

| Issue | Chunk |
|---|---|
| [#3](https://github.com/kg-aifabrik/iac-gke/issues/3) | Foundation and bootstrap |
| [#4](https://github.com/kg-aifabrik/iac-gke/issues/4) | network module |
| [#5](https://github.com/kg-aifabrik/iac-gke/issues/5) | gke-cluster module |
| [#6](https://github.com/kg-aifabrik/iac-gke/issues/6) | supply-chain module |
| [#7](https://github.com/kg-aifabrik/iac-gke/issues/7) | access (Connect Gateway) module |
| [#8](https://github.com/kg-aifabrik/iac-gke/issues/8) | envs/dev wiring |
| [#9](https://github.com/kg-aifabrik/iac-gke/issues/9) | approval-gated workflows (plan/apply/destroy) |
| [#10](https://github.com/kg-aifabrik/iac-gke/issues/10) | extend setup-doctor (cluster-setup checks) |
| [#11](https://github.com/kg-aifabrik/iac-gke/issues/11) | examples/ + post-build validation (end-user) |
| [#18](https://github.com/kg-aifabrik/iac-gke/issues/18) | retrospective |

## M2 — Ingress and TLS ✅

GitHub Milestone: [Milestone 3](https://github.com/kg-aifabrik/iac-gke/milestone/3) — closed.

Two gateways per cluster (internal `gke-l7-rilb`, external global). Public endpoints use
Certificate Manager managed certificates; internal endpoints use a private CA in CAS via
cert-manager / google-cas-issuer / trust-manager, so internal hostnames never enter public
Certificate Transparency logs. A baseline Cloud Armor policy fronts the external edge.

| Issue | Chunk |
|---|---|
| [#19](https://github.com/kg-aifabrik/iac-gke/issues/19) | Network: proxy-only subnet |
| [#20](https://github.com/kg-aifabrik/iac-gke/issues/20) | private-ca (CAS) module |
| [#21](https://github.com/kg-aifabrik/iac-gke/issues/21) | gke-gateway module |
| [#22](https://github.com/kg-aifabrik/iac-gke/issues/22) | in-cluster TLS add-ons (cert-manager, google-cas-issuer, trust-manager) |
| [#23](https://github.com/kg-aifabrik/iac-gke/issues/23) | envs/dev wiring + pipeline |
| [#24](https://github.com/kg-aifabrik/iac-gke/issues/24) | extend setup-doctor (ingress checks) |
| [#25](https://github.com/kg-aifabrik/iac-gke/issues/25) | examples + ingress validate test (end-user) |
| [#29](https://github.com/kg-aifabrik/iac-gke/issues/29) | retrospective |

## M3 — High availability 🟢

GitHub Milestone: [Milestone 4](https://github.com/kg-aifabrik/iac-gke/milestone/4) — **open**.

Built and **validated 13/13 against a live dev cluster**, then torn down. The milestone is held
open for a single cold-start assertion ([#46](https://github.com/kg-aifabrik/iac-gke/issues/46))
that can only be observed on the *next* bring-up — node-pool growth from the initial count under
load. Everything else is delivered, tested, and closed.

| Issue | Chunk | State |
|---|---|---|
| [#35](https://github.com/kg-aifabrik/iac-gke/issues/35) | HA-1: node-pool autoscaling + pinned surge as runtime config | ✅ closed |
| [#36](https://github.com/kg-aifabrik/iac-gke/issues/36) | HA-2: Backup for GKE — agent, CMEK key grant, backup + restore plans | ✅ closed |
| [#37](https://github.com/kg-aifabrik/iac-gke/issues/37) | HA-3: regional persistent-disk StorageClass (`encrypted-regional-rwo`) | ✅ closed |
| [#38](https://github.com/kg-aifabrik/iac-gke/issues/38) | HA-4a: multi-host gateways — hostname lists, per-host public certs, multi-SAN CAS cert | ✅ closed |
| [#39](https://github.com/kg-aifabrik/iac-gke/issues/39) | HA-4b: Cloud DNS — private zone for internal names; opt-in public zone | ✅ closed |
| [#40](https://github.com/kg-aifabrik/iac-gke/issues/40) | HA-5: platform scheduling tiers + HA for the TLS add-ons | ✅ closed |
| [#41](https://github.com/kg-aifabrik/iac-gke/issues/41) | HA-6: setup-doctor checks — autoscaling, backup plan, private DNS | ✅ closed |
| [#42](https://github.com/kg-aifabrik/iac-gke/issues/42) | HA-7: production-grade HA examples + extended validate.sh | ✅ closed |
| [#43](https://github.com/kg-aifabrik/iac-gke/issues/43) | HA-8: live bring-up, integration validation, retrospective | 🟢 open (pending #46) |
| [#44](https://github.com/kg-aifabrik/iac-gke/issues/44) | tracking | 🟢 open |
| [#45](https://github.com/kg-aifabrik/iac-gke/issues/45) | retrospective | 🟢 open |
| [#46](https://github.com/kg-aifabrik/iac-gke/issues/46) | verify cold-start node-autoscale growth (3→N) on the next bring-up | 🟢 open |

A cross-cutting teardown fix landed alongside this milestone:
[#31](https://github.com/kg-aifabrik/iac-gke/issues/31) — the GKE Gateway controller's load
balancers were orphaned by cluster deletion and blocked `terraform destroy`; the destroy
workflow now deletes the in-cluster Gateways first so the controller releases them. The
validation matrix was baselined in [#34](https://github.com/kg-aifabrik/iac-gke/issues/34).

## M4 — Security hardening 🔭 (planned)

No native GitHub Milestone yet — it begins with interactive security-requirements design work.
Overview issue: [#17](https://github.com/kg-aifabrik/iac-gke/issues/17). Expected scope: flip
Binary Authorization to enforce, supply-chain attestation, security posture, namespace stamps,
and a service-to-service mTLS / mesh decision.

## Pending / deferred work (not yet scheduled)

Open follow-ups that are intentionally out of a current milestone. Each will be pulled into the
milestone it belongs to (several into M4) when that work starts.

| Issue | Title |
|---|---|
| [#12](https://github.com/kg-aifabrik/iac-gke/issues/12) | Flip Binary Authorization to enforce |
| [#13](https://github.com/kg-aifabrik/iac-gke/issues/13) | Build the dev Management Plane (MGMT) cluster |
| [#14](https://github.com/kg-aifabrik/iac-gke/issues/14) | Stage and production clusters + controlled-upgrade day-2 operation |
| [#15](https://github.com/kg-aifabrik/iac-gke/issues/15) | Decide service-to-service mTLS / service mesh |
| [#16](https://github.com/kg-aifabrik/iac-gke/issues/16) | Node-pool day-2 operations + autoscaling baseline |
| [#26](https://github.com/kg-aifabrik/iac-gke/issues/26) | Enable + tune Cloud Armor WAF on the public gateway |
| [#27](https://github.com/kg-aifabrik/iac-gke/issues/27) | Mirror platform TLS add-on images through Artifact Registry (no public egress) |
| [#28](https://github.com/kg-aifabrik/iac-gke/issues/28) | Distribute the CAS root to browser trust stores via mobile device management (MDM) |
| [#33](https://github.com/kg-aifabrik/iac-gke/issues/33) | Observability: workload alerting, dashboards, and service-level objectives (SLOs) |
