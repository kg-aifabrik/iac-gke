# Inputs for the gke-gateway module. One instance is one gateway of a given
# exposure (internal or external); the hardening (TLS-required, HTTP→HTTPS
# redirect, SSL policy) is identical, the issuer and load-balancer class differ.

variable "exposure" {
  description = "internal (regional internal ALB, CAS cert) or external (global external ALB, Certificate Manager cert + Cloud Armor)."
  type        = string

  validation {
    condition     = contains(["internal", "external"], var.exposure)
    error_message = "exposure must be \"internal\" or \"external\"."
  }
}

variable "name" {
  description = "Gateway name (also names its IP / SSL policy / cert resources), e.g. \"external\" or \"internal\"."
  type        = string
}

variable "project_id" {
  description = "The Google Cloud project."
  type        = string
}

variable "region" {
  description = "Region (for the internal ALB's regional resources)."
  type        = string
}

variable "subnetwork" {
  description = "Node subnet self link or id — the internal gateway reserves its VIP from this subnet. Unused for external."
  type        = string
  default     = null
}

variable "gateway_namespace" {
  description = "Namespace the Gateway and its policies/routes live in (platform-owned)."
  type        = string
  default     = "gateway-system"
}

variable "hostnames" {
  description = "Hostnames served by the gateway (ADR-0005). External: each gets its own DNS authorization + managed certificate + certificate-map entry, served by SNI. Internal: all names are SANs on one CAS-issued certificate. Adding an app is adding a list entry."
  type        = list(string)

  validation {
    condition     = length(var.hostnames) > 0
    error_message = "hostnames needs at least one entry."
  }
}

variable "route_namespace_label" {
  description = "Label a workload namespace must carry to attach HTTPRoutes to this gateway (allowedRoutes selector). Key/value."
  type = object({
    key   = string
    value = string
  })
  default = {
    key   = "ingress"
    value = ""
  }
}

variable "min_tls_version" {
  description = "Minimum TLS version on the SSL policy."
  type        = string
  default     = "TLS_1_2"
}

# --- Internal-only: CAS-issued certificate ----------------------------------

variable "cas_cluster_issuer" {
  description = "Name of the cert-manager ClusterIssuer backed by CAS (internal exposure)."
  type        = string
  default     = "cas-issuer"
}

variable "tls_secret_name" {
  description = "Secret cert-manager writes the internal CAS-issued cert to, referenced by the Gateway (internal exposure). Null derives \"<name>-gateway-tls\"."
  type        = string
  default     = null
}

# --- External-only: Cloud Armor ---------------------------------------------

variable "enable_cloud_armor" {
  description = "Create a baseline Cloud Armor policy for the external gateway (full OWASP enforcement is tracked separately)."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels for labelable resources."
  type        = map(string)
  default     = {}
}
