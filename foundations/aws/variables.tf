variable "environment" {
  description = "Environment name (dev, staging, prod). Used in resource names and secret prefixes."
  type        = string
}

variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-west-1"
}

variable "name_prefix" {
  description = "Prefix for all resource names, e.g. 'onek8s'."
  type        = string
  default     = "onek8s"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block of the cluster VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "node_desired_size" {
  description = "Desired node count of the managed node group."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count of the managed node group."
  type        = number
  default     = 4
}

variable "eso_chart_version" {
  description = "External Secrets Operator Helm chart version."
  type        = string
  default     = "2.9.0"
}

variable "cilium_chart_version" {
  description = "Cilium Helm chart version."
  type        = string
  default     = "1.19.6"
}
