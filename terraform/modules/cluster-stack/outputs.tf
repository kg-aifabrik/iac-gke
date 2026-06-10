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

output "incluster_manifests" {
  description = "Multi-doc YAML the pipeline applies with kubectl after the cluster is reachable: priority tiers, namespaces, operator RBAC, encrypted StorageClasses, CAS trust root + issuer + bundle, and the two gateways."
  value       = local.incluster_manifests
}

output "priorityclass_manifests" {
  description = "The three platform PriorityClasses alone — applied BEFORE the Helm add-ons (admission rejects pods whose priorityClassName doesn't exist); also included in incluster_manifests (idempotent re-apply)."
  value       = join("\n---\n", local.priorityclass_manifests)
}

output "external_gateway_ip" {
  description = "Public IP reserved for the external gateway."
  value       = module.gateway_external.ip_address
}

output "internal_gateway_ip" {
  description = "Private VIP reserved for the internal gateway."
  value       = module.gateway_internal.ip_address
}

output "dns_records" {
  description = "DNS records to create at the registrar for the external gateway (the cert DNS-authorization CNAME + the hostname A record)."
  value       = module.gateway_external.dns_records
}

output "cert_manager_gsa_email" {
  description = "Google service account to annotate the google-cas-issuer KSA with at Helm install."
  value       = module.private_ca.cert_manager_gsa_email
}

output "cas_subordinate_pool" {
  description = "CAS subordinate pool the GoogleCASClusterIssuer issues from."
  value       = module.private_ca.subordinate_ca_pool_name
}

output "external_hostnames" {
  description = "External hostnames, comma-joined for scripts (validate.sh)."
  value       = join(",", var.external_hostnames)
}

output "internal_hostnames" {
  description = "Internal hostnames, comma-joined for scripts (validate.sh)."
  value       = join(",", var.internal_hostnames)
}

output "private_zone_dns_name" {
  description = "DNS name of the private zone resolving the internal hostnames inside the VPC."
  value       = module.dns.private_zone_dns_name
}

output "public_zone_name_servers" {
  description = "NS records to set at the registrar when manage_public_dns is on (null otherwise)."
  value       = module.dns.public_zone_name_servers
}

output "backup_plan_name" {
  description = "Backup for GKE plan name (null when backup is disabled) — used by the validation suite for on-demand backups."
  value       = var.enable_backup ? module.backup[0].backup_plan_name : null
}

output "restore_plan_name" {
  description = "Backup for GKE restore-plan name (null when backup is disabled)."
  value       = var.enable_backup ? module.backup[0].restore_plan_name : null
}
