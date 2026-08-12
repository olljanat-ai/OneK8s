# -----------------------------------------------------------------------------
# Tenants: ONE stack for all clouds. The target cloud is just a parameter
# (`cloud = "azure" | "aws" | "gcp" | "oci"`) in the chosen env file:
#
#   terraform init -backend-config=backend/aws-dev.hcl
#   terraform apply -var-file=envs/aws-dev.tfvars
#
# A Terraform working directory supports exactly one backend type, so ALL
# tenant states (every cloud, every environment) live in the Azure Storage
# "state home" under distinct keys (tenants/<cloud>/<env>.tfstate). Azure
# credentials (ARM_* env vars / az login) are therefore required for every
# tenant deploy, plus the credentials of the selected cloud.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  # backend "azurerm" {}

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
