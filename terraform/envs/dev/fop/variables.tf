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

variable "external_hostnames" {
  description = "Public FQDNs served by the external gateway (one managed cert + DNS-auth CNAME + A record each — SRE creates the records at the registrar). Two dev hosts exercise the multi-host path; dev stays on the registrar-controlled test domain because public DNS is manual (ADR-0006)."
  type        = list(string)
  default     = ["app.dev.arthos.app", "hello.dev.arthos.app"]
}

variable "internal_hostnames" {
  description = "Private FQDNs served by the internal gateway (SANs on the CAS cert + A records in the private zone). Private zones need no registrar control, so dev uses the work-domain convention (ADR-0006)."
  type        = list(string)
  default     = ["hello.dev.aifabrik.com", "tools.dev.aifabrik.com"]
}
