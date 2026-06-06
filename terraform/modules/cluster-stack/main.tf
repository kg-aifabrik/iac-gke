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
