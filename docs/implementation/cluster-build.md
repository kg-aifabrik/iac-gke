# How the cluster is built

An operator-facing record of how a cluster is assembled, and why — read this instead
of reverse-engineering the Terraform. It grows one section per layer as each is built.

*Design (the why): [`docs/designs/google-cloud-design.md`](../designs/google-cloud-design.md). Plans: [`milestone-1-cluster-factory.md`](../plans/milestone-1-cluster-factory.md) (cluster), [`milestone-2-ingress.md`](../plans/milestone-2-ingress.md) (ingress & TLS).*

---

## Foundation — `terraform/modules/project-foundation`

What it creates in each environment's project:

- **Enabled services** — the APIs the cluster and its supply chain use (GKE, Compute,
  KMS, Artifact Registry + scanning, Binary Authorization, fleet + Connect Gateway,
  logging/monitoring, Secret Manager, DNS). Left enabled on teardown, because disabling
  them is slow and disruptive.
- **GKE service agent** — force-created (so it exists before we grant it key access;
  otherwise the key grant races the agent's lazy creation).
- **Cluster encryption key** — a Cloud KMS key ring + key in the cluster's region (KMS has
  no global option for this), rotating every 90 days. Created once and kept: key rings and
  keys can't be deleted, so teardown leaves them and re-runs reuse them.
- **Three key grants** — the **GKE** service agent gets key use for **secret (etcd)**
  encryption; the **Compute** service agent for **node/disk** encryption; the **Backup for
  GKE** service agent for **backup** encryption (ADR-0004). The first two are required —
  missing either breaks the cluster; the third is required for CMEK-encrypted backups.
- **Node identity** — a least-privilege node service account holding only
  `roles/container.defaultNodeServiceAccount` (logging, metrics, inventory). Image pull
  (`roles/artifactregistry.reader`) is granted repository-scoped by the supply-chain module.
  Pods use Workload Identity, not this account.

Notes:
- To remove key material later, destroy the key *versions*
  (`gcloud kms keys versions destroy …`) — ~$0.06 per active version per month, $0 once
  destroyed. The key ring/key resources themselves are permanent.

---

## Bootstrap for Terraform builds — `bootstrap/setup-build-foundation.sh`

One-time and human-run (it grants the automation its powers, so the automation can't grant
them to itself). Idempotent.

- **State bucket** — a versioned Cloud Storage bucket `<project>-tf-state` (uniform access,
  public access blocked). Each environment's state lives under a prefix (`env/dev`,
  `env/stage`, …), so one bucket serves the fleet.
- **Build-role elevation** — raises the Milestone 0 automation identity from its read-only
  role to a least-privilege **build** set (project-scoped predefined roles, no Owner/Editor):
  `serviceUsageAdmin` (enable services); `compute.networkAdmin` + `compute.securityAdmin` +
  `dns.admin` (network, firewall, DNS); `container.admin` (clusters); `cloudkms.admin` (key +
  key IAM); `iam.serviceAccountAdmin` + `iam.serviceAccountUser` (node identity);
  `resourcemanager.projectIamAdmin` (grant node/Gateway roles); `artifactregistry.admin`;
  `binaryauthorization.policyEditor`; `gkehub.admin` (fleet); `privateca.admin` (CAS pools and
  CAs for internal TLS); and `certificatemanager.owner` (public managed certs / maps / DNS
  authorizations — `owner`, not `editor`, because `editor` lacks the `*.delete` permissions a
  clean teardown needs); and `gkebackup.admin` (backup/restore plans + on-demand backups,
  ADR-0004). Superseded roles — the Milestone 0 read-only viewer, and
  `certificatemanager.editor` once replaced by `.owner` — are removed so the set stays exact.

Elevating the identity changes its role set, so the `verify-access` workflow's expected-roles
value is re-synced to this build set when the bootstrap is run — kept out of that commit so
the Milestone 0 check isn't tripped before the roles actually change.

## Network — `terraform/modules/network`

- **Custom VPC** — `auto_create_subnetworks = false`; subnets are placed deliberately.
- **Regional subnet + two secondary ranges** — one subnet (a subnet spans all zones in its
  region) with `pods` and `services` secondary ranges for the VPC-native (alias-IP) cluster.
  The Pod range comes from `100.64.0.0/10` (to spare RFC1918 space) and is the dominant
  consumer; **secondary ranges are immutable after creation**, so they're sized once.
- **Private Google Access** — on the subnet, so private nodes (no external IP) reach Google
  APIs and Artifact Registry over Google's internal path — no NAT needed for Google services.
- **Cloud NAT** — optional (`enable_cloud_nat`, default off); only for workloads needing the
  public internet. The namespace stamps (security milestone, #17) will additionally gate egress
  with a per-namespace default-deny network policy. (Dev currently turns Cloud NAT on so the
  in-cluster TLS controllers can pull their images from quay.io until those are mirrored
  through Artifact Registry — issue #27.)
- **Proxy-only subnet** — a regional `REGIONAL_MANAGED_PROXY` subnet (`enable_proxy_only_subnet`),
  required by the internal regional Application Load Balancer (the internal gateway) for its
  managed Envoy proxies. Created only when a cluster fronts an internal gateway.

Outputs the network/subnet and the `pods`/`services` range names the cluster's IP
allocation policy references. (Restricted-VIP private DNS for VPC Service Controls is a
future hardening, not built here — Private Google Access suffices for the cluster to work.)

## GKE cluster — `terraform/modules/gke-cluster`

One hardened, private, regional cluster + node pools. Hardening is identical everywhere;
sizing/options are inputs (per environment, per purpose).

- **Regional + explicit pools** — control plane across the region's zones; nodes across the
  given zones. The default pool is created then removed so every real pool uses our settings.
- **Private, no public endpoint** — private nodes; the control plane uses the **DNS-based
  endpoint** with external access off. (DNS-endpoint availability is confirmed on the target
  GKE version at build — design open item.)
- **VPC-native + Dataplane V2** — `ADVANCED_DATAPATH` (Cilium); the per-namespace default-deny
  policy it will enforce arrives with the namespace stamps (security milestone, #17).
- **Hardening** — shielded nodes, Container-Optimized OS, Workload Identity (pool + per-node
  `GKE_METADATA`), secret encryption with our key, node/disk encryption (`boot_disk_kms_key`).
- **Admission** — Binary Authorization opts into the project policy (audit first, then enforce).
- **Observability** — system + workload logs; system metrics + **managed Prometheus**.
- **Other** — Gateway API for ingress; cost-allocation enabled (per-cluster/per-namespace cost);
  fleet membership (for Connect Gateway); deletion protection; maintenance window in dev.
- **Node pools** — `general` (e2-medium, on-demand by default); optional `confidential`
  (memory-encrypting, always on-demand, tainted so only opted-in workloads land there).
- **Autoscaling (ADR-0007)** — the general pool autoscales between **per-zone** min/max bounds
  (`general_autoscaling`; null keeps a fixed pool of `general_node_count`). `BALANCED` location
  policy spreads scale-out across zones; the cluster-autoscaler `autoscaling_profile` is an
  input (`BALANCED` default). Node auto-provisioning stays **off** — every node comes from the
  hardened pool template. When autoscaling, Terraform stops managing `node_count` (the
  autoscaler owns it) and seeds the pool at the minimum; `initial_node_count` drift is ignored
  so raising the minimum later never recreates the pool.
- **Surge pinned** — `max_surge=1, max_unavailable=0` on both pools: upgrades replace one node
  at a time in the zone being upgraded, so capacity never drops below steady state.

## Supply chain — `terraform/modules/supply-chain`

Where cluster images come from, and which images are allowed to run.

- **Two registries** — a private **`app`** repository for the team's own images, and a
  **remote pull-through proxy** (`docker-remote`) for public Docker Hub images. Workloads
  reference the proxy instead of `docker.io`, so every public image is fetched once, cached
  in the project, scanned, and admitted through the same policy — and node pulls need no
  public egress (they ride Private Google Access). Both are in the cluster's region so pulls
  stay in-region.
- **Repository-scoped pull access** — the node service account gets
  `roles/artifactregistry.reader` on **these two repositories only**, not project-wide. The
  grant lives in this module (with the repositories it concerns), not in the foundation.
- **Binary Authorization policy** — one per project, wired to the cluster's
  `PROJECT_SINGLETON_POLICY_ENFORCE`. It starts in **audit**: `ALWAYS_ALLOW` with
  `DRYRUN_AUDIT_LOG_ONLY`, so the cluster comes up and nothing is blocked while the policy
  resource is in place. (`REQUIRE_ATTESTATION` is invalid until attestors exist — the API
  rejects an empty `require_attestations_by` — so it can't be the starting posture.) Our two
  registries are whitelisted (`admission_whitelist_patterns`), and Google-managed system
  images are covered by `global_policy_evaluation_mode = ENABLE`, ready for the enforce flip.

Notes:
- **Flip to enforce** is deliberate and deferred (issue #12): add attestors and set the
  default rule's `enforcement_mode` to `ENFORCED_BLOCK_AND_AUDIT_LOG`. Done once an
  image-signing pipeline exists — until then enforce would block everything not whitelisted.
- **Registry encryption** is left at Google-managed at-rest (the default). Customer-managed
  (CMEK) encryption of the repositories is a possible later hardening; it needs a third key
  grant (the Artifact Registry service agent) and isn't required for the cluster to work.

## Access — `terraform/modules/access`

The control plane has no public endpoint, so the only way in is the fleet's **Connect
Gateway**. Reaching the cluster takes two grants that must agree — the module derives both
from one identity list so they can't drift apart:

- **Google IAM (can I use the gateway?)** — operators and the automation identity get
  `roles/gkehub.gatewayEditor` (read-write kubectl through the gateway) and
  `roles/gkehub.viewer` (resolve which membership to route to). Granted at the project level
  (SRE operate every cluster in the project); tightening to a per-membership grant is a later
  least-privilege step.
- **Kubernetes RBAC (what may I do once in?)** — the gateway authenticates a Google identity
  and presents it to the cluster as a Kubernetes **User** named by its email (only Google
  Groups map to `Group`). A `ClusterRoleBinding` binds the **operators** to `cluster-admin` to
  start (namespace-scoped roles arrive with the namespace-stamp milestone). The automation is
  deliberately *not* in the binding — it already authorizes as cluster-admin through GKE's IAM
  authorizer because it holds `roles/container.admin`, which is also why it can apply this
  binding in the first place.

**Why the RBAC is a rendered manifest, not a Terraform `kubernetes` resource:** the cluster
has no public endpoint, so a `kubernetes` provider pointed at it cannot connect *at plan
time on the first run* — the cluster doesn't exist yet — which would break the approval
gate's `plan`. Managing in-cluster objects in the same state as the cluster that hosts them
is a known footgun. So Terraform manages only Google Cloud resources (clean plan), and the
module **renders the `ClusterRoleBinding` as a YAML output** from the same identity list it
uses for the IAM grants (one source of truth). The pipeline writes that output to a file and
`kubectl apply`s it over the gateway after the cluster is up. Every in-cluster object
(this binding, the platform manifests, the examples) follows the same
Terraform-for-Google, kubectl-for-in-cluster split.

**How an operator connects:**

```bash
# One-time: point kubeconfig at the cluster through Connect Gateway (no VPN, no public IP).
gcloud container fleet memberships get-credentials <cluster-name> --project <project-id>

# Now kubectl is proxied through the gateway, authenticated as your Google identity.
kubectl get nodes
```

The automation does the same with the impersonated service account to apply in-cluster
resources during a build.

## Private CA — `terraform/modules/private-ca`

Internal endpoints get TLS from a private certificate authority, so their hostnames never
appear in public Certificate Transparency logs (ADR-0002). Certificate Authority Service (CAS)
holds the hierarchy — in dev it is **per-cluster** (created by `cluster-stack`, removed by a
`fop` teardown so nothing bills while dev is idle). The pool, CA, and service-account names
carry a **per-generation random suffix** (`<env>-cas-<rand>-*`, `cert-manager-cas-<rand>`):
destroyed with the cluster and regenerated on the next apply, so a retired CaPool id or a
soft-deleted service-account id is never reused (ADR-0002 amendment 3). Stage/prod can host it
in their foundation for a durable MDM root:

- **Root + subordinate** — a self-signed root (10-year, kept cold) signs a per-environment
  subordinate (5-year) that issues the leaf certificates; **DEVOPS** tier in dev (~10x cheaper; stage/prod use `ENTERPRISE`), RSA-4096.
  Unprotected (dev) CAs purge immediately on destroy so their pools delete cleanly in one run;
  protected (prod) CAs keep the 30-day recovery window (see the lock/teardown notes and #31).
- **cert-manager identity** — a Google service account that google-cas-issuer impersonates via
  Workload Identity, holding `roles/privateca.certificateRequester` on the **subordinate pool
  only** (least privilege — it may request leaves, not manage the CAs and not touch the root).

Terraform owns the CAS Google resources; the in-cluster `GoogleCASClusterIssuer`, the root
trust bundle, and the leaf `Certificate`s are rendered manifests (see the in-cluster section).

## Ingress & TLS — `terraform/modules/gke-gateway`

Every cluster gets **two gateways**, one module instance each (ADR-0001):

- **External** (`gke-l7-global-external-managed`) — a global external Application Load Balancer
  for end-user traffic: a reserved global IP, a baseline Cloud Armor policy (created but not yet
  attached to any backend; attachment + WAF enforcement is issue #26), and **per-hostname**
  Certificate Manager managed certificates (a DNS
  authorization + certificate + certificate-map *entry* per host; the map stays singular and is
  attached by the `networking.gke.io/certmap` annotation, serving certs by SNI — ADR-0005). The
  HTTPS listener carries no inline `tls` block — certificates come from the certmap.
- **Internal** (`gke-l7-rilb`) — a regional internal Application Load Balancer for in-VPC
  traffic: a reserved internal VIP on the proxy-only subnet, and one **multi-SAN** CAS-issued
  certificate (every internal hostname an explicit SAN, no wildcards) that cert-manager writes
  into a Secret the listener terminates with; adding a hostname reissues it automatically.
- **Hostnames are lists** (`external_hostnames` / `internal_hostnames`) — adding an app to a
  gateway is one list entry; the `dns_records` output emits the registrar records per external
  host. Listeners match all attached hostnames; HTTPRoutes declare the names they own, and
  namespace labels still gate attachment.

Both render the same in-cluster shape: a `Gateway`, an HTTP→HTTPS redirect `HTTPRoute`, and a
`GCPGatewayPolicy` setting the SSL policy (minimum TLS 1.2, MODERN profile). Workload
`HTTPRoute`s attach across namespaces by a selector label (`ingress=external|internal`), so a
namespace opts into a gateway by labelling itself — consistent WAF/TLS configuration stays in
the platform, not in each application.

## DNS — `terraform/modules/dns-zones`

Internal hostnames resolve inside the VPC with zero client setup; public records stay
SRE-manual with automation one flag away (ADR-0006, design §8).

- **Private zone** — one per environment (dev: `dev.aifabrik.com`), bound to the cluster VPC,
  with an A record per internal hostname → the internal gateway VIP. Pods resolve it through
  the node resolver (kube-dns → metadata → Cloud DNS); split-horizon with the public domain,
  the names never leave the VPC. Private zones need no registrar control, so every
  environment uses the work-domain convention.
- **Public zone (opt-in)** — `manage_public_dns` (default **off**). When the domain (or a
  subdomain) is delegated to Cloud DNS at the registrar — one-time, manual — the per-host A
  records *and* the Certificate Manager DNS-authorization CNAMEs (the record whose absence
  stalled the M2 cert in `PROVISIONING`) become Terraform-managed. Until then SREs create
  them from the `dns_records` output. The zone's `name_servers` output is the delegation
  record set.
- **Teardown hygiene (#31)** — `force_destroy` follows the cluster's deletion-protection
  setting, so dev zones delete even with records present.

## Backup and restore — `terraform/modules/gke-backup`

Stateful workloads are recoverable from deletion, corruption, and operator error
(ADR-0004, design §9). Backup for GKE captures Kubernetes objects, Secrets, and volume data
**together**, so a restore is a working workload, not a loose disk image.

- **Agent** — enabled on the cluster (`gke_backup_agent_config`); free until a plan exists.
- **Backup plan** (`<cluster>-daily`) — cron schedule + retention as runtime inputs, all
  namespaces, volume data + Secrets included, **CMEK-encrypted** with the cluster key (the
  third service-agent grant in the foundation). Dev keeps retention short (3 days) and no
  delete lock, so teardown never strands storage; production sets real retention (and a
  delete lock as a later hardening).
- **Restore plan** (`<cluster>-restore`) — the pinned restore policy: namespaced resources
  delete-and-restore, volumes from backup data, cluster-scoped resources untouched (they
  belong to the platform). An on-demand restore is an operator/automation action against it
  (`gcloud backup-restore restores create`).
- **Teardown discipline (#31)** — backups can outlive the cluster by design; the validation
  deletes the backups it creates. A destroy-path purge of any remaining (e.g. scheduled)
  backups — without which a plan still holding backups blocks `terraform destroy` — is future
  work (#47). The automation holds `roles/gkebackup.admin` (15th build role).

## The factory — `modules/cluster-stack` + `envs/`

Building a cluster is **choosing coordinates, not writing code**. The three dimensions —
**account** (the project), **environment**, **purpose** — map onto the layout:

```
modules/cluster-stack/    composes network + supply-chain + gke-cluster + access + private-ca + gateways + dns-zones + gke-backup
envs/dev/foundation/      the per-project foundation (services, KMS, node SA) — applied once
envs/<env>/<purpose>/     a generated cluster root: reads foundation, calls the stack
                          (e.g. envs/dev/fop, envs/dev/mgmt)
```

- **Why foundation is split out (per project, not per cluster)** — services-enablement, the
  KMS key ring, the node service account, and project IAM are **project singletons**. If each
  cluster root created them, a second purpose in the same project would collide on them. So
  the foundation is its own root, applied once; the per-purpose roots read its outputs via
  `terraform_remote_state`. Adding `dev/mgmt` later never re-creates a singleton.
- **`cluster-stack` is the composition** — it takes the coordinates (environment, purpose,
  sizing) and the foundation's outputs, derives names (`gke-dev-fop`, …) and the **three
  zones** (the region's first three, unless overridden), stamps consistent
  `environment/purpose/cluster` labels, and wires the eight per-purpose modules. The hardening
  inside those modules is identical for every cluster; only the inputs differ.
- **The roots are generated, not hand-written (ADR-0009).** `config/clusters.yaml` is the
  single source of truth — per-`(env,purpose)` shape/sizing as data, merged
  defaults → env → purpose → cluster override. The `tools/cluster-factory` generator renders
  each active cluster's thin root from it: `envs/dev/fop` pins dev-FOP's shape (`e2-medium`,
  general pool, autoscaling 1–2 nodes/zone × 3 zones; `REGULAR` channel + a weekend window; not
  deletion-protected) with only the account/identity values left as variables. Roots are
  **normalized and committed** (like lockfiles); regenerating an existing cluster is a
  `terraform plan` no-op (its module inputs don't change).
- **Adding a purpose** = add it under `purposes:` and `clusters:` in `config/clusters.yaml`,
  then run [`bootstrap/add-cluster-purpose.sh`](../../bootstrap/add-cluster-purpose.sh). That
  renders the new root **and** regenerates the pipeline's `env`/`purpose` input lists from the
  registry (kept in sync via sentinel-marked regions). `env` is a fixed set (`dev`/`stage`/`prod`);
  `purpose` is the open axis. CI guards drift with `cluster-factory generate --check`.
- **Account stays out of git** — the state-bucket name and project id are supplied at
  `init`/apply (`-backend-config`, `terraform.tfvars` (git-ignored), or `TF_VAR_*`), never
  committed. Each root keeps its own state under a prefix: `env/<env>/foundation`,
  `env/<env>/<purpose>` (e.g. `env/dev/fop`, `env/dev/mgmt`).

State backend (per root):

```bash
terraform -chdir=terraform/envs/dev/foundation  init -backend-config="bucket=<project>-tf-state"
terraform -chdir=terraform/envs/<env>/<purpose> init -backend-config="bucket=<project>-tf-state"
```

**Provider dependency locks (`.terraform.lock.hcl`).** The lock pins the exact provider
versions and checksums for a build; the version *constraints* in code stay deliberately
wide (`>= 6.0, < 8.0`), and the lock is what actually freezes a build at a known-good
version. Two rules keep it trustworthy, learned from a drift that broke a teardown:

- **Roots only, never modules.** A lock is committed only at the env roots
  (`envs/dev/{foundation,fop}`), where `terraform init` runs. A lock inside a reusable
  module (`modules/*`) is never consulted by a root's `init` — it only drifts and confuses.
  `.gitignore` ignores `terraform/modules/**/.terraform.lock.hcl` so a stray `init`/
  `validate` run inside a module directory cannot recommit one.
- **Multi-platform.** Each root lock carries checksums for every platform that runs
  Terraform — `linux_amd64` (CI) and developer Macs (`darwin_amd64`, `darwin_arm64`) —
  produced with `terraform providers lock -platform=linux_amd64 -platform=darwin_amd64
  -platform=darwin_arm64`. A lock holding only one platform's hash (e.g. a Mac-generated
  lock) makes CI either silently re-resolve, losing the pin, or fail outright. Because the
  roots are generated, the factory keeps **one** canonical lock at
  `tools/cluster-factory/src/cluster_factory/templates/terraform.lock.hcl` and copies it into
  every root, so all clusters pin identically — refresh providers by updating that one file
  and regenerating.

CI enforces both: every workflow's `init` runs with `-lockfile=readonly`, so a lock that is
missing, single-platform, or stale **fails the run** instead of being rewritten on the
runner. Updating a lock is therefore a deliberate, committed act — `terraform init -upgrade`
to move versions within constraints, or `terraform providers lock` to add a platform or
refresh hashes — done locally (the `init` examples above, without `readonly`) and reviewed
in the diff.

## The pipeline — `.github/workflows/terraform-{plan,apply,destroy}.yml`

A change to a cluster is a reviewed change, never a console click. All three workflows
authenticate **keyless** (Workload Identity Federation — no stored keys) and read
account-specific values from repository variables, so nothing project-specific is in git.

All three take an `env` + `purpose` selector (`TF_ROOT = terraform/envs/<env>/<purpose>`);
`foundation` is offered as a special `purpose`. The `purpose` choice list and the plan matrix
are **generated from the registry** (sentinel-marked regions, kept current by the prime
script), so the dispatch menu can't offer a cluster that has no root. `env` today is wired
only for `dev` (stage/prod are modeled but unbuilt — ADR-0009).

- **`terraform-plan` (preview)** — runs on every PR touching `terraform/`. Its matrix plans
  every `(env, purpose)` root the registry declares (each env's `foundation` + each cluster)
  and **posts the plan to the PR** (one collapsible, self-updating comment per root), uploading
  each saved plan as an artifact. This is the reviewer's diff.
- **`terraform-apply` (gated, saved plan)** — manually dispatched for one `(env, purpose)`. The
  run **plans, then waits on the `dev` GitHub Environment** whose *required reviewers are the SRE
  approver list*; the apply job is blocked until one approves. It then applies the **saved plan
  from the same run**, so what is applied is exactly what was approved. For any cluster purpose
  (i.e. not `foundation`) it finishes by applying the in-cluster platform manifests over Connect
  Gateway (with a short retry for IAM propagation). Concurrency serializes applies per
  `(env, purpose)` and never cancels one mid-flight.
- **`terraform-destroy` (gated)** — manually dispatched, requires re-typing the `purpose` to
  confirm, and goes through the same `dev` Environment approval. Tears down a short-lived
  cluster after verification. (Destroying `foundation` leaves the KMS key ring/key behind —
  Cloud KMS forbids deletion — so a later apply reuses them.)

**One-time setup an operator must do** (beyond the Milestone 0 keyless-access runbook):

- A **GitHub Environment named `dev`** with the SRE approvers added as **required reviewers** —
  this *is* the approval gate. Without it, apply/destroy would run unreviewed.
- Repository variables: `GCP_REGION` (optional; defaults to `us-central1`) and
  `SRE_OPERATOR_MEMBERS` — a JSON array of IAM member strings, e.g.
  `["group:sre@aifabrik.com"]`. The automation member is derived from `WIF_SERVICE_ACCOUNT`.

## In-cluster platform manifests + validation — `examples/`

Some platform pieces are *in-cluster* objects, not Terraform-managed cluster fields. They
follow the **Terraform-for-Google, kubectl-for-in-cluster** split (see the access module):
the stack *renders* them and the apply pipeline applies them over Connect Gateway as one
multi-doc YAML (`incluster_manifests`):

- **Operator RBAC** — the `ClusterRoleBinding` from the access module.
- **Encrypted StorageClasses** — two CMEK-encrypted persistent-disk classes rendered from the
  cluster key (the Compute service agent already holds the key grant): **`encrypted-rwo`**
  (zonal, the usual choice) and **`encrypted-regional-rwo`** (regional `pd-balanced`,
  synchronously replicated across two zones — survives a zone failure at ~2× disk cost,
  ADR-0008). Neither is marked the cluster default (to avoid duelling with GKE's
  `standard-rwo`); workloads opt in by name.
- **Platform namespaces** — `gateway-system` plus the workload namespaces, each labelled so its
  HTTPRoutes may attach to the matching gateway (`ingress=external|internal`).
- **PriorityClasses (design §5)** — three shared tiers (`platform-critical` / `workload-high` /
  `workload-default`), none `globalDefault`. Applied **before** the Helm add-ons (separate
  `priorityclass_manifests` output) because admission rejects pods whose priorityClassName
  doesn't exist yet; cert-manager installs at `platform-critical` with 2 replicas per component
  + PodDisruptionBudgets, while trust-manager/google-cas-issuer stay single-replica
  deliberately (a PDB on one replica blocks drains; renewal is asynchronous).
- **Gateways + TLS wiring** — the `fop` apply first Helm-installs the pinned TLS controllers
  (cert-manager, trust-manager, google-cas-issuer) so their custom resource definitions exist,
  then applies the two `Gateway`s with their redirect routes and SSL policies, the
  `GoogleCASClusterIssuer`, and the CAS root **trust bundle** that trust-manager fans out to
  every namespace.

**Validation (`examples/validate.sh`)** proves the cluster is genuinely ready for workloads
from an end user's point of view (WLD-2), and the examples double as **compliant reference
deployments** (non-root, read-only root filesystem, dropped capabilities, seccomp
`RuntimeDefault`, resource limits, zone spread, PodDisruptionBudgets, priority tiers). It
deploys **thirteen cases** and asserts the end-to-end outcome, not just that pods start —
serving on every hostname over both gateways (internal ones **by name** through the private
zone), persistence, supply chain, Workload Identity, and the high-availability behaviors:
drain survival and a rolling deploy with **zero failed requests**, node autoscaling, the
Horizontal Pod Autoscaler, regional-disk zone failover, priority preemption, and a full
backup→delete→restore round-trip. The authoritative case matrix lives in
[`examples/README.md`](../../examples/README.md) — one source of truth, not duplicated here.

Run at bring-up by an operator (it needs operator-level permissions to create the throwaway
Workload-Identity scaffolding); the summary is pasted into the milestone's verification issue
as evidence, and the runtime acceptance criteria are checked off only once it passes against
the real cluster.
