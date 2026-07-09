# Inputs for the cloud-sql module.

variable "project_id" {
  description = "The Google Cloud project that hosts the instance."
  type        = string
}

variable "region" {
  description = "Region for the instance (regional service; a zone is chosen within it)."
  type        = string
}

variable "instance_name" {
  description = "Base name for the instance; a short random suffix is appended so a dev teardown/rebuild does not collide with Cloud SQL's week-long name reservation."
  type        = string
}

variable "network_id" {
  description = "Id (or self link) of the VPC the instance's private IP lives on. The network's Private Service Access peering must exist first (order this module after the network)."
  type        = string
}

variable "tier" {
  description = "Machine tier. Dev uses a small shared tier (db-custom-1-3840 = 1 vCPU / 3.75 GB); production sizes up (see the research repo's Cloud SQL sizing)."
  type        = string
  default     = "db-custom-1-3840"
}

variable "database_version" {
  description = "PostgreSQL major version. Temporal is tested against 13-16."
  type        = string
  default     = "POSTGRES_16"
}

variable "availability_type" {
  description = "ZONAL (single zone, dev) or REGIONAL (synchronous standby, prod HA). Temporal requires strong consistency, so only synchronous HA is useful — never async read replicas."
  type        = string
  default     = "ZONAL"
}

variable "disk_size_gb" {
  description = "Initial data-disk size in GB (autoresizes upward)."
  type        = number
  default     = 20
}

variable "databases" {
  description = "Databases to create. Temporal needs two: the core store and the visibility store."
  type        = list(string)
  default     = ["temporal", "temporal_visibility"]
}

variable "database_flags" {
  description = "Extra PostgreSQL flags (e.g. max_connections). cloudsql.iam_authentication is always set on by the module and need not be listed here."
  type        = map(string)
  default     = {}
}

variable "deletion_protection" {
  description = "Guard against accidental deletion (both the Terraform resource guard and the API-level guard). Off in dev so teardown is clean."
  type        = bool
  default     = false
}

variable "backup_enabled" {
  description = "Enable automated backups + point-in-time recovery. Off in dev to avoid stranded backup storage on teardown; on in production."
  type        = bool
  default     = false
}

variable "encryption_key_name" {
  description = "CMEK key to encrypt the instance with (matches the platform's disk/secret posture). Null = Google-managed encryption. A CMEK instance also needs a key grant to the Cloud SQL service agent (wired in project-foundation)."
  type        = string
  default     = null
}

variable "labels" {
  description = "Labels applied to the instance (cost allocation / inventory)."
  type        = map(string)
  default     = {}
}
