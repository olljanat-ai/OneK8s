# Traefik as the platform ingress controller, the same one every other cloud
# runs (modules/platform-ingress). It replaces the AKS application routing
# add-on, whose managed NGINX only ever served this one cluster and whose
# Ingress annotations had no equivalent on EKS, GKE or OKE.
#
# TLS terminates on the platform wildcard, which reaches the cluster the way
# it did under app routing — through the Secrets Store CSI driver, so the
# private key travels Key Vault -> kubelet and is never read by Terraform:
#
#   Key Vault certificate
#     --(SecretProviderClass + CSI volume on the Traefik pod)-->
#       Secret platform-wildcard-tls (kubernetes.io/tls)
#         --(Traefik default TLSStore)--> every websecure router
#
# The last hop is the point of the exercise: an Ingress that names a host
# under *.onek8s.lol needs no TLS block and no certificate of its own.
locals {
  ingress_namespace       = "traefik"
  ingress_class_name      = "traefik"
  ingress_tls_secret_name = "platform-wildcard-tls"

  # The name the CSI driver reads the certificate under. It is also the name
  # the ABAC condition below allows, so both halves stay in agreement.
  ingress_certificate_name = var.ingress_certificate_name

  # The Key Vault secrets provider add-on runs with its own user-assigned
  # identity; the CSI driver authenticates as it (kubelet identity mode), so
  # no pod-level workload identity is involved.
  kv_secrets_provider = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0]

  # https://<name>.vault.azure.net/ -> <name>
  key_vault_name = azurerm_key_vault.this.name
}

# --- Ingress certificate access ----------------------------------------------
# "Key Vault Certificate User" carries getSecret on the whole vault, which on
# a shared vault would hand every tenant's secrets to whoever can mount a
# SecretProviderClass; the ABAC condition narrows the secret half of the role
# to exactly the wildcard certificate. Certificate reads stay unconditioned —
# Key Vault ABAC covers secret data actions only.
resource "azurerm_role_assignment" "ingress_certificate_user" {
  count = var.enable_ingress ? 1 : 0

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Certificate User"
  principal_id         = local.kv_secrets_provider.object_id

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
        @Resource[Microsoft.KeyVault/vaults/secrets:name] StringEquals '${local.ingress_certificate_name}'
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

  # The Azure load balancer needs no annotations for a plain public address;
  # health probing of the Service's own ports is the default.
  service_annotations = {}

  # Deliberately not waiting for the release to become ready. The certificate
  # arrives as a CSI volume, so a vault that has no certificate yet keeps the
  # Traefik pod from starting — and on a brand-new environment there is no
  # certificate until the Renew Certificate workflow has run, which in turn
  # needs this stack's outputs to find the vault. Waiting here would make the
  # two deadlock on a first apply; not waiting leaves an ingress that comes up
  # by itself once the certificate lands.
  wait = false

  # The CSI volume is what actually triggers the sync: the driver only
  # materializes secretObjects for a SecretProviderClass that a running pod
  # mounts, and re-reads the vault on its rotation poll, so a renewed
  # certificate reaches Traefik without an apply here.
  additional_volumes = [{
    name = "platform-wildcard"
    csi = {
      driver   = "secrets-store.csi.k8s.io"
      readOnly = true
      volumeAttributes = {
        secretProviderClass = "platform-wildcard"
      }
    }
  }]

  additional_volume_mounts = [{
    name      = "platform-wildcard"
    mountPath = "/mnt/platform-wildcard"
    readOnly  = true
  }]

  extra_objects = [
    {
      apiVersion = "secrets-store.csi.x-k8s.io/v1"
      kind       = "SecretProviderClass"
      metadata = {
        name = "platform-wildcard"
      }
      spec = {
        provider = "azure"

        # A Key Vault *certificate* read as objectType "secret" comes back as
        # the PEM bundle of key + chain; mapping the same object to both
        # tls.key and tls.crt of a kubernetes.io/tls secret is what splits it.
        secretObjects = [{
          secretName = local.ingress_tls_secret_name
          type       = "kubernetes.io/tls"
          data = [
            {
              objectName = local.ingress_certificate_name
              key        = "tls.key"
            },
            {
              objectName = local.ingress_certificate_name
              key        = "tls.crt"
            },
          ]
        }]

        parameters = {
          usePodIdentity         = "false"
          useVMManagedIdentity   = "true"
          userAssignedIdentityID = local.kv_secrets_provider.client_id
          keyvaultName           = local.key_vault_name
          tenantId               = data.azurerm_client_config.current.tenant_id
          # Version-less on purpose: the driver follows whatever version the
          # vault currently holds, so a renewal rolls in on the next rotation
          # poll. The array's entries are themselves YAML documents, which is
          # the shape the Key Vault CSI provider parses.
          objects = <<-EOT
            array:
              - |
                objectName: ${local.ingress_certificate_name}
                objectType: secret
          EOT
        }
      }
    },
  ]

  depends_on = [azurerm_role_assignment.ingress_certificate_user]
}
