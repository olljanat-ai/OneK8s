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

variable "service_account_name" {
  description = "Name of the tenant workload ServiceAccount."
  type        = string
  default     = "workload"
}
