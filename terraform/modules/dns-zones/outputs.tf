# Outputs for the dns-zones module.

output "private_zone_name" {
  description = "Cloud DNS managed-zone name of the private zone."
  value       = google_dns_managed_zone.private.name
}

output "private_zone_dns_name" {
  description = "DNS name of the private zone (with trailing dot)."
  value       = google_dns_managed_zone.private.dns_name
}

output "public_zone_name_servers" {
  description = "Name servers of the public zone — the NS records to set at the registrar for delegation (null while manage_public_dns is off)."
  value       = var.manage_public_dns ? google_dns_managed_zone.public[0].name_servers : null
}
