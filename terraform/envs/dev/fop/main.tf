# dev-FOP — the dev Fleet Operations Plane cluster. Thin by design: it reads the
# per-project foundation's outputs and calls the cluster-stack with dev-FOP's
# coordinates and sizing. Adding another purpose (e.g. dev-MGMT) is a sibling
# folder like this one with a different purpose/sizing — config, not new code.

data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "env/dev/foundation"
  }
}

module "stack" {
  source = "../../../modules/cluster-stack"

  project_id  = var.project_id
  region      = var.region
  environment = "dev"
  purpose     = "fop"

  # From the per-project foundation.
  kms_key_id                 = data.terraform_remote_state.foundation.outputs.kms_crypto_key_id
  node_service_account_email = data.terraform_remote_state.foundation.outputs.node_service_account_email

  # Sizing: smallest viable for dev — one e2-medium per zone across three zones
  # (the stack defaults to the region's first three zones), general pool only.
  general_machine_type = "e2-medium"
  general_node_count   = 1

  # Dev enrolls in auto-upgrades within a weekend maintenance window; stage/prod
  # will hold upgrades and schedule them deliberately.
  release_channel = "REGULAR"
  maintenance_recurring_window = {
    start_time = "2026-01-03T09:00:00Z" # a Saturday 09:00 UTC
    end_time   = "2026-01-03T17:00:00Z"
    recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
  }

  # Dev is short-lived and torn down during milestone verification, so it is not
  # deletion-protected. Stage/prod set this true.
  deletion_protection = false

  operator_members  = var.operator_members
  automation_member = var.automation_member
}
