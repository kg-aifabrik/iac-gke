# Inputs for the network module.

variable "project_id" {
  description = "The Google Cloud project that hosts the network."
  type        = string
}

variable "region" {
  description = "Region for the subnet (a subnet spans all zones in its region)."
  type        = string
}

variable "network_name" {
  description = "Name of the custom VPC network."
  type        = string
  default     = "gke"
}

variable "subnet_name" {
  description = "Name of the node subnet."
  type        = string
  default     = "gke-nodes"
}

variable "node_cidr" {
  description = "Primary range for node addresses."
  type        = string
  default     = "10.0.0.0/20"
}

variable "pod_cidr" {
  description = "Secondary range for Pods (alias IP). Dominant consumer; drawn from 100.64.0.0/10 to spare RFC1918 space. Immutable after creation."
  type        = string
  default     = "100.64.0.0/14"
}

variable "service_cidr" {
  description = "Secondary range for Services (alias IP). Immutable after creation."
  type        = string
  default     = "10.1.0.0/20"
}

variable "enable_cloud_nat" {
  description = "Create Cloud NAT for outbound public-internet egress. Off by default (Google APIs use Private Google Access, which needs no NAT)."
  type        = bool
  default     = false
}
