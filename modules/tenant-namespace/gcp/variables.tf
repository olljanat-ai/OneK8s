variable "tenant_name" {
  description = "Tenant name; used for the namespace, service account and secret prefix."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "project_id" {
  description = "GCP project ID hosting the cluster and Secret Manager (from the foundation)."
  type        = string
}

variable "project_number" {
  description = "GCP project number, needed for the Secret Manager IAM condition (from the foundation)."
  type        = string
}

variable "cluster_name" {
  description = "GKE cluster name (for the ESO workloadIdentity auth block)."
  type        = string
}

variable "cluster_location" {
  description = "GKE cluster location (for the ESO workloadIdentity auth block)."
  type        = string
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

variable "namespace_labels" {
  description = "Extra labels for the namespace."
  type        = map(string)
  default     = {}
}

variable "pod_security_standard" {
  description = "Pod Security Standard the tenant namespace is labelled for: \"restricted\" (the platform default — workloads must run as a non-root user), \"baseline\", or \"privileged\" to enforce nothing."
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
