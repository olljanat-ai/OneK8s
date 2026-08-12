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

variable "network_policy" {
  description = <<-EOT
    Default tenant NetworkPolicy, expressed with the same vocabulary as the
    Azure managed-namespace defaultNetworkPolicy (AllowAll, AllowSameNamespace,
    DenyAll) so tenant definitions stay identical on every cloud. Only applied
    when create_namespace is true; on Azure the managed namespace enforces it.
  EOT
  type = object({
    ingress = optional(string, "AllowSameNamespace")
    egress  = optional(string, "AllowAll")
  })
  default = {}

  validation {
    condition = alltrue([
      contains(["AllowAll", "AllowSameNamespace", "DenyAll"], var.network_policy.ingress),
      contains(["AllowAll", "AllowSameNamespace", "DenyAll"], var.network_policy.egress),
    ])
    error_message = "network_policy.ingress and network_policy.egress must each be one of: AllowAll, AllowSameNamespace, DenyAll."
  }
}

variable "limit_range" {
  description = <<-EOT
    Per-container default resource requests/limits (applied when a container
    omits them) and optional per-container maximums. Without these defaults the
    ResourceQuota's limits.* entries would reject any pod that does not declare
    explicit limits.
  EOT
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

variable "redis_connection" {
  description = "Connection details for the shared managed Redis, published as a \"redis-connection\" ConfigMap in the tenant namespace. null = tenant has no Redis access."
  type        = map(string)
  default     = null
}

variable "redis_auth_remote_key" {
  description = "Vault name of this tenant's Redis AUTH secret; synced into the namespace as Secret \"redis-auth\" (key REDIS_PASSWORD) by an ExternalSecret. null = tenant has no Redis access."
  type        = string
  default     = null
}
