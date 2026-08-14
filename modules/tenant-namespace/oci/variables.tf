variable "tenant_name" {
  description = "Tenant name; used for the namespace, policy name and secret prefix."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "compartment_id" {
  description = "OCID of the compartment holding the cluster and the vault (from the foundation)."
  type        = string
}

variable "cluster_id" {
  description = "OKE cluster OCID; pins the workload-identity policy to this cluster (from the foundation)."
  type        = string
}

variable "vault_id" {
  description = "OCID of the OCI Vault the tenant reads its secrets from (from the foundation)."
  type        = string
}

variable "region" {
  description = "OCI region of the vault, for the ESO SecretStore (from the foundation)."
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

variable "ingress_controller_namespace" {
  description = "Namespace of the platform ingress controller (foundations/<cloud> ingress.tf), allowed to reach tenant workloads by an additional NetworkPolicy. Empty string adds no allowance, which leaves tenant Ingresses unreachable."
  type        = string
  default     = "traefik"
}
