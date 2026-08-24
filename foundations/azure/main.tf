locals {
  name = "${var.name_prefix}-${var.environment}"

  tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    stack       = "foundations-azure"
  })

  # The one subnet this stack owns. Read through the module's output rather
  # than rebuilt from strings, so a rename of the subnet key is a compile-time
  # error instead of a resource ID that resolves to nothing.
  aks_subnet_id = module.virtual_network.subnets["aks"].resource_id
}

data "azurerm_client_config" "current" {}

# --- Resource group ----------------------------------------------------------
module "resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "0.4.0"

  name             = "rg-${local.name}"
  location         = var.location
  enable_telemetry = var.enable_telemetry
  tags             = local.tags
}

# --- Network -----------------------------------------------------------------
# One VNet, one subnet for the cluster. The module takes the resource group by
# resource ID (`parent_id`) rather than by name, and owns its subnets as part
# of the same resource — which is what keeps a subnet edit from racing the
# VNet's own read-modify-write.
#
# `default_outbound_access_enabled` is left at the module's default of false.
# Azure is retiring implicit outbound access for new subnets anyway, and the
# nodes do not use it: egress goes through the cluster's standard load
# balancer (`outbound_type = loadBalancer`, aks.tf).
module "virtual_network" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.22.1"

  name             = "vnet-${local.name}"
  location         = var.location
  parent_id        = module.resource_group.resource_id
  address_space    = [var.vnet_cidr]
  enable_telemetry = var.enable_telemetry
  tags             = local.tags

  subnets = {
    aks = {
      name             = "snet-aks"
      address_prefixes = [cidrsubnet(var.vnet_cidr, 4, 0)]

      # The service endpoints are what let another resource allow this subnet
      # by name instead of by public IP address: Microsoft.Sql for the logical
      # server in sql.tf, Microsoft.KeyVault for the vault firewall an
      # environment turns on with var.key_vault_network_acls. Both follow the
      # feature that needs them rather than being always-on.
      service_endpoints = toset(compact([
        var.enable_sql ? "Microsoft.Sql" : "",
        var.key_vault_network_acls != null ? "Microsoft.KeyVault" : "",
      ]))
    }
  }
}
