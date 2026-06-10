# ADR-0002: Internal endpoint TLS uses a private CA in Certificate Authority Service

- **Status:** Accepted
- **Date:** 2026-06-08
- **Deciders:** SRE
- **References:** [google-cloud-design.md §8](../designs/google-cloud-design.md); technology-choices TC-7; [security-requirements.md SEC-10](../security-requirements.md)

## Context

The internal gateway terminates TLS for internal-tool hostnames. Internal hostnames must not
appear in public Certificate Transparency (CT) logs. The clients are humans using browsers.

## Decision drivers

- Internal hostnames stay private — no public CT disclosure.
- Automated issuance and rotation.
- Forward compatibility with a possible future service mesh.
- Cost is not a constraint.

## Considered options

1. **Public Certificate Manager certificate for an owned-domain internal hostname**
   (DNS-authorized). Rejected: publicly trusted certificates are logged in CT, which discloses
   internal hostnames; a wildcard certificate was also rejected.
2. **Self-managed in-cluster CA** (cert-manager self-signed root). Rejected: the operator must
   protect the root key, audit is weaker, and a future mesh would replace it.
3. **Private CA in Certificate Authority Service (CAS), issued via cert-manager +
   `google-cas-issuer`.** Chosen.
4. **Service-mesh CA.** Deferred (see ADR-0003); the mesh is a security-phase decision.

## Decision

Internal endpoint certificates are issued by a private CA in CAS: a long-lived root with
per-environment subordinate CAs. cert-manager with `google-cas-issuer` requests leaf
certificates and writes them to Secrets the gateway references (`tls.certificateRefs`). The
CAS root reaches human/browser clients through MDM and in-cluster service clients through
trust-manager.

## Consequences

- **Good:** internal hostnames never enter public CT; a managed CA with IAM and audit;
  automated leaf rotation; forward-compatible with a mesh (ADR-0003).
- **Bad:** CAS carries a recurring cost; trust distribution to browsers (MDM) is operator-owned
  work.

## Amendment (2026-06-10, Milestone 3 bring-up)

The CAS hierarchy moved from the per-cluster roots into the **per-project
foundation** root, and the pools are named ``<env>-cas-root`` /
``<env>-cas-subordinate`` (the ``-ca-`` generation was burned switching dev to the
DEVOPS tier — see the cost addendum below). Two forcing facts surfaced at the bring-up (run
27249785152):

- Google **permanently retires a deleted CaPool id** — ``dev-root`` and
  ``dev-subordinate``, purged at the Milestone 2 teardown, can never be
  recreated; hence the ``-ca-`` infix.
- The root must **outlive cluster rebuilds** anyway: MDM-distributed browser
  trust (and any recorded leaf chains) break if the root churns with every
  dev teardown.

The foundation is the existing home for resources whose lifetime exceeds a
cluster's (the KMS key ring). A ``fop`` destroy no longer touches CAS; the
standing pool cost is accepted (cost was already a non-driver here).

## Amendment 2 (2026-06-10, Milestone 3 cost review)

**Tier is per environment: dev uses DEVOPS, stage/prod use ENTERPRISE.** Leaving the
ENTERPRISE default standing in the foundation made CAS the milestone's single largest
cost (~$12 over the bring-up — ~85% of the bill — versus ~$2.50 for the whole cluster),
because ENTERPRISE bills a premium per-CA fee and the churny bring-up created several CA
generations. DEVOPS is ~10x cheaper and sufficient for dev: it issues the same short-lived,
auto-rotated internal leaves; it lacks certificate-revocation/CRL and issued-cert tracking,
which dev does not need. Stage/prod keep ENTERPRISE (revocation matters there).

Switching tier replaces the pool (``tier`` is immutable), which deletes — and therefore
burns — the ``<env>-ca-*`` ids; the next generation is ``<env>-cas-*``.

## Amendment 3 (2026-06-10, ephemeral-dev requirement) — supersedes the location of Amendment 1

**Dev must leave zero billable resources on teardown**, so the CAS hierarchy moved back out
of the foundation into the **per-cluster scope** (`cluster-stack`): a `fop` destroy now
removes it. Amendment 1 had parked CAS in the foundation to dodge two Google lifecycle
traps — but the real fix is a **per-generation random suffix** on the pool/CA/service-account
names (`<env>-cas-<rand>-*`, `cert-manager-cas-<rand>`): destroyed with the cluster,
regenerated on the next apply, so a deleted CaPool id or a soft-deleted service-account id
is never reused. This is collision-free across rebuilds *and* leaves nothing standing.

- **MDM browser-trust durability** (Amendment 1's other reason) does not apply to dev (test
  traffic), so a per-cluster, regenerated dev root is fine.
- **Stage/prod**, if they want a durable root for MDM-distributed trust, can instantiate the
  same module from their *foundation* root and keep the `ENTERPRISE` tier — the module works
  in either scope. That is a per-environment choice, not a code fork.

Net: dev teardown leaves only the free/undeletable foundation singletons (enabled APIs, the
node service account, the KMS key shell). The standing-pool cost that Amendment 1 accepted is
eliminated for dev.
