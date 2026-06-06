# Outputs for the dev-FOP root — surfaced to operators and the pipeline.

output "cluster_name" {
  description = "Name of the dev-FOP cluster."
  value       = module.stack.cluster_name
}

output "location" {
  description = "Region the cluster runs in."
  value       = module.stack.location
}

output "workload_pool" {
  description = "Workload Identity pool for binding Kubernetes SAs to Google SAs."
  value       = module.stack.workload_pool
}

output "app_repository_url" {
  description = "Base path for the team's own images."
  value       = module.stack.app_repository_url
}

output "proxy_repository_url" {
  description = "Base path for the Docker Hub pull-through proxy."
  value       = module.stack.proxy_repository_url
}

# The pipeline writes this to a file and applies it with kubectl over Connect
# Gateway once the cluster is reachable.
output "rbac_manifest" {
  description = "Operator ClusterRoleBinding (YAML) to apply post-build."
  value       = module.stack.rbac_manifest
}
