variable "cluster_name" {
  description = "Name of the NKP-managed workload cluster, as it appears in `kubectl get clusters` on the management cluster."
  type        = string
}

variable "cluster_namespace" {
  description = "Namespace on the management cluster holding the cluster object and its kubeconfig Secret. NKP puts a workspace's clusters in that workspace's namespace; the default workspace is kommander-default-workspace."
  type        = string
  default     = "kommander-default-workspace"
}

variable "kubeconfig_secret_name" {
  description = "Name of the kubeconfig Secret. Null (the default) uses Cluster API's convention, '<cluster_name>-kubeconfig'."
  type        = string
  default     = null
}
