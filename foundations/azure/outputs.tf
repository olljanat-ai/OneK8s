# Everything the tenants stack needs is exported here and consumed through
# terraform_remote_state — the dependency direction is strictly
# foundations -> tenants.
output "resource_group_name" {
  description = "Resource group containing the cluster and vault."
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Azure region."
  value       = azurerm_resource_group.this.location
}

output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  description = "AKS cluster resource ID (parent for azapi managed namespaces)."
  value       = azurerm_kubernetes_cluster.this.id
}

output "oidc_issuer_url" {
  description = "AKS OIDC issuer URL for workload identity federation."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "key_vault_id" {
  description = "Resource ID of the shared Key Vault."
  value       = azurerm_key_vault.this.id
}

output "key_vault_uri" {
  description = "Vault URI of the shared Key Vault."
  value       = azurerm_key_vault.this.vault_uri
}

output "managed_redis_id" {
  description = "Resource ID of the shared Azure Managed Redis cluster."
  value       = azapi_resource.redis.id
}

output "managed_redis_database_id" {
  description = "Resource ID of the Managed Redis default database (parent for tenant access policy assignments)."
  value       = azapi_resource.redis_default_db.id
}

output "managed_redis_hostname" {
  description = "Hostname of the shared Azure Managed Redis instance."
  value       = azapi_resource.redis.output.properties.hostName
}

output "managed_redis_port" {
  description = "TLS port of the Managed Redis default database."
  value       = azapi_resource.redis_default_db.output.properties.port
}

output "environment" {
  description = "Environment this foundation was deployed for."
  value       = var.environment
}
