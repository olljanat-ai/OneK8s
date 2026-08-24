# -----------------------------------------------------------------------------
# Azure foundation: AKS cluster + Azure Key Vault ("vault") pair.
#
# Every Azure resource in this stack that Microsoft ships an Azure Verified
# Module for is built from that module rather than from hand-written provider
# resources (docs/azure-verified-modules.md). What is left as a raw resource is
# only what no AVM module covers today, and each of those carries a comment
# saying so.
#
# State is stored in the shared Azure Storage state home, which holds every
# stack's state on every cloud. The backend block is left partial on purpose:
# pass the per-environment settings at init time, e.g.
#
#   terraform init -backend-config=backend/prototype.hcl
# -----------------------------------------------------------------------------
terraform {
  # 1.11 is the floor of the AVM Key Vault and managed-cluster modules, which
  # use write-only arguments.
  required_version = ">= 1.11.0"

  backend "azurerm" {}

  required_providers {
    # Pinned to the 4.x line, not 5.x: the AVM modules this stack is built from
    # declare `azurerm < 5.0.0` (managed identity, SQL server, Log Analytics),
    # and 4.81.0 is both the newest release in that line and the floor the AVM
    # Key Vault module asks for. Move to 5.x when every module below has.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.81.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "= 2.12.0"
    }
    # AVM modules report anonymous deployment telemetry through this provider.
    # It is declared here so the version is pinned in this stack's lock file
    # like every other provider; var.enable_telemetry turns the reporting off.
    modtm = {
      source  = "Azure/modtm"
      version = "= 0.3.5"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.0"
    }
    # AVM modules use `time_sleep` to wait for RBAC propagation before the
    # data-plane operations that follow a role assignment.
    time = {
      source  = "hashicorp/time"
      version = "= 0.14.1"
    }
    # Kargo's admission webhooks are served over TLS the API server has to
    # trust, and this platform runs no cert-manager (docs/architecture.md).
    # The certificate is minted here instead (kargo.tf).
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.1.0"
    }
  }
}
