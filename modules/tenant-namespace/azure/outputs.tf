output "namespace" {
  description = "The tenant namespace name."
  value       = module.common.namespace
}

output "service_account_name" {
  description = "The tenant workload ServiceAccount name."
  value       = module.common.service_account_name
}

output "identity_client_id" {
  description = "Client ID of the tenant's user-assigned managed identity."
  value       = azurerm_user_assigned_identity.tenant.client_id
}

output "identity_principal_id" {
  description = "Principal (object) ID of the tenant's managed identity."
  value       = azurerm_user_assigned_identity.tenant.principal_id
}

output "secret_prefix" {
  description = "Key Vault secret name prefix this tenant is allowed to read."
  value       = local.secret_prefix
}

output "secret_store_name" {
  description = "Name of the tenant's namespaced SecretStore."
  value       = module.common.secret_store_name
}

output "redis_endpoint" {
  description = "host:port of the shared Managed Redis, or null when the tenant has no Redis access."
  value       = var.redis_enabled ? "${var.redis_hostname}:${var.redis_port}" : null
}
