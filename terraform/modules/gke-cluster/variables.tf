# Inputs for the gke-cluster module. Sizing/options are per (environment,
# purpose); the hardening is identical for every cluster.

variable "project_id" {
  description = "The Google Cloud project that hosts the cluster."
  type        = string
}

variable "region" {
  description = "Region for the regional cluster (multi-zone control plane)."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name, e.g. dev-fop."
  type        = string
}

# --- Wiring from the network and project-foundation modules ----------------

variable "network" {
  description = "VPC network self link or id (from the network module)."
  type        = string
}

variable "subnetwork" {
  description = "Node subnet self link or id (from the network module)."
  type        = string
}

variable "pods_range_name" {
  description = "Name of the Pods secondary range on the subnet."
  type        = string
}

variable "services_range_name" {
  description = "Name of the Services secondary range on the subnet."
  type        = string
}

variable "kms_key_id" {
  description = "CMEK key id used for secret (etcd) and node disk encryption (from project-foundation)."
  type        = string
}

variable "node_service_account_email" {
  description = "Least-privilege node service account email (from project-foundation)."
  type        = string
}

# --- Cluster shape ----------------------------------------------------------

variable "release_channel" {
  description = "GKE release channel (RAPID/REGULAR/STABLE). Dev is enrolled for auto-upgrades; stage/prod hold upgrades via maintenance exclusions."
  type        = string
  default     = "REGULAR"
}

variable "node_locations" {
  description = "Zones to spread nodes across (e.g. 3 zones). Empty = GKE selects."
  type        = list(string)
  default     = []
}

variable "deletion_protection" {
  description = "Guard against accidental cluster deletion."
  type        = bool
  default     = true
}

variable "maintenance_recurring_window" {
  description = "Recurring maintenance window for automatic upgrades (used in dev). Null = none."
  type = object({
    start_time = string
    end_time   = string
    recurrence = string
  })
  default = null
}

variable "labels" {
  description = "Labels for the cluster and nodes (e.g. environment / purpose / cluster)."
  type        = map(string)
  default     = {}
}

# --- Node pools -------------------------------------------------------------

variable "general_machine_type" {
  description = "Machine type for the general node pool."
  type        = string
  default     = "e2-medium"
}

variable "general_node_count" {
  description = "Nodes per zone in the general pool (regional total = count x zones)."
  type        = number
  default     = 1
}

variable "general_disk_size_gb" {
  description = "Boot disk size (GB) for general nodes."
  type        = number
  default     = 50
}

variable "general_spot" {
  description = "Use spot (preemptible) VMs for the general pool."
  type        = bool
  default     = false
}

variable "general_autoscaling" {
  description = "Autoscaling bounds for the general pool, PER ZONE (regional pool: total = value x zones, so the ceiling stays symmetric across zones). Null keeps a fixed-size pool of general_node_count. BALANCED spreads scale-out evenly across zones (ADR-0007)."
  type = object({
    min_per_zone    = number
    max_per_zone    = number
    location_policy = optional(string, "BALANCED")
  })
  default = null

  validation {
    condition = var.general_autoscaling == null ? true : (
      var.general_autoscaling.min_per_zone >= 0 &&
      var.general_autoscaling.max_per_zone >= var.general_autoscaling.min_per_zone &&
      contains(["BALANCED", "ANY"], var.general_autoscaling.location_policy)
    )
    error_message = "general_autoscaling needs 0 <= min_per_zone <= max_per_zone and location_policy BALANCED or ANY."
  }
}

variable "autoscaling_profile" {
  description = "Cluster-autoscaler profile: BALANCED (default) or OPTIMIZE_UTILIZATION (denser bin-packing, opt-in). Applies to the per-pool autoscaler; node auto-provisioning stays off (ADR-0007)."
  type        = string
  default     = "BALANCED"

  validation {
    condition     = contains(["BALANCED", "OPTIMIZE_UTILIZATION"], var.autoscaling_profile)
    error_message = "autoscaling_profile must be BALANCED or OPTIMIZE_UTILIZATION."
  }
}

variable "enable_confidential_pool" {
  description = "Create a Confidential (memory-encrypting) node pool. Always on-demand."
  type        = bool
  default     = false
}

variable "confidential_machine_type" {
  description = "Machine type for the Confidential pool (must support Confidential VM)."
  type        = string
  default     = "n2d-standard-2"
}

variable "confidential_node_count" {
  description = "Nodes per zone in the Confidential pool."
  type        = number
  default     = 1
}
