# Outputs consumed by the gke-cluster module (network/subnet + the secondary
# range names the cluster's IP allocation policy references).

output "network_id" {
  description = "Full id of the VPC network."
  value       = google_compute_network.this.id
}

output "network_self_link" {
  description = "Self link of the VPC network."
  value       = google_compute_network.this.self_link
}

output "subnetwork_id" {
  description = "Full id of the node subnet."
  value       = google_compute_subnetwork.this.id
}

output "subnetwork_self_link" {
  description = "Self link of the node subnet."
  value       = google_compute_subnetwork.this.self_link
}

output "pods_range_name" {
  description = "Name of the secondary range for Pods."
  value       = "pods"
}

output "services_range_name" {
  description = "Name of the secondary range for Services."
  value       = "services"
}
