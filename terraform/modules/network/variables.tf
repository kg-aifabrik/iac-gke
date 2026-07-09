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

variable "enable_proxy_only_subnet" {
  description = "Create the regional proxy-only subnet that regional Application Load Balancers (the internal gateway, §8) require. One per region per network. Off unless an internal gateway is used."
  type        = bool
  default     = false
}

variable "proxy_only_cidr" {
  description = "CIDR for the regional proxy-only subnet (Envoy proxies, not workloads). Must not overlap the node/Pod/Service ranges."
  type        = string
  default     = "10.2.0.0/23"
}

variable "enable_private_service_access" {
  description = "Reserve a Private Service Access range and peer it to servicenetworking so a managed service (Cloud SQL) can be reached on a private IP over this VPC. Off unless a private managed database is used."
  type        = bool
  default     = false
}

variable "private_service_access_prefix_length" {
  description = "Prefix length of the reserved PSA range. A /16 gives Google's managed services ample room; the block is auto-allocated and must not overlap the node/Pod/Service ranges."
  type        = number
  default     = 16
}
