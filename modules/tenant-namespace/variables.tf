variable "cloud" {
  description = "Which cloud this tenant lands on: azure, aws, gcp or oci."
  type        = string

  validation {
    condition     = contains(["azure", "aws", "gcp", "oci"], var.cloud)
    error_message = "cloud must be one of: azure, aws, gcp, oci."
  }
}

variable "tenant_name" {
  description = "Tenant name; used for the namespace, identity and secret prefix."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "foundation" {
  description = <<-EOT
    The outputs object of the matching foundations/<cloud> stack (pass
    data.terraform_remote_state.<...>.outputs). Required keys per cloud:
      azure: resource_group_name, location, cluster_id, oidc_issuer_url,
             key_vault_id, key_vault_uri
      aws:   oidc_issuer_url, oidc_provider_arn, region, account_id,
             secrets_kms_key_arn
      gcp:   project_id, project_number, cluster_name, cluster_location
      oci:   compartment_id, cluster_id, vault_id, region
  EOT
  type        = any
}

variable "quota" {
  description = "Resource quota applied to the tenant namespace."
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
