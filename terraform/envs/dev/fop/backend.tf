# Remote state for the dev Fleet-Operations-Plane cluster. Bucket supplied at
# init (account-specific, not committed):
#   terraform init -backend-config="bucket=<project>-tf-state"
terraform {
  backend "gcs" {
    prefix = "env/dev/fop"
  }
}
