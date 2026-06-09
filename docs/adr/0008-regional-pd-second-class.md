# ADR-0008: Regional persistent disk is a second named StorageClass, not the default

- **Status:** Accepted
- **Date:** 2026-06-09
- **Deciders:** SRE
- **References:** [google-cloud-design.md §5](../designs/google-cloud-design.md)

## Context

The platform StorageClass `encrypted-rwo` provisions zonal CMEK-encrypted disks. On a regional
cluster, a zonal volume pins its workload to one zone: if that zone fails, the volume — and
the pod bound to it — is stranded despite the cluster surviving. Regional persistent disks
replicate synchronously across two zones but cost roughly twice as much.

## Decision drivers

- A zone failure must not strand stateful workloads that need to survive it.
- Workloads that replicate at the application layer (or tolerate zonal storage) must not pay
  the 2× replication cost by default.
- Same encryption posture (CMEK with the cluster key) for every class.

## Considered options

1. **Make regional persistent disk the platform default** (replace `encrypted-rwo`). Rejected:
   doubles storage cost for every consumer, including those that don't need cross-zone
   volumes.
2. **Leave zonal-only; rely on application replication + backups.** Rejected: some workloads
   genuinely need infrastructure-level zone survival, and backup-restore is recovery, not
   availability.
3. **A second named class, `encrypted-regional-rwo`, workloads opt in by name.** Chosen —
   same opt-in-by-name pattern as `encrypted-rwo`.

## Decision

A second rendered StorageClass `encrypted-regional-rwo`: `pd.csi.storage.gke.io`,
`type: pd-balanced`, `replication-type: regional-pd`, CMEK-encrypted with the cluster key,
`WaitForFirstConsumer`, expansion allowed, not the cluster default. The validation suite
proves the property: a pod writes, its zone is drained, the replacement pod schedules in the
surviving zone and reads the data.

## Consequences

- **Good:** zone-survivable storage exists as a one-line choice; nobody pays for replication
  they didn't choose; encryption posture is uniform.
- **Bad:** teams must pick correctly — guidance lives in the reference examples; the
  namespace-stamp milestone can constrain choices per tenant later.
- **Bad:** regional disks attach in exactly two of the three zones; scheduling after a
  failover is constrained to the replica zones (`WaitForFirstConsumer` handles placement).
