# AKS cluster with:
#  - OIDC issuer + Workload Identity (tenant identities federate against it,
#    and so does the platform's own ingress identity)
#  - Azure CNI overlay with the Cilium data plane
#  - Azure Policy add-on for guardrails
#
# No managed add-on reads the vault or serves HTTP: secrets come through
# External Secrets and ingress through Traefik, the same two components every
# other cloud runs (eso.tf, ingress.tf).
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = local.name
  kubernetes_version  = var.kubernetes_version

  node_provisioning_profile {
    default_node_pools = "None"
    mode               = "Auto"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  azure_policy_enabled      = true

  # Local accounts stay enabled so this stack's Helm provider can bootstrap
  # add-ons with the cluster client certificate. Human access should go
  # through Entra ID; tighten with AAD-only + kubelogin once a break-glass
  # path exists for CI.
  local_account_disabled = false

  default_node_pool {
    name                        = "system"
    node_count                  = var.system_node_count
    vm_size                     = var.system_node_vm_size
    vnet_subnet_id              = azurerm_subnet.aks.id
    temporary_name_for_rotation = "systemtmp"
    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    pod_cidr            = var.pod_cidr
    load_balancer_sku   = "standard"
  }

  tags = local.tags
}
