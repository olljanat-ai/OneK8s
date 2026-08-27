output "cluster_vars" {
  description = "The facts this cluster hands to every manifest in the delivery-plane repository through Flux's postBuild substitution."
  value       = local.cluster_vars
}

output "cluster_path" {
  description = "Path in the delivery-plane repository that holds this cluster's objects."
  value       = local.cluster_path
}

output "secret_key_prefix" {
  description = "How this cloud's secret backend spells the tenant's slice of it — 'team-beta-' on a per-environment vault, 'prototype/team-beta/' where the backend is account-wide."
  value       = local.secret_key_prefix
}

output "configmap_name" {
  description = "Name of the ConfigMap, which is what a Kustomization's substituteFrom has to say."
  value       = kubernetes_config_map_v1.cluster_vars.metadata[0].name
}
