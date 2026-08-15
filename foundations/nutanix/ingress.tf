# Traefik as the platform ingress controller, the same one every other cloud
# runs (modules/platform-ingress), plus the one thing that is genuinely
# private-cloud-shaped: reading the platform wildcard certificate out of Vault.
#
# This is the consumer the Renew Certificate workflow's "distribute" mode was
# built for. The certificate is written there as a single KV v2 secret holding
# tls.crt and tls.key, under the reserved "platform" tenant's prefix, so it
# reaches the cluster the same way a tenant's own secrets do:
#
#   Vault <mount>/platform-wildcard-…
#     --(SecretStore + ExternalSecret, Vault JWT auth on the cluster's own
#        OIDC issuer)-->
#       Secret platform-wildcard-tls (kubernetes.io/tls)
#         --(Traefik default TLSStore)--> every websecure router
locals {
  ingress_namespace            = "traefik"
  ingress_class_name           = "traefik"
  ingress_tls_secret_name      = "platform-wildcard-tls"
  ingress_service_account_name = "platform-secrets"
  ingress_secret_store_name    = "platform-store"

  # The reserved prefix of the platform's own objects, the counterpart of a
  # tenant's "<tenant>-" prefix. vault.tf scopes the ingress role to it.
  platform_secret_prefix = "platform-"

  # The SecretStore's provider block, built once here and by
  # modules/tenant-namespace/nutanix for each tenant. caBundle and namespace
  # are merged in rather than set to null: a Vault with a publicly trusted
  # certificate needs no bundle, and Vault Community has no namespaces.
  ingress_secret_store_provider = {
    vault = merge(
      {
        server  = var.vault_address
        path    = vault_mount.secrets.path
        version = "v2"
        # jwt, not kubernetes: External Secrets asks the API server for a
        # short-lived token with the audience Vault's role requires, and posts
        # it to the JWT mount. Vault verifies the signature — it never calls
        # back into the cluster, and neither side holds a credential for the
        # other.
        auth = {
          jwt = {
            path = vault_jwt_auth_backend.cluster.path
            role = var.enable_ingress ? vault_jwt_auth_backend_role.ingress[0].role_name : ""
            kubernetesServiceAccountToken = {
              serviceAccountRef = {
                name = local.ingress_service_account_name
              }
              audiences         = [local.vault_audience]
              expirationSeconds = var.vault_token_expiration_seconds
            }
          }
        }
      },
      var.vault_ca_bundle == "" ? {} : { caBundle = var.vault_ca_bundle },
      var.vault_namespace == "" ? {} : { namespace = var.vault_namespace },
    )
  }
}

module "ingress" {
  source = "../../modules/platform-ingress"
  count  = var.enable_ingress ? 1 : 0

  chart_version                   = var.traefik_chart_version
  namespace                       = local.ingress_namespace
  ingress_class_name              = local.ingress_class_name
  default_certificate_secret_name = local.ingress_tls_secret_name
  dashboard_hostname              = var.ingress_dashboard_hostname

  # There is no cloud load balancer to annotate for. On NKP a Service of type
  # LoadBalancer is answered by MetalLB, which takes an address out of a pool —
  # optionally a specific one, which is what a private cloud's DNS record is
  # usually pinned to.
  service_annotations = var.ingress_service_annotations
  service_spec        = var.ingress_load_balancer_ip == null ? {} : { loadBalancerIP = var.ingress_load_balancer_ip }

  # The certificate plumbing is applied with the release rather than as
  # kubernetes_manifest resources, which would need the External Secrets CRDs
  # to exist at *plan* time — before this stack has ever been applied.
  extra_objects = [
    {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        # No annotation: the identity is the ServiceAccount itself. Its token
        # carries sub = system:serviceaccount:traefik:platform-secrets, which
        # is what the Vault role's bound_subject pins — the same string an
        # IRSA trust policy or a federated identity credential pins.
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
        provider = local.ingress_secret_store_provider
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
        # dataFrom/extract, never dataFrom/find: a KV v2 secret is a map
        # already, so extracting it maps tls.crt and tls.key through under
        # their own names — and the tenant policies grant no "list", so a find
        # has nothing to enumerate anyway.
        dataFrom = [{
          extract = {
            key = var.ingress_certificate_name
          }
        }]
      }
    },
  ]

  # The External Secrets CRDs and webhook have to be up before the objects
  # above are applied, and the Vault role has to exist before the SecretStore
  # tries to log in with it.
  depends_on = [
    helm_release.external_secrets,
    vault_jwt_auth_backend.cluster,
  ]
}
