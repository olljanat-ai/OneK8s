# -----------------------------------------------------------------------------
# Azure foundation: AKS cluster + Azure Key Vault ("vault") pair.
#
# State is stored in the shared Azure Storage state home, which holds every
# stack's state on every cloud. The backend block is left partial on purpose:
# pass the per-environment settings at init time, e.g.
#
#   terraform init -backend-config=backend/prototype.hcl
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.0.1"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "= 2.12.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.0"
    }
    # Kargo's admission webhooks are served over TLS the API server has to
    # trust, and this platform runs no cert-manager (docs/architecture.md).
    # The certificate is minted here instead (kargo.tf).
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.1.0"
    }
  }
}
