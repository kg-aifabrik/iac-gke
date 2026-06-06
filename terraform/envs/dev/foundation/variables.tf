# Inputs for the dev foundation root. Account-specific values (the project id)
# are supplied at apply via terraform.tfvars (git-ignored) or TF_VAR_*, never
# committed — see terraform.tfvars.example.

variable "project_id" {
  description = "The dev Google Cloud project."
  type        = string
}

variable "region" {
  description = "Region for regional foundation resources (the KMS key ring location matches the cluster region)."
  type        = string
  default     = "us-central1"
}
