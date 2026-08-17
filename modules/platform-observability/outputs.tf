output "namespace" {
  description = "Namespace the collectors and the credentials Secret live in."
  value       = var.namespace
}

output "cluster_name" {
  description = "Value of the 'cluster' label this cluster's telemetry carries in Grafana Cloud."
  value       = var.cluster_name
}

output "credentials_secret_name" {
  description = "Kubernetes Secret the collectors read the Grafana Cloud instance IDs and token from."
  value       = var.credentials_secret_name
}

output "collector_names" {
  description = "Alloy collectors this cluster runs, which is exactly the set the enabled features need."
  value       = sort(keys(local.collectors))
}

output "destination_names" {
  description = "Grafana Cloud destinations configured on the collectors."
  value       = sort(keys(local.destinations))
}

output "release_name" {
  description = "Name of the k8s-monitoring Helm release."
  value       = helm_release.k8s_observability.name
}
