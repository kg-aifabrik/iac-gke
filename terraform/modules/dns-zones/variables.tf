# Inputs for the dns-zones module: the per-environment private zone for
# internal hostnames, and the opt-in public zone (ADR-0006).

variable "project_id" {
  description = "The Google Cloud project that hosts the zones."
  type        = string
}

variable "internal_zone_domain" {
  description = "Domain of the private zone (e.g. dev.aifabrik.com). Internal hostnames must live under it."
  type        = string
}

variable "internal_records" {
  description = "Internal A records: hostname => IP (every internal gateway hostname pointing at the internal VIP)."
  type        = map(string)
}

variable "network_self_link" {
  description = "VPC the private zone is visible to."
  type        = string
}

variable "manage_public_dns" {
  description = "Create a PUBLIC zone and manage the external records in it (off by default — public DNS stays SRE-manual until the domain is delegated to Cloud DNS at the registrar; ADR-0006). Flipping this on changes nothing until that delegation exists."
  type        = bool
  default     = false
}

variable "public_zone_domain" {
  description = "Domain of the public zone (required when manage_public_dns is true)."
  type        = string
  default     = null
}

variable "public_records" {
  description = "Per-hostname external records to manage when manage_public_dns is on — the gke-gateway dns_records output shape: hostname => { dns_authorization = {name,type,data}, a_record = {host,ip} }."
  type = map(object({
    dns_authorization = object({ name = string, type = string, data = string })
    a_record          = object({ host = string, ip = string })
  }))
  default = {}
}

variable "force_destroy" {
  description = "Delete zones even when they still hold records (dev teardown hygiene; off for protected environments)."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels for the managed zones."
  type        = map(string)
  default     = {}
}
