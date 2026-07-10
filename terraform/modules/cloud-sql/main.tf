# cloud-sql — a private-IP Cloud SQL for PostgreSQL instance (the state store for
# a workload such as Temporal), reachable only over the VPC via the network
# module's Private Service Access peering, with the workload's databases and IAM
# database authentication turned on. The per-user IAM binding + cloudsql.client
# grant are the workload's concern (created at deploy time), not this module's —
# this module provisions the generic instance. See ADR-0010 and
# docs/implementation/cluster-build.md for the rationale.

# Cloud SQL reserves a deleted instance's name for up to a week; a random suffix
# keeps a dev teardown/rebuild collision-free (same reasoning as private-ca).
resource "random_id" "suffix" {
  byte_length = 2
}

resource "google_sql_database_instance" "this" {
  project             = var.project_id
  name                = "${var.instance_name}-${random_id.suffix.hex}"
  region              = var.region
  database_version    = var.database_version
  encryption_key_name = var.encryption_key_name

  # Terraform-level guard against accidental destroy (the API-level guard is in
  # settings below). Off in dev so `terraform destroy` succeeds unattended.
  deletion_protection = var.deletion_protection

  settings {
    tier = var.tier
    # Pin the edition: POSTGRES_16 defaults to ENTERPRISE_PLUS, which only accepts
    # db-perf-optimized-N-* tiers and would reject the small db-custom-* dev tier.
    edition           = var.edition
    availability_type = var.availability_type
    disk_size         = var.disk_size_gb
    disk_autoresize   = true
    user_labels       = var.labels

    # Private IP only — no public endpoint. The instance is reachable over the
    # VPC through the Private Service Access peering the network module created,
    # so nothing traverses the public internet.
    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
    }

    # IAM database authentication: callers connect as a Google identity (via the
    # Cloud SQL Auth Proxy with --auto-iam-authn) instead of a stored password.
    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }
    dynamic "database_flags" {
      for_each = var.database_flags
      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }

    backup_configuration {
      enabled = var.backup_enabled
    }

    deletion_protection_enabled = var.deletion_protection
  }
}

resource "google_sql_database" "this" {
  for_each = toset(var.databases)
  project  = var.project_id
  instance = google_sql_database_instance.this.name
  name     = each.value
}
