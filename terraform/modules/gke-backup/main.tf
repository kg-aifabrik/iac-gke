# gke-backup — Backup for GKE for one cluster (ADR-0004): a scheduled,
# CMEK-encrypted backup plan covering all workload namespaces (Kubernetes
# objects, Secrets, and volume data together), plus a restore plan that pins
# the restore policy so recovery is a defined path, not an improvisation.
#
# Teardown discipline (#31): backups can outlive the cluster by design, so dev
# uses short retention and no delete lock; the destroy path purges remaining
# backups before the plan. Confirm-at-build (design §12): deleting a plan that
# has held backups.

resource "google_gke_backup_backup_plan" "this" {
  project  = var.project_id
  name     = "${var.name}-daily"
  location = var.region
  cluster  = var.cluster_id
  labels   = var.labels

  backup_schedule {
    cron_schedule = var.schedule
  }

  retention_policy {
    backup_retain_days = var.retain_days
    # No delete lock: dev tears down freely. A production delete-lock (WORM)
    # is a deliberate later hardening, set per environment.
    backup_delete_lock_days = 0
  }

  backup_config {
    # One plan covers every workload namespace; Kubernetes state, Secrets, and
    # volume data restore together — a disk image alone is not a recovery.
    all_namespaces      = true
    include_volume_data = true
    include_secrets     = true

    encryption_key {
      gcp_kms_encryption_key = var.kms_key_id
    }
  }
}

# The pinned restore policy: namespaced resources from the backup replace what
# exists (delete-and-restore), volumes restore from backup data, cluster-scoped
# resources are not touched (they belong to the platform, not the backup).
#
# Scope: WORKLOAD namespaces only — never all_namespaces. DELETE_AND_RESTORE on
# an unrestricted scope would delete and recreate the platform namespaces
# (gateway-system, cert-manager) mid-restore, tearing down ingress and
# certificate issuance. The backup still CAPTURES everything; the restore plan
# pins what may be replayed.
resource "google_gke_backup_restore_plan" "this" {
  project     = var.project_id
  name        = "${var.name}-restore"
  location    = var.region
  backup_plan = google_gke_backup_backup_plan.this.id
  cluster     = var.cluster_id
  labels      = var.labels

  restore_config {
    selected_namespaces {
      namespaces = var.restore_namespaces
    }
    namespaced_resource_restore_mode = "DELETE_AND_RESTORE"
    volume_data_restore_policy       = "RESTORE_VOLUME_DATA_FROM_BACKUP"

    cluster_resource_restore_scope {
      no_group_kinds = true
    }
    cluster_resource_conflict_policy = "USE_EXISTING_VERSION"
  }
}
