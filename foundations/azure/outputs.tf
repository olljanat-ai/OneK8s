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

# --- Azure SQL ----------------------------------------------------------------
# All null when enable_sql is false, which is how the gitops stack decides
# whether to deploy the db-hello application at all: no database, no
# application, and nothing to keep in sync between the two.
output "sql_server_name" {
  description = "Name of the Entra-only SQL logical server (null when SQL is disabled)."
  value       = one(azurerm_mssql_server.this[*].name)
}

output "sql_server_fqdn" {
  description = "Host the applications connect to, e.g. sql-onek8s-prototype-ab12.database.windows.net (null when SQL is disabled)."
  value       = local.sql_server_fqdn
}

output "sql_database_name" {
  description = "Database on that server (null when SQL is disabled). It holds no user for any tenant until the tenants deploy grants one."
  value       = local.sql_enabled ? var.sql_database_name : null
}

output "sql_admin_object_id" {
  description = "Entra principal that administers the SQL server — the only identity that can create database users for tenants (null when SQL is disabled)."
  value       = local.sql_enabled ? local.sql_admin_object_id : null
}

output "argocd_url" {
  description = "Public URL of the Argo CD UI (null when the extension is disabled)."
  value       = var.enable_argocd ? local.argocd_url : null
}

output "argocd_namespace" {
  description = "Namespace the Argo CD extension is released into. The gitops stack writes each spoke's cluster Secret here."
  value       = local.argocd_namespace
}

output "kargo_url" {
  description = "Public URL of the Kargo UI and API (null when Kargo is disabled, or when it runs controller-only because no way to sign in is configured)."
  value       = local.kargo_enabled && local.kargo_api_enabled ? local.kargo_url : null
}

output "kargo_namespace" {
  description = "Namespace Kargo runs in on this cluster (null when Kargo is disabled)."
  value       = local.kargo_enabled ? local.kargo_namespace : null
}

output "kargo_shared_resources_namespace" {
  description = "Namespace Kargo reads credentials shared by every Project from — where the Git credential that lets a promotion push to the delivery-plane repository is put, out of band (null when Kargo is disabled)."
  value       = local.kargo_enabled ? local.kargo_shared_resources_namespace : null
}

output "portainer_url" {
  description = "Public URL of the Portainer UI, and the address Edge Agents poll (null when Portainer is disabled). The portainer/ stack registers every spoke against it."
  value       = local.portainer_enabled ? local.portainer_url : null
}

output "portainer_namespace" {
  description = "Namespace the Portainer server runs in on this cluster."
  value       = local.portainer_enabled ? local.portainer_namespace : null
}

output "portainer_edge_tunnel" {
  description = "Address Edge Agents open their reverse tunnel to — the ingress load balancer on Portainer's tunnel port. Null when the tunnel is not published, in which case Edge environments can be registered but not browsed."
  value       = local.portainer_edge_published ? "${var.portainer_hostname}:${local.portainer_edge_port}" : null
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
  description = "TLS secret in the ingress namespace that Traefik serves for hosts without a certificate of their own — the platform wildcard, read from Key Vault by External Secrets."
  value       = var.enable_ingress ? local.ingress_tls_secret_name : null
}

output "ingress_dashboard_url" {
  description = "URL of the Traefik dashboard, null when ingress or the dashboard is disabled."
  value       = var.enable_ingress ? module.ingress[0].dashboard_url : null
}

output "observability_namespace" {
  description = "Namespace the Grafana Alloy collectors run in, null when observability is disabled."
  value       = var.enable_observability ? local.observability_namespace : null
}

output "observability_cluster_name" {
  description = "Value of the 'cluster' label this cluster's telemetry carries in Grafana Cloud, null when observability is disabled."
  value       = var.enable_observability ? local.observability_cluster_name : null
}

output "environment" {
  description = "Environment this foundation was deployed for."
  value       = var.environment
}
