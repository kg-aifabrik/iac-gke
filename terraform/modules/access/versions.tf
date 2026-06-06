# Provider and version constraints for the access module.
# The kubernetes provider is declared here but configured by the env root
# (a module must not configure its own provider — that breaks destroy and reuse).
# The root points it at the cluster via Connect Gateway.

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.20, < 3.0"
    }
  }
}
