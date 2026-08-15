locals {
  spoke_modules = {
    aws     = module.spoke_aws
    gcp     = module.spoke_gcp
    oci     = module.spoke_oci
    nutanix = module.spoke_nutanix
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

output "root_application" {
  description = "The Argo CD root Application this stack plants on the hub, and the repository path it hands the rest of the delivery plane over to. Null when platform applications are disabled or the hub has no Argo CD."
  value = local.platform_apps_enabled ? {
    name           = var.platform_apps.name
    namespace      = local.argocd_namespace
    repo_url       = var.platform_apps.repo_url
    revision       = var.platform_apps.target_revision
    path           = var.platform_apps.path
    tenant         = var.platform_apps.tenant
    url            = "${try(local.hub.argocd_url, "")}/applications/${var.platform_apps.name}"
    argocd_project = var.platform_apps.project
  } : null
}

output "application_host_pattern" {
  description = "How the applications Argo CD deploys are published: one host per cluster, one label deep under the platform wildcard. Which applications exist is gitops/argocd/values.yaml's business, not this stack's — 'hello' on all five clouds is https://azure-hello.onek8s.lol, https://aws-hello.onek8s.lol and so on. The A records are created out of band, like every other host here."
  value       = local.platform_apps_enabled ? "<cloud>-<app>.${var.platform_apps.domain}" : null
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
