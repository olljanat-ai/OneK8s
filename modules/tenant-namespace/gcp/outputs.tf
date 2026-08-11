output "namespace" {
  description = "The tenant namespace name."
  value       = module.common.namespace
}

output "service_account_name" {
  description = "The tenant workload ServiceAccount name."
  value       = module.common.service_account_name
}

output "gsa_email" {
  description = "Email of the tenant's Google Service Account."
  value       = google_service_account.tenant.email
}

output "secret_prefix" {
  description = "Secret Manager secret ID prefix this tenant is allowed to read."
  value       = local.secret_prefix
}

output "secret_store_name" {
  description = "Name of the tenant's namespaced SecretStore."
  value       = module.common.secret_store_name
}
