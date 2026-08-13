# -----------------------------------------------------------------------------
# Tenants: ONE stack for all clouds. The target cloud is just a parameter
# (`cloud = "azure" | "aws" | "gcp" | "oci"`) in the chosen env file:
#
#   terraform init -backend-config=backend/aws-prototype.hcl
#   terraform apply -var-file=envs/aws-prototype.tfvars
#
# ALL state (every stack, every cloud, every environment) lives in the Azure
# Storage "state home" under distinct keys — tenants/<cloud>/<env>.tfstate
# here, foundations/<cloud>/<env>.tfstate for the foundations this stack
# reads. Azure credentials (ARM_* env vars / az login) are therefore required
# for every deploy, plus the credentials of the selected cloud.
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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
  }
}
