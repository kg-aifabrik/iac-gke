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

# The CAS hierarchy lives here, NOT in the cluster roots: the root CA must
# outlive cluster rebuilds (MDM-distributed trust), and Google permanently
# retires a deleted CaPool id — so the pools persist like the KMS key
# (ADR-0002, amended at the Milestone 3 bring-up).
# One-shot adoption (remove after the HA-8 bring-up): the cert-manager GSA was
# created by the fop root before the CA hierarchy moved here; adopt it instead
# of failing on 409. The matching `removed` block in the fop root forgets it
# there without destroying it.
import {
  to = module.private_ca.google_service_account.cert_manager
  id = "projects/${var.project_id}/serviceAccounts/cert-manager-cas@${var.project_id}.iam.gserviceaccount.com"
}

module "private_ca" {
  source = "../../../modules/private-ca"

  project_id  = var.project_id
  region      = var.region
  environment = "dev"
  # Project-level Workload Identity pool — the same for every cluster in the
  # project, so the binding works regardless of which cluster cert-manager
  # runs in.
  workload_pool       = "${var.project_id}.svc.id.goog"
  deletion_protection = false # dev; stage/prod set true
  labels              = local.labels
}
