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

*(written next)*
