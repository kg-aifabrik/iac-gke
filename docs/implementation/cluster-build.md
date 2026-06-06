# How the cluster is built

An operator-facing record of how a cluster is assembled, and why — read this instead
of reverse-engineering the Terraform. It grows one section per layer as each is built.

*Design (the why): [cluster-ctrl `docs/designs/google-cloud-design.md`](https://github.com/kg-aifabrik/cluster-ctrl/blob/main/docs/designs/google-cloud-design.md). Plan: [`docs/plans/milestone-1-cluster-factory.md`](../plans/milestone-1-cluster-factory.md).*

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
- **Two key grants** — the **GKE** service agent gets key use for **secret (etcd)**
  encryption; the **Compute** service agent gets key use for **node/disk** encryption. Both
  are required — missing either breaks the cluster.
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
  `binaryauthorization.policyEditor`; `gkehub.admin` (fleet). The superseded read-only role
  is removed so the set stays exact.

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
  public internet. Egress is also gated by the namespace default-deny network policy.

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
- **VPC-native + Dataplane V2** — `ADVANCED_DATAPATH` (Cilium); default-deny is applied as
  in-cluster manifests.
- **Hardening** — shielded nodes, Container-Optimized OS, Workload Identity (pool + per-node
  `GKE_METADATA`), secret encryption with our key, node/disk encryption (`boot_disk_kms_key`).
- **Admission** — Binary Authorization opts into the project policy (audit first, then enforce).
- **Observability** — system + workload logs; system metrics + **managed Prometheus**.
- **Other** — Gateway API for ingress; cost-allocation enabled (per-cluster/per-namespace cost);
  fleet membership (for Connect Gateway); deletion protection; maintenance window in dev.
- **Node pools** — `general` (e2-medium, on-demand by default); optional `confidential`
  (memory-encrypting, always on-demand, tainted so only opted-in workloads land there).

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
  `PROJECT_SINGLETON_POLICY_ENFORCE`. It starts in **audit (dry-run)**: `REQUIRE_ATTESTATION`
  with `DRYRUN_AUDIT_LOG_ONLY`, so the cluster comes up while the policy *logs* what it would
  deny rather than blocking anything. Our two registries are whitelisted (`admission_whitelist_patterns`),
  and Google-managed system images are covered by `global_policy_evaluation_mode = ENABLE`,
  so the eventual enforce flip catches only un-attested third-party images.

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
(this binding, the default-deny network policy, the examples) follows the same
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

## The factory — `modules/cluster-stack` + `envs/`

Building a cluster is **choosing coordinates, not writing code**. The three dimensions —
**account** (the project), **environment**, **purpose** — map onto the layout:

```
modules/cluster-stack/    composes network + supply-chain + gke-cluster + access (one purpose)
envs/dev/foundation/      the per-project foundation (services, KMS, node SA) — applied once
envs/dev/fop/             dev Fleet-Operations-Plane: reads foundation, calls the stack
```

- **Why foundation is split out (per project, not per cluster)** — services-enablement, the
  KMS key ring, the node service account, and project IAM are **project singletons**. If each
  cluster root created them, a second purpose in the same project would collide on them. So
  the foundation is its own root, applied once; the per-purpose roots read its outputs via
  `terraform_remote_state`. Adding `dev/mgmt` later never re-creates a singleton.
- **`cluster-stack` is the composition** — it takes the coordinates (environment, purpose,
  sizing) and the foundation's outputs, derives names (`gke-dev-fop`, …) and the **three
  zones** (the region's first three, unless overridden), stamps consistent
  `environment/purpose/cluster` labels, and wires the four per-purpose modules. The hardening
  inside those modules is identical for every cluster; only the inputs differ.
- **`envs/dev/fop` is thin** — it pins dev-FOP's shape (smallest sizing: one `e2-medium` per
  zone × 3 zones, general pool only; `REGULAR` channel + a weekend maintenance window; not
  deletion-protected because dev is torn down) and supplies only account/identity values.
  **Adding a purpose** = a sibling folder like this one with a different `purpose` and sizing.
- **Account stays out of git** — the state-bucket name and project id are supplied at
  `init`/apply (`-backend-config`, `terraform.tfvars` (git-ignored), or `TF_VAR_*`), never
  committed. Each root keeps its own state under a prefix: `env/dev/foundation`, `env/dev/fop`.

State backend (per root):

```bash
terraform -chdir=terraform/envs/dev/foundation init -backend-config="bucket=<project>-tf-state"
terraform -chdir=terraform/envs/dev/fop        init -backend-config="bucket=<project>-tf-state"
```
