# ADR-0006: Internal DNS is a Cloud DNS private zone; public DNS stays manual with an opt-in zone

- **Status:** Accepted
- **Date:** 2026-06-09
- **Deciders:** SRE
- **References:** [google-cloud-design.md §8](../designs/google-cloud-design.md); technology-choices TC-8

## Context

Internal hostnames had no DNS at all — clients (and the validation suite) reached the internal
gateway by its raw VIP. Public records are created manually by an SRE at the registrar, which
stalled the Milestone 2 certificate in `PROVISIONING` until the validation CNAME appeared.
Private zones require no registrar control; public automation requires delegating the domain
(or a subdomain) to Cloud DNS — a registrar change the team is not ready to make.

## Decision drivers

- Internal names must resolve inside the VPC, platform-owned, per environment.
- Internal names adopt the work-domain convention (`dev.aifabrik.com`) without waiting on any
  registrar action.
- No standing privileged controller for a handful of records.
- Public automation available the day the domain is delegated — without redesign.

## Considered options

1. **Keep VIP-based access internally.** Rejected: not a usable contract for teams; every
   client must learn an IP that changes per environment.
2. **external-dns controller.** Rejected: an always-on, DNS-privileged in-cluster controller
   to manage two gateways' records — disproportionate attack surface for the need (YAGNI).
3. **Terraform-owned Cloud DNS: a private zone now; a public zone behind an opt-in flag.**
   Chosen.

## Decision

A Terraform-owned **Cloud DNS private zone** per environment (e.g. `dev.aifabrik.com`), bound
to the VPC, with an A record per internal hostname pointing at the internal gateway VIP —
split-horizon with the public domain, names never leave the VPC. **Public DNS stays SRE-manual
by default**: Terraform outputs the exact records per hostname. A **public zone + records**
exist behind `manage_public_dns` (default off) for when the domain is delegated to Cloud DNS;
until then the flag changes nothing.

## Consequences

- **Good:** internal names resolve by cluster DNS with zero client setup; validation tests the
  real resolution path, not `--resolve` overrides; one registrar delegation later flips public
  records to fully automated (certificate validation CNAMEs included).
- **Bad:** until delegation, every new external hostname is a manual two-record SRE task — the
  Milestone 2 PROVISIONING stall stays possible, mitigated by the records being precomputed
  Terraform outputs.
- **Bad:** a private zone shadowing the work domain means internal names must not collide with
  public ones the VPC also needs — naming stays under per-environment subdomains.
