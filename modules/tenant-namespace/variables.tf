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

  # An empty object means terraform_remote_state read a state file that does
  # not exist (or holds no outputs) — usually a foundation that was never
  # applied, or one whose state was written to a different storage account,
  # container or key. Without this the failure surfaces as a pile of
  # "Unsupported attribute" errors below.
  validation {
    condition     = length(keys(var.foundation)) > 0
    error_message = "foundation has no attributes: the foundations/<cloud> state for the tenant's cloud and environment is missing or empty. Deploy that foundation first (cd foundations/<cloud> && terraform init -backend-config=backend/<env>.hcl && terraform apply -var-file=envs/<env>.tfvars), and check that state_home in tenants/envs/<env>.tfvars names the same storage account and container as foundations/<cloud>/backend/<env>.hcl — the blob key foundations/<cloud>/<env>.tfstate is derived from the cloud and environment."
  }
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
