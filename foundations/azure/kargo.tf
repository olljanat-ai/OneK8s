# Kargo, the promotion engine in front of Argo CD.
#
# Argo CD answers "is the cluster what Git says it is". It has no opinion about
# *which* revision of an application belongs on which cluster, so before this
# existed the platform expressed "production is gated" as the absence of
# syncPolicy.automated on one Application and a GitHub workflow that pressed
# Sync after an approval. That gate held only as long as nobody added the
# missing block back, it said nothing about *what* was promoted (the image tag
# was the moving "latest"), and it left no record beyond a workflow run.
#
# Kargo makes the release path a first-class object instead: a Warehouse
# watches the application's image and chart, freezes each new build as a piece
# of Freight, and Stages carry that Freight along a defined order — staging on
# AKS first, production on EKS only from staging, and only when a human asks.
# A promotion is a commit that Kargo writes to the delivery-plane repository,
# so what is deployed where is readable in Git rather than in a controller's
# memory, and Argo CD stays a pure sync loop with both stages auto-synced.
#
# Installed as an ordinary Helm release rather than as an AKS extension: unlike
# Argo CD, Azure offers none, and the upstream chart is the only distribution.
# It follows Argo CD in every other respect — the UI published on one host
# through Traefik with the platform wildcard, Entra ID as the identity
# provider, and no credential in this stack's state.
#
#   kargo.onek8s.lol --(A record, pointed at the ingress by hand)-->
#                    Traefik
#                      --(default TLSStore)--> Key Vault cert via ESO
#                      --(HTTP)--> kargo-api
#
# What Kargo may do to Argo CD is Kubernetes RBAC on Application resources
# (argocd.dataPlane in the chart), not an Argo CD API account: promotion is a
# controller writing objects, so there is no token to mint, hand out or rotate.
locals {
  kargo_namespace = "kargo"

  # Where credentials shared by every Kargo Project live. The chart creates the
  # namespace and grants the controller read access to Secrets in it; the
  # Secrets themselves are put there out of band, exactly like the Argo CD
  # account tokens before them (docs/kargo.md). Kargo needs one: a Git
  # credential that may push to the delivery-plane repository, since a
  # promotion is a commit.
  kargo_shared_resources_namespace = "kargo-shared-resources"

  kargo_url = "https://${var.kargo_hostname}"

  # The chart names the API Service unconditionally, and it serves plain HTTP
  # on port 80 because TLS is terminated upstream (below).
  kargo_service_name = "kargo-api"
  kargo_service_port = 80

  # Kargo without Argo CD would have nothing to promote onto: every Stage's
  # health and its last step are an Argo CD Application. So the hub's delivery
  # plane is one switch, not two.
  kargo_enabled = var.enable_kargo && var.enable_argocd

  # The UI and the API are installed only once somebody can sign in to them:
  # Entra ID, or the break-glass admin account. Without either, Kargo runs
  # controller-only — Warehouses still discover artifacts, auto-promotion still
  # runs, and a manual promotion is a Promotion object created with kubectl.
  # The alternative, an API server with no authentication configured at all,
  # would either refuse to start or publish an unauthenticated one.
  kargo_api_enabled = local.kargo_admin_enabled || local.kargo_sso_enabled

  # Break-glass, and off unless an environment provides a hash. Entra ID is the
  # way in for people; the admin account is the account that still works when
  # SSO is the thing that broke. The password never reaches Terraform — only
  # its bcrypt hash does — and the key that signs the resulting tokens is
  # generated here rather than configured, so no environment shares one.
  #
  # nonsensitive(): *whether* an environment has an admin account decides
  # whether an Ingress and a URL exist, and that is not a secret. The hash
  # itself is never unwrapped.
  kargo_admin_enabled = nonsensitive(var.kargo_admin_password_hash != null)

  kargo_admin_account = merge(
    { enabled = local.kargo_admin_enabled },
    local.kargo_admin_enabled ? {
      passwordHash    = var.kargo_admin_password_hash
      tokenSigningKey = one(random_password.kargo_token_signing_key[*].result)
    } : {},
  )

  kargo_sso_enabled   = var.kargo_sso_client_id != null
  kargo_sso_tenant_id = coalesce(var.kargo_sso_tenant_id, data.azurerm_client_config.current.tenant_id)

  # Entra ID, through Kargo's own OIDC support. Two client IDs on purpose: the
  # UI redirects to the app registration's web platform, while `kargo login`
  # opens a loopback redirect, which Entra only allows on a registration's
  # "mobile and desktop" platform — the same registration serves both when it
  # declares both, and var.kargo_sso_cli_client_id covers the case where it
  # does not.
  #
  # Group object IDs map to Kargo's four system roles. Those are cluster-wide
  # ("may create Projects", "may see everything"); who may promote a *stage* is
  # not decided here at all — it is a Role in the Project's namespace, and so
  # it lives in the delivery-plane repository with the Stage it guards.
  kargo_oidc = {
    enabled     = true
    issuerURL   = "https://login.microsoftonline.com/${local.kargo_sso_tenant_id}/v2.0"
    clientID    = var.kargo_sso_client_id
    cliClientID = coalesce(var.kargo_sso_cli_client_id, var.kargo_sso_client_id)
    # Entra returns group membership as object IDs in the "groups" claim, which
    # is the claim the bindings below are written against.
    additionalScopes = ["groups"]
    usernameClaim    = "email"
    admins           = { claims = local.kargo_group_claims.admins }
    projectCreators  = { claims = local.kargo_group_claims.project_creators }
    users            = { claims = local.kargo_group_claims.users }
    viewers          = { claims = local.kargo_group_claims.viewers }
    # Dex bridges to IdPs Kargo cannot talk to directly. Entra is not one of
    # them, so it stays off — one less deployment on a small node pool.
    dex = { enabled = false }
  }

  # An empty group list must not render as an empty claim, which Kargo would
  # read as "this claim matches nothing" — the key is left out instead.
  kargo_group_claims = {
    for role, groups in {
      admins           = var.kargo_rbac_groups.admins
      project_creators = var.kargo_rbac_groups.project_creators
      users            = var.kargo_rbac_groups.users
      viewers          = var.kargo_rbac_groups.viewers
    } : role => length(groups) > 0 ? { groups = groups } : {}
  }

  kargo_values = {
    api = {
      enabled = local.kargo_api_enabled
      host    = var.kargo_hostname
      tls = {
        # The Service speaks plain HTTP; Traefik holds the certificate, as it
        # does for every other host on the platform. terminatedUpstream is how
        # Kargo is told that anyway, so the links it renders and the address
        # the CLI is pointed at are https:// rather than http://.
        enabled            = false
        terminatedUpstream = true
      }
      # The chart's own Ingress would want a certificate of its own. The object
      # below is the one that carries the class and the host, for the same
      # reason argocd.tf writes its own.
      ingress      = { enabled = false }
      adminAccount = local.kargo_admin_account
      # Deep links from a Stage to the Application behind it. One shard, so the
      # empty key is the whole map.
      argocd = { urls = { "" = local.argocd_url } }
      # Argo Rollouts is not installed on this platform; saying so explicitly
      # grants the API server fewer permissions than letting it discover that.
      rollouts = { integrationEnabled = false }
    }

    controller = {
      argocd = {
        # What makes a Stage's health the Argo CD Application's health, and
        # what lets the argocd-update promotion step ask for a sync.
        integrationEnabled = true
        namespace          = local.argocd_namespace
      }
      rollouts = { integrationEnabled = false }
    }

    global = {
      sharedResources = { namespace = local.kargo_shared_resources_namespace }
    }
  }
}

# The signing key for admin-account tokens. Generated rather than configured:
# it is not a password anybody types, and an environment that rebuilds its
# control plane should not keep signing tokens with a key from the last one.
resource "random_password" "kargo_token_signing_key" {
  count = local.kargo_enabled && local.kargo_admin_enabled ? 1 : 0

  length  = 48
  special = false
}

resource "helm_release" "kargo" {
  count = local.kargo_enabled ? 1 : 0

  name             = "kargo"
  repository       = "oci://ghcr.io/akuity/kargo-charts"
  chart            = "kargo"
  version          = var.kargo_chart_version
  namespace        = local.kargo_namespace
  create_namespace = true

  # One document per concern rather than one merged object: Helm merges them in
  # order, so the OIDC block is simply absent when no app registration is
  # configured, and an environment's own overrides come last.
  values = concat(
    [yamlencode(local.kargo_values)],
    local.kargo_sso_enabled ? [yamlencode({ api = { oidc = local.kargo_oidc } })] : [],
    [yamlencode(var.kargo_extra_values)],
  )

  # Kargo's controller reconciles Argo CD Applications and its API server
  # sanity-checks the Argo CD CRDs at startup, so the extension has to be
  # installed first.
  depends_on = [azurerm_kubernetes_cluster_extension.argocd]
}

# --- Ingress -----------------------------------------------------------------
# The same shape as the Argo CD one next to it: a host, a backend and no TLS
# section at all, because Traefik's default TLSStore serves the platform
# wildcard.
resource "kubernetes_ingress_v1" "kargo" {
  count = local.kargo_enabled && local.kargo_api_enabled ? 1 : 0

  metadata {
    name      = "kargo"
    namespace = local.kargo_namespace
  }

  spec {
    ingress_class_name = var.enable_ingress ? local.ingress_class_name : null

    rule {
      host = var.kargo_hostname

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = local.kargo_service_name
              port {
                number = local.kargo_service_port
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.kargo]
}
