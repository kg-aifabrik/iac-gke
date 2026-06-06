# Provider and version constraints for the cluster-stack composition module.
# Google-only: the project-singleton foundation (which needs google-beta) is a
# separate per-project root; this module composes the per-purpose pieces.

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
}
