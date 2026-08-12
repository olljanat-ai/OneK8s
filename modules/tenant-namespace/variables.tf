variable "cloud" {
  description = "Which cloud this tenant lands on: azure, aws or gcp."
  type        = string

  validation {
    condition     = contains(["azure", "aws", "gcp"], var.cloud)
    error_message = "cloud must be one of: azure, aws, gcp."
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
    Additionally required when redis_enabled = true:
      azure: managed_redis_database_id, managed_redis_hostname,
             managed_redis_port
      aws:   redis_arn, redis_user_group_id, redis_endpoint_address,
             redis_endpoint_port
      gcp:   redis_cluster_name, redis_cluster_location, redis_host,
             redis_port
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

variable "network_policy" {
  description = <<-EOT
    Default tenant NetworkPolicy, using the Azure managed-namespace vocabulary
    (AllowAll, AllowSameNamespace, DenyAll) on every cloud. On Azure it is
    enforced by the managed namespace; on AWS/GCP by an equivalent in-cluster
    NetworkPolicy.
  EOT
  type = object({
    ingress = optional(string, "AllowSameNamespace")
    egress  = optional(string, "AllowAll")
  })
  default = {}

  validation {
    condition = alltrue([
      contains(["AllowAll", "AllowSameNamespace", "DenyAll"], var.network_policy.ingress),
      contains(["AllowAll", "AllowSameNamespace", "DenyAll"], var.network_policy.egress),
    ])
    error_message = "network_policy.ingress and network_policy.egress must each be one of: AllowAll, AllowSameNamespace, DenyAll."
  }
}

variable "limit_range" {
  description = "Per-container default resource requests/limits (applied when a container omits them) and optional per-container maximums."
  type = object({
    default_cpu_request    = optional(string, "100m")
    default_memory_request = optional(string, "128Mi")
    default_cpu_limit      = optional(string, "500m")
    default_memory_limit   = optional(string, "512Mi")
    max_cpu                = optional(string)
    max_memory             = optional(string)
  })
  default = {}
}

variable "redis_enabled" {
  description = <<-EOT
    Delegate access to the foundation's shared managed Redis to this tenant's
    workload identity: Azure Managed Redis access policy assignment (azure),
    key-prefix-scoped IAM-auth ElastiCache user + elasticache:Connect (aws),
    or cluster-scoped roles/redis.dbConnectUser on Memorystore (gcp). Also
    drops a "redis-connection" ConfigMap into the tenant namespace.
  EOT
  type        = bool
  default     = false
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
