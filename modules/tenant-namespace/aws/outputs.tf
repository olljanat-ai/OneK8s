output "namespace" {
  description = "The tenant namespace name."
  value       = module.common.namespace
}

output "service_account_name" {
  description = "The tenant workload ServiceAccount name."
  value       = module.common.service_account_name
}

output "iam_role_arn" {
  description = "ARN of the tenant's IAM role (IRSA)."
  value       = aws_iam_role.tenant.arn
}

output "secret_prefix" {
  description = "Secrets Manager name prefix this tenant is allowed to read."
  value       = local.secret_prefix
}

output "secret_store_name" {
  description = "Name of the tenant's namespaced SecretStore."
  value       = module.common.secret_store_name
}
