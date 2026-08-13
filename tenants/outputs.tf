locals {
  tenant_modules = {
    azure = module.tenants_azure
    aws   = module.tenants_aws
    gcp   = module.tenants_gcp
    oci   = module.tenants_oci
  }
}

output "clouds" {
  description = "Clouds this environment currently has tenants on."
  value       = sort([for c in local.clouds : c if local.active[c]])
}

output "tenants" {
  description = "Per-tenant onboarding results, keyed like var.tenants (identical shape for every cloud)."
  value = merge([
    for cloud, instances in local.tenant_modules : {
      for key, t in instances : key => {
        cloud           = cloud
        namespace       = t.namespace
        service_account = t.service_account_name
        identity        = t.identity
        secret_prefix   = t.secret_prefix
        secret_store    = t.secret_store_name
      }
    }
  ]...)
}
