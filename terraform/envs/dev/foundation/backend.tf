# Remote state for the dev project foundation. The bucket name contains the
# project id (account-specific), so it is supplied at init, not committed:
#   terraform init -backend-config="bucket=<project>-tf-state"
terraform {
  backend "gcs" {
    prefix = "env/dev/foundation"
  }
}
