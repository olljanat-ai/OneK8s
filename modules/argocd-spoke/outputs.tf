output "name" {
  description = "Name Argo CD knows this cluster by ({{name}} in an ApplicationSet)."
  value       = local.name
}

output "server" {
  description = "API server URL the hub connects to."
  value       = local.server
}

output "secret_name" {
  description = "Name of the cluster Secret in the hub's Argo CD namespace."
  value       = kubernetes_secret_v1.cluster.metadata[0].name
}

output "service_account" {
  description = "The manager ServiceAccount on the spoke, as <namespace>/<name>."
  value       = "${kubernetes_service_account_v1.manager.metadata[0].namespace}/${kubernetes_service_account_v1.manager.metadata[0].name}"
}

output "scope" {
  description = "What Argo CD may touch on this spoke: the allowed namespaces (empty = all) and whether cluster-scoped resources are included."
  value = {
    namespaces        = var.namespaces
    cluster_resources = var.cluster_resources
    binding           = local.namespace_scoped ? "RoleBinding per namespace" : "ClusterRoleBinding"
  }
}

output "labels" {
  description = "Labels on the cluster Secret — the selector surface of an ApplicationSet cluster generator."
  value       = local.labels
}
