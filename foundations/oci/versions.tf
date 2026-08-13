# -----------------------------------------------------------------------------
# OCI foundation: OKE cluster + OCI Vault ("vault") pair.
#
#   terraform init -backend-config=backend/prototype.hcl
#
# State lives in OCI Object Storage through its S3-compatible endpoint, so the
# stack uses the standard "s3" backend (see backend/*.hcl for the endpoint and
# the compatibility flags it needs).
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "s3" {}

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
