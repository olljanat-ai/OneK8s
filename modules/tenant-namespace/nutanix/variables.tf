variable "tenant_name" {
  description = "Tenant name; used for the namespace, the Vault role/policy name and the secret prefix."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "vault_address" {
  description = "Address of the Vault server the tenant reads its secrets from, for the ESO SecretStore (from the foundation)."
  type        = string
}

variable "vault_namespace" {
  description = "Vault namespace everything lives in (Vault Enterprise); empty on Vault Community (from the foundation)."
  type        = string
  default     = ""
}

variable "vault_ca_bundle" {
  description = "Base64-encoded PEM CA bundle for Vault's TLS certificate, passed to the SecretStore; empty when it is publicly trusted (from the foundation)."
  type        = string
  default     = ""
}

variable "vault_mount_path" {
  description = "Path of the KV v2 mount holding all tenants' secrets (from the foundation). The tenant's policy grants its own prefix inside it and nothing else."
  type        = string
}

variable "vault_auth_path" {
  description = "Path of the JWT auth mount that trusts this cluster's token issuer (from the foundation). One mount per cluster, so a role is pinned to one cluster's assertions."
  type        = string
}

variable "vault_audience" {
  description = "Audience the cluster mints ServiceAccount tokens for and the Vault role requires (from the foundation). A token minted for any other audience is refused, the way sts.amazonaws.com and api://AzureADTokenExchange are on the other clouds."
  type        = string
  default     = "vault"
}

variable "vault_token_ttl" {
  description = "TTL, in seconds, of the Vault tokens issued to this tenant's workloads."
  type        = number
  default     = 3600
}

variable "vault_token_expiration_seconds" {
  description = "Lifetime of the ServiceAccount token External Secrets mints to log in with. Vault verifies its signature rather than calling back into the cluster, so this expiry — not a revocation check — is what bounds a leaked token, exactly as on the public clouds."
  type        = number
  default     = 600
}

variable "quota" {
  description = "ResourceQuota limits for the tenant namespace."
  type = object({
    cpu_requests    = optional(string, "4")
    cpu_limits      = optional(string, "8")
    memory_requests = optional(string, "8Gi")
    memory_limits   = optional(string, "16Gi")
    pods            = optional(string, "50")
  })
  default = {}
}

variable "namespace_labels" {
  description = "Extra labels for the namespace."
  type        = map(string)
  default     = {}
}

variable "service_account_name" {
  description = "Name of the tenant workload ServiceAccount."
  type        = string
  default     = "workload"
}

variable "ingress_controller_namespace" {
  description = "Namespace of the platform ingress controller (foundations/<cloud> ingress.tf), allowed to reach tenant workloads by an additional NetworkPolicy. Empty string adds no allowance, which leaves tenant Ingresses unreachable."
  type        = string
  default     = "traefik"
}
