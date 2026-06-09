# private-ca — the private certificate authority for internal-endpoint TLS
# (ADR-0002). A long-lived self-signed root signs a per-environment subordinate;
# cert-manager (google-cas-issuer) issues leaf certs from the subordinate pool.
# Internal hostnames never enter public Certificate Transparency logs.
#
# Terraform owns the Google resources (this module). The cert-manager add-on and
# the trust-manager bundle that distributes the root are in-cluster manifests.

locals {
  # Shared CA certificate config (a signing CA: cert_sign + crl_sign).
  ca_x509 = {
    is_ca     = true
    cert_sign = true
    crl_sign  = true
  }
}

# --- Root: self-signed, long-lived, kept cold -------------------------------

resource "google_privateca_ca_pool" "root" {
  project  = var.project_id
  name     = "${var.environment}-root"
  location = var.region
  tier     = var.cas_tier
  labels   = var.labels
}

resource "google_privateca_certificate_authority" "root" {
  project                  = var.project_id
  location                 = var.region
  pool                     = google_privateca_ca_pool.root.name
  certificate_authority_id = "${var.environment}-root"
  type                     = "SELF_SIGNED"
  lifetime                 = var.root_ca_lifetime
  labels                   = var.labels

  # Allow deletion in dev even after the subordinate has been signed.
  deletion_protection                    = var.deletion_protection
  ignore_active_certificates_on_deletion = true
  # Purge immediately on delete (no 30-day recovery window) when the CA is
  # unprotected, so its pool can be deleted in the same `terraform destroy` run
  # instead of failing on "CAs must be past their recovery period" (#31). A
  # protected (prod) CA keeps the recovery window.
  skip_grace_period = !var.deletion_protection

  config {
    subject_config {
      subject {
        organization = var.organization
        common_name  = "${var.organization} Internal Root (${var.environment})"
      }
    }
    x509_config {
      ca_options {
        is_ca = local.ca_x509.is_ca
      }
      key_usage {
        base_key_usage {
          cert_sign = local.ca_x509.cert_sign
          crl_sign  = local.ca_x509.crl_sign
        }
        extended_key_usage {}
      }
    }
  }

  key_spec {
    algorithm = "RSA_PKCS1_4096_SHA256"
  }
}

# --- Subordinate: per environment, signed by the root, issues the leaves ----

resource "google_privateca_ca_pool" "subordinate" {
  project  = var.project_id
  name     = "${var.environment}-subordinate"
  location = var.region
  tier     = var.cas_tier
  labels   = var.labels
}

resource "google_privateca_certificate_authority" "subordinate" {
  project                  = var.project_id
  location                 = var.region
  pool                     = google_privateca_ca_pool.subordinate.name
  certificate_authority_id = "${var.environment}-subordinate"
  type                     = "SUBORDINATE"
  lifetime                 = var.subordinate_ca_lifetime
  labels                   = var.labels

  deletion_protection                    = var.deletion_protection
  ignore_active_certificates_on_deletion = true
  # See the root CA above: purge immediately when unprotected so the pool deletes
  # cleanly in one destroy run (#31); keep the recovery window when protected.
  skip_grace_period = !var.deletion_protection

  # Signed (and auto-activated) by the root above.
  subordinate_config {
    certificate_authority = google_privateca_certificate_authority.root.id
  }

  config {
    subject_config {
      subject {
        organization = var.organization
        common_name  = "${var.organization} Internal Issuing CA (${var.environment})"
      }
    }
    x509_config {
      ca_options {
        is_ca = local.ca_x509.is_ca
      }
      key_usage {
        base_key_usage {
          cert_sign = local.ca_x509.cert_sign
          crl_sign  = local.ca_x509.crl_sign
        }
        extended_key_usage {}
      }
    }
  }

  key_spec {
    algorithm = "RSA_PKCS1_4096_SHA256"
  }
}

# --- cert-manager identity (Workload Identity) ------------------------------

# The Google service account google-cas-issuer impersonates to request leaves.
resource "google_service_account" "cert_manager" {
  project      = var.project_id
  account_id   = var.cert_manager_gsa_id
  display_name = "cert-manager CAS issuer (${var.environment})"
}

# It may request certificates from the subordinate pool only (least privilege) —
# not from the root, and not manage the CAs.
resource "google_privateca_ca_pool_iam_member" "cert_manager_requester" {
  project = var.project_id
  ca_pool = google_privateca_ca_pool.subordinate.id
  role    = "roles/privateca.certificateRequester"
  member  = "serviceAccount:${google_service_account.cert_manager.email}"
}

# Bind the in-cluster google-cas-issuer KSA to the GSA.
resource "google_service_account_iam_member" "cert_manager_wi" {
  service_account_id = google_service_account.cert_manager.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.workload_pool}[${var.cert_manager_ksa_namespace}/${var.cert_manager_ksa_name}]"
}
