# Outputs consumed by the network, gke-cluster, and supply-chain modules.

output "project_number" {
  description = "The numeric project number."
  value       = data.google_project.this.number
}

output "kms_crypto_key_id" {
  description = "Full id of the cluster encryption key (used for secret and disk encryption)."
  value       = google_kms_crypto_key.cluster.id
}

output "node_service_account_email" {
  description = "Email of the least-privilege node service account."
  value       = google_service_account.node.email
}

output "gke_service_agent_email" {
  description = "Email of the GKE service agent granted secret-encryption access to the key."
  value       = google_project_service_identity.gke.email
}

output "enabled_services" {
  description = "The services enabled by this module."
  value       = sort([for s in google_project_service.this : s.service])
}
