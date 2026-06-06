# Both providers target the dev project. Credentials come from the environment
# (Application Default Credentials locally, Workload Identity Federation in CI),
# never from committed key files.

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
