variable "environment" {
  description = "Environment name (dev, staging, prod). Used in resource names and secret prefixes."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "project_id" {
  description = "GCP project ID hosting the cluster and Secret Manager."
  type        = string
}

variable "region" {
  description = "GCP region for the cluster."
  type        = string
  default     = "europe-west1"
}

variable "name_prefix" {
  description = "Prefix for all resource names, e.g. 'onek8s'."
  type        = string
  default     = "onek8s"
}

variable "node_machine_type" {
  description = "Machine type of the default node pool."
  type        = string
  default     = "e2-standard-4"
}

variable "node_count_per_zone" {
  description = "Node count per zone in the default node pool."
  type        = number
  default     = 1
}

variable "redis_shard_count" {
  description = "Shard count of the shared Memorystore Redis cluster."
  type        = number
  default     = 1
}

variable "redis_replica_count" {
  description = "Replicas per shard of the shared Memorystore Redis cluster."
  type        = number
  default     = 0
}

variable "redis_node_type" {
  description = "Node type of the shared Memorystore Redis cluster."
  type        = string
  default     = "REDIS_SHARED_CORE_NANO"
}

variable "eso_chart_version" {
  description = "External Secrets Operator Helm chart version."
  type        = string
  default     = "0.18.2"
}

variable "deletion_protection" {
  description = "Protect the cluster from accidental terraform destroy."
  type        = bool
  default     = true
}
