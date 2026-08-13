locals {
  spoke_modules = merge(module.spoke_aws, module.spoke_gcp, module.spoke_oci)

  # Placeholder rather than an error: these feed the two "here is the command
  # you still have to run" outputs, which should stay printable even when the
  # hub foundation is what is missing.
  hub_resource_group = try(local.foundation.azure.resource_group_name, "<azure-foundation-not-deployed>")
  hub_cluster_name   = try(local.foundation.azure.cluster_name, "<azure-foundation-not-deployed>")
  hub_cluster_id     = try(local.foundation.azure.cluster_id, "<azure-foundation-not-deployed>")
}

output "principal_endpoint" {
  description = "Address every agent dials to reach the hub. The only endpoint in this topology that has to be reachable from outside its own cluster."
  value       = "${local.principal_address}:${var.principal_port}"
}

output "principal_fqdn" {
  description = "FQDN AKS assigns the principal's load balancer from its DNS label. Point your own name at this if you would rather agents dialled something like argocd-agent.onek8s.lol."
  value       = local.principal_fqdn
}

output "agents" {
  description = "Registered agents, keyed by cloud. \"name\" is what an Application targets with spec.destination.name."
  value = {
    for cloud, agent in local.agents : cloud => {
      name      = agent.name
      mode      = agent.mode
      namespace = local.spoke_modules[cloud].namespace
      cluster   = "cluster-${agent.name}"
    }
  }
}

output "ca_certificate_pem" {
  description = "The argocd-agent CA certificate. Not a secret — it is what agents verify the principal against, and it is already on every spoke."
  value       = tls_self_signed_cert.ca.cert_pem
}

output "certificate_expiry" {
  description = "Expiry of every certificate this stack issues. Leaves are reissued on apply once they are inside certificate_renewal_days of expiry; the CA is not, and rotating it means reissuing everything below it."
  value = merge(
    {
      ca             = tls_self_signed_cert.ca.validity_end_time
      principal      = tls_locally_signed_cert.principal.validity_end_time
      resource_proxy = tls_locally_signed_cert.resource_proxy.validity_end_time
      redis_proxy    = tls_locally_signed_cert.redis_proxy.validity_end_time
    },
    { for cloud, cert in tls_locally_signed_cert.agent : "agent-${local.agents[cloud].name}" => cert.validity_end_time },
  )
}

output "hub_extension_command" {
  description = "The extension update this stack needs but does not apply while manage_hub_extension is false. Run it once; without it the hub's UI cannot render live resources for spoke applications."
  value = join(" ", concat(
    [
      "az k8s-extension update",
      "--resource-group ${local.hub_resource_group}",
      "--cluster-name ${local.hub_cluster_name}",
      "--cluster-type managedClusters",
      "--name ${var.hub_extension_name}",
    ],
    [for k, v in local.hub_extension_required_settings : "--config \"${k}=${v}\""],
  ))
}

output "hub_extension_import" {
  description = "How to bring the existing AKS Argo CD extension under Terraform, which is what setting manage_hub_extension = true requires first."
  value       = "terraform import azurerm_kubernetes_cluster_extension.argocd[0] ${local.hub_cluster_id}/providers/Microsoft.KubernetesConfiguration/extensions/${var.hub_extension_name}"
}
