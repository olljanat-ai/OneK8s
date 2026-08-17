# Traefik as the platform ingress controller, the same one every other cloud
# runs (modules/platform-ingress). It replaces the AKS application routing
# add-on, whose managed NGINX only ever served this one cluster and whose
# Ingress annotations had no equivalent on EKS, GKE or OKE.
#
# The certificate is read the same way as everywhere else too — External
# Secrets against the backend this cloud's tenants already use — so no
# managed add-on is involved in either half:
#
#   Key Vault certificate
#     --(SecretStore + ExternalSecret, workload identity)-->
#       Secret platform-wildcard-tls (kubernetes.io/tls)
#         --(Traefik default TLSStore)--> every websecure router
#
# The last hop is the point of the exercise: an Ingress that names a host
# under *.onek8s.lol needs no TLS block and no certificate of its own.
locals {
  ingress_namespace            = "traefik"
  ingress_class_name           = "traefik"
  ingress_tls_secret_name      = "platform-wildcard-tls"
  ingress_service_account_name = "platform-secrets"
  ingress_secret_store_name    = "platform-store"
}

# --- Platform identity: UAMI + federated credential --------------------------
# Same shape as a tenant identity in modules/tenant-namespace/azure, pinned to
# the ingress namespace's own ServiceAccount and to the one certificate. No
# tenant identity can read it, and this one can read no tenant's secrets.
resource "azurerm_user_assigned_identity" "ingress" {
  count = var.enable_ingress ? 1 : 0

  name                = "id-platform-ingress-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "ingress" {
  count = var.enable_ingress ? 1 : 0

  name                      = "aks-platform-ingress"
  user_assigned_identity_id = azurerm_user_assigned_identity.ingress[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${local.ingress_namespace}:${local.ingress_service_account_name}"
}

# "Key Vault Secrets User" grants getSecret/readMetadata on the whole vault —
# every tenant's secrets — so the ABAC condition narrows it to exactly the
# wildcard. A certificate is read through the secret of the same name, which
# is why this is the secrets role and not a certificates one.
resource "azurerm_role_assignment" "ingress_certificate_user" {
  count = var.enable_ingress ? 1 : 0

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.ingress[0].principal_id

  condition_version = "2.0"
  condition         = <<-EOT
    (
      (
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/getSecret/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})
      )
      OR
      (
        @Resource[Microsoft.KeyVault/vaults/secrets:name] StringEquals '${var.ingress_certificate_name}'
      )
    )
  EOT
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

  # The Azure load balancer needs no annotations for a plain public address;
  # health probing of the Service's own ports is the default.
  service_annotations = {}

  # Portainer's Edge tunnel, when it is enabled: an extra TCP entrypoint on
  # this Service's load balancer (portainer.tf builds both halves).
  extra_ports = local.portainer_ingress_ports

  # The certificate plumbing is applied with the release rather than as
  # kubernetes_manifest resources, which would need the External Secrets CRDs
  # to exist at *plan* time — before this stack has ever been applied.
  extra_objects = concat([
    {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        name = local.ingress_service_account_name
        annotations = {
          "azure.workload.identity/client-id" = azurerm_user_assigned_identity.ingress[0].client_id
          "azure.workload.identity/tenant-id" = data.azurerm_client_config.current.tenant_id
        }
        labels = {
          "azure.workload.identity/use" = "true"
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
          azurekv = {
            authType = "WorkloadIdentity"
            vaultUrl = azurerm_key_vault.this.vault_uri
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
        # Key Vault is the source of truth for the certificate, so this is the
        # copy that is refreshed first after a renewal; an hour of staleness
        # is the worst case, against 30 days of remaining validity.
        refreshInterval = "1h"
        secretStoreRef = {
          kind = "SecretStore"
          name = local.ingress_secret_store_name
        }
        target = {
          name           = local.ingress_tls_secret_name
          creationPolicy = "Owner"
          # Unlike the copies the distribute mode writes to the other three
          # clouds — one JSON object with tls.crt and tls.key already split —
          # Key Vault hands back what was imported: a single PEM bundle of the
          # private key followed by the chain. filterPEM splits it here, so
          # the workflow keeps writing one certificate and this cluster reads
          # the same object the vault is the source of truth for.
          #
          # The backticks are not decoration: Helm runs every extraObject
          # through `tpl`, so an ESO template written plainly would be
          # evaluated (and emptied) at chart render time. Wrapping it in a Go
          # raw string makes Helm emit it verbatim for ESO to evaluate later.
          template = {
            type          = "kubernetes.io/tls"
            engineVersion = "v2"
            data = {
              "tls.crt" = "{{ `{{ .bundle | filterPEM \"CERTIFICATE\" }}` }}"
              "tls.key" = "{{ `{{ .bundle | filterPEM \"PRIVATE KEY\" }}` }}"
            }
          }
        }
        # The certificate is referenced without a version, so a renewal is
        # picked up on the next refresh rather than by an apply here.
        data = [{
          secretKey = "bundle"
          remoteRef = {
            key = var.ingress_certificate_name
          }
        }]
      }
    },
  ], local.portainer_ingress_objects)

  # The External Secrets CRDs and webhook have to be up before the objects
  # above are applied, and the role assignment before the first read. The
  # Portainer namespace is in the list for the same reason: Helm applies the
  # Edge route into it, so it has to exist first.
  depends_on = [
    helm_release.external_secrets,
    azurerm_role_assignment.ingress_certificate_user,
    kubernetes_namespace_v1.portainer,
  ]
}
