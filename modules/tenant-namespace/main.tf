# Dispatcher: exactly one cloud-specific implementation is instantiated,
# selected by var.cloud. Arguments of unselected branches are not evaluated,
# so var.foundation only needs the keys of the selected cloud.
module "azure" {
  source = "./azure"
  count  = var.cloud == "azure" ? 1 : 0

  tenant_name          = var.tenant_name
  environment          = var.environment
  resource_group_name  = var.foundation.resource_group_name
  location             = var.foundation.location
  aks_cluster_id       = var.foundation.cluster_id
  oidc_issuer_url      = var.foundation.oidc_issuer_url
  key_vault_id         = var.foundation.key_vault_id
  key_vault_uri        = var.foundation.key_vault_uri
  quota                = var.quota
  network_policy       = var.network_policy
  limit_range          = var.limit_range
  namespace_labels     = var.namespace_labels
  service_account_name = var.service_account_name

  # try(): foundations deployed before the Redis feature lack these outputs;
  # they are only required when redis_enabled = true (preconditions enforce it).
  redis_enabled     = var.redis_enabled
  redis_database_id = try(var.foundation.managed_redis_database_id, null)
  redis_hostname    = try(var.foundation.managed_redis_hostname, null)
  redis_port        = try(var.foundation.managed_redis_port, null)
}

module "aws" {
  source = "./aws"
  count  = var.cloud == "aws" ? 1 : 0

  tenant_name          = var.tenant_name
  environment          = var.environment
  oidc_issuer_url      = var.foundation.oidc_issuer_url
  oidc_provider_arn    = var.foundation.oidc_provider_arn
  region               = var.foundation.region
  account_id           = var.foundation.account_id
  secrets_kms_key_arn  = var.foundation.secrets_kms_key_arn
  quota                = var.quota
  network_policy       = var.network_policy
  limit_range          = var.limit_range
  namespace_labels     = var.namespace_labels
  service_account_name = var.service_account_name

  redis_enabled          = var.redis_enabled
  redis_arn              = try(var.foundation.redis_arn, null)
  redis_user_group_id    = try(var.foundation.redis_user_group_id, null)
  redis_endpoint_address = try(var.foundation.redis_endpoint_address, null)
  redis_endpoint_port    = try(var.foundation.redis_endpoint_port, null)
}

module "gcp" {
  source = "./gcp"
  count  = var.cloud == "gcp" ? 1 : 0

  tenant_name          = var.tenant_name
  environment          = var.environment
  project_id           = var.foundation.project_id
  project_number       = var.foundation.project_number
  cluster_name         = var.foundation.cluster_name
  cluster_location     = var.foundation.cluster_location
  quota                = var.quota
  network_policy       = var.network_policy
  limit_range          = var.limit_range
  namespace_labels     = var.namespace_labels
  service_account_name = var.service_account_name

  redis_enabled          = var.redis_enabled
  redis_cluster_name     = try(var.foundation.redis_cluster_name, null)
  redis_cluster_location = try(var.foundation.redis_cluster_location, null)
  redis_host             = try(var.foundation.redis_host, null)
  redis_port             = try(var.foundation.redis_port, null)
}
