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
  description = "Create the namespace and its ResourceQuota in-cluster. Set to false when the cloud layer already provides a managed namespace (Azure). The NetworkPolicies are created either way — they are the platform's ingress isolation on every cloud."
  type        = bool
  default     = true
}

variable "namespace_labels" {
  description = "Extra labels for the namespace."
  type        = map(string)
  default     = {}
}

variable "pod_security_standard" {
  description = "Pod Security Standard the namespace is labelled for, in all three modes (enforce, warn, audit): \"restricted\" — the platform default, and the only level that requires workloads to run as a non-root user — \"baseline\", or \"privileged\" to enforce nothing."
  type        = string
  default     = "restricted"

  validation {
    condition     = contains(["privileged", "baseline", "restricted"], var.pod_security_standard)
    error_message = "pod_security_standard must be one of: privileged, baseline, restricted."
  }
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

variable "ingress_controller_namespace" {
  description = "Namespace of the platform ingress controller (foundations/<cloud> ingress.tf), allowed to reach tenant workloads by an additional NetworkPolicy. Empty string adds no allowance, which leaves tenant Ingresses unreachable."
  type        = string
  default     = "traefik"
}
