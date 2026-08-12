# Unified outputs: same shape regardless of cloud.
output "namespace" {
  description = "The tenant namespace name."
  value = coalesce(
    one(module.azure[*].namespace),
    one(module.aws[*].namespace),
    one(module.gcp[*].namespace),
  )
}

output "service_account_name" {
  description = "The tenant workload ServiceAccount name."
  value = coalesce(
    one(module.azure[*].service_account_name),
    one(module.aws[*].service_account_name),
    one(module.gcp[*].service_account_name),
  )
}

output "identity" {
  description = "The tenant's cloud identity: UAMI client ID (azure), IAM role ARN (aws) or GSA email (gcp)."
  value = coalesce(
    one(module.azure[*].identity_client_id),
    one(module.aws[*].iam_role_arn),
    one(module.gcp[*].gsa_email),
  )
}

output "secret_prefix" {
  description = "Secret name prefix this tenant is allowed to read in the shared backend."
  value = coalesce(
    one(module.azure[*].secret_prefix),
    one(module.aws[*].secret_prefix),
    one(module.gcp[*].secret_prefix),
  )
}

# one(concat()) instead of coalesce(): the value is legitimately null when
# the tenant has no Redis access.
output "redis_endpoint" {
  description = "host:port of the shared managed Redis, or null when redis_enabled is false."
  value = one(concat(
    module.azure[*].redis_endpoint,
    module.aws[*].redis_endpoint,
    module.gcp[*].redis_endpoint,
  ))
}

output "secret_store_name" {
  description = "Name of the tenant's namespaced SecretStore."
  value = coalesce(
    one(module.azure[*].secret_store_name),
    one(module.aws[*].secret_store_name),
    one(module.gcp[*].secret_store_name),
  )
}
