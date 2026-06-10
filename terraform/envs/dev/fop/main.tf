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
  # The CA hierarchy outlives clusters (foundation-owned; ADR-0002 amended).
  cas_subordinate_pool_name = data.terraform_remote_state.foundation.outputs.cas_subordinate_pool_name
  cas_root_ca_pem           = data.terraform_remote_state.foundation.outputs.cas_root_ca_pem
  cert_manager_gsa_email    = data.terraform_remote_state.foundation.outputs.cert_manager_gsa_email

  # Sizing: smallest viable for dev — e2-medium across three zones (the stack
  # defaults to the region's first three), general pool only, autoscaling
  # between 1 and 2 nodes per zone (3-6 total) so scale-out is exercised while
  # the ceiling stays cheap. BALANCED keeps zones even (ADR-0007).
  general_machine_type = "e2-medium"
  general_autoscaling = {
    min_per_zone = 1
    max_per_zone = 2
  }

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

  # Ingress hostnames (public external + private internal), multi-app per
  # gateway (ADR-0005); internal names resolve via the private zone (ADR-0006).
  external_hostnames   = var.external_hostnames
  internal_hostnames   = var.internal_hostnames
  internal_zone_domain = var.internal_zone_domain
  manage_public_dns    = var.manage_public_dns
  public_zone_domain   = var.public_zone_domain

  # The platform TLS add-ons (cert-manager/trust-manager/google-cas-issuer) pull
  # images from quay.io, which private nodes can't reach over Private Google
  # Access. Enable Cloud NAT so they can. Mirroring these through Artifact
  # Registry to restore no-public-egress is tracked separately.
  enable_cloud_nat = true
}

# One-shot (remove after the HA-8 bring-up): the first Milestone-3 apply
# created the private-ca resources here before the CA hierarchy moved to the
# foundation (ADR-0002 amendment). Forget them WITHOUT destroying — the
# foundation imports and owns the service account now; destroying it here
# would break the identity the foundation manages.
removed {
  from = module.stack.module.private_ca

  lifecycle {
    destroy = false
  }
}
