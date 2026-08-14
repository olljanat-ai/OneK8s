# Argo CD, installed as the Microsoft-offered AKS cluster extension
# ("Microsoft.ArgoCD") rather than as a Helm release of our own: Azure owns
# the manifests, the upgrades and the CVE patching of the Argo CD components,
# and the extension is the only supported way to reach the portal's GitOps
# blade and the Entra ID integrations (workload identity, SSO).
#
# The UI is published on a single host through the Traefik ingress controller
# installed in ingress.tf, terminating TLS with the platform wildcard
# certificate that the Renew Certificate workflow keeps in this environment's
# Key Vault:
#
#   argocd.onek8s.lol --(A record, pointed at the ingress by hand)-->
#                     Traefik
#                       --(default TLSStore)--> Key Vault cert via ESO
#                       --(HTTP)--> argocd-server
#
# Users sign in with Entra ID; group object IDs map to Argo CD roles through
# var.argocd_rbac_group_roles.
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

  # The SSO app registration is expected in the same directory as the deploy
  # identity; var.argocd_sso_tenant_id overrides that for a multi-tenant app.
  argocd_sso_tenant_id = coalesce(var.argocd_sso_tenant_id, data.azurerm_client_config.current.tenant_id)

  # Entra ID as the UI's identity provider. The SSO app registration proves
  # itself with the cluster's federated credential instead of a client secret
  # ("useWorkloadIdentity"), which is why SSO here presupposes workload
  # identity. Groups are requested as an essential ID token claim because the
  # RBAC policy below binds roles to group object IDs.
  argocd_oidc_config = <<-EOT
    name: Azure
    issuer: https://login.microsoftonline.com/${local.argocd_sso_tenant_id}/v2.0
    clientID: ${var.argocd_sso_client_id}
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

  # Role definitions first, then the group bindings. Built-in roles (admin,
  # readonly) need no "p" lines; see
  # https://github.com/argoproj/argo-cd/blob/master/assets/builtin-policy.csv
  argocd_rbac_policy_csv = join("\n", concat(
    var.argocd_rbac_policies,
    [for group, role in var.argocd_rbac_group_roles : "g, \"${group}\", ${role}"],
  ))

  # Extension configuration is a flat map of Helm values (dots in a *value
  # key* — an argocd-cm/argocd-cmd-params-cm entry — are escaped with a
  # backslash). var.argocd_extra_configuration is merged last so an
  # environment can override any of these without editing this file.
  argocd_configuration = merge(
    {
      # Redis HA is the extension's default and needs four nodes; the
      # prototype runs one.
      "redis-ha.enabled" = tostring(var.argocd_high_availability)

      # Both halves of "where does Argo CD live": global.domain is what the
      # components render links with, configs.cm.url is the externally
      # reachable base URL — and the root of the OIDC callback, so it has to
      # match a redirect URI on the SSO app registration.
      "global.domain"  = var.argocd_hostname
      "configs.cm.url" = local.argocd_url

      # TLS terminates at the ingress, so argocd-server serves plain HTTP and
      # stops issuing its own 307 redirect to HTTPS — without this, Traefik
      # and argocd-server redirect each other in a loop.
      "configs.params.server\\.insecure" = "true"

      # The chart's own Ingress stays off: the object below is the one that
      # carries the class, the host and (deliberately) no certificate. Two
      # Ingresses for one host would race, and an extension-managed one is
      # also how an Azure-specific annotation creeps back in — which matters
      # more than it sounds, because an Ingress annotated for the application
      # routing add-on makes that add-on generate a SecretProviderClass, and
      # AKS refuses to disable the Key Vault secrets provider add-on while
      # any SecretProviderClass exists.
      "server.ingress.enabled" = "false"

      # Dex is only needed to bridge to an external IdP. Entra ID SSO on this
      # extension goes through Argo CD's own OIDC support, so nothing needs
      # Dex today and it is one less deployment on a small node pool.
      "dex.enabled" = "false"

      # Who may do what. The default applies to any authenticated identity
      # with no explicit binding, so an unmapped Entra user lands on
      # read-only rather than on nothing at all.
      "configs.rbac.policy\\.default" = var.argocd_rbac_default_role
      "configs.rbac.policy\\.csv"     = local.argocd_rbac_policy_csv
    },
    # Workload identity: the components federate as this user-assigned
    # identity to reach Azure (ACR, Azure DevOps) without stored credentials.
    var.argocd_workload_identity_client_id != null ? {
      "azure.workloadIdentity.enabled"  = "true"
      "azure.workloadIdentity.clientId" = var.argocd_workload_identity_client_id
    } : {},
    # Entra ID SSO for the UI. Without it the built-in admin account is the
    # only way in.
    var.argocd_sso_client_id != null ? {
      "azure.workloadIdentity.entraSSOClientId" = var.argocd_sso_client_id
      "configs.cm.oidc\\.config"                = local.argocd_oidc_config
    } : {},
    # "Applications in any namespace": empty means Application/ApplicationSet
    # objects are honoured only in the argocd namespace.
    length(var.argocd_application_namespaces) > 0 ? {
      "configs.params.application\\.namespaces" = join(",", var.argocd_application_namespaces)
    } : {},
    var.argocd_extra_configuration,
  )
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
# Written here rather than left to the chart's own "server.ingress.*" values,
# which would also want a TLS secret of their own. This is the platform's own
# example of the tenant-facing contract: an Ingress with a host, a backend and
# no TLS section at all — the default TLSStore serves it the wildcard. The
# class is named only because leaving it out would let the API server fill it
# in from the default IngressClass, which this resource would then see as
# drift on every plan; a tenant writing YAML can omit it.
resource "kubernetes_ingress_v1" "argocd" {
  count = var.enable_argocd ? 1 : 0

  metadata {
    name      = "argocd"
    namespace = local.argocd_namespace
  }

  spec {
    ingress_class_name = var.enable_ingress ? local.ingress_class_name : null

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
  }

  # The extension creates the namespace and the Service this points at.
  depends_on = [azurerm_kubernetes_cluster_extension.argocd]
}
