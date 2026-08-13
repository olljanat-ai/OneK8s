# Argo CD, installed as the Microsoft-offered AKS cluster extension
# ("Microsoft.ArgoCD") rather than as a Helm release of our own: Azure owns
# the manifests, the upgrades and the CVE patching of the Argo CD components,
# and the extension is the only supported way to reach the portal's GitOps
# blade and the Entra ID integrations (workload identity, SSO).
#
# The UI is published on a single host through the application routing add-on
# enabled in aks.tf, terminating TLS with the platform wildcard certificate
# that the Renew Certificate workflow keeps in this environment's Key Vault:
#
#   argocd.onek8s.lol --(A record, out of band)--> app routing NGINX
#                       --(Ingress + Secrets Store CSI)--> Key Vault cert
#                       --(HTTP)--> argocd-server
#
# The extension is in public preview, which is why it is pinned to the
# "Preview" release train and why var.enable_argocd exists: an environment
# that cannot take preview surface just turns it off.
locals {
  argocd_namespace = "argocd"

  # The extension installs the community argo-cd chart under a fixed release
  # name, so the API/UI Service is "argocd-server". It serves plain HTTP on
  # port 80 because of the "server.insecure" setting below.
  argocd_service_name = "argocd-server"
  argocd_service_port = 80

  argocd_url = "https://${var.argocd_hostname}"

  # The IngressClass the application routing add-on creates. Any platform
  # service that wants the managed NGINX (and the wildcard certificate) uses
  # this class plus the annotation below.
  ingress_class_name = "webapprouting.kubernetes.azure.com"

  # Version-less certificate URI on purpose: the Secrets Store CSI driver then
  # follows whatever version the vault currently holds, so a renewal by the
  # Renew Certificate workflow rolls into the ingress on the next rotation
  # poll instead of waiting for a Terraform apply.
  ingress_certificate_uri = "${azurerm_key_vault.this.vault_uri}certificates/${var.ingress_certificate_name}"

  # Extension configuration is a flat map of Helm values (dots in a *value
  # key* — an argocd-cm/argocd-cmd-params-cm entry — are escaped with a
  # backslash). var.argocd_extra_configuration is merged last so an
  # environment can override any of these without editing this file.
  argocd_configuration = merge(
    {
      # Authentication
      "azure.workloadIdentity.clientId"         = "eca6aad4-fd01-4c67-acb9-95b33d89c53b"
      "azure.workloadIdentity.enabled"          = "true"
      "azure.workloadIdentity.entraSSOClientId" = "6598a87b-227b-4f20-9f3b-dbdd74604492"
      "configs.cm.oidc\\.config"                = <<-EOT
                name: Azure
                issuer: https://login.microsoftonline.com/d9007062-1aae-4619-abb0-320699664975/v2.0
                clientID: 6598a87b-227b-4f20-9f3b-dbdd74604492
                azure:
                  useWorkloadIdentity: true
                requestedIDTokenClaims:
                  groups:
                    essential: true
                requestedScopes:
                  - openid
                  - profile
                  - email
EOT
      "configs.params.application\\.namespaces" = null
      # Look: https://github.com/argoproj/argo-cd/blob/master/assets/builtin-policy.csv
      "configs.rbac.policy\\.csv"     = <<-EOT
                p, role:org-admin, applications, *, */*, allow
                p, role:org-admin, clusters, get, *, allow
                p, role:org-admin, repositories, get, *, allow
                p, role:org-admin, repositories, create, *, allow
                p, role:org-admin, repositories, update, *, allow
                p, role:org-admin, repositories, delete, *, allow
                g, "46a1d986-c8a7-42d3-b2a4-a88f789f7ecc", role:admin
                g, "59a92e0b-f653-4d5d-bdba-473eb331a5be", role:org-admin
                g, "4301eb89-fc3d-4836-95d1-41b497f102ad", role:readonly
EOT
      "configs.rbac.policy\\.default" = "role:readonly"

      # Redis HA is the extension's default and needs four nodes; the
      # prototype runs one.
      "redis-ha.enabled" = tostring(var.argocd_high_availability)

      # Both halves of "where does Argo CD live": global.domain is what the
      # components render links with, configs.cm.url is the externally
      # reachable base URL (and OIDC callback root, once SSO is wired).
      "global.domain"  = var.argocd_hostname
      "configs.cm.url" = local.argocd_url

      # TLS terminates at the ingress, so argocd-server serves plain HTTP and
      # stops issuing its own 307 redirect to HTTPS — without this, NGINX and
      # argocd-server redirect each other in a loop.
      "configs.params.server\\.insecure" = "true"

      # Dex is only needed to bridge to an external IdP. Entra ID SSO on this
      # extension goes through Argo CD's own OIDC support, so nothing needs
      # Dex today and it is one less deployment on a small node pool.
      "dex.enabled" = "false"
    },
    # "Applications in any namespace": empty means Application/ApplicationSet
    # objects are honoured only in the argocd namespace.
    length(var.argocd_application_namespaces) > 0 ? {
      "configs.params.application\\.namespaces" = join(",", var.argocd_application_namespaces)
    } : {},
    var.argocd_extra_configuration,
  )
}

# --- Ingress certificate access ----------------------------------------------
# The application routing add-on runs with its own managed identity and pulls
# the certificate named in the Ingress annotation through the Secrets Store
# CSI driver. "Key Vault Certificate User" carries getSecret on the whole
# vault, which on a shared vault would hand every tenant's secrets to anyone
# who can create an Ingress; the ABAC condition narrows the secret half of the
# role to exactly the wildcard certificate. Certificate reads stay
# unconditioned — Key Vault ABAC covers secret data actions only.
resource "azurerm_role_assignment" "app_routing_certificate_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Certificate User"
  principal_id         = azurerm_kubernetes_cluster.this.web_app_routing[0].web_app_routing_identity[0].object_id

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

# --- The extension -----------------------------------------------------------
resource "azurerm_kubernetes_cluster_extension" "argocd" {
  count = var.enable_argocd ? 1 : 0

  name           = "argocd"
  cluster_id     = azurerm_kubernetes_cluster.this.id
  extension_type = "Microsoft.ArgoCD"

  # Leaving version unset lets Azure install the latest and auto-upgrade it
  # within the release train, which is what we want while this is preview —
  # pin var.argocd_extension_version to freeze an environment on a known
  # build. Both are ForceNew, so changing either reinstalls the extension.
  release_train = var.argocd_release_train
  version       = var.argocd_extension_version

  release_namespace = local.argocd_namespace

  configuration_settings = local.argocd_configuration

  # Argo CD's repo-server and controllers are the first workloads that need
  # more than the system node pool; nothing here depends on ESO, but keeping
  # the add-ons in a deterministic order keeps a cold apply readable.
  depends_on = [helm_release.external_secrets]
}

# --- Ingress -----------------------------------------------------------------
# Written here rather than left to the chart's own "server.ingress.*" values:
# the application routing add-on derives the name of the CSI-backed TLS secret
# from the Ingress name ("keyvault-<ingress name>"), and the chart hardcodes
# its TLS secret to "argocd-server-tls". Owning the object keeps the two names
# in agreement and keeps the annotation, host and backend in one readable
# place.
resource "kubernetes_ingress_v1" "argocd" {
  count = var.enable_argocd ? 1 : 0

  metadata {
    name      = "argocd"
    namespace = local.argocd_namespace

    annotations = {
      "kubernetes.azure.com/tls-cert-keyvault-uri" = local.ingress_certificate_uri
    }
  }

  spec {
    ingress_class_name = local.ingress_class_name

    rule {
      host = var.argocd_hostname

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = local.argocd_service_name
              port {
                number = local.argocd_service_port
              }
            }
          }
        }
      }
    }

    tls {
      hosts = [var.argocd_hostname]
      # Must be "keyvault-" + metadata.name above: that is the secret the
      # add-on creates from the annotated certificate.
      secret_name = "keyvault-argocd"
    }
  }

  # The extension creates the namespace and the Service this points at.
  depends_on = [
    azurerm_kubernetes_cluster_extension.argocd,
    azurerm_role_assignment.app_routing_certificate_user,
  ]
}
