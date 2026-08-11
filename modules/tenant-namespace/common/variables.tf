variable "tenant_name" {
  description = "Tenant name; used for the namespace and resource naming."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$", var.tenant_name))
    error_message = "tenant_name must be a lowercase DNS-1123 label of at most 32 characters."
  }
}

variable "namespace" {
  description = "Namespace name (defaults to the tenant name)."
  type        = string
  default     = null
}

variable "create_namespace" {
  description = "Create the namespace, ResourceQuota and NetworkPolicy in-cluster. Set to false when the cloud layer already provides a managed namespace (Azure)."
  type        = bool
  default     = true
}

variable "namespace_labels" {
  description = "Extra labels for the namespace."
  type        = map(string)
  default     = {}
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

variable "service_account_name" {
  description = "Name of the tenant workload ServiceAccount."
  type        = string
  default     = "workload"
}

variable "service_account_annotations" {
  description = "Annotations binding the ServiceAccount to the tenant's cloud identity."
  type        = map(string)
  default     = {}
}

variable "service_account_labels" {
  description = "Extra labels for the ServiceAccount (e.g. azure.workload.identity/use)."
  type        = map(string)
  default     = {}
}

variable "secret_store_provider" {
  description = "The `spec.provider` object of the tenant's namespaced ESO SecretStore, as built by the cloud-specific wrapper module."
  type        = any
}
