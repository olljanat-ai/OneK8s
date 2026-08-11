locals {
  name = "${var.name_prefix}-${var.environment}"
}

data "google_project" "this" {
  project_id = var.project_id
}

# Required APIs. disable_on_destroy = false so destroying this stack does not
# break other workloads in the project.
resource "google_project_service" "required" {
  for_each = toset([
    "container.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_network" "this" {
  name                    = "vpc-${local.name}"
  auto_create_subnetworks = false

  depends_on = [google_project_service.required]
}

resource "google_compute_subnetwork" "gke" {
  name          = "snet-${local.name}-gke"
  network       = google_compute_network.this.id
  region        = var.region
  ip_cidr_range = "10.30.0.0/20"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.32.0.0/14"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.36.0.0/20"
  }
}
