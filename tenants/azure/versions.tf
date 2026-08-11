# -----------------------------------------------------------------------------
# Azure tenants: instantiates modules/tenant-namespace/azure per tenant on a
# cluster provisioned by foundations/azure. Deployed independently of the
# foundation; depends only on its remote-state outputs.
#
#   terraform init -backend-config=backend/dev.hcl
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}
