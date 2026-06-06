# Outputs consumed by the per-purpose cluster roots via terraform_remote_state.

output "project_number" {
  description = "Numeric project number."
  value       = module.foundation.project_number
}

output "kms_crypto_key_id" {
  description = "CMEK key id (secret + disk encryption)."
  value       = module.foundation.kms_crypto_key_id
}

output "node_service_account_email" {
  description = "Least-privilege node service account email."
  value       = module.foundation.node_service_account_email
}

output "enabled_services" {
  description = "Services enabled in the project."
  value       = module.foundation.enabled_services
}
