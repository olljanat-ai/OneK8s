# -----------------------------------------------------------------------------
# AWS tenants: instantiates modules/tenant-namespace/aws per tenant on a
# cluster provisioned by foundations/aws.
#
#   terraform init -backend-config=backend/dev.hcl
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}
