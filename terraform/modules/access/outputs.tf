# Outputs for the access module.

output "cluster_role_binding" {
  description = "Name of the ClusterRoleBinding granting the operators and automation in-cluster access."
  value       = kubernetes_cluster_role_binding.operators.metadata[0].name
}

output "gateway_members" {
  description = "Identities granted Connect Gateway access (operators + automation)."
  value       = local.gateway_members
}
