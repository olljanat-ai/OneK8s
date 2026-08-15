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
  description = "Extra labels for the namespace. Merged over the Pod Security Admission labels below, so a tenant that must run something the level forbids can say so explicitly rather than by turning enforcement off everywhere."
  type        = map(string)
  default     = {}
}

variable "pod_security" {
  description = <<-EOT
    Pod Security Admission levels for the tenant namespace, applied as the
    "pod-security.kubernetes.io/*" labels the API server enforces itself. No
    controller to install and nothing to keep running: admission is part of
    the API server on all four clouds.

    "restricted" is the default and is what the platform's own workloads are
    written for — non-root, no privilege escalation, all capabilities dropped,
    RuntimeDefault seccomp, no host namespaces. A tenant with a genuine need
    for more can be dropped to "baseline" here, per tenant, which is a visible
    decision in the tfvars rather than a namespace nobody remembers relaxing.

    "version" pins the ruleset to a Kubernetes version. "latest" tracks
    whatever the cluster is running, so a cluster upgrade can tighten the rules
    under a workload; the four clusters are on four clouds' release trains, so
    pinning one version across them is its own kind of wrong. Pin it per
    environment if that trade goes the other way for you.
  EOT
  type = object({
    enforce = optional(string, "restricted")
    audit   = optional(string, "restricted")
    warn    = optional(string, "restricted")
    version = optional(string, "latest")
  })
  default = {}

  validation {
    condition = alltrue([
      for level in [var.pod_security.enforce, var.pod_security.audit, var.pod_security.warn] :
      contains(["privileged", "baseline", "restricted"], level)
    ])
    error_message = "pod_security enforce/audit/warn must each be one of: privileged, baseline, restricted."
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
