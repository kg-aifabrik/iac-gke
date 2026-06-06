# Outputs for the supply-chain module — the registry paths workloads reference.

output "app_repository_url" {
  description = "Base path for the team's own images, e.g. <region>-docker.pkg.dev/<project>/app."
  value       = "${local.registry_host}/${var.project_id}/${google_artifact_registry_repository.app.repository_id}"
}

output "proxy_repository_url" {
  description = "Base path for the Docker Hub pull-through proxy; reference public images through here."
  value       = "${local.registry_host}/${var.project_id}/${google_artifact_registry_repository.docker_proxy.repository_id}"
}

output "app_repository_id" {
  description = "Repository id of the team's own image repository."
  value       = google_artifact_registry_repository.app.repository_id
}

output "binary_authorization_policy_id" {
  description = "Id of the project Binary Authorization policy (audit/dry-run until issue #12)."
  value       = google_binary_authorization_policy.this.id
}
