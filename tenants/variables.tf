variable "cloud" {
  description = "Which cloud these tenants land on: azure, aws, gcp or oci."
  type        = string

  validation {
    condition     = contains(["azure", "aws", "gcp", "oci"], var.cloud)
    error_message = "cloud must be one of: azure, aws, gcp, oci."
  }
}

variable "environment" {
  description = "Environment name (dev, staging, prod); must match the foundation environment."
  type        = string
}

variable "foundation_state" {
  description = <<-EOT
    Backend location of the foundations/<cloud> state for this environment.
    Every foundation stores its state in the Azure Storage state home, so the
    keys are the azurerm backend's on every cloud — only the blob key differs:
      resource_group_name, storage_account_name, container_name, key
    They must match foundations/<cloud>/backend/<env>.hcl.
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
    labels = optional(map(string), {})
  }))
  default = {}
}
