# ADR-0004: Workload backup and restore uses Backup for GKE

- **Status:** Accepted
- **Date:** 2026-06-09
- **Deciders:** SRE
- **References:** [google-cloud-design.md §9](../designs/google-cloud-design.md); requirements REL; issue #34

## Context

Production stateful workloads must be recoverable from deletion, corruption, and operator
error. The cluster runs CMEK-encrypted persistent disks; nothing today can restore a deleted
PersistentVolumeClaim, a removed namespace, or pre-corruption data. Dev clusters are built and
destroyed frequently, so whatever holds backups must also tear down cleanly.

## Decision drivers

- Kubernetes state and volume data must restore **together** (a disk image without the PVC/
  workload objects is not a recovery).
- Managed over self-run; CMEK encryption with the cluster key.
- Clean, complete teardown in dev — no orphaned billable storage.

## Considered options

1. **Compute Engine disk-snapshot schedules** (`google_compute_resource_policy`). Rejected:
   disk-only — no Kubernetes objects, no namespace-scoped restore; restoring means hand-wiring
   disks back to PVCs.
2. **Velero.** Rejected: self-run controller plus bucket credentials to protect; another
   add-on to harden and upgrade; the managed service covers the need.
3. **Backup for GKE.** Chosen: managed, application-aware (namespaces, secrets, and volume
   data in one backup), scheduled plans with retention, CMEK support, restore plans as a
   defined path.

## Decision

Backup for GKE provides backup and restore: the agent is enabled on the cluster; a
Terraform-owned **backup plan** (cron + retention as runtime inputs, volume data and Secrets
included, CMEK-encrypted via a service-agent key grant in the foundation) covers the workload
namespaces; a Terraform-owned **restore plan** pins the restore policy. The validation suite
proves the round-trip: write → back up → delete the namespace → restore → the workload serves
its data again.

## Consequences

- **Good:** one backup covers objects + data; restores are namespace-scoped and repeatable;
  no self-run backup infrastructure; encrypted with our key.
- **Bad:** backups can outlive the cluster (the point, but a teardown liability) — dev uses
  short retention and validation deletes the backups it creates (issue #31 lesson). The
  destroy-path purge of remaining (e.g. scheduled) backups is tracked in issue #47; until it
  lands, a plan still holding backups blocks `terraform destroy`.
- **Bad:** per-GB backup storage cost — negligible at dev scale, priced per environment later.
