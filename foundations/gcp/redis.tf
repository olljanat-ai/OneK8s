# Shared Memorystore for Redis Cluster — GCP's managed Redis offering with
# IAM authentication. Consumed by tenants that opt in with
# `redis_enabled = true`: the tenant module grants the tenant GSA
# roles/redis.dbConnectUser scoped to this cluster
# (see modules/tenant-namespace/gcp).
#
# Memorystore clusters attach to the VPC via Private Service Connect; the
# service connection policy below lets the Redis service create PSC
# endpoints in the GKE subnet.
resource "google_network_connectivity_service_connection_policy" "redis" {
  name          = "scp-${local.name}-redis"
  location      = var.region
  service_class = "gcp-memorystore-redis"
  network       = google_compute_network.this.id

  psc_config {
    subnetworks = [google_compute_subnetwork.gke.id]
  }

  depends_on = [google_project_service.required]
}

resource "google_redis_cluster" "this" {
  name   = "redis-${local.name}"
  region = var.region

  shard_count   = var.redis_shard_count
  replica_count = var.redis_replica_count
  node_type     = var.redis_node_type

  # IAM only — no AUTH string to distribute. Tenants authenticate with an
  # access token of their workload-identity GSA.
  authorization_mode      = "AUTH_MODE_IAM_AUTH"
  transit_encryption_mode = "TRANSIT_ENCRYPTION_MODE_SERVER_AUTHENTICATION"

  psc_configs {
    network = google_compute_network.this.id
  }

  deletion_protection_enabled = var.deletion_protection

  depends_on = [google_network_connectivity_service_connection_policy.redis]
}
