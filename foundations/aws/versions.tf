# -----------------------------------------------------------------------------
# AWS foundation: EKS cluster + AWS Secrets Manager ("vault") pair.
#
# State lives in the shared Azure Storage state home, not in S3 — see
# docs/architecture.md. Azure credentials are therefore needed alongside the
# AWS ones. The backend block is left partial on purpose: pass the
# per-environment settings at init time, e.g.
#
#   terraform init -backend-config=backend/prototype.hcl
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "azurerm" {}

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
