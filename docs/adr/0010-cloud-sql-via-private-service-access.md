# ADR-0010: Cloud SQL for PostgreSQL via Private Service Access, opt-in per purpose

- **Status:** Accepted
- **Date:** 2026-07-09
- **Deciders:** kg@ (SRE)
- **References:** the `cloud-sql` and `network` modules; `config/clusters.yaml` (`fop`); the shared-Temporal design in the `research/temporal` repo (`shared-instance-architecture.md`).

## Context

The Fleet Operations Plane runs Temporal as a shared workflow engine, and Temporal's durable state lives in PostgreSQL. The cluster factory provisioned no database. We need a managed PostgreSQL that (a) is reachable only over the VPC — no public endpoint, matching the private-cluster posture — and (b) authenticates without stored passwords, matching the CMEK/least-privilege posture elsewhere. It must be config-driven per the factory (ADR-0009), not a hand-built one-off, and it is not needed by every cluster (only purposes that host a stateful platform service).

## Decision drivers

- No public database endpoint; traffic stays inside Google's network.
- Secretless auth (no DB password to store, rotate, or leak).
- Config-driven and opt-in — a cluster without a database provisions nothing extra and its Terraform root is unchanged.
- Clean teardown for dev (no standing cost, no name-reservation collisions on rebuild).

## Considered options

1. **Cloud SQL for PostgreSQL with a private IP via Private Service Access (PSA), IAM database authentication, opt-in per purpose — Chosen.** A new `cloud-sql` module places the instance on a private IP peered to the VPC through PSA (a reserved range + a `servicenetworking` connection added to the `network` module behind a flag). IAM database authentication is enabled on the instance; workloads connect through the Cloud SQL Auth Proxy as their Google identity (Workload Identity), so no password exists. The `fop` purpose turns it on via `config/clusters.yaml` (`enable_cloud_sql: true`); the generator emits the inputs only for opted-in clusters.
2. **Cloud SQL with a public IP + authorized networks — Rejected.** A public endpoint contradicts the private-cluster posture; authorized-network allowlists are brittle and still expose the instance to the internet.
3. **Self-hosted PostgreSQL in-cluster (StatefulSet + PVC) — Rejected.** Shifts backup, HA, patching, and failover onto us; the point of a managed database is to not run one. (Fine for the local Rancher setup, not for a shared production plane.)
4. **AlloyDB — Rejected.** Not on Temporal's tested-database list; its columnar analytics engine does not help Temporal's write-heavy OLTP pattern. Revisit only if scale outgrows Cloud SQL.
5. **A dedicated `temporal` cluster purpose instead of a toggle on `fop` — Rejected for now.** More generator/config surface and a second cluster to run; a per-purpose toggle is the simpler fit while Temporal is one tenant of the FOP.

## Decision

Add a `cloud-sql` module and compose it in `cluster-stack` under `enable_cloud_sql` (default off). When on, the `network` module reserves a PSA range and peers it to `servicenetworking`, and the instance is created private-IP-only with IAM authentication enabled. `project-foundation` enables `sqladmin` and `servicenetworking`; the build role set gains `roles/cloudsql.admin` and `roles/servicenetworking.networksAdmin`. The instance name carries a random suffix (as `private-ca` does) so a dev teardown/rebuild does not hit Cloud SQL's week-long name reservation. The per-workload IAM database user, `cloudsql.client` grant, and Workload Identity binding are created at deploy time by the workload, not by this generic infra module.

## Consequences

- **Good:** No public database surface; secretless IAM auth; config-driven and opt-in so non-database clusters are unaffected; teardown is clean.
- **Good:** PSA lives in the `network` module behind a flag, so any future private managed service can reuse it.
- **Bad:** PSA reserves an internal range and creates a VPC peering — one more networking construct to reason about, and the range is effectively immutable once the peering exists.
- **Limitation:** CMEK for the instance is supported (a key input) but left Google-managed in dev to keep the first bring-up simple; production should set the key and add the Cloud SQL service-agent key grant in `project-foundation`.
- **Limitation:** ZONAL availability in dev has no standby; production sets `availability_type = REGIONAL` (synchronous HA — the only replication Temporal can use).
