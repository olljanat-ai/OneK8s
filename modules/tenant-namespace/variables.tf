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
  # not exist, or one that exists but carries no outputs (an apply that never
  # finished). Naming the cloud, environment and blob key is the whole point:
  # without this the failure surfaces as a pile of "Unsupported attribute"
  # errors that say nothing about which foundation is missing.
  validation {
    condition     = length(keys(var.foundation)) > 0
    error_message = "No outputs in the ${var.cloud} foundation state for environment ${var.environment}: blob key foundations/${var.cloud}/${var.environment}.tfstate in the state_home container. Either the blob is absent — deploy the foundation (cd foundations/${var.cloud} && terraform init -backend-config=backend/${var.environment}.hcl && terraform apply -var-file=envs/${var.environment}.tfvars), or check whether it was written under an older key and needs migrating — or the blob exists but its apply never completed, so it holds resources and no outputs. `az storage blob list --account-name <state account> --container-name <container> --auth-mode login --prefix foundations/ -o table` tells the two apart; see docs/getting-started.md (Troubleshooting)."
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

variable "pod_security_standard" {
  description = "Pod Security Standard the tenant namespace is labelled for, in all three modes (enforce, warn, audit): \"restricted\" — the platform default, and the only built-in level that requires workloads to run as a non-root user — \"baseline\", or \"privileged\" to enforce nothing. Lower it only for a tenant with a workload that genuinely cannot comply."
  type        = string
  default     = "restricted"

  validation {
    condition     = contains(["privileged", "baseline", "restricted"], var.pod_security_standard)
    error_message = "pod_security_standard must be one of: privileged, baseline, restricted."
  }
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
