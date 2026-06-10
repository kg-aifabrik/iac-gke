# Provider and version constraints for the private-ca module.

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
    # A per-generation random suffix on the pool/CA/SA names so each
    # create->destroy->create cycle is collision-free (Google permanently
    # retires deleted CaPool ids; deleting a service account soft-reserves its
    # id for ~30 days). On destroy the random is removed from state; the next
    # apply regenerates it, yielding fresh names every rebuild.
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5, < 4.0"
    }
  }
}
