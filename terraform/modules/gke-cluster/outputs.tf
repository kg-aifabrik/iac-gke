# Outputs for the gke-cluster module.

output "cluster_id" {
  description = "Full id of the cluster."
  value       = google_container_cluster.this.id
}

output "cluster_name" {
  description = "Cluster name."
  value       = google_container_cluster.this.name
}

output "location" {
  description = "Cluster region."
  value       = google_container_cluster.this.location
}

output "workload_pool" {
  description = "The Workload Identity pool for the cluster."
  value       = local.workload_pool
}
