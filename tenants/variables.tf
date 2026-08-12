variable "cloud" {
  description = "Which cloud these tenants land on: azure, aws or gcp."
  type        = string

  validation {
    condition     = contains(["azure", "aws", "gcp"], var.cloud)
    error_message = "cloud must be one of: azure, aws, gcp."
  }
}

variable "environment" {
  description = "Environment name (dev, staging, prod); must match the foundation environment."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "foundation_state" {
  description = <<-EOT
    Backend location of the foundations/<cloud> state for this environment.
    Keys depend on var.cloud (they mirror that backend's config):
      azure: resource_group_name, storage_account_name, container_name, key
      aws:   bucket, key, region
      gcp:   bucket, prefix
  EOT
  type        = any
}

variable "tenants" {
  description = "Tenants to onboard on this cluster, keyed by tenant name. Identical syntax for every cloud."
  type = map(object({
    quota = optional(object({
      cpu_requests    = optional(string, "4")
      cpu_limits      = optional(string, "8")
      memory_requests = optional(string, "8Gi")
      memory_limits   = optional(string, "16Gi")
      pods            = optional(string, "50")
    }), {})
    # Per-container defaults applied when a workload omits resources, plus
    # optional per-container maximums (LimitRange).
    limit_range = optional(object({
      default_cpu_request    = optional(string, "100m")
      default_memory_request = optional(string, "128Mi")
      default_cpu_limit      = optional(string, "500m")
      default_memory_limit   = optional(string, "512Mi")
      max_cpu                = optional(string)
      max_memory             = optional(string)
    }), {})
    # Azure managed-namespace vocabulary on every cloud:
    # AllowAll | AllowSameNamespace | DenyAll.
    network_policy = optional(object({
      ingress = optional(string, "AllowSameNamespace")
      egress  = optional(string, "AllowAll")
    }), {})
    labels = optional(map(string), {})
    # Delegate access to the foundation's shared managed Redis (Azure Managed
    # Redis / ElastiCache / Memorystore) to this tenant's workload identity.
    redis_enabled = optional(bool, false)
  }))
  default = {}
}
