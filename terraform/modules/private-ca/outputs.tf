# Outputs for the private-ca module.

output "subordinate_ca_pool_id" {
  description = "Full id of the subordinate CA pool — the issuer the cert-manager ClusterIssuer points at."
  value       = google_privateca_ca_pool.subordinate.id
}

output "subordinate_ca_pool_name" {
  description = "Name of the subordinate CA pool."
  value       = google_privateca_ca_pool.subordinate.name
}

output "root_ca_id" {
  description = "Full id of the root certificate authority (its cert is the trust anchor distributed via MDM / trust-manager)."
  value       = google_privateca_certificate_authority.root.id
}

output "cert_manager_gsa_email" {
  description = "Google service account google-cas-issuer impersonates; annotate its Kubernetes service account with this."
  value       = google_service_account.cert_manager.email
}
