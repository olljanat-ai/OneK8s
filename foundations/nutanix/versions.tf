# -----------------------------------------------------------------------------
# Nutanix foundation: an NKP workload cluster + HashiCorp Vault ("vault") pair
# — the platform's private cloud.
#
# The pairing is the same one the four public clouds have, with private-cloud
# parts: NKP (Nutanix Kubernetes Platform, Starter edition, included with the
# Nutanix licence) is the cluster, and a HashiCorp Vault KV v2 mount is the
# secret backend. What replaces cloud IAM is the mechanism the public clouds
# themselves use: the cluster is an OIDC provider, Vault is registered as a
# relying party on its published keys, and a tenant's ServiceAccount token is
# federated into a Vault token whose policy grants exactly that tenant's path
# prefix. See docs/nutanix.md.
#
# State lives in the shared Azure Storage state home, not on-prem — see
# docs/architecture.md. Azure credentials are therefore needed alongside the
# NKP and Vault ones. The backend block is left partial on purpose: pass the
# per-environment settings at init time, e.g.
#
#   terraform init -backend-config=backend/prototype.hcl
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "azurerm" {}

  required_providers {
    # No nutanix provider: NKP owns the cluster's lifecycle and is driven
    # through its own Kubernetes API (Cluster API), so everything this stack
    # does on the Nutanix side is an object in that API.
    # Two configurations, declared in providers.tf: the default one is the
    # workload cluster this stack builds the platform on, "nkp" is the NKP
    # management cluster it is created from and read back through.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "= 5.11.0"
    }
    # Reads one unauthenticated endpoint of the cluster's own API server: the
    # OIDC discovery document that says which issuer its tokens carry.
    http = {
      source  = "hashicorp/http"
      version = "= 3.6.1"
    }
  }
}
