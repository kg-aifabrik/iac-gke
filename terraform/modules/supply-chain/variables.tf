# Inputs for the supply-chain module: where images live and who may pull them.

variable "project_id" {
  description = "The Google Cloud project that hosts the registries and the Binary Authorization policy (one policy per project)."
  type        = string
}

variable "region" {
  description = "Region for the Artifact Registry repositories (kept equal to the cluster's region so pulls stay in-region)."
  type        = string
}

variable "node_service_account_email" {
  description = "Least-privilege node service account (from project-foundation). Granted reader scoped to these repositories only — not project-wide."
  type        = string
}

variable "app_repository_id" {
  description = "Repository id for the team's own (published) images."
  type        = string
  default     = "app"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.app_repository_id))
    error_message = "app_repository_id must be lowercase letters, digits, and hyphens; start with a letter."
  }
}

variable "proxy_repository_id" {
  description = "Repository id for the remote pull-through proxy of public Docker Hub images."
  type        = string
  default     = "docker-remote"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.proxy_repository_id))
    error_message = "proxy_repository_id must be lowercase letters, digits, and hyphens; start with a letter."
  }
}

variable "labels" {
  description = "Labels applied to the repositories (e.g. environment / purpose / cluster)."
  type        = map(string)
  default     = {}
}
