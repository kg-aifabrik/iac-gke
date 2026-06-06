# Outputs for the cluster-stack — what an operator and the pipeline need after
# a build: how to reach the cluster, where images live, and the RBAC to apply.

output "cluster_name" {
  description = "Name of the built cluster."
  value       = module.cluster.cluster_name
}

output "location" {
  description = "Region the cluster runs in."
  value       = module.cluster.location
}

output "workload_pool" {
  description = "Workload Identity pool (for binding Kubernetes SAs to Google SAs)."
  value       = module.cluster.workload_pool
}

output "app_repository_url" {
  description = "Base path for the team's own images."
  value       = module.supply_chain.app_repository_url
}

output "proxy_repository_url" {
  description = "Base path for the Docker Hub pull-through proxy."
  value       = module.supply_chain.proxy_repository_url
}

output "gateway_members" {
  description = "Identities granted Connect Gateway access."
  value       = module.access.gateway_members
}

output "rbac_manifest" {
  description = "ClusterRoleBinding (YAML) the pipeline applies with kubectl after the cluster is reachable."
  value       = module.access.rbac_manifest
}
