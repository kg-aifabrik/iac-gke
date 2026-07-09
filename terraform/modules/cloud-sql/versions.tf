# Provider and version constraints for the cloud-sql module.

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
    # A short random suffix on the instance name: Cloud SQL reserves a deleted
    # instance's name for up to a week, which would block a dev teardown/rebuild.
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5, < 4.0"
    }
  }
}
