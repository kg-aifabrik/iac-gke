# ADR-0007: Node scaling is the per-pool cluster autoscaler; node auto-provisioning is not used

- **Status:** Accepted
- **Date:** 2026-06-09
- **Deciders:** SRE
- **References:** [google-cloud-design.md §5](../designs/google-cloud-design.md); issue #16

## Context

Node pools were fixed-size: a load spike had nowhere to go, and a zone loss permanently
removed a third of capacity until a human resized the pool. Every node must come from the
hardened pool template (shielded, Container-Optimized OS, CMEK boot disk, our node identity,
Workload Identity metadata) — node shape is a security property here, not just a sizing one.

## Decision drivers

- Capacity follows demand within explicit, reviewed bounds — minimum and maximum are runtime
  configuration per environment.
- Every node carries the hardened template; nothing invents node shapes.
- Zonal balance is preserved as the pool scales (high availability across three zones).

## Considered options

1. **Stay fixed-size, resize as a Day-2 operation.** Rejected: a human in the scaling loop
   defeats "production, highly available".
2. **Node auto-provisioning (NAP).** Rejected: NAP creates new node pools with shapes the
   autoscaler chooses; that moves node configuration out of the reviewed template. Revisit if
   workload shapes diversify beyond a few explicit pools.
3. **Cluster autoscaler on the explicit general pool** — per-zone min/max as runtime inputs,
   `location_policy = BALANCED`, cluster `autoscaling_profile` as an input. Chosen.

## Decision

The general pool autoscales between per-zone minimum and maximum inputs (a regional pool, so
the ceiling is symmetric across zones); `BALANCED` location policy spreads scale-out across
zones. The cluster-level autoscaling profile is an input (`BALANCED` default,
`OPTIMIZE_UTILIZATION` opt-in). A null autoscaling input keeps a fixed-size pool. The
Confidential pool stays fixed until it has a consumer. Upgrade surge is pinned (`max_surge=1`,
`max_unavailable=0`) so upgrades never reduce capacity below steady state.

## Consequences

- **Good:** pending pods add hardened nodes within minutes, bounded by reviewed limits; zone
  balance holds; scale-to-demand without new attack surface.
- **Bad:** the autoscaler reacts to *unschedulable pods*, so workloads must set resource
  requests honestly (the reference examples model this); metric-based scaling stays at the
  pod layer (Horizontal Pod Autoscaler).
- **Bad:** scale-in is conservative (~10-minute cooldown) — capacity drains slowly after a
  spike, a cost, not a correctness, concern.
