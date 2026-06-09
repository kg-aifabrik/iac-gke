# Inputs for the dev-FOP cluster root. The cluster's *shape* (dev, fop, smallest
# sizing) is pinned in main.tf; only account- and identity-specific values are
# variables, supplied via terraform.tfvars (git-ignored) or TF_VAR_*.

variable "project_id" {
  description = "The dev Google Cloud project."
  type        = string
}

variable "region" {
  description = "Region for the regional cluster."
  type        = string
  default     = "us-central1"
}

variable "state_bucket" {
  description = "Cloud Storage bucket holding the foundation's remote state (<project>-tf-state)."
  type        = string
}

variable "operator_members" {
  description = "SRE operator identities (IAM member strings) granted Connect Gateway + cluster-admin RBAC, e.g. [\"group:sre@aifabrik.com\"]."
  type        = list(string)
}

variable "automation_member" {
  description = "CI automation identity that applies in-cluster resources via the gateway, e.g. \"serviceAccount:auto@project.iam.gserviceaccount.com\"."
  type        = string
}

variable "external_hostname" {
  description = "Public FQDN served by the external gateway (its managed cert is validated for this name)."
  type        = string
  default     = "app.dev.arthos.app"
}

variable "internal_hostname" {
  description = "Private FQDN served by the internal gateway (on the CAS-issued cert)."
  type        = string
  default     = "hello.internal.dev.arthos.app"
}
