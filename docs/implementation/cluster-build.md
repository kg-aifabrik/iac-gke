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
