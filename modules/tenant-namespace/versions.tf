# Unified, cloud-agnostic entry point of the tenant-namespace module.
#
# Every cloud's providers are declared here because the dispatcher forwards
# them to the cloud-specific submodules; the root configuration must configure
# all of them (see tenants/providers.tf). Only the selected cloud's provider is
# ever actually used — the other submodules have count = 0.
#
# OCI additionally needs its home-region alias: aliased provider
# configurations are never inherited, so callers must pass `oci.home`
# explicitly, and passing any provider disables default inheritance for the
# rest — hence the full list.
terraform {
  required_version = ">= 1.9.0"

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
      source                = "oracle/oci"
      version               = "= 8.26.0"
      configuration_aliases = [oci.home]
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
