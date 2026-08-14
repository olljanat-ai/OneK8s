# Traefik as the platform ingress controller, the same one every other cloud
# runs (modules/platform-ingress), plus the one thing that is genuinely
# GCP-shaped: reading the platform wildcard certificate out of Secret Manager.
#
# This is the consumer the Renew Certificate workflow's "distribute" mode was
# built for. The certificate is written there as a single JSON value holding
# tls.crt and tls.key, under the reserved "platform" tenant's prefix, so it
# reaches the cluster the same way a tenant's own secrets do:
#
#   Secret Manager platform-wildcard-…
#     --(SecretStore + ExternalSecret, Workload Identity)-->
#       Secret platform-wildcard-tls (kubernetes.io/tls)
#         --(Traefik default TLSStore)--> every websecure router
locals {
  ingress_namespace            = "traefik"
  ingress_class_name           = "traefik"
  ingress_tls_secret_name      = "platform-wildcard-tls"
  ingress_service_account_name = "platform-secrets"
  ingress_secret_store_name    = "platform-store"

  # The reserved prefix of the platform's own objects, the counterpart of a
  # tenant's "<tenant>-" prefix.
  ingress_platform_secret_prefix = "platform-"

  # GSA account IDs are limited to 30 characters.
  ingress_gsa_account_id = substr("platform-ingress-${var.environment}", 0, 30)
}

# --- Platform identity: Google Service Account + Workload Identity -----------
# Same shape as a tenant identity in modules/tenant-namespace/gcp, pinned to
# the ingress namespace's own ServiceAccount and to the reserved "platform-"
# prefix. No tenant identity can read that prefix, and this one can read no
# tenant's.
resource "google_service_account" "ingress" {
  count = var.enable_ingress ? 1 : 0

  project      = var.project_id
  account_id   = local.ingress_gsa_account_id
  display_name = "Platform ingress (${var.environment})"
}

resource "google_service_account_iam_member" "ingress_workload_identity" {
  count = var.enable_ingress ? 1 : 0

  service_account_id = google_service_account.ingress[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.ingress_namespace}/${local.ingress_service_account_name}]"
}

resource "google_project_iam_member" "ingress_secret_accessor" {
  count = var.enable_ingress ? 1 : 0

  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.ingress[0].email}"

  condition {
    title       = "platform-prefix"
    description = "Restrict access to secrets prefixed with ${local.ingress_platform_secret_prefix}"
    expression  = "resource.name.startsWith(\"projects/${data.google_project.this.number}/secrets/${local.ingress_platform_secret_prefix}\")"
  }
}

# --- The controller ----------------------------------------------------------
module "ingress" {
  source = "../../modules/platform-ingress"
  count  = var.enable_ingress ? 1 : 0

  chart_version                   = var.traefik_chart_version
  namespace                       = local.ingress_namespace
  ingress_class_name              = local.ingress_class_name
  default_certificate_secret_name = local.ingress_tls_secret_name
  dashboard_hostname              = var.ingress_dashboard_hostname

  # A Service of type LoadBalancer on GKE is an external passthrough network
  # load balancer, which is what Traefik wants — it terminates TLS itself.
  service_annotations = {}

  # The certificate plumbing is applied with the release rather than as
  # kubernetes_manifest resources, which would need the External Secrets CRDs
  # to exist at *plan* time — before this stack has ever been applied.
  extra_objects = [
    {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        name = local.ingress_service_account_name
        annotations = {
          "iam.gke.io/gcp-service-account" = google_service_account.ingress[0].email
        }
      }
    },
    {
      apiVersion = "external-secrets.io/v1"
      kind       = "SecretStore"
      metadata = {
        name = local.ingress_secret_store_name
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
                  name = local.ingress_service_account_name
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
        name = "platform-wildcard"
      }
      spec = {
        # The distribution run is manual, so an hour of staleness after a
        # renewal is the worst case; the certificate has 30 days left when
        # the renewal starts.
        refreshInterval = "1h"
        secretStoreRef = {
          kind = "SecretStore"
          name = local.ingress_secret_store_name
        }
        target = {
          name           = local.ingress_tls_secret_name
          creationPolicy = "Owner"
          template = {
            type = "kubernetes.io/tls"
          }
        }
        # dataFrom/extract rather than two remoteRefs with a property: the
        # stored value is exactly {"tls.crt": …, "tls.key": …}, and extracting
        # it maps both fields through under their own names without a
        # property path having to quote the dots in them.
        dataFrom = [{
          extract = {
            key = var.ingress_certificate_name
          }
        }]
      }
    },
  ]

  # The External Secrets CRDs and webhook have to be up before the objects
  # above are applied.
  depends_on = [helm_release.external_secrets]
}
