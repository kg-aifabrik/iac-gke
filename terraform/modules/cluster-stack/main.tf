# cluster-stack — the per-purpose composition: network, supply chain, the
# hardened cluster, and access, wired together. The per-project foundation
# (services, KMS, node identity) is applied separately and passed in, so
# several purposes can share one project without colliding on its singletons.
#
# Building a cluster is choosing coordinates (environment, purpose, sizing) and
# calling this module — not writing new resources.

locals {
  cluster_name = coalesce(var.cluster_name, "${var.environment}-${var.purpose}")
  network_name = coalesce(var.network_name, "gke-${local.cluster_name}")
  subnet_name  = coalesce(var.subnet_name, "${local.cluster_name}-nodes")

  # Regional cluster across three zones. An explicit list wins; otherwise take
  # the first three zones the region offers (guarantees 3 AZs, region-agnostic).
  node_locations = length(var.node_locations) > 0 ? var.node_locations : slice(sort(data.google_compute_zones.available.names), 0, 3)

  # Every labelable resource carries the same identifying labels (used for cost
  # allocation and inventory); callers may add more.
  labels = merge({
    environment = var.environment
    purpose     = var.purpose
    cluster     = local.cluster_name
    managed-by  = "cluster-ctrl"
  }, var.extra_labels)

  # The platform's CMEK-encrypted persistent-disk StorageClasses (the Compute
  # service agent already holds the key grant). Neither is marked the cluster
  # default (avoids duelling with GKE's standard-rwo); workloads opt in by
  # name. `encrypted-regional-rwo` replicates synchronously across two zones so
  # the volume survives a zone failure — ~2x the disk cost, which is why it is
  # a second named class and not the default (ADR-0008). Rendered (not
  # kubernetes_* resources) and applied by the pipeline with kubectl.
  storageclass_manifests = [
    for sc in [
      { name = "encrypted-rwo", params = {} },
      { name = "encrypted-regional-rwo", params = { "replication-type" = "regional-pd" } },
      ] : yamlencode({
        apiVersion = "storage.k8s.io/v1"
        kind       = "StorageClass"
        metadata = {
          name   = sc.name
          labels = { "app.kubernetes.io/managed-by" = "cluster-ctrl" }
        }
        provisioner = "pd.csi.storage.gke.io"
        parameters = merge({
          type                      = "pd-balanced"
          "disk-encryption-kms-key" = var.kms_key_id
        }, sc.params)
        volumeBindingMode    = "WaitForFirstConsumer"
        allowVolumeExpansion = true
        reclaimPolicy        = "Delete"
    })
  ]

  # Platform namespaces: the gateway namespace and the two workload namespaces,
  # labelled so their HTTPRoutes may attach to the matching gateway. Full
  # namespace stamping (default-deny, quotas) is the security milestone.
  namespace_manifests = [
    for ns in [
      { name = var.gateway_namespace, labels = {} },
      { name = var.external_namespace, labels = { ingress = "external" } },
      { name = var.internal_namespace, labels = { ingress = "internal" } },
      ] : yamlencode({
        apiVersion = "v1"
        kind       = "Namespace"
        metadata   = { name = ns.name, labels = merge(ns.labels, { "app.kubernetes.io/managed-by" = "cluster-ctrl" }) }
    })
  ]

  # Platform PriorityClasses (design §5): three shared tiers so every team uses
  # the same scale instead of inventing values; none is globalDefault, so
  # nothing changes for pods that don't opt in. Rendered as a SEPARATE output
  # too: the pipeline applies them before the Helm add-ons, because admission
  # rejects a pod whose priorityClassName doesn't exist yet.
  priorityclass_manifests = [
    for pc in [
      { name = "platform-critical", value = 900000000, description = "Platform add-ons (certificate issuance, trust distribution): schedules ahead of all workloads and may preempt them." },
      { name = "workload-high", value = 1000000, description = "Production-serving workloads: schedules ahead of, and may preempt, default-tier pods under pressure." },
      { name = "workload-default", value = 0, description = "Normal workloads — identical to an unlabeled pod; the explicit name keeps manifests self-documenting." },
      ] : yamlencode({
        apiVersion    = "scheduling.k8s.io/v1"
        kind          = "PriorityClass"
        metadata      = { name = pc.name, labels = { "app.kubernetes.io/managed-by" = "cluster-ctrl" } }
        value         = pc.value
        globalDefault = false
        description   = pc.description
    })
  ]

  # The CAS root distributed to workloads: a source ConfigMap in the trust
  # namespace + a trust-manager Bundle that fans it out to every namespace. The
  # source ConfigMap (cas-root-ca) must be named differently from the Bundle
  # (cas-root) — trust-manager names the *target* ConfigMaps after the Bundle and
  # rejects a source that equals the target.
  cas_root_configmap = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "cas-root-ca", namespace = "cert-manager" }
    data       = { "ca.crt" = join("", module.private_ca.root_ca_pem) }
  })
  cas_cluster_issuer = yamlencode({
    apiVersion = "cas-issuer.jetstack.io/v1beta1"
    kind       = "GoogleCASClusterIssuer"
    metadata   = { name = "cas-issuer" }
    spec       = { project = var.project_id, location = var.region, caPoolId = module.private_ca.subordinate_ca_pool_name }
  })
  trust_bundle = yamlencode({
    apiVersion = "trust.cert-manager.io/v1alpha1"
    kind       = "Bundle"
    metadata   = { name = "cas-root" }
    spec = {
      sources = [{ configMap = { name = "cas-root-ca", key = "ca.crt" } }]
      target  = { configMap = { key = "ca.crt" } }
    }
  })

  # Everything the pipeline applies in-cluster after a build (after the Helm
  # add-ons): namespaces, operator RBAC, the encrypted StorageClasses, the CAS
  # trust root + issuer + bundle, and the two gateways.
  incluster_manifests = join("\n---\n", concat(
    local.priorityclass_manifests,
    local.namespace_manifests,
    [module.access.rbac_manifest],
    local.storageclass_manifests,
    [
      local.cas_root_configmap,
      local.cas_cluster_issuer,
      local.trust_bundle,
      module.gateway_external.incluster_manifests,
      module.gateway_internal.incluster_manifests,
    ],
  ))
}

data "google_compute_zones" "available" {
  project = var.project_id
  region  = var.region
}

module "network" {
  source = "../network"

  project_id       = var.project_id
  region           = var.region
  network_name     = local.network_name
  subnet_name      = local.subnet_name
  node_cidr        = var.node_cidr
  pod_cidr         = var.pod_cidr
  service_cidr     = var.service_cidr
  enable_cloud_nat = var.enable_cloud_nat

  # The internal gateway is a regional internal ALB, which needs a proxy-only subnet.
  enable_proxy_only_subnet = true
  proxy_only_cidr          = var.proxy_only_cidr
}

module "supply_chain" {
  source = "../supply-chain"

  project_id                 = var.project_id
  region                     = var.region
  node_service_account_email = var.node_service_account_email
  app_repository_id          = var.app_repository_id
  proxy_repository_id        = var.proxy_repository_id
  labels                     = local.labels
}

module "cluster" {
  source = "../gke-cluster"

  project_id   = var.project_id
  region       = var.region
  cluster_name = local.cluster_name

  network             = module.network.network_self_link
  subnetwork          = module.network.subnetwork_self_link
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name

  kms_key_id                 = var.kms_key_id
  node_service_account_email = var.node_service_account_email

  release_channel              = var.release_channel
  node_locations               = local.node_locations
  deletion_protection          = var.deletion_protection
  maintenance_recurring_window = var.maintenance_recurring_window
  labels                       = local.labels

  general_machine_type = var.general_machine_type
  general_node_count   = var.general_node_count
  general_disk_size_gb = var.general_disk_size_gb
  general_spot         = var.general_spot
  general_autoscaling  = var.general_autoscaling
  autoscaling_profile  = var.autoscaling_profile

  enable_confidential_pool  = var.enable_confidential_pool
  confidential_machine_type = var.confidential_machine_type
  confidential_node_count   = var.confidential_node_count
}

module "access" {
  source = "../access"

  project_id        = var.project_id
  operator_members  = var.operator_members
  automation_member = var.automation_member
  cluster_role      = var.cluster_role
}

# DNS (ADR-0006): the per-environment private zone resolving every internal
# hostname to the internal VIP inside the VPC, plus the opt-in public zone.
module "dns" {
  source = "../dns-zones"

  project_id           = var.project_id
  internal_zone_domain = var.internal_zone_domain
  internal_records     = { for h in var.internal_hostnames : h => module.gateway_internal.ip_address }
  network_self_link    = module.network.network_self_link

  manage_public_dns  = var.manage_public_dns
  public_zone_domain = var.public_zone_domain
  public_records     = var.manage_public_dns ? module.gateway_external.dns_records : {}

  # Dev teardown hygiene (#31) follows the cluster's protection setting.
  force_destroy = !var.deletion_protection
  labels        = local.labels
}

# Backup for GKE (ADR-0004): scheduled CMEK-encrypted backups + the pinned
# restore path. Off only where a cluster genuinely holds nothing worth keeping.
module "backup" {
  source = "../gke-backup"
  count  = var.enable_backup ? 1 : 0

  project_id  = var.project_id
  region      = var.region
  cluster_id  = module.cluster.cluster_id
  name        = local.cluster_name
  schedule    = var.backup_schedule
  retain_days = var.backup_retain_days
  kms_key_id  = var.kms_key_id
  labels      = local.labels
}

# Private CA (CAS) for internal-endpoint TLS, plus the cert-manager identity.
module "private_ca" {
  source = "../private-ca"

  project_id          = var.project_id
  region              = var.region
  environment         = var.environment
  workload_pool       = module.cluster.workload_pool
  deletion_protection = var.deletion_protection
  labels              = local.labels
}

# Two gateways per cluster (ADR-0001). External: internet-facing, public cert,
# Cloud Armor. Internal: private VIP, CAS cert.
module "gateway_external" {
  source = "../gke-gateway"

  exposure          = "external"
  name              = "external"
  project_id        = var.project_id
  region            = var.region
  gateway_namespace = var.gateway_namespace
  hostnames         = var.external_hostnames
  labels            = local.labels
}

module "gateway_internal" {
  source = "../gke-gateway"

  exposure          = "internal"
  name              = "internal"
  project_id        = var.project_id
  region            = var.region
  subnetwork        = module.network.subnetwork_self_link
  gateway_namespace = var.gateway_namespace
  hostnames         = var.internal_hostnames
  labels            = local.labels
}
