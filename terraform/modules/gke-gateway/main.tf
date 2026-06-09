# gke-gateway — one gateway of a given exposure: the Google edge resources
# (reserved IP, SSL policy, HTTP→HTTPS redirect, and — external only —
# per-hostname Certificate Manager certs + Cloud Armor) plus the rendered
# in-cluster Gateway / redirect HTTPRoute / GCPGatewayPolicy (and, internal,
# the multi-SAN cert-manager Certificate). Hostnames are a list: adding an app
# is adding an entry (ADR-0005). See design §8 and ADR-0001/0002.
#
# Confirm-at-build: regional internal SSL-policy support on gke-l7-rilb via
# GCPGatewayPolicy; the external HTTPS listener picking up certs from the
# certmap annotation.

locals {
  is_external   = var.exposure == "external"
  gateway_class = local.is_external ? "gke-l7-global-external-managed" : "gke-l7-rilb"

  tls_secret  = coalesce(var.tls_secret_name, "${var.name}-gateway-tls")
  route_label = { (var.route_namespace_label.key) = coalesce(var.route_namespace_label.value, var.name) }

  # Per-hostname slugs for Google resource names (which take [a-z0-9-] only).
  host_slug = { for h in var.hostnames : h => replace(h, ".", "-") }

  # External hostnames as a set for for_each (empty when internal).
  external_hosts = local.is_external ? toset(var.hostnames) : toset([])

  address_name    = local.is_external ? google_compute_global_address.external[0].name : google_compute_address.internal[0].name
  ssl_policy_name = local.is_external ? google_compute_ssl_policy.external[0].name : google_compute_region_ssl_policy.internal[0].name

  # --- Rendered in-cluster manifests ---------------------------------------
  gateway = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = merge(
      { name = var.name, namespace = var.gateway_namespace, labels = { "app.kubernetes.io/managed-by" = "cluster-ctrl" } },
      local.is_external ? { annotations = { "networking.gke.io/certmap" = google_certificate_manager_certificate_map.external[0].name } } : {},
    )
    spec = {
      gatewayClassName = local.gateway_class
      addresses        = [{ type = "NamedAddress", value = local.address_name }]
      listeners = [
        {
          name          = "http"
          protocol      = "HTTP"
          port          = 80
          allowedRoutes = { namespaces = { from = "Selector", selector = { matchLabels = local.route_label } } }
        },
        merge(
          {
            # No listener hostname: the gateway serves every name on its
            # certificates, and HTTPRoutes declare the hostnames they own.
            # Attachment stays gated by the namespace label (ADR-0005;
            # per-hostname ownership arrives with the namespace stamps).
            name          = "https"
            protocol      = "HTTPS"
            port          = 443
            allowedRoutes = { namespaces = { from = "Selector", selector = { matchLabels = local.route_label } } }
          },
          # External: TLS is supplied by the certmap annotation, so the HTTPS
          # listener carries NO tls block (a tls block with mode Terminate would
          # require certificateRefs and be rejected). Internal: terminate with the
          # CAS-issued multi-SAN Secret cert-manager populates.
          local.is_external ? {} : { tls = { mode = "Terminate", certificateRefs = [{ kind = "Secret", name = local.tls_secret, group = "" }] } },
        ),
      ]
    }
  }

  redirect_route = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "${var.name}-redirect", namespace = var.gateway_namespace }
    spec = {
      parentRefs = [{ name = var.name, sectionName = "http" }]
      rules      = [{ filters = [{ type = "RequestRedirect", requestRedirect = { scheme = "https", statusCode = 301 } }] }]
    }
  }

  ssl_gatewaypolicy = {
    apiVersion = "networking.gke.io/v1"
    kind       = "GCPGatewayPolicy"
    metadata   = { name = "${var.name}-ssl", namespace = var.gateway_namespace }
    spec = {
      default   = { sslPolicy = local.ssl_policy_name }
      targetRef = { group = "gateway.networking.k8s.io", kind = "Gateway", name = var.name }
    }
  }

  # Internal only: cert-manager requests one multi-SAN leaf from CAS into the
  # Secret — every internal hostname is an explicit SAN (no wildcards,
  # ADR-0005); adding a name reissues the certificate automatically.
  internal_certificate = local.is_external ? null : {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "${var.name}-tls", namespace = var.gateway_namespace }
    spec = {
      secretName = local.tls_secret
      dnsNames   = var.hostnames
      issuerRef  = { name = var.cas_cluster_issuer, kind = "GoogleCASClusterIssuer", group = "cas-issuer.jetstack.io" }
      privateKey = { algorithm = "RSA", size = 2048 }
      usages     = ["server auth", "digital signature", "key encipherment"]
    }
  }

  manifests           = [for m in [local.gateway, local.redirect_route, local.ssl_gatewaypolicy, local.internal_certificate] : m if m != null]
  incluster_manifests = join("\n---\n", [for m in local.manifests : yamlencode(m)])
}

# --- Reserved IP ------------------------------------------------------------

resource "google_compute_global_address" "external" {
  count   = local.is_external ? 1 : 0
  project = var.project_id
  name    = "${var.name}-gw"
}

resource "google_compute_address" "internal" {
  count        = local.is_external ? 0 : 1
  project      = var.project_id
  name         = "${var.name}-gw"
  region       = var.region
  address_type = "INTERNAL"
  purpose      = "SHARED_LOADBALANCER_VIP"
  subnetwork   = var.subnetwork
}

# --- SSL policy (minimum TLS) ----------------------------------------------

resource "google_compute_ssl_policy" "external" {
  count           = local.is_external ? 1 : 0
  project         = var.project_id
  name            = "${var.name}-ssl"
  min_tls_version = var.min_tls_version
  profile         = "MODERN"
}

resource "google_compute_region_ssl_policy" "internal" {
  count           = local.is_external ? 0 : 1
  project         = var.project_id
  name            = "${var.name}-ssl"
  region          = var.region
  min_tls_version = var.min_tls_version
  profile         = "MODERN"
}

# --- Cloud Armor (external, baseline) --------------------------------------

resource "google_compute_security_policy" "armor" {
  count       = local.is_external && var.enable_cloud_armor ? 1 : 0
  project     = var.project_id
  name        = "${var.name}-armor"
  description = "Baseline Cloud Armor for the external gateway; OWASP enforcement is tracked separately."

  rule {
    action      = "allow"
    priority    = 2147483647
    description = "default allow (baseline)"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

# --- Certificate Manager (external, public managed certs) ------------------
# One DNS authorization + managed certificate + map ENTRY per hostname; the
# certificate MAP stays singular (the Gateway's certmap annotation points at
# it) and serves the right certificate by SNI (ADR-0005).

resource "google_certificate_manager_dns_authorization" "external" {
  for_each = local.external_hosts
  project  = var.project_id
  name     = "${var.name}-dnsauth-${local.host_slug[each.value]}"
  domain   = each.value
  labels   = var.labels
}

resource "google_certificate_manager_certificate" "external" {
  for_each = local.external_hosts
  project  = var.project_id
  name     = "${var.name}-cert-${local.host_slug[each.value]}"
  labels   = var.labels
  managed {
    domains            = [each.value]
    dns_authorizations = [google_certificate_manager_dns_authorization.external[each.value].id]
  }
}

resource "google_certificate_manager_certificate_map" "external" {
  count   = local.is_external ? 1 : 0
  project = var.project_id
  name    = "${var.name}-certmap"
  labels  = var.labels
}

resource "google_certificate_manager_certificate_map_entry" "external" {
  for_each     = local.external_hosts
  project      = var.project_id
  name         = "${var.name}-certmap-${local.host_slug[each.value]}"
  map          = google_certificate_manager_certificate_map.external[0].name
  certificates = [google_certificate_manager_certificate.external[each.value].id]
  hostname     = each.value
}
