variable "environment" {
  description = "Environment name (dev, staging, prod); must match the foundation environment."
  type        = string
}

variable "foundation_state" {
  description = "azurerm backend location of the foundations/azure state for this environment."
  type = object({
    resource_group_name  = string
    storage_account_name = string
    container_name       = string
    key                  = string
  })
}

variable "tenants" {
  description = "Tenants to onboard on this cluster, keyed by tenant name."
  type = map(object({
    quota = optional(object({
      cpu_requests    = optional(string, "4")
      cpu_limits      = optional(string, "8")
      memory_requests = optional(string, "8Gi")
      memory_limits   = optional(string, "16Gi")
      pods            = optional(string, "50")
    }), {})
    labels = optional(map(string), {})
  }))
  default = {}
}
