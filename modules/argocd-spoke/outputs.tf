output "agent_name" {
  description = "Name this spoke is registered under on the hub."
  value       = var.agent_name
}

output "namespace" {
  description = "Namespace the agent and the spoke's Argo CD run in."
  value       = var.namespace
}

output "agent_mode" {
  description = "Mode the agent operates in."
  value       = var.agent_mode
}

output "principal_endpoint" {
  description = "Hub endpoint the agent dials out to."
  value       = "${var.principal_address}:${var.principal_port}"
}

output "argocd_installed" {
  description = "Whether this module installed the spoke's Argo CD, or found it already there."
  value       = var.install_argocd
}
