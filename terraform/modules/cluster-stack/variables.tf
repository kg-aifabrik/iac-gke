# Inputs for the cluster-stack composition: the per-purpose pieces of one
# cluster. The three factory dimensions appear here — account (project_id),
# environment, and purpose — plus the per-(env,purpose) sizing. The hardening
# recipe inside the modules is identical for every cluster.

# --- The three dimensions + context ----------------------------------------

variable "project_id" {
  description = "The Google Cloud project (the account dimension's project context)."
  type        = string
}

variable "region" {
  description = "Region for the regional cluster and its network."
  type        = string
}

variable "environment" {
  description = "Environment dimension: dev / stage / prod."
  type        = string
}

variable "purpose" {
  description = "Purpose dimension: fop (Fleet Operations Plane), mgmt (Management Plane), or a new one. One cluster per purpose per environment."
  type        = string
}

variable "cluster_name" {
  description = "Override the cluster name. Null derives \"<environment>-<purpose>\"."
  type        = string
  default     = null
}

# --- Wiring from the per-project foundation (passed in, not created here) ---

variable "kms_key_id" {
  description = "CMEK key id from the foundation (secret + disk encryption)."
  type        = string
}

variable "node_service_account_email" {
  description = "Least-privilege node service account email from the foundation."
  type        = string
}

# --- Network ----------------------------------------------------------------

variable "network_name" {
  description = "VPC name. Null derives \"gke-<cluster>\" so purposes don't collide in one project."
  type        = string
  default     = null
}

variable "subnet_name" {
  description = "Node subnet name. Null derives \"<cluster>-nodes\"."
  type        = string
  default     = null
}

variable "node_cidr" {
  description = "Primary node range."
  type        = string
  default     = "10.0.0.0/20"
}

variable "pod_cidr" {
  description = "Secondary Pod range (alias IP). Immutable after creation."
  type        = string
  default     = "100.64.0.0/14"
}

variable "service_cidr" {
  description = "Secondary Service range (alias IP). Immutable after creation."
  type        = string
  default     = "10.1.0.0/20"
}

variable "enable_cloud_nat" {
  description = "Create Cloud NAT for outbound public egress (off by default)."
  type        = bool
  default     = false
}

# --- Database (Cloud SQL) — opt-in per purpose (ADR-0010) -------------------

variable "enable_cloud_sql" {
  description = "Provision a private-IP Cloud SQL for PostgreSQL instance for this cluster (e.g. Temporal's state store) and the Private Service Access peering it needs. Off by default; turned on per purpose in the registry."
  type        = bool
  default     = false
}

variable "cloud_sql_tier" {
  description = "Machine tier for the Cloud SQL instance (db-custom-1-3840 in dev; larger in prod). Only used when enable_cloud_sql is true."
  type        = string
  default     = "db-custom-1-3840"
}

variable "cloud_sql_databases" {
  description = "Databases created on the Cloud SQL instance (defaults to Temporal's core + visibility stores)."
  type        = list(string)
  default     = ["temporal", "temporal_visibility"]
}

# --- Cluster shape (per environment, per purpose) ---------------------------

variable "node_locations" {
  description = "Zones to spread nodes across. Empty = the first three available zones in the region (regional, 3 AZs)."
  type        = list(string)
  default     = []
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
  default     = "REGULAR"
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
  description = "Use spot VMs for the general pool."
  type        = bool
  default     = false
}

variable "general_autoscaling" {
  description = "Autoscaling bounds for the general pool, per zone (null = fixed-size pool of general_node_count). See the gke-cluster module / ADR-0007."
  type = object({
    min_per_zone    = number
    max_per_zone    = number
    location_policy = optional(string, "BALANCED")
  })
  default = null
}

variable "autoscaling_profile" {
  description = "Cluster-autoscaler profile (BALANCED or OPTIMIZE_UTILIZATION)."
  type        = string
  default     = "BALANCED"
}

variable "enable_confidential_pool" {
  description = "Create a Confidential (memory-encrypting) node pool."
  type        = bool
  default     = false
}

variable "cas_tier" {
  description = "CAS pool tier for this cluster's private CA: DEVOPS (dev) or ENTERPRISE (stage/prod). See the private-ca module / ADR-0002."
  type        = string
  default     = "ENTERPRISE"
}

variable "enable_backup" {
  description = "Create the Backup for GKE backup + restore plans for this cluster (ADR-0004)."
  type        = bool
  default     = true
}

variable "backup_schedule" {
  description = "Cron schedule for automatic backups."
  type        = string
  default     = "0 3 * * *"
}

variable "backup_retain_days" {
  description = "Days a backup is kept (short in dev so teardown never strands storage)."
  type        = number
  default     = 3
}

variable "confidential_machine_type" {
  description = "Machine type for the Confidential pool."
  type        = string
  default     = "n2d-standard-2"
}

variable "confidential_node_count" {
  description = "Nodes per zone in the Confidential pool."
  type        = number
  default     = 1
}

# --- Supply chain -----------------------------------------------------------

variable "app_repository_id" {
  description = "Repository id for the team's own images."
  type        = string
  default     = "app"
}

variable "proxy_repository_id" {
  description = "Repository id for the Docker Hub pull-through proxy."
  type        = string
  default     = "docker-remote"
}

# --- Access -----------------------------------------------------------------

variable "operator_members" {
  description = "SRE operator identities (IAM member strings) granted Connect Gateway + cluster-admin RBAC."
  type        = list(string)
}

variable "automation_member" {
  description = "CI automation identity (serviceAccount:...) granted Connect Gateway access."
  type        = string
}

variable "cluster_role" {
  description = "Kubernetes ClusterRole the operators bind to."
  type        = string
  default     = "cluster-admin"
}

# --- Labels -----------------------------------------------------------------

variable "extra_labels" {
  description = "Additional labels merged onto the standard environment/purpose/cluster labels."
  type        = map(string)
  default     = {}
}

# --- Ingress (gateways + TLS) ----------------------------------------------

variable "external_hostnames" {
  description = "Public FQDNs served by the external gateway — one managed cert + DNS authorization each, served by SNI (ADR-0005)."
  type        = list(string)
}

variable "internal_hostnames" {
  description = "Private FQDNs served by the internal gateway — all SANs on one CAS-issued cert; each gets an A record in the private zone (ADR-0005/0006)."
  type        = list(string)
}

variable "internal_zone_domain" {
  description = "Domain of the per-environment Cloud DNS private zone the internal hostnames live under (e.g. dev.aifabrik.com; ADR-0006)."
  type        = string
}

variable "manage_public_dns" {
  description = "Opt-in: create a public Cloud DNS zone and manage the external records (requires registrar delegation; off = SRE creates them manually; ADR-0006)."
  type        = bool
  default     = false
}

variable "public_zone_domain" {
  description = "Domain of the public zone (only used when manage_public_dns is true)."
  type        = string
  default     = null
}

variable "proxy_only_cidr" {
  description = "CIDR for the regional proxy-only subnet the internal gateway needs."
  type        = string
  default     = "10.2.0.0/23"
}

variable "gateway_namespace" {
  description = "Namespace the platform gateways live in."
  type        = string
  default     = "gateway-system"
}

variable "external_namespace" {
  description = "Workload namespace for public, internet-facing services (attaches to the external gateway)."
  type        = string
  default     = "public-services"
}

variable "internal_namespace" {
  description = "Workload namespace for internal tools (attaches to the internal gateway)."
  type        = string
  default     = "internal-tools"
}
