terraform {
  required_version = ">= 1.9.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "= 8.26.0"

      # IAM resources can only be written in the tenancy's home region, which
      # is not necessarily the region the cluster runs in.
      configuration_aliases = [oci.home]
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
  }
}
