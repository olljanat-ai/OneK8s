output "namespace" {
  description = "The tenant namespace name."
  value       = module.common.namespace
}

output "service_account_name" {
  description = "The tenant workload ServiceAccount name."
  value       = module.common.service_account_name
}

output "workload_principal" {
  description = "The tenant's OCI workload identity — the (cluster, namespace, service account) tuple its IAM policy matches on."
  value       = "workload:${var.cluster_id}:${module.common.namespace}:${module.common.service_account_name}"
}

output "policy_id" {
  description = "OCID of the IAM policy granting this tenant its prefix-scoped vault access."
  value       = oci_identity_policy.tenant_secrets.id
}

output "secret_prefix" {
  description = "Vault secret name prefix this tenant is allowed to read."
  value       = local.secret_prefix
}

output "secret_store_name" {
  description = "Name of the tenant's namespaced SecretStore."
  value       = module.common.secret_store_name
}
