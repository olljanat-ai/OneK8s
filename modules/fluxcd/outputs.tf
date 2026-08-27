output "namespace" {
  description = "Namespace Flux runs in on this cluster."
  value       = var.namespace
}

output "repo_url" {
  description = "The delivery-plane repository this cluster reconciles."
  value       = var.repo_url
}

output "branch" {
  description = "Branch of that repository this cluster follows."
  value       = var.branch
}

output "cluster_path" {
  description = "Path in the delivery-plane repository that holds this cluster's objects — the only path Terraform points Flux at."
  value       = local.cluster_path
}

output "source_name" {
  description = "Name of the GitRepository the bootstrap creates. The delivery-plane repository's Kustomizations name it as their sourceRef, so the two have to agree."
  value       = helm_release.sync.name
}

output "cluster_vars" {
  description = "The facts this cluster hands to every manifest in the delivery-plane repository through postBuild substitution. Nothing here is a secret: they are names, a domain and a key prefix, and they authorize nobody."
  value       = local.cluster_vars
}

output "tenant" {
  description = "Tenant namespace the applications are released into."
  value       = var.tenant
}

output "application_host_pattern" {
  description = "How the applications Flux deploys are published on this cluster: one label deep under the platform wildcard. The A records are created out of band, like every other host here."
  value       = "${var.cloud}-<app>.${var.domain}"
}
