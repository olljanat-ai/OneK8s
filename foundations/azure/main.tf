locals {
  name = "${var.name_prefix}-${var.environment}"

  tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    stack       = "foundations-azure"
  })
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 4, 0)]

  # The service endpoint is what lets sql.tf allow this subnet on the logical
  # server by name instead of by public IP address. Nothing else on the
  # cluster needs it, so it follows enable_sql rather than being always-on.
  dynamic "service_endpoint" {
    for_each = var.enable_sql ? ["Microsoft.Sql"] : []

    content {
      service = service_endpoint.value
    }
  }
}
