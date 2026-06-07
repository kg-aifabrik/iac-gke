# supply-chain — where cluster images come from and which images are trusted.
#
# Two Artifact Registry repositories (the team's own images, and a pull-through
# proxy so public images are cached/scanned inside the project instead of pulled
# from the internet at runtime), the node identity granted pull access scoped to
# those repositories, and a Binary Authorization policy that decides what may run.
#
# The policy starts in AUDIT (dry-run: log violations, block nothing) so the
# cluster comes up while we observe what would be denied. Flipping to enforce is
# a deliberate later step (issue #12), once an image-signing pipeline exists.
# See docs/implementation/cluster-build.md for the rationale.

locals {
  registry_host = "${var.region}-docker.pkg.dev"
}

# --- Registries -------------------------------------------------------------

# The team's own images, published by CI and pulled by the cluster.
resource "google_artifact_registry_repository" "app" {
  project       = var.project_id
  location      = var.region
  repository_id = var.app_repository_id
  description   = "Private images published by the team."
  format        = "DOCKER"
  mode          = "STANDARD_REPOSITORY"
  labels        = var.labels
}

# Pull-through cache for public Docker Hub images. Workloads reference this
# proxy instead of docker.io, so every public image is fetched once, cached in
# the project, and subject to the same scanning and admission policy — and node
# pulls need no public internet egress (they use Private Google Access).
resource "google_artifact_registry_repository" "docker_proxy" {
  project       = var.project_id
  location      = var.region
  repository_id = var.proxy_repository_id
  description   = "Remote pull-through proxy/cache for public Docker Hub images."
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  labels        = var.labels

  remote_repository_config {
    description = "Docker Hub pull-through cache."
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }
}

# --- Pull access (repository-scoped, least privilege) -----------------------

# The node identity may read these two repositories only — not every repository
# in the project. Image pull is granted here, not in project-foundation, so the
# grant lives with the repositories it concerns.
resource "google_artifact_registry_repository_iam_member" "node_reader_app" {
  project    = var.project_id
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.node_service_account_email}"
}

resource "google_artifact_registry_repository_iam_member" "node_reader_proxy" {
  project    = var.project_id
  location   = google_artifact_registry_repository.docker_proxy.location
  repository = google_artifact_registry_repository.docker_proxy.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.node_service_account_email}"
}

# --- Admission policy (Binary Authorization) --------------------------------

resource "google_binary_authorization_policy" "this" {
  project = var.project_id

  # Evaluate Google-managed system images against Google's maintained policy, so
  # GKE's own components stay admissible when we later enforce.
  global_policy_evaluation_mode = "ENABLE"

  # Always admit images from our own registries — trusted by origin. Listing
  # them now means the enforce flip (issue #12) won't accidentally block our
  # own or proxied images; only un-attested third-party images get caught.
  admission_whitelist_patterns {
    name_pattern = "${local.registry_host}/${var.project_id}/${google_artifact_registry_repository.app.repository_id}/*"
  }
  admission_whitelist_patterns {
    name_pattern = "${local.registry_host}/${var.project_id}/${google_artifact_registry_repository.docker_proxy.repository_id}/*"
  }

  # AUDIT stage: admit everything for now (ALWAYS_ALLOW), so the cluster comes up
  # and nothing is blocked while the policy resource is in place. REQUIRE_ATTESTATION
  # is invalid until attestors exist — the API rejects an empty require_attestations_by
  # — so the enforce flip is deferred to #12, which adds attestors and switches to
  # REQUIRE_ATTESTATION + ENFORCED_BLOCK_AND_AUDIT_LOG.
  default_admission_rule {
    evaluation_mode  = "ALWAYS_ALLOW"
    enforcement_mode = "DRYRUN_AUDIT_LOG_ONLY"
  }
}
