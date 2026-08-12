# Shared Memorystore for Redis — GCP's managed Redis offering with AUTH
# string support. Consumed by tenants that opt in with `redis_enabled =
# true`: the tenant module copies the AUTH string into Secret Manager under
# each opted-in tenant's secret prefix, from where the tenant's ESO
# SecretStore (workload identity, prefix-scoped) delivers it — so tenant
# apps stay free of cloud-specific auth code
# (see modules/tenant-namespace/gcp and ADR-0002).
#
# Transit encryption is deliberately off: Memorystore TLS uses an
# instance-private CA that every client would have to be taught to trust,
# which is exactly the kind of cloud-specific client burden this design
# avoids. The endpoint is VPC-internal only; enable SERVER_AUTHENTICATION
# and distribute server_ca_certs if you need encryption in transit.
resource "google_redis_instance" "this" {
  name           = "redis-${local.name}"
  region         = var.region
  tier           = var.redis_tier
  memory_size_gb = var.redis_memory_size_gb
  redis_version  = "REDIS_7_2"

  authorized_network = google_compute_network.this.id
  connect_mode       = "DIRECT_PEERING"

  auth_enabled            = true
  transit_encryption_mode = "DISABLED"

  depends_on = [google_project_service.required]
}
