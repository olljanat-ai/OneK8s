variable "tenant_name" {
  description = "Tenant name; used for the namespace, identity and secret prefix."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group in which the tenant identity is created (from the foundation)."
  type        = string
}

variable "location" {
  description = "Azure region (from the foundation)."
  type        = string
}

variable "aks_cluster_id" {
  description = "AKS cluster resource ID (parent of the managed namespace)."
  type        = string
}

variable "oidc_issuer_url" {
  description = "AKS OIDC issuer URL (from the foundation)."
  type        = string
}

variable "key_vault_id" {
  description = "Resource ID of the shared Key Vault (from the foundation)."
  type        = string
}

variable "key_vault_uri" {
  description = "Vault URI of the shared Key Vault (from the foundation)."
  type        = string
}

variable "quota" {
  description = "Default resource quota applied to the managed namespace."
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

variable "managed_namespace_api_version" {
  description = "azapi API version for AKS managed namespaces."
  type        = string
  default     = "2025-05-02-preview"
}
