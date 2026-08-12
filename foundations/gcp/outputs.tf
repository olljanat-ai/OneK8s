output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.this.name
}

output "cluster_location" {
  description = "GKE cluster location (region)."
  value       = google_container_cluster.this.location
}

output "cluster_endpoint" {
  description = "GKE API server endpoint."
  value       = google_container_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
}

output "project_id" {
  description = "GCP project ID."
  value       = var.project_id
}

output "project_number" {
  description = "GCP project number (needed for Secret Manager IAM conditions)."
  value       = data.google_project.this.number
}

output "workload_identity_pool" {
  description = "Workload identity pool of the cluster."
  value       = "${var.project_id}.svc.id.goog"
}

output "redis_cluster_name" {
  description = "Name of the shared Memorystore Redis cluster."
  value       = google_redis_cluster.this.name
}

output "redis_cluster_location" {
  description = "Location (region) of the shared Memorystore Redis cluster."
  value       = google_redis_cluster.this.region
}

output "redis_host" {
  description = "Discovery endpoint address of the shared Memorystore Redis cluster."
  value       = google_redis_cluster.this.discovery_endpoints[0].address
}

output "redis_port" {
  description = "Discovery endpoint port of the shared Memorystore Redis cluster."
  value       = google_redis_cluster.this.discovery_endpoints[0].port
}

output "environment" {
  description = "Environment this foundation was deployed for."
  value       = var.environment
}
