# network — the custom VPC and regional subnet (with Pod/Service secondary
# ranges) a private VPC-native cluster runs on, plus optional public egress.
# See docs/implementation/cluster-build.md for the rationale.

resource "google_compute_network" "this" {
  project = var.project_id
  name    = var.network_name

  # Custom mode: we place subnets deliberately, rather than letting Google
  # auto-create one per region with preset ranges.
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  project       = var.project_id
  name          = var.subnet_name
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.node_cidr

  # Pods and Services are alias-IP secondary ranges on this one subnet
  # (VPC-native). These ranges are immutable after creation — sized once.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pod_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.service_cidr
  }

  # Let private nodes (no external IP) reach Google APIs and Artifact Registry
  # over Google's internal path — no NAT needed for Google services.
  private_ip_google_access = true
}

# Optional outbound internet for workloads that need it (off by default — least
# exposure). Google APIs do not require this (Private Google Access above).
resource "google_compute_router" "this" {
  count   = var.enable_cloud_nat ? 1 : 0
  project = var.project_id
  name    = "${var.network_name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  count                              = var.enable_cloud_nat ? 1 : 0
  project                            = var.project_id
  name                               = "${var.network_name}-nat"
  region                             = var.region
  router                             = google_compute_router.this[0].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Regional proxy-only subnet — the managed Envoy proxy pool that fronts regional
# Application Load Balancers (the internal gateway, §8). One per region per
# network; it carries no workloads (purpose REGIONAL_MANAGED_PROXY). Created only
# when an internal gateway is used.
resource "google_compute_subnetwork" "proxy_only" {
  count         = var.enable_proxy_only_subnet ? 1 : 0
  project       = var.project_id
  name          = "${var.network_name}-proxy-only"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.proxy_only_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# Private Service Access — a reserved internal range peered to Google's
# servicenetworking, so a managed service placed on a private IP (Cloud SQL, §DB)
# is reachable over this VPC without leaving Google's network. Created only when
# a private managed database is used. Google auto-allocates a free block of the
# requested size; the range is immutable once the peering exists.
resource "google_compute_global_address" "psa" {
  count         = var.enable_private_service_access ? 1 : 0
  project       = var.project_id
  name          = "${var.network_name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.private_service_access_prefix_length
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "psa" {
  count                   = var.enable_private_service_access ? 1 : 0
  network                 = google_compute_network.this.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa[0].name]
}
