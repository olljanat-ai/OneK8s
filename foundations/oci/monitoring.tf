# Grafana Cloud monitoring, the same module every other cloud runs
# (modules/platform-monitoring), plus the one thing that is OCI-shaped: reading
# the Grafana Cloud credentials out of the Vault.
#
# The credentials arrive there the way the wildcard certificate does — written
# to Key Vault and distributed by a workflow, under the reserved "platform-"
# prefix — so they reach the cluster the same way a tenant's own secrets do:
#
#   Vault secret platform-grafana-cloud
#     --(SecretStore + ExternalSecret, OKE Workload Identity)-->
#       Secret grafana-cloud-credentials
#         --(Alloy remote.kubernetes.secret)--> Grafana Cloud
locals {
  monitoring_namespace            = "monitoring"
  monitoring_service_account_name = "platform-monitoring"
  monitoring_secret_store_name    = "platform-store"
  monitoring_credentials_secret   = "grafana-cloud-credentials"

  # One Grafana Cloud stack holds all four clusters, told apart only by this
  # label, so it carries both the cloud and the environment.
  monitoring_cluster_name = "${var.name_prefix}-oci-${var.environment}"

  # OKE Workload Identity has no identity object: the principal *is* the
  # (cluster, namespace, service account) tuple, asserted by OKE and matched
  # in the policy below. Unlike the ingress' policy this names one secret
  # rather than a prefix — the credentials are the only thing here to read.
  monitoring_workload_conditions = join(", ", [
    "request.principal.type = 'workload'",
    "request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'",
    "request.principal.namespace = '${local.monitoring_namespace}'",
    "request.principal.service_account = '${local.monitoring_service_account_name}'",
    "target.secret.name = '${var.grafana_cloud_secret_name}'",
  ])
}

# --- Least-privilege secret access -------------------------------------------
# IAM is global but writable only in the tenancy's home region, hence the
# oci.home provider alias.
resource "oci_identity_policy" "monitoring_credentials" {
  count    = var.enable_monitoring ? 1 : 0
  provider = oci.home

  compartment_id = var.compartment_ocid
  name           = "platform-monitoring-${local.name}-secrets"
  description    = "Platform monitoring (${var.environment}): read '${var.grafana_cloud_secret_name}' via OKE workload identity"

  statements = [
    "Allow any-user to read secret-bundles in compartment id ${var.compartment_ocid} where all {${local.monitoring_workload_conditions}}",
    "Allow any-user to read secrets in compartment id ${var.compartment_ocid} where all {${local.monitoring_workload_conditions}}",
  ]
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
        # No annotation: OKE asserts the tuple itself, so there is no
        # identity to point the ServiceAccount at.
        name = local.monitoring_service_account_name
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
          oracle = {
            vault         = oci_kms_vault.secrets.id
            region        = var.region
            principalType = "Workload"
            serviceAccountRef = {
              name = local.monitoring_service_account_name
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
        # dataFrom/extract, never dataFrom/find: the policy above grants reads
        # of one named secret and not listing, so a find has nothing to match
        # its condition against. Extract also maps every field of the stored
        # JSON object through under its own name.
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
