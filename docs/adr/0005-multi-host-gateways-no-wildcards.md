# ADR-0005: Gateways serve hostname lists — per-host public certs, one multi-SAN private cert

- **Status:** Accepted
- **Date:** 2026-06-09
- **Deciders:** SRE
- **References:** [google-cloud-design.md §8](../designs/google-cloud-design.md); extends [ADR-0002](0002-internal-tls-private-ca.md)

## Context

Each gateway originally served exactly one hostname, with the certificate, DNS authorization,
and listener built around it. Multiple applications will live under each domain
(`app.aifabrik.com`, `billing.aifabrik.com` externally; `tools.dev.aifabrik.com`,
`metrics.dev.aifabrik.com` internally), and adding an application must be configuration, not
module surgery. ADR-0002 already rejects wildcard certificates.

## Decision drivers

- Adding an application = one list entry (+ its DNS records), nothing structural.
- No wildcard certificates (ADR-0002): internal hostnames stay explicit and private; external
  certs stay per-host.
- One uniform mechanism on both gateways.

## Considered options

1. **Wildcard certificates** (`*.domain`). Rejected (re-affirming ADR-0002): a wildcard leaks
   the namespace of every future app and widens the blast radius of a key compromise.
2. **One listener + one certificate per hostname.** Rejected: listener count grows per app;
   the internal Secret-per-host sprawl buys nothing — SNI selection happens anyway.
3. **Hostname lists; external = per-host Certificate Manager cert/DNS-auth/certificate-map
   entry (one map, SNI-routed); internal = one multi-SAN CAS leaf in one Secret.** Chosen.

## Decision

The gateway module takes `hostnames` (a list) per exposure. External: a DNS authorization, a
managed certificate, and a certificate-map *entry* per hostname; the certificate map stays
singular and serves certificates by Server Name Indication. Internal: one CAS-issued
certificate carrying every hostname as an explicit Subject Alternative Name; cert-manager
reissues it when the list changes. Listeners match all attached hostnames; namespace labels
still gate which routes may attach.

## Consequences

- **Good:** app onboarding is a list entry; no wildcards anywhere; one certificate-map and one
  internal Secret regardless of app count.
- **Bad:** within ingress-labelled namespaces, per-hostname route ownership is not yet
  enforced — a namespace stamp (security milestone) closes that.
- **Bad:** each external hostname still needs its DNS-authorization CNAME + A record created
  (manual by SRE, or the opt-in public zone — ADR-0006).
