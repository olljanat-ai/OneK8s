output "namespace" {
  description = "The tenant namespace name."
  value       = local.namespace
}

output "service_account_name" {
  description = "The tenant workload ServiceAccount name."
  value       = kubernetes_service_account_v1.workload.metadata[0].name
}

output "secret_store_name" {
  description = "Name of the tenant's namespaced SecretStore."
  value       = "tenant-store"
}
