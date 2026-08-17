# Grafana Cloud monitoring, the same module every other cloud runs
# (modules/platform-monitoring), plus the one thing that is GCP-shaped: reading
# the Grafana Cloud credentials out of Secret Manager.
#
# The credentials arrive there the way the wildcard certificate does — written
# to Key Vault and distributed by a workflow, under the reserved "platform-"
# prefix — so they reach the cluster the same way a tenant's own secrets do:
#
#   Secret Manager platform-grafana-cloud
#     --(SecretStore + ExternalSecret, Workload Identity)-->
#       Secret grafana-cloud-credentials
#         --(Alloy remote.kubernetes.secret)--> Grafana Cloud
locals {
  monitoring_namespace            = "monitoring"
  monitoring_service_account_name = "platform-monitoring"
  monitoring_secret_store_name    = "platform-store"
  monitoring_credentials_secret   = "grafana-cloud-credentials"

  # One Grafana Cloud stack holds all four clusters, told apart only by this
  # label, so it carries both the cloud and the environment.
  monitoring_cluster_name = "${var.name_prefix}-gcp-${var.environment}"

  # GSA account IDs are limited to 30 characters.
  monitoring_gsa_account_id = substr("platform-monitoring-${var.environment}", 0, 30)
}

# --- Platform identity: Google Service Account + Workload Identity -----------
# A second platform identity rather than a share of the ingress': the two
# components are independently deployable, and each reads exactly one secret.
resource "google_service_account" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  project      = var.project_id
  account_id   = local.monitoring_gsa_account_id
  display_name = "Platform monitoring (${var.environment})"
}

resource "google_service_account_iam_member" "monitoring_workload_identity" {
  count = var.enable_monitoring ? 1 : 0

  service_account_id = google_service_account.monitoring[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.monitoring_namespace}/${local.monitoring_service_account_name}]"
}

# Narrowed to the one secret rather than to the whole "platform-" prefix: this
# identity has no business reading the wildcard certificate's private key,
# which is the other thing that prefix holds.
resource "google_project_iam_member" "monitoring_secret_accessor" {
  count = var.enable_monitoring ? 1 : 0

  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.monitoring[0].email}"

  condition {
    title       = "grafana-cloud-credentials"
    description = "Restrict access to the ${var.grafana_cloud_secret_name} secret"
    expression  = "resource.name.startsWith(\"projects/${data.google_project.this.number}/secrets/${var.grafana_cloud_secret_name}\")"
  }
}

# --- The collectors ----------------------------------------------------------
module "monitoring" {
  source = "../../modules/platform-monitoring"
  count  = var.enable_monitoring ? 1 : 0

  chart_version           = var.k8s_monitoring_chart_version
  namespace               = local.monitoring_namespace
  cluster_name            = local.monitoring_cluster_name
  credentials_secret_name = local.monitoring_credentials_secret
  collector_preset        = var.monitoring_collector_preset

  metrics_url = var.grafana_cloud_metrics_url
  logs_url    = var.grafana_cloud_logs_url
  traces_url  = var.grafana_cloud_traces_url

  enable_pod_logs = var.monitoring_enable_pod_logs

  # The credential plumbing is applied with the release rather than as
  # kubernetes_manifest resources, which would need the External Secrets CRDs
  # to exist at *plan* time — before this stack has ever been applied.
  extra_objects = [
    {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        name = local.monitoring_service_account_name
        annotations = {
          "iam.gke.io/gcp-service-account" = google_service_account.monitoring[0].email
        }
      }
    },
    {
      apiVersion = "external-secrets.io/v1"
      kind       = "SecretStore"
      metadata = {
        name = local.monitoring_secret_store_name
      }
      spec = {
        provider = {
          gcpsm = {
            projectID = var.project_id
            auth = {
              workloadIdentity = {
                clusterLocation  = google_container_cluster.this.location
                clusterName      = google_container_cluster.this.name
                clusterProjectID = var.project_id
                serviceAccountRef = {
                  name = local.monitoring_service_account_name
                }
              }
            }
          }
        }
      }
    },
    {
      apiVersion = "external-secrets.io/v1"
      kind       = "ExternalSecret"
      metadata = {
        name = "grafana-cloud"
      }
      spec = {
        # An hour of staleness after a token rotation, on every cloud. The
        # collectors keep using the token they hold until then, so a rotation
        # is only visible as remote writes failing once the old token is
        # actually revoked.
        refreshInterval = "1h"
        secretStoreRef = {
          kind = "SecretStore"
          name = local.monitoring_secret_store_name
        }
        target = {
          name           = local.monitoring_credentials_secret
          creationPolicy = "Owner"
        }
        # The stored value is one JSON object of instance IDs and the token,
        # and extract maps every field through under its own name — so adding
        # a signal is a new field in the backend, not a change here.
        dataFrom = [{
          extract = {
            key = var.grafana_cloud_secret_name
          }
        }]
      }
    },
  ]

  # The External Secrets CRDs and webhook have to be up before the objects
  # above are applied.
  depends_on = [helm_release.external_secrets]
}
