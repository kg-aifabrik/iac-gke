# dev project foundation — applied once per project. Enables services, creates
# the CMEK key and its two grants, and the least-privilege node identity. The
# per-purpose cluster roots (fop, mgmt, ...) read these outputs via remote state,
# so adding a purpose never re-creates project singletons.

module "foundation" {
  source = "../../../modules/project-foundation"

  project_id = var.project_id
  region     = var.region

  labels = {
    environment = "dev"
    managed-by  = "cluster-ctrl"
  }
}
