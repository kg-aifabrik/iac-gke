# Provider and version constraints for the access module.
# Google-only: this module manages the Connect Gateway IAM grants and renders
# the in-cluster RBAC as a manifest (an output). The manifest is applied with
# kubectl over the gateway after the cluster exists — deliberately not via a
# Terraform kubernetes provider, which can't reach the not-yet-created private
# cluster at plan time (it would break the approval gate's plan).

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
}
