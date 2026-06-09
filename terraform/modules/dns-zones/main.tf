# dns-zones — Cloud DNS for the cluster's hostnames (ADR-0006, design §8).
#
# Private: a per-environment zone bound to the VPC; every internal gateway
# hostname gets an A record to the internal VIP. Pods resolve it through the
# node resolver (kube-dns → metadata → Cloud DNS), so internal names work with
# zero client setup and never leave the VPC (split-horizon with the public
# domain). Private zones need no registrar control.
#
# Public: opt-in only (manage_public_dns). When the domain (or a subdomain) is
# delegated to Cloud DNS at the registrar — a one-time manual step — the same
# per-host records SREs create by hand today (the hostname A record and the
# Certificate Manager DNS-authorization CNAME) become Terraform-managed.
# Until then the flag stays off and nothing here changes.

resource "google_dns_managed_zone" "private" {
  project     = var.project_id
  name        = replace(var.internal_zone_domain, ".", "-")
  dns_name    = "${var.internal_zone_domain}."
  description = "Internal hostnames for the ${var.internal_zone_domain} environment (cluster-ctrl; ADR-0006)."
  visibility  = "private"
  labels      = var.labels

  private_visibility_config {
    networks {
      network_url = var.network_self_link
    }
  }

  # Dev teardown hygiene (#31): a zone must delete even if records linger.
  force_destroy = var.force_destroy
}

resource "google_dns_record_set" "internal_a" {
  for_each     = var.internal_records
  project      = var.project_id
  managed_zone = google_dns_managed_zone.private.name
  name         = "${each.key}."
  type         = "A"
  ttl          = 300
  rrdatas      = [each.value]
}

# --- Public zone (opt-in; ADR-0006) -----------------------------------------

resource "google_dns_managed_zone" "public" {
  count       = var.manage_public_dns ? 1 : 0
  project     = var.project_id
  name        = replace(var.public_zone_domain, ".", "-")
  dns_name    = "${var.public_zone_domain}."
  description = "External hostnames for ${var.public_zone_domain} (cluster-ctrl; delegated at the registrar)."
  visibility  = "public"
  labels      = var.labels

  force_destroy = var.force_destroy
}

resource "google_dns_record_set" "public_a" {
  for_each     = var.manage_public_dns ? var.public_records : {}
  project      = var.project_id
  managed_zone = google_dns_managed_zone.public[0].name
  name         = "${each.value.a_record.host}."
  type         = "A"
  ttl          = 300
  rrdatas      = [each.value.a_record.ip]
}

# The Certificate Manager DNS-authorization CNAME per hostname — the record
# whose absence stalled the M2 certificate in PROVISIONING.
resource "google_dns_record_set" "public_dns_authorization" {
  for_each     = var.manage_public_dns ? var.public_records : {}
  project      = var.project_id
  managed_zone = google_dns_managed_zone.public[0].name
  name         = each.value.dns_authorization.name
  type         = each.value.dns_authorization.type
  ttl          = 300
  rrdatas      = [each.value.dns_authorization.data]
}
