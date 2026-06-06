# Inputs for the access module: who may reach the private cluster, and as whom
# inside it. Identities are given once as IAM member strings and used for both
# the Google-side Connect Gateway grant and the in-cluster RBAC binding.

variable "project_id" {
  description = "The Google Cloud project that hosts the fleet/Connect Gateway."
  type        = string
}

variable "operator_members" {
  description = "Identities that operate the cluster (the SRE approver group and/or users), as IAM member strings — e.g. \"group:sre@aifabrik.com\" or \"user:alice@aifabrik.com\"."
  type        = list(string)

  validation {
    condition     = length(var.operator_members) > 0
    error_message = "Provide at least one operator identity, or no one can reach the private cluster."
  }
  validation {
    condition     = alltrue([for m in var.operator_members : can(regex("^(user|group):", m))])
    error_message = "operator_members must be \"user:<email>\" or \"group:<email>\"."
  }
}

variable "automation_member" {
  description = "The CI automation identity that applies in-cluster resources (RBAC, network policy, workloads) via the gateway — e.g. \"serviceAccount:auto@project.iam.gserviceaccount.com\"."
  type        = string

  validation {
    condition     = can(regex("^serviceAccount:", var.automation_member))
    error_message = "automation_member must be \"serviceAccount:<email>\"."
  }
}

variable "cluster_role" {
  description = "Kubernetes ClusterRole the operators and automation are bound to. cluster-admin to start (SRE operate the whole cluster); namespace-scoped roles arrive with the namespace-stamp milestone."
  type        = string
  default     = "cluster-admin"
}

variable "binding_name" {
  description = "Name of the ClusterRoleBinding created for these identities."
  type        = string
  default     = "aifabrik-sre-cluster-admins"
}
