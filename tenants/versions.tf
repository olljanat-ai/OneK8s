# -----------------------------------------------------------------------------
# Tenants: ONE stack, ONE state file per environment, all clouds in one run.
# The target cloud is a per-tenant parameter (`cloud = "azure" | "aws" | "gcp"
# | "oci" | "nutanix"`), so an environment is deployed with a single:
#
#   terraform init -backend-config=backend/prototype.hcl
#   terraform apply -var-file=envs/prototype.tfvars
#
# ALL state (every stack, every cloud, every environment) lives in the Azure
# Storage "state home" under distinct keys — tenants/<env>.tfstate here,
# foundations/<cloud>/<env>.tfstate for the foundations this stack reads.
# Azure credentials (ARM_* env vars / az login) are therefore required for
# every deploy, plus the credentials of every cloud that has tenants.
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
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.58.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "= 7.44.0"
    }
    oci = {
      source  = "oracle/oci"
      version = "= 8.26.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "= 5.11.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
  }
}
