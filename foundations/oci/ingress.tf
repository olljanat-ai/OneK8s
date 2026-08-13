# Traefik as the platform ingress controller, the same one every other cloud
# runs (modules/platform-ingress), plus the one thing that is genuinely
# OCI-shaped: reading the platform wildcard certificate out of the Vault.
#
# This is the consumer the Renew Certificate workflow's "distribute" mode was
# built for. The certificate is written there as a single JSON value holding
# tls.crt and tls.key, under the reserved "platform" tenant's prefix, so it
# reaches the cluster the same way a tenant's own secrets do:
#
#   Vault secret platform-wildcard-…
#     --(SecretStore + ExternalSecret, OKE Workload Identity)-->
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

  # OKE Workload Identity has no identity object: the principal *is* the
  # (cluster, namespace, service account) tuple, asserted by OKE and matched
  # in the policy below — the same mechanism modules/tenant-namespace/oci
  # uses, pointed at the ingress namespace and the reserved prefix.
  ingress_workload_conditions = join(", ", [
    "request.principal.type = 'workload'",
    "request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'",
    "request.principal.namespace = '${local.ingress_namespace}'",
    "request.principal.service_account = '${local.ingress_service_account_name}'",
    "target.secret.name = /${local.ingress_platform_secret_prefix}*/",
  ])
}

# --- Least-privilege secret access -------------------------------------------
# IAM is global but writable only in the tenancy's home region, hence the
# oci.home provider alias.
resource "oci_identity_policy" "ingress_secrets" {
  count    = var.enable_ingress ? 1 : 0
  provider = oci.home

  compartment_id = var.compartment_ocid
  name           = "platform-ingress-${local.name}-secrets"
  description    = "Platform ingress (${var.environment}): read the '${local.ingress_platform_secret_prefix}' secrets via OKE workload identity"

  statements = [
    "Allow any-user to read secret-bundles in compartment id ${var.compartment_ocid} where all {${local.ingress_workload_conditions}}",
    "Allow any-user to read secrets in compartment id ${var.compartment_ocid} where all {${local.ingress_workload_conditions}}",
  ]
}

# --- The controller ----------------------------------------------------------
module "ingress" {
  source = "../../modules/platform-ingress"
  count  = var.enable_ingress ? 1 : 0

  chart_version                   = var.traefik_chart_version
  namespace                       = local.ingress_namespace
  ingress_class_name              = local.ingress_class_name
  default_certificate_secret_name = local.ingress_tls_secret_name

  service_annotations = {
    # A flexible-shape load balancer sized at its floor: the prototype's
    # traffic is negligible and the shape is what the bill follows. The LB
    # lands in the public subnet the cluster was given for service load
    # balancers (see oke.tf), whose security list already opens 80 and 443.
    "oci.oraclecloud.com/load-balancer-type"                      = "lb"
    "service.beta.kubernetes.io/oci-load-balancer-shape"          = "flexible"
    "service.beta.kubernetes.io/oci-load-balancer-shape-flex-min" = tostring(var.ingress_load_balancer_min_mbps)
    "service.beta.kubernetes.io/oci-load-balancer-shape-flex-max" = tostring(var.ingress_load_balancer_max_mbps)
  }

  # The certificate plumbing is applied with the release rather than as
  # kubernetes_manifest resources, which would need the External Secrets CRDs
  # to exist at *plan* time — before this stack has ever been applied.
  extra_objects = [
    {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        # No annotation: OKE asserts the tuple itself, so there is no
        # identity to point the ServiceAccount at.
        name = local.ingress_service_account_name
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
          oracle = {
            vault         = oci_kms_vault.secrets.id
            region        = var.region
            principalType = "Workload"
            serviceAccountRef = {
              name = local.ingress_service_account_name
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
        # dataFrom/extract, never dataFrom/find: the policy above grants
        # reads of named secrets and not listing, so a find has nothing to
        # match its condition against. Extract also maps "tls.crt"/"tls.key"
        # through under their own names without a property path having to
        # quote the dots in them.
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
