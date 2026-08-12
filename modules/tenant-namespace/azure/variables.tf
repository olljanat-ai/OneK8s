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

variable "redis_enabled" {
  description = "Copy the shared Managed Redis access key into this tenant's Key Vault secret prefix and deliver it via ESO."
  type        = bool
  default     = false
}

variable "redis_hostname" {
  description = "Hostname of the shared Managed Redis instance (from the foundation). Required when redis_enabled."
  type        = string
  default     = null
}

variable "redis_port" {
  description = "TLS port of the shared Managed Redis database (from the foundation)."
  type        = number
  default     = null
}

variable "redis_access_key" {
  description = "Access key of the shared Managed Redis database (from the foundation). Required when redis_enabled."
  type        = string
  default     = null
  sensitive   = true
}

variable "managed_namespace_api_version" {
  description = "azapi API version for AKS managed namespaces."
  type        = string
  default     = "2025-05-02-preview"
}

variable "network_policy" {
  description = "Default tenant NetworkPolicy (Azure managed-namespace vocabulary: AllowAll, AllowSameNamespace, DenyAll)."
  type = object({
    ingress = optional(string, "AllowSameNamespace")
    egress  = optional(string, "AllowAll")
  })
  default = {}
}

variable "limit_range" {
  description = "Per-container default resource requests/limits and optional maximums for the tenant namespace."
  type = object({
    default_cpu_request    = optional(string, "100m")
    default_memory_request = optional(string, "128Mi")
    default_cpu_limit      = optional(string, "500m")
    default_memory_limit   = optional(string, "512Mi")
    max_cpu                = optional(string)
    max_memory             = optional(string)
  })
  default = {}
}
