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
# Memorystore's IAM auth is per cluster, not per key: the condition pins the
# grant to the shared cluster, but inside it tenants share one keyspace —
# unlike the AWS ACL key slice. Don't co-locate tenants with hostile trust
# boundaries on the same Memorystore cluster. (IAM conditions reference the
# project NUMBER, as with Secret Manager.)
resource "google_project_iam_member" "redis_connect" {
  count = var.redis_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/redis.dbConnectUser"
  member  = "serviceAccount:${google_service_account.tenant.email}"

  condition {
    title       = "tenant-${var.tenant_name}-redis"
    description = "Restrict connect access to the shared Memorystore cluster ${var.redis_cluster_name}"
    expression  = "resource.name.startsWith(\"projects/${var.project_number}/locations/${var.redis_cluster_location}/clusters/${var.redis_cluster_name}\")"
  }

  lifecycle {
    precondition {
      condition     = var.redis_cluster_name != null && var.redis_cluster_location != null
      error_message = "redis_enabled = true but the foundation exports no redis_cluster_name/redis_cluster_location — deploy a foundation that includes the shared Memorystore cluster first."
    }
  }
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
    REDIS_TLS  = "true"
    # IAM auth: username = "default", password = an access token of the
    # tenant GSA obtained through workload identity.
    REDIS_USERNAME = "default"
  } : null

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
