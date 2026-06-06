# Outputs for the access module.

output "gateway_members" {
  description = "Identities granted Connect Gateway access (operators + automation)."
  value       = local.gateway_members
}

# The in-cluster half of access, rendered from the same identity list as the
# IAM grants (single source of truth). The pipeline writes this to a file and
# applies it with kubectl once the cluster is reachable over the gateway.
output "rbac_manifest" {
  description = "ClusterRoleBinding (YAML) mapping the operator identities to the cluster role; apply with `kubectl apply -f`."
  value = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name   = var.binding_name
      labels = { "app.kubernetes.io/managed-by" = "cluster-ctrl" }
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = var.cluster_role
    }
    subjects = [
      for s in local.rbac_subjects : {
        kind     = s.kind
        name     = s.name
        apiGroup = "rbac.authorization.k8s.io"
      }
    ]
  })
}
