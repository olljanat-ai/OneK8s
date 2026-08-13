# -----------------------------------------------------------------------------
# AWS foundation: EKS cluster + AWS Secrets Manager ("vault") pair.
#
#   terraform init -backend-config=backend/dev.hcl
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.58.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.3.0"
    }
  }
}
