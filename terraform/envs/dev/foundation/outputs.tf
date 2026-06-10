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

# --- Private CA (CAS) — consumed by the cluster roots ------------------------

output "cas_subordinate_pool_name" {
  description = "CAS subordinate pool the GoogleCASClusterIssuer issues from."
  value       = module.private_ca.subordinate_ca_pool_name
}

output "cas_root_ca_pem" {
  description = "The CAS root certificate (PEM) trust-manager distributes in-cluster."
  value       = join("", module.private_ca.root_ca_pem)
}

output "cert_manager_gsa_email" {
  description = "Google service account the google-cas-issuer KSA impersonates."
  value       = module.private_ca.cert_manager_gsa_email
}
