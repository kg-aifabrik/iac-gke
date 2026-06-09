# Provider and version constraints for the gke-gateway module.
# Google-only: the Gateway/HTTPRoute/policy/Certificate objects are rendered as
# manifests (an output) and applied by the pipeline with kubectl over Connect
# Gateway — not via a kubernetes provider (the cluster is private; see the M1
# access module for the same rationale).

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
}
