# Everything the tenants stack needs is exported here and consumed through
# terraform_remote_state — the dependency direction is strictly
# foundations -> tenants.
output "resource_group_name" {
  description = "Resource group containing the cluster and vault."
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Azure region."
  value       = azurerm_resource_group.this.location
}

output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  description = "AKS cluster resource ID (parent for azapi managed namespaces)."
  value       = azurerm_kubernetes_cluster.this.id
}

output "oidc_issuer_url" {
  description = "AKS OIDC issuer URL for workload identity federation."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "key_vault_id" {
  description = "Resource ID of the shared Key Vault."
  value       = azurerm_key_vault.this.id
}

output "key_vault_uri" {
  description = "Vault URI of the shared Key Vault."
  value       = azurerm_key_vault.this.vault_uri
}

output "argocd_url" {
  description = "Public URL of the Argo CD UI (null when the extension is disabled)."
  value       = var.enable_argocd ? local.argocd_url : null
}

output "ingress_class_name" {
  description = "IngressClass of the application routing add-on, for platform services published on this cluster."
  value       = local.ingress_class_name
}

output "ingress_certificate_uri" {
  description = "Version-less Key Vault certificate URI to annotate ingresses with (kubernetes.azure.com/tls-cert-keyvault-uri)."
  value       = local.ingress_certificate_uri
}

output "environment" {
  description = "Environment this foundation was deployed for."
  value       = var.environment
}
