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
# Gateway once the cluster is reachable (namespaces, RBAC, StorageClass, CAS
# issuer/bundle, and the gateways).
output "incluster_manifests" {
  description = "In-cluster platform manifests (YAML) to apply post-build."
  value       = module.stack.incluster_manifests
}

output "priorityclass_manifests" {
  description = "Platform PriorityClasses — applied before the Helm add-ons."
  value       = module.stack.priorityclass_manifests
}

output "cert_manager_gsa_email" {
  description = "Annotate the google-cas-issuer KSA with this at Helm install (Workload Identity)."
  value       = module.stack.cert_manager_gsa_email
}

# The two records to create at the registrar (GoDaddy) for the external gateway.
output "dns_records" {
  description = "External-gateway DNS records: the cert DNS-authorization CNAME + the hostname A record."
  value       = module.stack.dns_records
}

output "external_gateway_ip" {
  description = "Public IP of the external gateway."
  value       = module.stack.external_gateway_ip
}

output "internal_gateway_ip" {
  description = "Private VIP of the internal gateway."
  value       = module.stack.internal_gateway_ip
}

output "private_zone_dns_name" {
  description = "Private zone resolving the internal hostnames inside the VPC."
  value       = module.stack.private_zone_dns_name
}

# Comma-joined for validate.sh.
output "external_hostnames" {
  description = "External hostnames served by the public gateway."
  value       = module.stack.external_hostnames
}

output "internal_hostnames" {
  description = "Internal hostnames served by the private gateway."
  value       = module.stack.internal_hostnames
}

# Used by the validation suite to trigger an on-demand backup and restore.
output "backup_plan_name" {
  description = "Backup for GKE plan name."
  value       = module.stack.backup_plan_name
}

output "restore_plan_name" {
  description = "Backup for GKE restore-plan name."
  value       = module.stack.restore_plan_name
}

# The one-time registrar delegation: NS records for the public subdomain point
# at these (re-check after a zone re-create — the set can change).
output "public_zone_name_servers" {
  description = "Cloud DNS nameservers to delegate the public subdomain to at the registrar."
  value       = module.stack.public_zone_name_servers
}
