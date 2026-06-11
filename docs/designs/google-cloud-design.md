# Google Cloud design — the hardened GKE cluster

*Status: draft for review · Date: 2026-06-08*
*Companion to [requirements.md](../requirements.md) and [technology-choices.md](../technology-choices.md). The security controls and evidence live in [security-requirements.md](../security-requirements.md).*

---

## 1. Scope

How one functioning, hardened **Google Kubernetes Engine (GKE)** cluster — Google's
managed Kubernetes — is assembled from Google Cloud resources: the pieces to create,
how they depend on each other, and why each choice. One cluster per environment, each
in its own project. These pieces are what the build recipe (Terraform) creates.

## 2. The shape

A custom **Virtual Private Cloud (VPC)** network holds a regional, private cluster with
**no public endpoint**. Operators and automation reach it only through **Connect
Gateway**. Nodes have no public address and reach Google services over a private path.
Secrets and disks are encrypted with our own key. Pods get cloud access through their
own identity, never the node's. Only signed images from our registry are admitted.

---

## 3. Foundation (per environment)

### Project
- One Google Cloud project per environment (dev / stage / prod) — the boundary for
  isolation, quotas, identity, and cost.
- Created and owned by the keyless automation identity built in Milestone 0.

### Enabled services (and why each)
Only the services the cluster uses are enabled; everything else stays off. Enabling GKE and
Compute also creates the Google-managed service agents (below).
- **container** — the GKE service itself (clusters and node pools).
- **compute** — the network, subnets, nodes (virtual machines), and disks underneath.
- **iam** / **iamcredentials** — service accounts and short-lived credentials.
- **cloudkms** — the encryption key for secrets and disks.
- **artifactregistry** + **containeranalysis** — store images and scan them.
- **binaryauthorization** — admit only trusted images.
- **gkehub** + **gkeconnect** + **connectgateway** — fleet membership and private API access.
- **logging** + **monitoring** — where logs and metrics go (incl. managed Prometheus).
- **secretmanager** — workload secrets (technology-choices TC-13).
- **certificatemanager** / **privateca** — TLS certificates (TC-7).
- **dns** — private DNS zones so private nodes resolve Google service names.

### Customer-managed encryption key (CMEK)
- **What it is** — our own key in **Cloud Key Management Service (KMS)**, used to encrypt
  the cluster's Kubernetes secrets (in etcd) and the nodes' disks. "Customer-managed"
  means the key is under our control and audit, not Google's alone.
- **Requirements** — a symmetric *encrypt/decrypt* key, in a key ring whose **location
  matches the cluster's region** (there is no global option for this use); automatic
  rotation enabled.
- **Created once, then kept** — the key resource is created once and lives for as long as
  the cluster does. Rotation periodically adds a *new key version* (old data stays
  readable), so the key changes over time but is never recreated. **Never destroy a key
  version still in use** — that makes the cluster's secrets unreadable.
- **How and where** — in Cloud KMS: create a key ring, then the key. Then grant *use* of
  the key (the "encrypter/decrypter" role) to two Google-managed identities (next), and
  point the cluster at the key in two places: its secret-encryption setting and its node
  disk-encryption setting.

### Service agents and the two key grants
- Google-managed identities that run parts of the cluster on our behalf. They don't exist
  until the APIs are enabled, and must exist before the key grants are applied, or the build
  races against their lazy creation.
- **Two separate grants**, both required:
  - the **GKE service agent** gets use of the key for **secret (etcd) encryption**;
  - the **Compute service agent** gets use of the key for **node and disk encryption**.

### Node service account
- A dedicated, least-privilege identity attached to the nodes, replacing Google's broad
  default. It can do only what nodes need: write logs and metrics, and pull images.
- Pods do **not** use it — they get their own identity (below), so this stays minimal.

### Workload Identity
- Maps a Kubernetes service account to a Google identity, so each **pod** gets its own
  scoped cloud access instead of borrowing the node's credentials.
- Set on the cluster (identity pool `<project>.svc.id.goog`) and on each node pool
  (metadata mode), so the node's credentials aren't reachable from pods.

---

## 4. Network

### Custom VPC (not auto mode)
- **Auto mode** would have Google create one subnet per region automatically, with fixed
  preset ranges. The network uses **custom mode** so every range is chosen deliberately,
  avoiding overlaps with other networks and surprise address space.

### Subnet and the Pod/Service ranges
- **A subnet is regional** — it spans every zone in the region. One subnet serves the nodes
  in all three availability zones; subnets are *not* per-zone.
- The cluster is **VPC-native** ("alias IP"): the node subnet has its **primary range** (node
  addresses) plus two **secondary ranges** on the same subnet — one for **Pods**, one for
  **Services**. Pods and Services are *secondary ranges*, not separate subnets.
- **Sizing** — GKE gives each node a `/24` (room for ~110 pods), so the Pod range must cover
  `max nodes × /24` and dominates consumption; the Services range defaults to a `/20`. Pull
  the Pod range from the `100.64.0.0/10` block (reserved for exactly this) to avoid burning
  ordinary private address space. All ranges are non-overlapping and sized generously up front.
- **Growing later** — the **primary (node) range can be expanded** in place; **extra Pod
  ranges can be added** to node pools as the cluster grows. The **Services range is fixed at
  creation** and cannot change — which is why it's sized up front.
- **Proxy-only subnet** — a separate subnet used only by *internal* load balancers / internal
  Gateways (the Envoy proxies that front internal HTTPS endpoints). It is created for the
  internal gateway (§8).

### Reaching Google services privately
- **Private Google Access** on the subnet lets nodes with no public address reach Google
  APIs and Artifact Registry over Google's internal network, with private DNS pointing those
  names at Google's restricted virtual IP.

### Outbound internet for pods
- Private nodes have no public address, so a pod that needs the public internet egresses
  through **Cloud NAT** (a managed network-address-translation service on a Cloud Router),
  which gives shared outbound IPs. Without Cloud NAT, pods can reach only Google services.
- It's **off by default** (least exposure) and added only when a workload needs it. Egress is
  also gated by the namespace's default-deny network policy, so a pod needs *both* the Cloud
  NAT path *and* an explicit egress allow.

### Dataplane V2 (Cilium)
- The cluster's data plane is **Dataplane V2**, Google's managed networking built on
  **Cilium / eBPF** (extended Berkeley Packet Filter — programmable in the Linux kernel). It
  enforces NetworkPolicy in the kernel and powers network flow logging.
- It is paired with a **default-deny** network policy in every namespace.

---

## 5. Cluster and nodes

### Regional cluster
- `location` is a **region**, which gives a control plane replicated across three zones
  automatically; `node_locations` pins nodes across three zones too — the cluster survives
  losing one zone.

### Default node pool removed
- Creating a cluster auto-creates one "default" node pool using Google's default settings
  (including the broad default identity). It is deleted (`remove_default_node_pool`) and
  replaced with our own pools.
- **Explicit pools** — every pool uses *our* hardened settings (our node identity, shielded
  nodes, Container-Optimized OS, machine type, labels/taints), and pools can be added, resized,
  or removed independently as day-2 operations.

### Versions and upgrades (per environment)
- **Dev** — enrolled in a **release channel** (Regular, the balanced one). Google auto-upgrades
  the control plane and nodes to tested versions during the maintenance window and auto-repairs
  nodes. Dev's stakes are low, and auto-upgrading it surfaces version issues early.
- **Staging and production** — upgrades are **deliberate, scheduled Day-2 operations, never
  automatic**: surprise upgrades risk developer productivity (staging) and customer impact
  (production). Automatic upgrades are held off (maintenance exclusions) and each upgrade is
  triggered on a planned schedule through the normal reviewed-change path.
- **Validate first** — before upgrading staging or production, a throwaway **test cluster** is
  built on the new version with the same automation to confirm workloads run correctly; then
  staging is upgraded, then production.
- The build recipe is identical across environments; the upgrade cadence is an environment
  parameter, not a different cluster.

### Hardening, built in
- Verified-boot ("shielded") nodes, **Container-Optimized OS (COS)** nodes (minimal,
  auto-patched), secret encryption with our key, Workload Identity, and Dataplane V2
  default-deny — together clearing the **Center for Internet Security (CIS) Level 2** floor.

### Logging and metrics
- **Logs** — system and workload logs flow to **Cloud Logging**.
- **Metrics** — flow to **Cloud Monitoring**; **Managed Service for Prometheus** is also
  enabled, so Prometheus-format workload metrics are collected and queryable without running a
  Prometheus server.

### Maintenance window (dev)
- A recurring window on the **dev** cluster bounds GKE's automatic upgrades to a predictable,
  low-traffic time. Staging and production have no automatic upgrades and use no window; their
  timing is set by the scheduled Day-2 upgrade operation.

### Ingress (Gateway API)
- The **GKE Gateway** controller (our chosen ingress, TC-6) is enabled on the cluster. The
  gateways themselves, their certificates, and how services are exposed are designed in **§8**.

### Deletion protection
- On for every cluster, guarding against accidental deletion.

### Node pools
- A **general** hardened pool (machine type, disk, on-demand), plus an optional
  **Confidential** (memory-encrypting) pool per cluster — always **on-demand**, never spot
  (spot Confidential nodes proved unreliable).

### Node autoscaling
- The **general pool autoscales**: minimum and maximum nodes **per zone** are runtime inputs
  (regional pool, so the ceiling is symmetric across the three zones), with `location_policy
  = BALANCED` so scale-out adds nodes **evenly across zones** rather than piling into one. A
  null autoscaling input keeps a fixed-size pool (the dev default before this milestone).
- The cluster autoscaler triggers on **unschedulable pods**, not metrics; metric-driven
  scaling is the Horizontal Pod Autoscaler at the workload layer (the reference examples show
  it). The cluster-level **autoscaling profile** is an input (`BALANCED` default;
  `OPTIMIZE_UTILIZATION` opt-in for denser bin-packing).
- **Node auto-provisioning is not used** — it invents node shapes outside the hardened pool
  template; every node comes from an explicitly defined pool (ADR-0007).
- The Confidential pool stays **fixed-size** — it is opt-in and tainted; autoscaling it is
  added when a consumer exists.
- **Upgrade surge is pinned** (`max_surge = 1`, `max_unavailable = 0`): upgrades replace one
  node at a time, zone by zone — the surge node is created in the same zone as the node being
  drained, so capacity never drops below steady-state and zonal balance holds throughout.

### Storage classes
- Two platform StorageClasses, both CMEK-encrypted with the cluster key, both
  `WaitForFirstConsumer`, neither marked the cluster default — workloads opt in by name:
  - **`encrypted-rwo`** — zonal `pd-balanced`; the default choice for stateful workloads whose
    availability story is replication at the application layer.
  - **`encrypted-regional-rwo`** — **regional** `pd-balanced` (`replication-type:
    regional-pd`), synchronously replicated across two zones; the volume survives a zone
    failure and the pod reschedules into the surviving zone with its data. Costs ~2× the zonal
    class, which is why it is a second named class and not the default (ADR-0008).

### Scheduling tiers
- Three platform **PriorityClasses**, rendered as in-cluster manifests; none is
  `globalDefault`, so nothing changes for pods that do not opt in:
  - **`platform-critical`** — the platform's own add-ons (cert-manager, trust-manager,
    google-cas-issuer); schedules ahead of all workloads and may preempt them.
  - **`workload-high`** — production-serving workloads; schedules ahead of, and may preempt,
    default-tier pods under resource pressure.
  - **`workload-default`** — value 0, identical to an unlabeled pod; the explicit name for
    "normal" so manifests are self-documenting.
- The platform add-ons run HA where it matters: **cert-manager runs 2 replicas with a
  PodDisruptionBudget**; trust-manager and google-cas-issuer stay single-replica deliberately
  (a PodDisruptionBudget on one replica blocks node drains, and a brief issuance pause is
  tolerable because certificate renewal is asynchronous).

---

## 6. Access — no public endpoint

### Private nodes + private control plane
- Nodes have no public address. The control plane uses the **DNS-based private endpoint**
  (Google's current recommended approach) with external access turned off — there is **no
  public API endpoint** to attack or allow-list.

### Fleet membership
- The cluster joins a **fleet** (a group of clusters). Today this is only the prerequisite
  for Connect Gateway.
- **Later fleet features** it unlocks (not used yet): multi-cluster Services and Gateways,
  fleet-wide configuration and policy management, team scopes for multi-tenancy, Cloud Service
  Mesh, and fleet-wide observability.

### Connect Gateway
- The single way operators and automation reach the cluster's Kubernetes interface — by
  Google **Identity and Access Management (IAM)** plus in-cluster role-based access control,
  with **no** network allow-lists or virtual private network (VPN).

---

## 7. Supply chain

### Artifact Registry
- One private image repository per project for our images, plus a proxy repository that
  mirrors public base images — so the cluster never pulls from the internet directly. The
  node identity has read-only access.

### Binary Authorization
- An admission policy that admits only trusted images. It starts in **audit** (logs, does not
  block) and switches to **enforce** once the image-signing pipeline exists.

*(Image scanning and the daily evidence reports are in [security-requirements.md](../security-requirements.md).)*

---

## 8. Ingress and TLS certificates

Traffic enters the cluster's services through gateways, and every endpoint is served over TLS.
The portable contract — identical on GKE and the future on-prem cluster — is the **Gateway
API**: a team exposes a Service by attaching an **HTTPRoute** to a gateway; TLS is required and
plain HTTP redirects to HTTPS. The gateway implementation and the certificate issuer are
GKE-specific (below); the on-prem equivalents are built with that cluster.

### Two gateways per cluster
- Each cluster runs exactly **two gateways**, one per exposure class:
  - an **internal** gateway — GatewayClass **`gke-l7-rilb`**, a regional internal Application
    (Layer 7) Load Balancer on a private virtual IP reachable only inside the VPC; it uses the
    proxy-only subnet (§4) and serves internal tools, which carry no customer traffic.
  - an **external** gateway — GatewayClass **`gke-l7-global-external-managed`**, a global
    external Application (Layer 7) Load Balancer on a public anycast IP, with a baseline Cloud
    Armor policy provisioned (attachment + enforcement: issue #26); it serves the end-user,
    internet-facing endpoints.
- Both gateways are Layer-7 Application Load Balancers; *internal* versus *external* denotes
  where the virtual IP is reachable, not the OSI layer.
- The gateways are platform-owned and live in a dedicated gateway namespace. Workload
  namespaces expose services by attaching **HTTPRoutes** to them: a route in the gateway's own
  namespace attaches directly, and a route in any other namespace attaches through a
  **cross-namespace grant** (`ReferenceGrant`) the platform issues per namespace. The gateway
  count stays fixed at two per cluster regardless of how many namespaces use them.

### Security configuration is Terraform-owned
- The security configuration of both gateways lives in **Google Cloud resources Terraform
  owns**, not in the Gateway objects: the **Cloud Armor (WAF) policy**, the **SSL policy**
  (minimum TLS 1.2, prefer 1.3), the **HTTP→HTTPS redirect**, and the certificates. A reusable
  **gateway module** instantiates both gateways from one baseline, so their posture is uniform
  by construction.
- **WAF** (Cloud Armor) belongs to the **external** gateway — the only internet door. A baseline
  policy resource ships now but is **not yet attached** to any backend; attaching it (a
  `GCPBackendPolicy` per public backend) and enabling/tuning the rule set (OWASP rules in
  enforce mode, rate-limiting) is tracked in issue #26. The internal gateway needs no internet
  WAF — it relies on network policy and being unreachable from outside the VPC.

### Certificates (TC-7)
- **External (public) endpoints → Certificate Manager managed certificates.** Publicly trusted,
  free, auto-renewed, validated by **DNS authorization** (a CNAME in the domain). Every client
  already trusts the chain — nothing to distribute.
- **Each gateway serves multiple hostnames under its domain** (e.g. `app.aifabrik.com` and
  `billing.aifabrik.com` externally; `tools.dev.aifabrik.com` and `metrics.dev.aifabrik.com`
  internally). Hostnames are a **list input** per gateway; no wildcard certificates are used
  (ADR-0005):
  - **External** — one DNS authorization, one managed certificate, and one certificate-map
    *entry* **per hostname**; the certificate map stays singular and serves the right
    certificate by Server Name Indication (SNI). Adding an app is one list entry plus the
    hostname's DNS records.
  - **Internal** — one **multi-SAN** CAS-issued certificate carrying every internal hostname
    as an explicit Subject Alternative Name, written to a single Secret the listener
    terminates with; cert-manager reissues it automatically when a name is added.
  - Listeners match all attached hostnames; which routes may attach stays gated by the
    namespace label (`ingress=external|internal`). Per-hostname route ownership inside the
    allowed namespaces is a multi-tenancy control that arrives with the namespace stamps
    (security milestone).
- **Internal endpoints use a private certificate authority in Certificate Authority Service
  (CAS).** Internal hostnames are **private and are not published to Certificate Transparency
  logs**, so public certificates do not apply to them; the private CA's cost and trust
  distribution are provided for below.
  - **Hierarchy** — a long-lived **root** CA kept cold, with **per-environment subordinate** CAs
    issuing the leaf certificates. In dev the hierarchy is **per-cluster** (created by
    `cluster-stack`, torn down with the cluster) with **random-suffixed** pool/CA/service-account
    names (`<env>-cas-<rand>-*`) so each rebuild is collision-free — a deleted CaPool id and a
    soft-deleted service-account id are never reused. Stage/prod may instead instantiate it from
    their foundation root for a durable, MDM-distributed root (ADR-0002, amendment 3).
  - **Issuance** — **cert-manager** with the **`google-cas-issuer`** requests a leaf from CAS,
    writes it to a Secret, and the gateway references it (`tls.certificateRefs`). Leaves
    auto-rotate.
  - **Trust distribution** — the CAS root is pushed to **human/browser** trust stores via **MDM**
    (the internal tools are accessed by people), and to in-cluster **service** clients via
    **`trust-manager`**, which syncs the CA bundle into namespaces.
- **Split** (the Terraform-for-Google, kubectl-for-in-cluster boundary) — Terraform owns the
  Google resources: the Certificate Manager certificate + map, the CAS pool/CA and the
  Workload-Identity grant that lets cert-manager request certs, the reserved external IP, and the
  SSL and Cloud Armor policies. The gateways, HTTPRoutes, policy attachments, and
  cert-manager / `google-cas-issuer` / `trust-manager` with their Certificate resources are
  in-cluster manifests applied by the pipeline.

### DNS (TC-8, ADR-0006)
- **In-cluster** name resolution is GKE's built-in **CoreDNS** — nothing to deploy.
- **Internal** hostnames resolve through a **Cloud DNS private zone** bound to the VPC
  (e.g. `dev.aifabrik.com`), with an A record per internal hostname pointing at the internal
  gateway's private VIP — Terraform-owned, created with the gateway. Private zones need no
  registrar control, so internal names adopt the work-domain convention in every environment;
  the names never leave the VPC (split-horizon with the public domain).
- **Public** records are **SRE-managed by default**: Terraform outputs exactly what to create
  per hostname (the A record and the Certificate Manager DNS-authorization CNAME), and an SRE
  adds them at the registrar. An **opt-in Cloud DNS public zone** (`manage_public_dns`,
  default off) automates both record sets once the domain (or a subdomain) is delegated to
  Cloud DNS at the registrar — a one-time manual step; until then nothing changes.
- No external-dns controller runs in the cluster — a standing privileged controller is not
  warranted for two gateways' records (ADR-0006).

### Forward note — service mesh
East-west, pod-to-pod **mutual TLS** is built in the **security phase** (SEC-10, requirements §8),
not in this ingress work. The ingress and certificate design above is forward-compatible with it:
- **CAS is the single private root.** Cloud Service Mesh, when adopted, uses the **same CAS** as
  its certificate authority, so the gateway certificates and the east-west workload certificates
  share one trust domain.
- **The GKE gateway remains the north-south entry point** under a mesh; the mesh is an east-west
  overlay (sidecar or ambient), and no mesh ingress gateway replaces it.
- The **gateway → backend pod** hop, which a mesh does not cover, is secured in the security
  phase with a GKE `BackendTLSPolicy` (re-encryption) or sidecar permissive mode.

---

## 9. Backup and restore

Stateful workloads are recoverable from deletion, corruption, and operator error via
**Backup for GKE** (ADR-0004) — managed, application-aware, namespace-scoped backups that
capture Kubernetes state *and* volume data together.

- **Agent + plan** — the Backup for GKE agent is enabled on the cluster; a Terraform-owned
  **backup plan** per cluster schedules backups (cron + retention as runtime inputs) covering
  the workload namespaces, **including volume data and Secrets**.
- **Encrypted with our key** — backups are CMEK-encrypted; the Backup for GKE service agent
  receives the same kind of key grant as the GKE and Compute agents (a third service-agent
  grant in the foundation).
- **Restore is a defined path, not an improvisation** — a Terraform-owned **restore plan**
  pins the restore policy (namespace-scoped, conflict handling); an on-demand restore is an
  operator/automation action against it. The validation suite proves the round-trip: write →
  back up → delete the namespace → restore → the workload serves its data again.
- **Backups can outlive the cluster deliberately** (that is the disaster-recovery property),
  so a clean dev teardown **deletes backups explicitly**: short retention in dev, validation
  cleans up the backups it creates, and the destroy path removes any remaining ones before
  deleting the plan — leaving no orphaned billable storage (the teardown-hygiene lesson of
  issue #31).

## 10. Build order

1. Project → enable services → force-create the service agents.
2. KMS key ring + key → the two key grants.
3. Node service account and its roles.
4. VPC → subnet + secondary ranges → Private Google Access / DNS (Cloud NAT if needed); proxy-only subnet for internal gateways.
5. Artifact Registry (+ reader grant) and the Binary Authorization policy.
6. Cluster (regional, private, hardened, Workload Identity, our key, Dataplane V2) → fleet membership.
7. Node pools (general; Confidential if requested).
8. Connect Gateway access (IAM + in-cluster roles).
9. Certificate Authority Service (in the foundation, step 1-3 territory — it persists across cluster rebuilds): pools + root + per-environment subordinate; grant cert-manager's identity the certificate-requester role.
10. In-cluster platform add-ons: cert-manager + `google-cas-issuer` + `trust-manager`.
11. Gateways: internal (`gke-l7-rilb`, multi-SAN CAS cert) and external (global external, per-host Certificate Manager certs + Cloud Armor + SSL policy + static IP); HTTPRoutes per namespace.
12. DNS: the private zone + per-host records for the internal gateway (the public zone only when `manage_public_dns` is on).
13. Backup for GKE: agent, the CMEK key grant for its service agent, and the backup + restore plans.

## 11. Decisions, in brief

- **One project per environment** — clean isolation, cost, and blast-radius boundary.
- **No public control-plane endpoint; DNS-based private endpoint + Connect Gateway** — nothing reaches the API over the internet.
- **Our own key for secrets and disks** — control and auditability; two grants because Google uses two managed identities.
- **Least-privilege node identity + Workload Identity** — nodes can do little; pods get scoped identities, not node keys.
- **Custom VPC, generous immutable Pod/Service ranges** — deliberate, non-overlapping addressing planned once.
- **Regional everywhere; upgrades by environment** — dev auto-upgrades on a release channel; staging and production upgrade deliberately via scheduled Day-2 operations, validated on a test cluster first.
- **Dataplane V2 default-deny, CIS Level 2** — secure by default.
- **Images only from our registry; Binary Authorization audit → enforce** — no untrusted images.
- **Two gateways per cluster (internal + external)** — one per exposure class, shared across workload namespaces via HTTPRoute attachment and cross-namespace grants; Terraform-owned policies keep their security baseline uniform.
- **Public certs for external, private CAS for internal** — internal hostnames stay out of public Certificate Transparency; trust is distributed by MDM (browsers) and trust-manager (services).
- **Mesh captured, not built** — CAS is the future mesh CA and the GKE gateway stays; east-west mTLS is built in the security phase.
- **Per-pool autoscaler with explicit pools; no node auto-provisioning** — scale within the hardened pool template (per-zone min/max, BALANCED), never invent node shapes.
- **Backup for GKE over disk snapshots or Velero** — application-aware, managed, CMEK-encrypted; Kubernetes state and volumes restore together.
- **Regional persistent disk as a second named class, not the default** — zone-survivable storage for the workloads that need it, without taxing the ones that don't.
- **Multi-host gateways, no wildcard certs** — per-host public certs picked by SNI; one explicit multi-SAN CAS leaf internally.
- **Cloud DNS private zone for internal names; public DNS manual with an opt-in zone** — internal resolution is platform-owned; no in-cluster DNS controller.

## 12. Open items

**Resolved at the Milestone 1 build:** the **control-plane DNS endpoint** is confirmed working on
GKE **1.35.3-gke.2190000** (the cluster was reached over Connect Gateway); **Binary
Authorization** runs the **generally-available project policy** in audit (the Preview check-based
policy is not used). **Resolved at the Milestone 2 build:** the **internal-gateway certificate
plumbing** — a CAS-issued leaf in a Secret attaches to the `gke-l7-rilb` gateway via
`tls.certificateRefs`, with the proxy-only subnet in place (verified live, HTTPS 200 against the
CAS root). Still open:

- **Full WAF enablement** — the external gateway ships a baseline Cloud Armor policy that is not
  yet attached to any backend; attaching it (`GCPBackendPolicy`) and enabling/tuning the OWASP
  rule set in enforce mode + rate-limiting is tracked as its own issue (#26).
- **Staging/production upgrade mechanism** — deferred until the stage/prod clusters are built
  (release channel + maintenance exclusions vs. a pinned version).
- **Service-to-service mutual TLS / service mesh** — a security-phase decision (SEC-10); the
  forward-compatible design is captured in §8.
- **Confirm at the high-availability build:** the `autoscaling_profile` applies with node
  auto-provisioning disabled; regional `pd-balanced` minimum size and CMEK behave as expected;
  deleting a backup plan that has held backups destroys cleanly (else the destroy path purges
  backups first); the preemption validation accounts for the autoscaler adding a node before
  preemption fires.

## 13. Related

[requirements.md](../requirements.md) · [technology-choices.md](../technology-choices.md) · [security-requirements.md](../security-requirements.md).
