# -----------------------------------------------------------------------------
# Azure foundation: AKS cluster + Azure Key Vault ("vault") pair.
#
# State is stored in an Azure Storage Account. The backend block is left
# partial on purpose: pass the per-environment settings at init time, e.g.
#
#   terraform init -backend-config=backend/dev.hcl
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
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.0"
    }
  }
}
