# GKE cluster with:
#  - Workload Identity (tenant KSAs impersonate Google Service Accounts)
#  - Dataplane V2 (eBPF/Cilium-based) for networking + NetworkPolicy
resource "google_container_cluster" "this" {
  name     = "gke-${local.name}"
  location = var.region

  # The floor for the control plane, not a pin: GKE auto-upgrades within the
  # release channel, so master_version can move past it. (Not
  # desired_emulated_version — that one completes a rollback-safe upgrade and
  # does not select the version the cluster runs.)
  min_master_version = var.kubernetes_version

  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.gke.id

  # Dataplane V2 == Cilium: NetworkPolicy enforcement is built in.
  datapath_provider = "ADVANCED_DATAPATH"

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  release_channel {
    channel = "REGULAR"
  }

  # We manage the node pool as a separate resource.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.deletion_protection

  depends_on = [google_project_service.required]
}

resource "google_service_account" "nodes" {
  account_id   = substr("gke-nodes-${local.name}", 0, 30)
  display_name = "GKE nodes for ${local.name}"
}

resource "google_project_iam_member" "nodes_minimal" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_node_pool" "default" {
  name       = "default"
  cluster    = google_container_cluster.this.id
  node_count = var.node_count_per_zone

  node_config {
    machine_type    = var.node_machine_type
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
