# Provider constraints for the dev-FOP cluster root. Google-only — the cluster
# stack manages Google resources; in-cluster objects are applied by the pipeline
# with kubectl (see the access module).

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
}
