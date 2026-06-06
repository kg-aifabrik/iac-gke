# Inputs for the project-foundation module.

variable "project_id" {
  description = "The Google Cloud project that hosts this environment's cluster."
  type        = string
}

variable "region" {
  description = "Region for regional resources. The KMS key ring is created here so the key's location matches the cluster's region (Cloud KMS has no global option for this use)."
  type        = string
}

variable "node_service_account_id" {
  description = "Account id (the part before @) for the least-privilege GKE node service account."
  type        = string
  default     = "gke-node"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.node_service_account_id))
    error_message = "node_service_account_id must be 6-30 chars: lowercase letters, digits, hyphens; start with a letter."
  }
}

variable "kms_key_rotation_period" {
  description = "Automatic rotation period for the cluster encryption key, in seconds (e.g. 7776000s = 90 days). Rotation adds a new key version; existing data stays readable."
  type        = string
  default     = "7776000s"
}

variable "labels" {
  description = "Labels applied to labelable resources (e.g. environment / purpose / cluster)."
  type        = map(string)
  default     = {}
}
