# Shared Azure Managed Redis for the cluster: one instance per cluster,
# consumed by tenants that opt in with `redis_enabled = true`. Data-plane
# access is Entra ID only (access keys disabled); per-tenant delegation is an
# access policy assignment for the tenant's managed identity
# (see modules/tenant-namespace/azure).
#
# Azure Managed Redis is the Microsoft.Cache/redisEnterprise resource type
# with the new AMR SKUs (Balanced_*, MemoryOptimized_*, ...); azurerm has no
# first-class resource for it yet, so azapi is used — same as the AKS managed
# namespaces.
resource "random_string" "redis_suffix" {
  length  = 4
  special = false
  upper   = false
}

resource "azapi_resource" "redis" {
  type = "Microsoft.Cache/redisEnterprise@${var.managed_redis_api_version}"
  # AMR names become a public DNS label, so they are globally unique.
  name      = "redis-${local.name}-${random_string.redis_suffix.result}"
  parent_id = azurerm_resource_group.this.id
  location  = azurerm_resource_group.this.location
  tags      = local.tags

  body = {
    sku = {
      name = var.redis_sku
    }
    properties = {
      minimumTlsVersion = "1.2"
    }
  }

  response_export_values = ["properties.hostName"]
}

resource "azapi_resource" "redis_default_db" {
  type      = "Microsoft.Cache/redisEnterprise/databases@${var.managed_redis_api_version}"
  name      = "default"
  parent_id = azapi_resource.redis.id

  body = {
    properties = {
      clientProtocol = "Encrypted"
      # Single-endpoint mode: standard (non-cluster) Redis clients work.
      clusteringPolicy = "EnterpriseCluster"
      evictionPolicy   = "NoEviction"
      # Entra ID only — no shared access keys to leak or rotate. Tenants
      # authenticate with their workload identity via an access policy
      # assignment created by the tenant module.
      accessKeysAuthentication = "Disabled"
    }
  }

  response_export_values = ["properties.port"]
}
