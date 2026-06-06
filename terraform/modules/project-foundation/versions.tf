# Provider and version constraints for the project-foundation module.
# google-beta is required for google_project_service_identity (used to
# force-create the GKE service agent before granting it key access).

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0, < 8.0"
    }
  }
}
