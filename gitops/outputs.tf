locals {
  spoke_modules = {
    aws = module.spoke_aws
    gcp = module.spoke_gcp
    oci = module.spoke_oci
  }
}

output "hub_url" {
  description = "Public URL of the Argo CD hub the spokes are attached to."
  value       = try(local.hub.argocd_url, null)
}

output "principal" {
  description = "The argocd-agent principal every spoke's agent dials, and the one endpoint in this topology that has to be reachable from outside a cluster's own network. Null when the hub was applied without it."
  value = local.hub_wired && try(local.hub.argocd_agent_enabled, false) ? {
    address              = local.principal.address
    port                 = local.principal.port
    namespace            = local.principal.namespace
    resource_proxy       = local.principal.resource_proxy_address
    label_selector       = local.principal.label_selector
    agent_chart_version  = var.agent_chart_version
    spoke_argocd_version = var.spoke_argocd_chart_version
  } : null
}

output "clouds" {
  description = "Clouds attached as spokes in this environment."
  value       = sort([for c in local.spoke_clouds : c if local.active[c]])
}

output "root_application" {
  description = "The Argo CD root Application this stack plants on the hub, and the repositories it hands the rest of the delivery plane over to: repo_url holds the Argo CD objects, apps_repo_url the application charts they deploy. Null when platform applications are disabled or the hub has no Argo CD."
  value = local.platform_apps_enabled ? {
    name           = var.platform_apps.name
    namespace      = local.argocd_namespace
    repo_url       = var.platform_apps.repo_url
    revision       = var.platform_apps.target_revision
    path           = var.platform_apps.path
    apps_repo_url  = var.platform_apps.apps_repo_url
    apps_revision  = var.platform_apps.apps_target_revision
    tenant         = var.platform_apps.tenant
    url            = "${try(local.hub.argocd_url, "")}/applications/${var.platform_apps.name}"
    argocd_project = var.platform_apps.project
  } : null
}

output "application_host_pattern" {
  description = "How the applications Argo CD deploys are published: one host per cluster, one label deep under the platform wildcard. Which applications exist, and on which clusters, is the delivery-plane repository's business rather than this stack's — the 'hello' example is staging on Azure (https://azure-hello.onek8s.lol) and production on AWS (https://aws-hello.onek8s.lol). The A records are created out of band, like every other host here."
  value       = local.platform_apps_enabled ? "<cloud>-<app>.${var.platform_apps.domain}" : null
}

output "spokes" {
  description = "Per-spoke results, keyed by cloud (identical shape for every cloud). No credential is exported — each agent's client certificate stays in the Secret on its own cluster. Note that \"server\" is the hub's resource proxy rather than the spoke's API endpoint: the hub no longer knows how to reach the spoke, and does not need to."
  value = merge([
    for cloud, instances in local.spoke_modules : {
      for key, s in instances : key => {
        cloud       = cloud
        name        = s.name
        server      = s.server
        secret_name = s.secret_name
        agent       = s.agent
        argocd      = s.argocd
        scope       = s.scope
        labels      = s.labels
      }
    }
  ]...)
}
