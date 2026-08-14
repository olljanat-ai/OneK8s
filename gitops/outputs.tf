locals {
  spoke_modules = {
    aws = module.spoke_aws
    gcp = module.spoke_gcp
    oci = module.spoke_oci
  }
}

output "hub_url" {
  description = "Public URL of the Argo CD hub the spokes are registered with."
  value       = try(local.hub.argocd_url, null)
}

output "clouds" {
  description = "Clouds registered as spokes in this environment."
  value       = sort([for c in local.spoke_clouds : c if local.active[c]])
}

output "spokes" {
  description = "Per-spoke registration results, keyed by cloud (identical shape for every cloud). No credential is exported — the bearer token stays in the cluster Secret."
  value = merge([
    for cloud, instances in local.spoke_modules : {
      for key, s in instances : key => {
        cloud           = cloud
        name            = s.name
        server          = s.server
        secret_name     = s.secret_name
        service_account = s.service_account
        scope           = s.scope
        labels          = s.labels
      }
    }
  ]...)
}
