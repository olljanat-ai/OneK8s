# Unified outputs: same shape regardless of cloud.
output "namespace" {
  description = "The tenant namespace name."
  value = coalesce(
    one(module.azure[*].namespace),
    one(module.aws[*].namespace),
    // one(module.gcp[*].namespace),
    // one(module.oci[*].namespace),
  )
}

output "service_account_name" {
  description = "The tenant workload ServiceAccount name."
  value = coalesce(
    one(module.azure[*].service_account_name),
    one(module.aws[*].service_account_name),
    // one(module.gcp[*].service_account_name),
    // one(module.oci[*].service_account_name),
  )
}

output "identity" {
  description = "The tenant's cloud identity: UAMI client ID (azure), IAM role ARN (aws), GSA email (gcp) or workload principal tuple (oci)."
  value = coalesce(
    one(module.azure[*].identity_client_id),
    one(module.aws[*].iam_role_arn),
    // one(module.gcp[*].gsa_email),
    // one(module.oci[*].workload_principal),
  )
}

output "secret_prefix" {
  description = "Secret name prefix this tenant is allowed to read in the shared backend."
  value = coalesce(
    one(module.azure[*].secret_prefix),
    one(module.aws[*].secret_prefix),
    // one(module.gcp[*].secret_prefix),
    // one(module.oci[*].secret_prefix),
  )
}

output "secret_store_name" {
  description = "Name of the tenant's namespaced SecretStore."
  value = coalesce(
    one(module.azure[*].secret_store_name),
    one(module.aws[*].secret_store_name),
    // one(module.gcp[*].secret_store_name),
    // one(module.oci[*].secret_store_name),
  )
}
