# Inputs for the private-ca module: the private CA hierarchy that issues TLS
# certificates for internal endpoints (ADR-0002), and the identity cert-manager
# uses to request them.

variable "project_id" {
  description = "The Google Cloud project that hosts the CAS resources."
  type        = string
}

variable "region" {
  description = "Region for the CA pools and CAs (kept equal to the cluster region)."
  type        = string
}

variable "environment" {
  description = "Environment (dev/stage/prod) — names the per-environment subordinate CA."
  type        = string
}

variable "workload_pool" {
  description = "The cluster's Workload Identity pool (<project>.svc.id.goog), used to bind the cert-manager Kubernetes service account to its Google service account."
  type        = string
}

variable "cas_tier" {
  description = "CAS pool tier. ENTERPRISE tracks issued certs and supports revocation."
  type        = string
  default     = "ENTERPRISE"
}

variable "organization" {
  description = "Subject organization on the CA certificates."
  type        = string
  default     = "AiFabrik"
}

variable "root_ca_lifetime" {
  description = "Root CA lifetime in seconds (default 10 years)."
  type        = string
  default     = "315360000s"
}

variable "subordinate_ca_lifetime" {
  description = "Subordinate CA lifetime in seconds (default 5 years)."
  type        = string
  default     = "157680000s"
}

variable "cert_manager_gsa_id" {
  description = "Account id for the Google service account cert-manager (google-cas-issuer) impersonates via Workload Identity."
  type        = string
  default     = "cert-manager-cas"
}

variable "cert_manager_ksa_namespace" {
  description = "Namespace of the google-cas-issuer Kubernetes service account."
  type        = string
  default     = "cert-manager"
}

variable "cert_manager_ksa_name" {
  description = "Name of the google-cas-issuer Kubernetes service account."
  type        = string
  default     = "cert-manager-google-cas-issuer"
}

variable "deletion_protection" {
  description = "Guard the CAs against deletion. False for short-lived dev."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels for the CA pools / CAs."
  type        = map(string)
  default     = {}
}
