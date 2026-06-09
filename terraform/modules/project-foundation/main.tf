# project-foundation — the per-environment Google Cloud foundation that every
# cluster depends on: enabled services, the Google-managed service agents and
# the two CMEK grants, the cluster encryption key, and the least-privilege node
# identity. See docs/implementation/cluster-build.md for the rationale.

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # Services the hardened cluster and its supply chain touch. Enabling
  # container/compute also materializes the Google-managed service agents.
  required_services = toset([
    "container.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudkms.googleapis.com",
    "artifactregistry.googleapis.com",
    "containeranalysis.googleapis.com",
    "binaryauthorization.googleapis.com",
    "gkehub.googleapis.com",
    "gkeconnect.googleapis.com",
    "connectgateway.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "dns.googleapis.com",
    "certificatemanager.googleapis.com", # public gateway certs (TC-7)
    "privateca.googleapis.com",          # CAS private CA for internal TLS (TC-7)
    "gkebackup.googleapis.com",          # Backup for GKE (ADR-0004)
  ])

  # The Compute service agent encrypts node boot/attached disks with our key.
  # It exists once the Compute API is enabled; reference it by its well-known email.
  compute_agent_email = "service-${data.google_project.this.number}@compute-system.iam.gserviceaccount.com"
}

resource "google_project_service" "this" {
  for_each = local.required_services
  project  = var.project_id
  service  = each.value

  # Leave services enabled on teardown: disabling them is slow and disruptive,
  # and other resources may still depend on them.
  disable_on_destroy = false
}

# Force the GKE service agent into existence before we grant it key access;
# otherwise the IAM binding races the agent's lazy creation.
resource "google_project_service_identity" "gke" {
  provider = google-beta
  project  = var.project_id
  service  = "container.googleapis.com"

  depends_on = [google_project_service.this]
}

# --- Cluster encryption key (CMEK) -----------------------------------------

resource "google_kms_key_ring" "this" {
  project  = var.project_id
  name     = "gke-${var.region}"
  location = var.region

  depends_on = [google_project_service.this]
}

resource "google_kms_crypto_key" "cluster" {
  name            = "cluster"
  key_ring        = google_kms_key_ring.this.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = var.kms_key_rotation_period
  labels          = var.labels
}

# Grant (a): the GKE service agent uses the key for application-layer secret
# (etcd) encryption — wired on the cluster's database_encryption block.
resource "google_kms_crypto_key_iam_member" "gke_secrets" {
  crypto_key_id = google_kms_crypto_key.cluster.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.gke.email}"
}

# Grant (b): the Compute service agent uses the key for node boot/attached disk
# encryption — wired on node_config.boot_disk_kms_key and the storage class.
resource "google_kms_crypto_key_iam_member" "compute_disks" {
  crypto_key_id = google_kms_crypto_key.cluster.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${local.compute_agent_email}"

  depends_on = [google_project_service.this]
}

# Force the Backup for GKE service agent into existence (same race as the GKE
# agent above: the key grant must not depend on lazy agent creation).
resource "google_project_service_identity" "gkebackup" {
  provider = google-beta
  project  = var.project_id
  service  = "gkebackup.googleapis.com"

  depends_on = [google_project_service.this]
}

# Grant (c): the Backup for GKE service agent encrypts backups with the same
# cluster key — wired on the backup plan's encryption_key (ADR-0004).
resource "google_kms_crypto_key_iam_member" "gkebackup_backups" {
  crypto_key_id = google_kms_crypto_key.cluster.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.gkebackup.email}"
}

# --- Least-privilege node identity -----------------------------------------

resource "google_service_account" "node" {
  project      = var.project_id
  account_id   = var.node_service_account_id
  display_name = "GKE nodes (least privilege)"
}

# The supported minimum bundle for node logging/metrics/inventory. Image pull
# (roles/artifactregistry.reader) is granted repo-scoped in the supply-chain module.
resource "google_project_iam_member" "node" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.node.email}"
}
