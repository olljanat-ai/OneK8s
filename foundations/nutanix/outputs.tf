# --- The cluster -------------------------------------------------------------
output "cluster_name" {
  description = "Name of the NKP workload cluster."
  value       = local.cluster_name
}

output "cluster_namespace" {
  description = "Namespace on the NKP management cluster holding the cluster object and its kubeconfig Secret. The tenants and gitops stacks read that Secret the same way this one does."
  value       = var.cluster_namespace
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint (https URL)."
  value       = module.cluster.host
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  value       = module.cluster.cluster_ca_certificate
}

# The management cluster's coordinates, not its credential: the stacks that
# have to reach this cluster resolve it the way everything else in the platform
# is resolved — coordinates out of the foundation state, credentials out of the
# environment (TF_VAR_nkp_management_token).
output "nkp_management_host" {
  description = "API server URL of the NKP management cluster."
  value       = var.nkp_management_host
}

output "nkp_management_ca_certificate" {
  description = "Base64-encoded CA certificate of the NKP management cluster's API server; empty when it is publicly trusted."
  value       = var.nkp_management_ca_certificate
}

# --- The vault ---------------------------------------------------------------
output "vault_address" {
  description = "Address of the Vault server holding this environment's secrets."
  value       = var.vault_address
}

output "vault_namespace" {
  description = "Vault namespace everything lives in; empty on Vault Community."
  value       = var.vault_namespace
}

output "vault_ca_bundle" {
  description = "Base64-encoded PEM CA bundle for Vault's TLS certificate, for the in-cluster SecretStores; empty when it is publicly trusted."
  value       = var.vault_ca_bundle
}

output "vault_mount_path" {
  description = "Path of the KV v2 mount holding all tenant secrets — this cloud's 'vault'."
  value       = vault_mount.secrets.path
}

output "vault_auth_path" {
  description = "Path of the JWT auth mount that trusts this cluster's token issuer. Tenant roles are created under it."
  value       = vault_jwt_auth_backend.cluster.path
}

output "vault_audience" {
  description = "Audience the cluster mints ServiceAccount tokens for and Vault roles require."
  value       = local.vault_audience
}

output "cluster_issuer" {
  description = "The 'iss' claim this cluster's ServiceAccount tokens carry, which the Vault auth mount is bound to — the private cloud's counterpart of an EKS OIDC provider URL."
  value       = local.cluster_issuer
}

# --- Ingress -----------------------------------------------------------------
output "ingress_class_name" {
  description = "IngressClass of the Traefik ingress controller (the cluster default), null when ingress is disabled."
  value       = var.enable_ingress ? local.ingress_class_name : null
}

output "ingress_namespace" {
  description = "Namespace the ingress controller runs in; tenant NetworkPolicies allow ingress from it."
  value       = var.enable_ingress ? local.ingress_namespace : null
}

output "ingress_default_certificate_secret" {
  description = "TLS secret in the ingress namespace that Traefik serves for hosts without a certificate of their own — the platform wildcard, read from Vault by External Secrets."
  value       = var.enable_ingress ? local.ingress_tls_secret_name : null
}

output "ingress_dashboard_url" {
  description = "URL of the Traefik dashboard, null when ingress or the dashboard is disabled."
  value       = var.enable_ingress ? module.ingress[0].dashboard_url : null
}

output "environment" {
  description = "Environment this foundation was deployed for."
  value       = var.environment
}
