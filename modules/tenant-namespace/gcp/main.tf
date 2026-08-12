locals {
  namespace = var.tenant_name

  # Secret Manager secret IDs are namespaced by convention:
  # "<tenant>-<secret-name>". The IAM condition below makes this convention a
  # hard security boundary. (IAM conditions reference the project NUMBER.)
  secret_prefix = "${var.tenant_name}-"

  # GSA account IDs are limited to 30 characters.
  gsa_account_id = substr("tenant-${var.tenant_name}-${var.environment}", 0, 30)
}

# --- Tenant identity: Google Service Account + Workload Identity -------------
resource "google_service_account" "tenant" {
  project      = var.project_id
  account_id   = local.gsa_account_id
  display_name = "Tenant ${var.tenant_name} (${var.environment})"
}

# Only the tenant's own KSA may impersonate this GSA.
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.tenant.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.namespace}/${var.service_account_name}]"
}

# --- Least-privilege secret access: IAM condition on resource name prefix ----
resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.tenant.email}"

  condition {
    title       = "tenant-${var.tenant_name}-prefix"
    description = "Restrict access to secrets prefixed with ${local.secret_prefix}"
    expression  = "resource.name.startsWith(\"projects/${var.project_number}/secrets/${local.secret_prefix}\")"
  }
}

# --- Optional shared Redis delegation ----------------------------------------
# The Memorystore AUTH string is copied into Secret Manager under this
# tenant's secret prefix. Delivery to the workload then rides the platform's
# normal chain: the tenant's prefix-scoped GSA + namespaced SecretStore +
# the "redis-auth" ExternalSecret created in common — no cloud-specific
# code in the app. Note: Memorystore has one AUTH string for the whole
# instance, so opted-in tenants share the keyspace (unlike the AWS ACL
# key slice).
resource "google_secret_manager_secret" "redis_auth" {
  count = var.redis_enabled ? 1 : 0

  project   = var.project_id
  secret_id = "${local.secret_prefix}redis-auth"

  replication {
    auto {}
  }

  lifecycle {
    precondition {
      condition     = var.redis_auth_string != null
      error_message = "redis_enabled = true but the foundation exports no redis_auth_string — deploy a foundation that includes the shared Memorystore instance first."
    }
  }
}

resource "google_secret_manager_secret_version" "redis_auth" {
  count = var.redis_enabled ? 1 : 0

  secret      = google_secret_manager_secret.redis_auth[0].id
  secret_data = var.redis_auth_string
}

# --- Kubernetes-side resources (namespace, SA, namespaced SecretStore) -------
module "common" {
  source = "../common"

  tenant_name      = var.tenant_name
  namespace        = local.namespace
  create_namespace = true
  namespace_labels = var.namespace_labels
  quota            = var.quota
  network_policy   = var.network_policy
  limit_range      = var.limit_range

  service_account_name = var.service_account_name
  service_account_annotations = {
    "iam.gke.io/gcp-service-account" = google_service_account.tenant.email
  }

  redis_connection = var.redis_enabled ? {
    REDIS_HOST = var.redis_host
    REDIS_PORT = tostring(var.redis_port)
    # VPC-internal endpoint; Memorystore TLS needs an instance-private CA on
    # every client, which this design deliberately avoids (see foundation).
    REDIS_TLS = "false"
  } : null
  redis_auth_remote_key = var.redis_enabled ? "${local.secret_prefix}redis-auth" : null

  secret_store_provider = {
    gcpsm = {
      projectID = var.project_id
      auth = {
        workloadIdentity = {
          clusterLocation  = var.cluster_location
          clusterName      = var.cluster_name
          clusterProjectID = var.project_id
          serviceAccountRef = {
            name = var.service_account_name
          }
        }
      }
    }
  }
}
