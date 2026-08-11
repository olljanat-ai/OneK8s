provider "azurerm" {
  features {}
}

provider "azapi" {}

# Cluster credentials come from the foundation's cluster, looked up live so
# this stack never stores kubeconfig material in its own state inputs.
data "azurerm_kubernetes_cluster" "this" {
  name                = data.terraform_remote_state.foundation.outputs.cluster_name
  resource_group_name = data.terraform_remote_state.foundation.outputs.resource_group_name
}

provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.this.kube_config[0].host
  client_certificate     = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
  client_key             = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
}
