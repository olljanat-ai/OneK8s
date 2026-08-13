# -----------------------------------------------------------------------------
# OCI foundation: OKE cluster + OCI Vault ("vault") pair.
#
# State lives in the shared Azure Storage state home, not in OCI Object
# Storage — see docs/architecture.md. Azure credentials are therefore needed
# alongside the OCI ones. The backend block is left partial on purpose: pass
# the per-environment settings at init time, e.g.
#
#   terraform init -backend-config=backend/prototype.hcl
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "azurerm" {}

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "= 8.26.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
  }
}
