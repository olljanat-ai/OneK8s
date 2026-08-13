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
  description = "IngressClass of the Traefik ingress controller (the cluster default), null when ingress is disabled."
  value       = var.enable_ingress ? local.ingress_class_name : null
}

output "ingress_namespace" {
  description = "Namespace the ingress controller runs in; tenant NetworkPolicies allow ingress from it."
  value       = var.enable_ingress ? local.ingress_namespace : null
}

output "ingress_default_certificate_secret" {
  description = "TLS secret in the ingress namespace that Traefik serves for hosts without a certificate of their own — the platform wildcard, synced from Key Vault by the Secrets Store CSI driver."
  value       = var.enable_ingress ? local.ingress_tls_secret_name : null
}

output "environment" {
  description = "Environment this foundation was deployed for."
  value       = var.environment
}
