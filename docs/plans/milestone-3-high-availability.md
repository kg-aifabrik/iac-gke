# Milestone 3 — High availability (implementation plan)

*Status: built & validated · Date: 2026-06-09*
*Design (the why): [`docs/designs/google-cloud-design.md`](../designs/google-cloud-design.md). Decisions: ADR-0004 (Backup for GKE), ADR-0005 (multi-host gateways, no wildcards), ADR-0006 (Cloud DNS — private zone, opt-in public), ADR-0007 (per-pool autoscaler, not Node Auto-Provisioning), ADR-0008 (regional persistent-disk second StorageClass), and ADR-0002 amendment 3 (ephemeral per-cluster Certificate Authority Service). Issues for this milestone link back to this plan.*
*Note: this plan was reconstructed for the record after the milestone shipped — M3 was driven directly from its GitHub issues, ADRs, and retrospective. It matches the as-built scope.*

---

## 1. Goal and definition of done

Make a built cluster **survive the failures a single-zone, fixed-size cluster cannot**: node
loss and load spikes (autoscaling), data loss (Backup for GKE + restore), zone loss for stateful
workloads (regional persistent disks), more than one ingress hostname per gateway (multi-host +
managed Domain Name System (DNS)), and noisy-neighbour eviction (scheduling tiers). High
availability (HA) is *runtime configuration on the same hardened recipe* — not a new cluster
type.

**Done when:** an operator builds the dev cluster, the pipeline provisions every HA capability,
and the validate suite proves them on a live cluster — serving on **every** hostname over both
gateways, **drain survival** and a **zero-failed-request rolling deploy**, **node autoscaling**,
**Horizontal Pod Autoscaler (HPA)** scale-up, **regional-PD zone failover**, **preemption** by
priority, and a **backup → restore** round-trip — evidence recorded, torn down with **zero
billable resources** left behind.

## 2. Scope

- **In:** per-zone node-pool autoscaling with pinned upgrade surge; Backup for GKE (agent, a
  Customer-Managed Encryption Key (CMEK) grant, backup + restore plans); a regional-PD
  StorageClass; multi-host gateways (hostname lists, per-host public certificates by Server Name
  Indication (SNI), a multi-Subject-Alternative-Name (SAN) internal certificate); Cloud DNS (a
  private zone, an opt-in public zone); platform scheduling tiers (PriorityClasses) + HA for the
  Transport Layer Security (TLS) add-ons; the setup verifier extension; production-grade HA
  examples + an extended `validate.sh`; the live bring-up and retrospective.
- **Out:** Node Auto-Provisioning (NAP) — rejected in favour of explicit per-pool autoscaling
  (ADR-0007); wildcard certificates (ADR-0005); cross-region disaster recovery; stage/prod
  clusters (their own track, #14); observability / alerting / service-level objectives (its own
  milestone, #33); the Cloud Armor web-application-firewall enforce pass (#26).

## 3. Repository layout

```
terraform/modules/
  gke-cluster/    + per-pool autoscaling (per-zone min/max, BALANCED), autoscaling_profile,
                    pinned surge (max_surge=1/max_unavailable=0), backup-agent addon
  gke-backup/     Backup for GKE: backup plan (cron, retention, CMEK) + restore plan   (new)
  dns-zones/      Cloud DNS: private zone + per-host records; opt-in public zone        (new)
  gke-gateway/    + hostname lists; per-host external certs (SNI); multi-SAN internal cert
  private-ca/     + ephemeral per-cluster CAS with random-suffix names (ADR-0002 amend. 3)
  project-foundation/  + gkebackup API, service agent, third CMEK grant (backup)
  cluster-stack/  + composes gke-backup, dns-zones, PriorityClasses, regional StorageClass
terraform/envs/dev/fop/   + autoscaling bounds, multi-host, manage_public_dns, backup wiring
examples/         + regional-PVC, autoscale, HPA, preemption cases; validate.sh (13 cases)
bootstrap/verifier/  + HA checks (autoscaling, backup plan, DNS zones, per-host active certs)
.github/workflows/  destroy: delete in-cluster Gateways first to release controller LBs (#31)
```

## 4. Issues

Nine chunk issues under the Milestone, each green on `terraform validate` + `plan` +
`tflint`/`tfsec` + plan-output assertions (no cloud cost), or tests green for `setup-doctor` /
manifests, following the coding standards and linking back to this plan — plus a tracking issue
and a retrospective.

### Issue HA-1 — Node-pool autoscaling + pinned surge ([#35](https://github.com/kg-aifabrik/iac-gke/issues/35))
- **Goal:** absorb load and node loss without manual resizing, with controlled upgrades.
- **Acceptance:** `gke-cluster` exposes per-pool autoscaling (per-zone `min`/`max`, `BALANCED`
  location policy) and an `autoscaling_profile`; cluster-level NAP stays **off** (ADR-0007);
  upgrade surge pinned (`max_surge=1`, `max_unavailable=0`); `initial_node_count` drift ignored;
  `validate`/`plan`/lint clean with assertions.

### Issue HA-2 — Backup for GKE ([#36](https://github.com/kg-aifabrik/iac-gke/issues/36))
- **Goal:** recover namespaces and volumes after data loss (ADR-0004).
- **Acceptance:** the foundation enables `gkebackup`, force-creates its service agent (with a
  propagation wait), and adds the **third** CMEK grant; a new `gke-backup` module renders a
  backup plan (cron, retention, volume + secret inclusion, CMEK) and a restore plan (selected
  workload namespaces, `DELETE_AND_RESTORE`, restore volume data); the cluster runs the backup
  agent; `validate`/`plan`/lint clean with assertions.

### Issue HA-3 — Regional persistent-disk StorageClass ([#37](https://github.com/kg-aifabrik/iac-gke/issues/37))
- **Goal:** let a stateful Pod survive the loss of a single zone (ADR-0008).
- **Acceptance:** a second StorageClass `encrypted-regional-rwo` (regional PD, CMEK, `WaitFor
  FirstConsumer`) alongside the existing `encrypted-rwo`; rendered by `cluster-stack`;
  manifests lint clean.

### Issue HA-4a — Multi-host gateways ([#38](https://github.com/kg-aifabrik/iac-gke/issues/38))
- **Goal:** serve more than one hostname per gateway, with no wildcard certificates (ADR-0005).
- **Acceptance:** `gke-gateway` takes a **hostname list**; external creates one DNS-authorization
  + managed certificate + cert-map entry **per host** (selected by SNI); internal issues a single
  **multi-SAN** CAS certificate covering every internal hostname; the HTTPS listener drops the
  per-hostname match; `validate`/lint clean with per-exposure assertions.

### Issue HA-4b — Cloud DNS ([#39](https://github.com/kg-aifabrik/iac-gke/issues/39))
- **Goal:** resolve internal names privately and (optionally) public names automatically (ADR-0006).
- **Acceptance:** a new `dns-zones` module creates a **private** zone with per-host A records
  pointing at the internal virtual IP; behind `manage_public_dns` it creates a **public** zone
  with the A records and certificate-validation records, and emits the zone's name servers (NS)
  for one-time registrar delegation; `force_destroy` follows `deletion_protection`;
  `validate`/lint clean.

### Issue HA-5 — Platform scheduling tiers + HA for the TLS add-ons ([#40](https://github.com/kg-aifabrik/iac-gke/issues/40))
- **Goal:** protect platform components and let workloads express priority.
- **Acceptance:** PriorityClass tiers (`platform-critical`, `workload-high`, `workload-default`),
  rendered before the Helm install; cert-manager runs **2 replicas** with a PodDisruptionBudget
  (PDB); the add-ons carry the platform PriorityClass; manifests lint clean.

### Issue HA-6 — Extend `setup-doctor` ([#41](https://github.com/kg-aifabrik/iac-gke/issues/41))
- **Goal:** keep the preflight current for HA.
- **Acceptance:** checks for node-pool autoscaling bounds, the backup plan, the private (and
  opt-in public) DNS zones, and per-host **ACTIVE** external certificates; the CAS check is
  **list-based** (discovers the random-suffixed `${env}-cas-` pools); mocked unit tests cover
  pass + each failure; `ruff`/`mypy` clean; runs locally and in CI.

### Issue HA-7 — Production-grade HA examples + extended `validate.sh` ([#42](https://github.com/kg-aifabrik/iac-gke/issues/42))
- **Goal:** prove every HA capability end to end from a user's point of view.
- **Acceptance:** examples gain `priorityClassName`, topology spread, PDBs, and a `preStop` drain
  delay; new cases for regional-PVC failover, node autoscale, HPA, and preemption
  (filler + critical); `validate.sh` runs the **13-case** matrix non-interactively, including
  `gcloud beta container backup-restore`; matrix documented in [`examples/README.md`](../../examples/README.md).

### Issue HA-8 — Live bring-up, integration validation, retrospective ([#43](https://github.com/kg-aifabrik/iac-gke/issues/43))
- **Goal:** build dev for real, run the full suite, record the milestone.
- **Acceptance:** the gated pipeline builds the dev cluster end to end; `setup-doctor` and the
  13-case `validate.sh` pass against the live cluster; evidence recorded; teardown leaves zero
  billable resources. *(Held open for one cold-start assertion, [#46](https://github.com/kg-aifabrik/iac-gke/issues/46) — node growth from the initial count, observable only on the next bring-up.)*

**Tracking:** [#44](https://github.com/kg-aifabrik/iac-gke/issues/44). **Retrospective:**
[#45](https://github.com/kg-aifabrik/iac-gke/issues/45). The validation matrix was baselined in
[#34](https://github.com/kg-aifabrik/iac-gke/issues/34).

## 5. Cross-cutting requirements

- **Coding standards (CLAUDE.md):** module/file headers; described variables/outputs; comments
  explain *why* and what was rejected; declarative documentation voice; pinned add-on versions.
- **Per-issue gate:** `validate`/`plan`/`tflint`/`tfsec`/assertions green (no cost), or tests
  green for `setup-doctor`/manifests, before commit; commit references the issue; close when green.
- **Living documents:** [`docs/designs/google-cloud-design.md`](../designs/google-cloud-design.md)
  and [`docs/implementation/cluster-build.md`](../implementation/cluster-build.md) are updated as
  part of each change, not after.
- **Ephemeral dev (ADR-0002 amendment 3):** the CAS hierarchy is per-cluster with random-suffix
  names, so a `fop` destroy removes it and the next apply regenerates fresh ids — no burned
  CaPool id or soft-deleted service-account collision, and nothing standing after teardown.

## 6. Milestone verification (real Google Cloud, then teardown)

- **Operator prerequisites:** for the managed public zone (dev default), one-time **NS
  delegation** at the registrar to the four name servers from the `public_zone_name_servers`
  output; internal names need no public DNS (the private zone resolves them in-VPC).
- Build dev through the pipeline; confirm autoscaling bounds, the backup plan, both DNS zones,
  and per-host certificates reach **ACTIVE**; run `setup-doctor`; run the **13-case**
  `validate.sh` (expect ~30–40 minutes — the drain/failover cases cordon nodes, backup→restore
  runs last). Record evidence in the Milestone, then `destroy`.
- **Result:** validated **13/13** on a live dev cluster, torn down. A `fop` teardown leaves zero
  billable resources; only the free/undeletable foundation singletons remain (enabled APIs, the
  node service account, the KMS key shell).
- **Cost while up:** 3–6 × `e2-medium` (autoscaling), two load balancers, backups, and the dev
  DEVOPS-tier CAS pair — all short-lived.

## 7. Cross-cutting fix landed with the milestone

- **Teardown orphans ([#31](https://github.com/kg-aifabrik/iac-gke/issues/31)):** the GKE Gateway
  controller's load balancers were orphaned by cluster deletion and blocked `terraform destroy`
  (they held the SSL policies, the internal address, and the proxy-only subnet). The destroy
  workflow now deletes the in-cluster Gateways **first** so the controller releases them before
  Terraform removes the edge resources. Idempotent: skipped when the fleet membership is already
  gone.

## 8. Deferred — tracked as open issues

- **Cold-start node-autoscale growth** — verify pool growth from the initial count under load on
  the next bring-up ([#46](https://github.com/kg-aifabrik/iac-gke/issues/46); holds the milestone open).
- **Cloud Armor WAF enforce + tuning** ([#26](https://github.com/kg-aifabrik/iac-gke/issues/26)).
- **Mirror platform TLS add-on images through Artifact Registry** ([#27](https://github.com/kg-aifabrik/iac-gke/issues/27)).
- **MDM CAS-root distribution** to browser trust stores ([#28](https://github.com/kg-aifabrik/iac-gke/issues/28)).
- **Observability** — alerting, dashboards, SLOs (its own milestone, [#33](https://github.com/kg-aifabrik/iac-gke/issues/33)).
- **Test-mode vs prod-mode CAS persistence** — keep dev ephemeral; let stage/prod instantiate the
  same module from their foundation with the ENTERPRISE tier (ADR-0002 amendment 3; deferred for
  focused design before stage/prod).

## 9. Related

[google-cloud-design.md](../designs/google-cloud-design.md) · [ADR-0002/0004/0005/0006/0007/0008](../adr/) · [`technology-choices.md`](../technology-choices.md) · [`security-requirements.md`](../security-requirements.md) · [`examples/README.md`](../../examples/README.md) · [progress report](../progress-report.md).
