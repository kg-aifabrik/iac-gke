# Outputs for the gke-gateway module.

output "incluster_manifests" {
  description = "Gateway + redirect HTTPRoute + GCPGatewayPolicy (+ internal cert-manager Certificate), as one multi-doc YAML the pipeline applies."
  value       = local.incluster_manifests
}

output "ip_address" {
  description = "The gateway's reserved IP (public for external, private VIP for internal)."
  value       = local.is_external ? google_compute_global_address.external[0].address : google_compute_address.internal[0].address
}

output "certificate_map_name" {
  description = "Certificate Manager certificate-map name referenced by the external Gateway annotation (external only; null otherwise)."
  value       = local.is_external ? google_certificate_manager_certificate_map.external[0].name : null
}

output "cloud_armor_policy_name" {
  description = "Baseline Cloud Armor security-policy name to attach to public backends via GCPBackendPolicy (external only; null otherwise)."
  value       = local.is_external && var.enable_cloud_armor ? google_compute_security_policy.armor[0].name : null
}

output "route_namespace_label" {
  description = "Label a workload namespace must carry to attach HTTPRoutes to this gateway."
  value       = local.route_label
}

# The DNS records the operator adds at the registrar for the external gateway,
# PER HOSTNAME: the Certificate Manager DNS-authorization CNAME (cert
# validation) and the hostname A record. The opt-in public zone (dns-zones
# module, ADR-0006) consumes the same structure when it automates them.
output "dns_records" {
  description = "Per-hostname external DNS records to create at the registrar (null for internal): hostname => { dns_authorization CNAME, a_record }."
  value = local.is_external ? {
    for h in var.hostnames : h => {
      dns_authorization = {
        name = google_certificate_manager_dns_authorization.external[h].dns_resource_record[0].name
        type = google_certificate_manager_dns_authorization.external[h].dns_resource_record[0].type
        data = google_certificate_manager_dns_authorization.external[h].dns_resource_record[0].data
      }
      a_record = {
        host = h
        ip   = google_compute_global_address.external[0].address
      }
    }
  } : null
}
