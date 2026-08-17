output "namespace" {
  description = "Namespace the agent runs in."
  value       = var.namespace
}

output "deployment" {
  description = "Name of the agent Deployment."
  value       = kubernetes_deployment_v1.agent.metadata[0].name
}

output "service_account" {
  description = "ServiceAccount the agent acts as on this cluster, and the ClusterRole bound to it."
  value = {
    name      = kubernetes_service_account_v1.agent.metadata[0].name
    namespace = kubernetes_service_account_v1.agent.metadata[0].namespace
    role      = var.cluster_role
    binding   = kubernetes_cluster_role_binding_v1.agent.metadata[0].name
  }
}

output "edge_id" {
  description = "Edge ID this agent registers with. No key is exported — it stays in the cluster Secret."
  value       = var.edge_id
}
