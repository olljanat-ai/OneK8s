output "namespace" {
  description = "Namespace the Flux configuration and its flux-applier ServiceAccount live in. The extension itself is always in flux-system."
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
  description = "Name of the GitRepository object in the cluster. Azure names it after the configuration, and the delivery-plane repository's Kustomizations name it as their sourceRef, so the two have to agree."
  value       = azurerm_kubernetes_flux_configuration.this.name
}

output "cluster_vars" {
  description = "The facts this cluster hands to every manifest in the delivery-plane repository through postBuild substitution. Nothing here is a secret: names, a domain and a key prefix, and they authorize nobody."
  value       = module.cluster_vars.cluster_vars
}

output "tenant" {
  description = "Tenant namespace the applications are released into."
  value       = var.tenant
}

output "install" {
  description = "How Flux got onto this cluster: the Azure-managed extension, as opposed to the community chart modules/fluxcd installs on the other clouds."
  value       = "microsoft.flux extension (${var.release_train} train)"
}

output "multi_tenancy_enforced" {
  description = "Whether the extension's multi-tenancy is enforced — sources may not be referenced across namespaces, and the controllers deploy as the flux-applier ServiceAccount rather than as themselves."
  value       = var.enforce_multi_tenancy
}

output "application_host_pattern" {
  description = "How the applications Flux deploys are published on this cluster: one label deep under the platform wildcard. The A records are created out of band, like every other host here."
  value       = "azure-<app>.${var.domain}"
}
