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

output "redis_host" {
  description = "Host address of the shared Memorystore Redis instance."
  value       = google_redis_instance.this.host
}

output "redis_port" {
  description = "Port of the shared Memorystore Redis instance."
  value       = google_redis_instance.this.port
}

output "redis_auth_string" {
  description = "AUTH string of the shared Memorystore Redis instance; the tenant module copies it into each opted-in tenant's vault prefix."
  value       = google_redis_instance.this.auth_string
  sensitive   = true
}

output "environment" {
  description = "Environment this foundation was deployed for."
  value       = var.environment
}
