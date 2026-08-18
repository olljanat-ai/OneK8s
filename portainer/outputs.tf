locals {
  agent_modules = {
    aws = module.agent_aws
    /*
    gcp = module.agent_gcp
    oci = module.agent_oci
    */
  }
}

output "portainer_url" {
  description = "Public URL of the Portainer server the environments are registered with, and the address every agent polls."
  value       = local.portainer_url
}

output "edge_tunnel" {
  description = "Address the agents open their reverse tunnel to. Null when the hub publishes no tunnel, in which case environments connect but cannot be browsed."
  value       = try(local.hub.portainer_edge_tunnel, null)
}

output "clouds" {
  description = "Clouds onboarded into Portainer in this environment. Azure is not among them by design: Portainer runs on that cluster and manages it directly."
  value       = sort([for c in local.agent_clouds : c if local.wired[c]])
}

output "environments" {
  description = "Per-cloud registration results (identical shape for every cloud). No Edge key is exported — it is written straight into the agent's cluster Secret and never leaves this run."
  value = merge([
    for cloud, instances in local.agent_modules : {
      for key, a in instances : key => {
        cloud          = cloud
        environment_id = portainer_environment.agent[key].id
        name           = portainer_environment.agent[key].name
        edge_id        = a.edge_id
        namespace      = a.namespace
        deployment     = a.deployment
        cluster_role   = a.service_account.role
        url            = "${local.portainer_url}/#!/${portainer_environment.agent[key].id}/kubernetes/dashboard"
      }
    }
  ]...)
}
