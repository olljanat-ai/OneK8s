# Authentication: use environment variables (ARM_CLIENT_ID, ARM_TENANT_ID,
# ARM_SUBSCRIPTION_ID, ARM_USE_OIDC=true) so that GitHub Actions can log in
# with OIDC and no long-lived secrets. Locally, `az login` works too.
provider "azurerm" {
  features {
    key_vault {
      # Never leave soft-deleted vaults behind in dev/test churn, but keep the
      # safety net in prod (purge protection is enabled on the vault itself).
      purge_soft_delete_on_destroy = false
    }
  }
}

provider "azapi" {}

# Helm talks to the AKS cluster we create in this same stack. Local accounts
# are enabled on the cluster specifically so that CI can bootstrap add-ons
# (ESO) without a separate Entra ID login dance.
provider "helm" {
  kubernetes = {
    host                   = azurerm_kubernetes_cluster.this.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
  }
}
