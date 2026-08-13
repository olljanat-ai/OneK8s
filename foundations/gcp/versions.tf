# -----------------------------------------------------------------------------
# GCP foundation: GKE cluster + GCP Secret Manager ("vault") pair.
#
#   terraform init -backend-config=backend/dev.hcl
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "= 7.44.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
  }
}
