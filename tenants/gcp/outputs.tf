output "tenants" {
  description = "Per-tenant onboarding results."
  value = {
    for name, t in module.tenant : name => {
      namespace       = t.namespace
      service_account = t.service_account_name
      gsa_email       = t.gsa_email
      secret_prefix   = t.secret_prefix
      secret_store    = t.secret_store_name
    }
  }
}
