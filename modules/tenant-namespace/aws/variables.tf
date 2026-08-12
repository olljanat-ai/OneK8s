variable "tenant_name" {
  description = "Tenant name; used for the namespace, IAM role and secret prefix."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "oidc_issuer_url" {
  description = "EKS cluster OIDC issuer URL (from the foundation)."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider (from the foundation)."
  type        = string
}

variable "region" {
  description = "AWS region of the cluster and Secrets Manager (from the foundation)."
  type        = string
}

variable "account_id" {
  description = "AWS account ID (from the foundation)."
  type        = string
}

variable "secrets_kms_key_arn" {
  description = "ARN of the CMK encrypting tenant secrets (from the foundation)."
  type        = string
}

variable "redis_enabled" {
  description = "Create an IAM-authenticated, key-prefix-scoped ElastiCache user for this tenant and allow elasticache:Connect."
  type        = bool
  default     = false
}

variable "redis_arn" {
  description = "ARN of the shared ElastiCache serverless cache (from the foundation). Required when redis_enabled."
  type        = string
  default     = null
}

variable "redis_user_group_id" {
  description = "ElastiCache user group to associate the tenant user into (from the foundation). Required when redis_enabled."
  type        = string
  default     = null
}

variable "redis_endpoint_address" {
  description = "Endpoint address of the shared ElastiCache serverless cache (from the foundation)."
  type        = string
  default     = null
}

variable "redis_endpoint_port" {
  description = "Endpoint port of the shared ElastiCache serverless cache (from the foundation)."
  type        = number
  default     = null
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

variable "network_policy" {
  description = "Default tenant NetworkPolicy (Azure managed-namespace vocabulary: AllowAll, AllowSameNamespace, DenyAll)."
  type = object({
    ingress = optional(string, "AllowSameNamespace")
    egress  = optional(string, "AllowAll")
  })
  default = {}
}

variable "limit_range" {
  description = "Per-container default resource requests/limits and optional maximums for the tenant namespace."
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
