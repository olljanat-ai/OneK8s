output "cloud" {
  description = "Cloud these tenants were deployed to."
  value       = var.cloud
}

output "tenants" {
  description = "Per-tenant onboarding results (identical shape for every cloud)."
  value = {
    for name, t in module.tenant : name => {
      namespace       = t.namespace
      service_account = t.service_account_name
      identity        = t.identity
      secret_prefix   = t.secret_prefix
      secret_store    = t.secret_store_name
      redis_endpoint  = t.redis_endpoint
    }
  }
}
