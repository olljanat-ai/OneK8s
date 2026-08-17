# Grafana Cloud observability, the same module every other cloud runs
# (modules/platform-observability), plus the one thing that is Azure-shaped:
# reading the Grafana Cloud credentials out of Key Vault.
#
# It is the ingress' certificate story with a different payload, and it is
# deliberately built from the same parts — a platform identity pinned to one
# namespace's ServiceAccount, an ABAC condition narrowing it to one secret, and
# External Secrets doing the reading:
#
#   Key Vault platform-grafana-cloud
#     --(SecretStore + ExternalSecret, workload identity)-->
#       Secret grafana-cloud-credentials
#         --(Alloy remote.kubernetes.secret)--> Grafana Cloud
#
# The last hop is why the token is read this way rather than passed in as a
# Terraform variable: it never enters the state file, and Alloy polls the
# Secret, so a rotated token is picked up without an apply or a restart.
locals {
  observability_namespace            = "observability"
  observability_service_account_name = "platform-observability"
  observability_secret_store_name    = "platform-store"
  observability_credentials_secret   = "grafana-cloud-credentials"

  # One Grafana Cloud stack holds all four clusters, told apart only by this
  # label, so it carries both the cloud and the environment.
  observability_cluster_name = "${var.name_prefix}-azure-${var.environment}"
}

# --- Platform identity: UAMI + federated credential --------------------------
# A second platform identity rather than a share of the ingress': the two
# components are independently deployable, and each reads exactly one secret.
resource "azurerm_user_assigned_identity" "observability" {
  count = var.enable_observability ? 1 : 0

  name                = "id-platform-observability-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "observability" {
  count = var.enable_observability ? 1 : 0

  name                      = "aks-platform-observability"
  user_assigned_identity_id = azurerm_user_assigned_identity.observability[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${local.observability_namespace}:${local.observability_service_account_name}"
}

# "Key Vault Secrets User" grants getSecret/readMetadata on the whole vault —
# every tenant's secrets and the platform wildcard's private key — so the ABAC
# condition narrows it to exactly the Grafana Cloud credentials.
resource "azurerm_role_assignment" "observability_credentials_user" {
  count = var.enable_observability ? 1 : 0

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.observability[0].principal_id

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
        @Resource[Microsoft.KeyVault/vaults/secrets:name] StringEquals '${var.grafana_cloud_secret_name}'
      )
    )
  EOT
}

# --- The collectors ----------------------------------------------------------
module "observability" {
  source = "../../modules/platform-observability"
  count  = var.enable_observability ? 1 : 0

  chart_version           = var.k8s_observability_chart_version
  namespace               = local.observability_namespace
  cluster_name            = local.observability_cluster_name
  credentials_secret_name = local.observability_credentials_secret
  collector_preset        = var.observability_collector_preset

  metrics_url = var.grafana_cloud_metrics_url
  logs_url    = var.grafana_cloud_logs_url
  traces_url  = var.grafana_cloud_traces_url

  enable_pod_logs = var.observability_enable_pod_logs

  # The credential plumbing is applied with the release rather than as
  # kubernetes_manifest resources, which would need the External Secrets CRDs
  # to exist at *plan* time — before this stack has ever been applied.
  extra_objects = [
    {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        name = local.observability_service_account_name
        annotations = {
          "azure.workload.identity/client-id" = azurerm_user_assigned_identity.observability[0].client_id
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
        name = local.observability_secret_store_name
      }
      spec = {
        provider = {
          azurekv = {
            authType = "WorkloadIdentity"
            vaultUrl = azurerm_key_vault.this.vault_uri
            serviceAccountRef = {
              name = local.observability_service_account_name
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
          name = local.observability_secret_store_name
        }
        target = {
          name           = local.observability_credentials_secret
          creationPolicy = "Owner"
        }
        # Unlike the wildcard certificate — which Key Vault hands back as the
        # PEM bundle it was imported as — this is an ordinary secret holding a
        # JSON object, so extract maps its fields through under their own
        # names and Azure reads it exactly like the other three clouds do.
        dataFrom = [{
          extract = {
            key = var.grafana_cloud_secret_name
          }
        }]
      }
    },
  ]

  # The External Secrets CRDs and webhook have to be up before the objects
  # above are applied, and the role assignment before the first read.
  depends_on = [
    helm_release.external_secrets,
    azurerm_role_assignment.observability_credentials_user,
  ]
}
