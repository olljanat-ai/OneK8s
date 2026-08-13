# -----------------------------------------------------------------------------
# GCP foundation: GKE cluster + GCP Secret Manager ("vault") pair.
#
# State lives in the shared Azure Storage state home, not in GCS — see
# docs/architecture.md. Azure credentials are therefore needed alongside the
# GCP ones. The backend block is left partial on purpose: pass the
# per-environment settings at init time, e.g.
#
#   terraform init -backend-config=backend/prototype.hcl
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "azurerm" {}

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
