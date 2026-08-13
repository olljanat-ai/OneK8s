# AKS cluster with:
#  - OIDC issuer + Workload Identity (tenant identities federate against it)
#  - Azure CNI overlay with the Cilium data plane
#  - Azure Policy add-on for guardrails
#  - Secrets Store CSI driver + application routing, which together put a
#    Key Vault certificate on the platform ingress (see argocd.tf)
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

  # Secrets Store CSI driver with the Key Vault provider. The application
  # routing add-on mounts the ingress certificate through it, so the private
  # key travels Key Vault -> kubelet and never lands in Terraform state.
  # Rotation is polled (default interval 2m), which is what lets the Renew
  # Certificate workflow replace the wildcard without an apply here.
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  # Application routing add-on: the AKS-managed NGINX ingress controller that
  # fronts platform services (Argo CD today). Zones listed in
  # var.ingress_dns_zone_ids are handed to the add-on's external-dns, which
  # then keeps a record per Ingress host of its class; an empty list leaves
  # DNS out of band. The zones live outside this stack (they are shared with
  # the Renew Certificate workflow's DNS-01 challenge), so they are
  # configuration, not a resource here — argocd.tf grants the add-on's
  # identity the rights to write them.
  web_app_routing {
    dns_zone_ids = var.ingress_dns_zone_ids
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
