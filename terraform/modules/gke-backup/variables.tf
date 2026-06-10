# Inputs for the gke-backup module: the scheduled, CMEK-encrypted backup plan
# and the pinned restore path for one cluster (ADR-0004).

variable "project_id" {
  description = "The Google Cloud project that hosts the cluster and its backups."
  type        = string
}

variable "region" {
  description = "Region for the backup and restore plans (kept equal to the cluster region)."
  type        = string
}

variable "cluster_id" {
  description = "Full id of the cluster to back up (projects/.../locations/.../clusters/...)."
  type        = string
}

variable "name" {
  description = "Name prefix for the plans (typically the cluster name)."
  type        = string
}

variable "schedule" {
  description = "Cron schedule for automatic backups (cluster-region time)."
  type        = string
  default     = "0 3 * * *"
}

variable "retain_days" {
  description = "Days a backup is kept before automatic deletion. Dev keeps this short so teardown never strands storage; production sets a real retention."
  type        = number
  default     = 3
}

variable "kms_key_id" {
  description = "CMEK key that encrypts backups (the cluster key; the Backup for GKE service agent holds the grant — project-foundation)."
  type        = string
}

variable "restore_namespaces" {
  description = "Workload namespaces the restore plan may DELETE_AND_RESTORE. Never include platform namespaces (gateway-system, cert-manager) — replaying those tears down ingress and issuance mid-restore."
  type        = list(string)

  validation {
    condition     = length(var.restore_namespaces) > 0
    error_message = "restore_namespaces needs at least one workload namespace."
  }
}

variable "labels" {
  description = "Labels for the plans."
  type        = map(string)
  default     = {}
}
