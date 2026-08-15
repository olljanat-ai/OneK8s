output "namespace" {
  description = "The tenant namespace name."
  value       = module.common.namespace
}

output "service_account_name" {
  description = "The tenant workload ServiceAccount name."
  value       = module.common.service_account_name
}

output "vault_role" {
  description = "The tenant's Vault identity — the role its ServiceAccount federates into, as <auth mount>/<role>."
  value       = "${var.vault_auth_path}/${vault_jwt_auth_backend_role.tenant.role_name}"
}

output "subject" {
  description = "The 'sub' claim this tenant's tokens carry and its Vault role pins — the same string the other clouds' trust policies name."
  value       = local.subject
}

output "vault_policy" {
  description = "Name of the Vault policy granting this tenant its prefix-scoped read access."
  value       = vault_policy.tenant.name
}

output "secret_prefix" {
  description = "Secret name prefix this tenant is allowed to read in the shared KV v2 mount."
  value       = local.secret_prefix
}

output "secret_store_name" {
  description = "Name of the tenant's namespaced SecretStore."
  value       = module.common.secret_store_name
}
