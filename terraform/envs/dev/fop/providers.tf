# Targets the dev project. Credentials come from the environment (ADC locally,
# Workload Identity Federation in CI), never from committed key files.

provider "google" {
  project = var.project_id
  region  = var.region
}
