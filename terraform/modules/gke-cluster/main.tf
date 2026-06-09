# gke-cluster — one hardened, private, regional GKE cluster and its node pools.
# The hardening is identical for every cluster; sizing/options are inputs.
# See docs/implementation/cluster-build.md for the rationale.

locals {
  workload_pool = "${var.project_id}.svc.id.goog"

  # Shared hardened node configuration for every pool.
  oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
}

resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.cluster_name
  location = var.region

  # Spread nodes across zones for high availability (null => GKE selects).
  node_locations = length(var.node_locations) > 0 ? var.node_locations : null

  # Manage node pools explicitly: create the cluster with a throwaway default
  # pool, then remove it so every real pool uses our hardened settings.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.deletion_protection
  resource_labels     = var.labels

  network    = var.network
  subnetwork = var.subnetwork

  # VPC-native (alias IP) + Dataplane V2 (Cilium/eBPF). Default-deny network
  # policy is applied as in-cluster manifests, not a cluster field.
  networking_mode   = "VPC_NATIVE"
  datapath_provider = "ADVANCED_DATAPATH"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Private nodes; the control plane uses the DNS-based endpoint with external
  # access off — there is no public API endpoint. (Confirm DNS endpoint support
  # on the target GKE version at build; see the design's open items.)
  private_cluster_config {
    enable_private_nodes = true
  }
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = false
    }
  }

  release_channel {
    channel = var.release_channel
  }

  enable_shielded_nodes = true

  workload_identity_config {
    workload_pool = local.workload_pool
  }

  # Application-layer secret (etcd) encryption with our key.
  database_encryption {
    state    = "ENCRYPTED"
    key_name = var.kms_key_id
  }

  # Admit only trusted images. The cluster opts into the project policy; that
  # policy (supply-chain module) runs in audit first, then enforce.
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  # Per-cluster / per-namespace cost attribution (viewed via GKE Cost Allocation).
  cost_management_config {
    enabled = true
  }

  # Cluster-autoscaler profile for the per-pool autoscalers. Node
  # auto-provisioning stays off (enabled = false): every node comes from an
  # explicitly defined hardened pool, never an autoscaler-invented shape
  # (ADR-0007).
  cluster_autoscaling {
    enabled             = false
    autoscaling_profile = var.autoscaling_profile
  }

  # Enable the Gateway API for ingress (the chosen ingress, TC-6).
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  # Backup for GKE agent (ADR-0004). The agent alone costs nothing; the
  # backup/restore plans live in the gke-backup module.
  addons_config {
    gke_backup_agent_config {
      enabled = var.enable_backup_agent
    }
  }

  # Join the fleet — the prerequisite for Connect Gateway.
  fleet {
    project = var.project_id
  }

  # Maintenance window for automatic upgrades (used in dev; null = none).
  dynamic "maintenance_policy" {
    for_each = var.maintenance_recurring_window != null ? [var.maintenance_recurring_window] : []
    content {
      recurring_window {
        start_time = maintenance_policy.value.start_time
        end_time   = maintenance_policy.value.end_time
        recurrence = maintenance_policy.value.recurrence
      }
    }
  }

  # Settings for the throwaway default pool (removed above); keep it off the
  # broad default identity even for its brief life.
  node_config {
    service_account = var.node_service_account_email
    oauth_scopes    = local.oauth_scopes
  }

  # Pools are managed separately (remove_default_node_pool). GKE echoes a pool's
  # settings (e.g. boot_disk_kms_key) back into the cluster's node_config on
  # read, which Terraform would otherwise treat as drift on an immutable field
  # and force a full cluster replacement on every apply. This block only
  # configures the throwaway default pool at creation, so ignoring later drift
  # on it is safe.
  lifecycle {
    ignore_changes = [node_config]
  }
}

# --- General hardened node pool --------------------------------------------

resource "google_container_node_pool" "general" {
  project = var.project_id
  name    = "general"
  cluster = google_container_cluster.this.id

  # Fixed-size pools manage node_count; autoscaled pools must not (Terraform
  # would fight the autoscaler on every apply), so the pool starts at the
  # per-zone minimum and the autoscaler owns the count from there.
  node_count         = var.general_autoscaling == null ? var.general_node_count : null
  initial_node_count = var.general_autoscaling == null ? null : var.general_autoscaling.min_per_zone

  # Per-zone bounds on a regional pool (total = value x zones); BALANCED keeps
  # scale-out even across zones so a zone loss never strands a majority of
  # capacity (ADR-0007). The autoscaler triggers on unschedulable pods.
  dynamic "autoscaling" {
    for_each = var.general_autoscaling == null ? [] : [var.general_autoscaling]
    content {
      min_node_count  = autoscaling.value.min_per_zone
      max_node_count  = autoscaling.value.max_per_zone
      location_policy = autoscaling.value.location_policy
    }
  }

  # Pin GKE's default surge upgrade explicitly: one surge node at a time (in
  # the zone being upgraded), zero unavailable — an upgrade never reduces
  # capacity below steady state.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.general_machine_type
    disk_size_gb    = var.general_disk_size_gb
    image_type      = "COS_CONTAINERD"
    service_account = var.node_service_account_email
    oauth_scopes    = local.oauth_scopes
    spot            = var.general_spot
    labels          = var.labels

    # Node/attached disk encryption with our key.
    boot_disk_kms_key = var.kms_key_id

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Each pod gets its own cloud identity, not the node's.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  # initial_node_count only seeds the pool at creation, but it is a force-new
  # field — without this, raising min_per_zone later would replace the pool.
  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

# --- Optional Confidential (memory-encrypting) node pool -------------------

resource "google_container_node_pool" "confidential" {
  count      = var.enable_confidential_pool ? 1 : 0
  project    = var.project_id
  name       = "confidential"
  cluster    = google_container_cluster.this.id
  node_count = var.confidential_node_count

  # Fixed-size by design: the pool is opt-in and tainted; autoscaling it is
  # added when a consumer exists (ADR-0007). Surge pinned like the general pool.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Confidential nodes are memory-encrypting and must run on-demand (spot
  # Confidential nodes proved unreliable).
  node_config {
    machine_type    = var.confidential_machine_type
    disk_size_gb    = var.general_disk_size_gb
    image_type      = "COS_CONTAINERD"
    service_account = var.node_service_account_email
    oauth_scopes    = local.oauth_scopes
    spot            = false
    labels          = var.labels

    boot_disk_kms_key = var.kms_key_id

    confidential_nodes {
      enabled = true
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Only workloads that opt in (tolerate this taint) land on Confidential nodes.
    taint {
      key    = "confidential"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }
}
