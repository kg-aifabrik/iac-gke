# dev project foundation — applied once per project. Enables services, creates
# the CMEK key and its grants, the least-privilege node identity, and the
# private CA hierarchy. The per-purpose cluster roots (fop, mgmt, ...) read
# these outputs via remote state, so adding a purpose never re-creates project
# singletons.

locals {
  labels = {
    environment = "dev"
    managed-by  = "cluster-ctrl"
  }
}

module "foundation" {
  source = "../../../modules/project-foundation"

  project_id = var.project_id
  region     = var.region
  labels     = local.labels
}

# Note: the private CA (CAS) is NOT here — it is per-cluster (cluster-stack), so
# a dev teardown leaves no standing CAS cost (ADR-0002 amendment 3). The
# foundation holds only free/undeletable singletons (enabled APIs, the node
# service account, and the KMS key, which Cloud KMS forbids deleting).
