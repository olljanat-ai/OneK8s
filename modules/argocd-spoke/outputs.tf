output "name" {
  description = "Name Argo CD knows this cluster by, and the agent's own identity ({{name}} in an ApplicationSet, spec.destination.name on an Application, the common name of the agent's client certificate)."
  value       = local.name
}

output "server" {
  description = "What Argo CD on the hub connects to for this cluster. It is the principal's resource proxy, not this cluster's API server — the spoke's API server is never dialled from the hub."
  value       = "https://${var.principal.resource_proxy_address}?agentName=${local.name}"
}

output "secret_name" {
  description = "Name of the cluster Secret in the hub's Argo CD namespace."
  value       = kubernetes_secret_v1.cluster.metadata[0].name
}

output "agent" {
  description = "The agent on the spoke: its namespace, its Helm release, the chart version it runs and the mode it runs in."
  value = {
    namespace     = kubernetes_namespace_v1.argocd.metadata[0].name
    release       = helm_release.agent.name
    chart_version = helm_release.agent.version
    mode          = "managed"
  }
}

output "argocd" {
  description = "The Argo CD installed alongside the agent on the spoke — application-controller, repo-server and redis, with no API server and no ApplicationSet controller."
  value = {
    release         = helm_release.argocd.name
    chart_version   = helm_release.argocd.version
    namespace       = kubernetes_namespace_v1.argocd.metadata[0].name
    service_account = local.controller_sa_name
  }
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
