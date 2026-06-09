# Outputs for the gke-backup module — what the validation suite and operators
# need to trigger an on-demand backup or restore.

output "backup_plan_name" {
  description = "Backup plan name (gcloud backup-restore backups create --backup-plan=...)."
  value       = google_gke_backup_backup_plan.this.name
}

output "backup_plan_id" {
  description = "Full backup plan id."
  value       = google_gke_backup_backup_plan.this.id
}

output "restore_plan_name" {
  description = "Restore plan name (gcloud backup-restore restores create --restore-plan=...)."
  value       = google_gke_backup_restore_plan.this.name
}

output "restore_plan_id" {
  description = "Full restore plan id."
  value       = google_gke_backup_restore_plan.this.id
}
