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
#
# The one certificate that is *not* the platform wildcard is the admission
# webhooks server's, below: that one is presented to the Kubernetes API server
# over a ClusterIP Service, never to a browser, so Traefik is not in the path
# and the wildcard would not match the name anyway. The chart's own answer is a
# cert-manager Certificate; this platform runs no cert-manager, so the
# certificate is minted here instead.
locals {
  kargo_namespace = "kargo"

  # Where credentials shared by every Kargo Project live. The chart creates the
  # namespace and grants the controller read access to Secrets in it; the
  # Secrets themselves are put there out of band, exactly like the Argo CD
  # account tokens before them (docs/kargo.md). Kargo needs one: a Git
  # credential that may push to the delivery-plane repository, since a
  # promotion is a commit.
  kargo_shared_resources_namespace = "kargo-shared-resources"

  # The Git credential that lives in that namespace, and the identity that
  # reads it. Kargo needs a username and a password that may push to the
  # delivery-plane repository, and this platform's answer to "a workload needs
  # a secret" is always the same one: a platform identity federated to one
  # ServiceAccount, a Key Vault role assignment narrowed by ABAC to one secret,
  # and External Secrets doing the reading (ingress.tf, monitoring.tf).
  #
  #   Key Vault platform-kargo-git
  #     --(SecretStore + ExternalSecret, workload identity)-->
  #       Secret onek8s-argocd-repo, labelled kargo.akuity.io/cred-type=git
  #         --(the git-push step of every promotion)--> OneK8s-argocd
  #
  # The PAT therefore never reaches Terraform: this stack says which Key Vault
  # secret to read and which Kubernetes Secret it lands in, exactly as the
  # Grafana Cloud token is handled, so nothing sensitive enters the state file
  # or a plan output. It also means the vault is read at *run* time rather than
  # at apply time — unlike Portainer's licence — so a brand-new environment
  # needs no second pass: the ExternalSecret simply stays unready until the
  # secret is put in the vault it created.
  kargo_git_credential_enabled = local.kargo_enabled && var.kargo_git_credential_secret_name != null

  # The Kubernetes Secret Kargo matches. Its name is arbitrary — Kargo finds it
  # by label and then by repoURL — but a Project-scoped copy would be named the
  # same way, so it says which repository it is for.
  kargo_git_credential_k8s_secret = "onek8s-argocd-repo"

  kargo_secrets_service_account_name = "platform-kargo"
  kargo_secret_store_name            = "platform-store"

  kargo_url = "https://${var.kargo_hostname}"

  # Kargo's admission webhooks are not decoration: the ValidatingWebhook on
  # Promotions is what enforces "who may promote this Stage", and the chart
  # registers them with failurePolicy: Fail, so a Kargo whose webhooks server
  # is absent is a Kargo that cannot create a Promotion at all. The Kubernetes
  # API server will only call them over TLS, and it validates that connection
  # against the caBundle pinned into each webhook entry — a certificate for
  # kargo-webhooks-server.kargo.svc, which no public CA would ever issue and
  # which the platform wildcard does not cover.
  #
  # Upstream expects cert-manager to produce it — a namespaced self-signed
  # Issuer and a Certificate per server — which is what an apply on this
  # cluster failed on. Rather than install a controller for one certificate no
  # client outside the cluster ever sees, the same self-signed certificate is
  # minted below and handed to the chart, with its own PEM as the caBundle:
  # exactly the shape cert-manager's selfSigned issuer produces, generated by
  # Terraform instead.
  kargo_webhooks_cert_secret_name = "kargo-webhooks-server-cert"
  kargo_webhooks_server_dns_name  = "kargo-webhooks-server.${local.kargo_namespace}.svc"

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

  # Entra ID, through Kargo's own OIDC support. Two client IDs on purpose, and
  # for a reason that is really about Entra's platform types: the UI is a
  # static bundle that redeems its own code in the browser, so its redirect
  # belongs to a "single-page application" platform, while `kargo login` opens
  # a loopback redirect, which Entra allows only on a "mobile and desktop" one.
  # A single registration declaring both serves both clients, and
  # var.kargo_sso_cli_client_id covers the case where it does not.
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
    # Empty, and deliberately not the chart's default of ["groups"].
    #
    # Kargo always requests openid, profile and email; additionalScopes is
    # appended to those, and upstream appends "groups" because Okta, Keycloak
    # and Google all publish a scope by that name. Entra ID does not. It
    # resolves an unqualified scope against Microsoft Graph, finds nothing
    # called "groups" there, and refuses the whole authorization request before
    # the user ever sees a consent screen:
    #
    #   AADSTS650053: The application asked for scope 'groups' that doesn't
    #   exist on the resource '00000003-0000-0000-c000-000000000000'.
    #
    # Group membership on Entra is not something a client asks for per request:
    # it is a property of the app registration ("Token configuration" -> "Add
    # groups claim"), and a registration configured that way puts the object
    # IDs in the ID token's "groups" claim for every sign-in. So the claim the
    # bindings below match on arrives either way, and asking for it by name
    # only breaks the request. See docs/kargo.md for what the registration has
    # to declare.
    additionalScopes = []
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

    webhooksServer = {
      tls = {
        selfSignedCert = false
        secretName     = local.kargo_webhooks_cert_secret_name
        caBundle       = one(tls_self_signed_cert.kargo_webhooks_server[*].cert_pem)
      }
    }

    # The inbound half: a public endpoint for GitHub or Docker Hub to POST to,
    # so a Warehouse refreshes on a push instead of on its polling interval.
    # Nothing in the delivery plane declares a WebhookReceiver, so enabling it
    # would buy a Deployment, a second route on the API's host and a
    # certificate for an endpoint with no callers. Warehouses poll; turn this
    # back on together with the first receiver, and terminate its TLS at
    # Traefik the way the API's is.
    externalWebhooksServer = { enabled = false }

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

  # The three objects that turn a Key Vault secret into the credential Kargo
  # looks up. Applied with the release rather than as kubernetes_manifest
  # resources, which would need the External Secrets CRDs to exist at *plan*
  # time — before this stack has ever been applied. The same reason the ingress
  # and the collectors pass theirs to their module as extra_objects.
  #
  # Every object names its namespace: the chart renders extraObjects into the
  # release namespace otherwise, and these belong to the shared-resources one
  # the chart also creates. Helm applies a Namespace before anything else in a
  # release, so the first install orders itself.
  #
  # Rendered into the release only when a Key Vault secret is configured (see
  # the values below); without one the namespace is left for a Secret created
  # by hand.
  kargo_credential_objects = [
    {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        name      = local.kargo_secrets_service_account_name
        namespace = local.kargo_shared_resources_namespace
        annotations = {
          "azure.workload.identity/client-id" = one(module.kargo_identity[*].client_id)
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
        name      = local.kargo_secret_store_name
        namespace = local.kargo_shared_resources_namespace
      }
      spec = {
        provider = {
          azurekv = {
            authType = "WorkloadIdentity"
            vaultUrl = local.key_vault_uri
            serviceAccountRef = {
              name = local.kargo_secrets_service_account_name
            }
          }
        }
      }
    },
    {
      apiVersion = "external-secrets.io/v1"
      kind       = "ExternalSecret"
      metadata = {
        name      = "kargo-git"
        namespace = local.kargo_shared_resources_namespace
      }
      spec = {
        # A rotated PAT is picked up within the hour without an apply and
        # without a restart — the controller reads the Secret per promotion.
        refreshInterval = "1h"
        secretStoreRef = {
          kind = "SecretStore"
          name = local.kargo_secret_store_name
        }
        target = {
          name           = local.kargo_git_credential_k8s_secret
          creationPolicy = "Owner"
          # The label is the whole point: Kargo finds credentials by listing
          # Secrets with it, then compares repoURL. A copy of this Secret
          # without the label is invisible to the credential lookup.
          #
          # repoURL is written here rather than kept in the vault because it is
          # configuration, not a secret — and it has to agree with what the
          # Stage passes the promotion task. Kargo lowercases both sides and
          # strips ".git" before comparing, so capitals and the suffix do not
          # matter; the host and the path do.
          #
          # The backticks are not decoration: the chart runs every extraObject
          # through `tpl`, so an ESO template written plainly would be
          # evaluated (and emptied) at chart render time. Wrapping it in a Go
          # raw string makes Helm emit it verbatim for ESO to evaluate later —
          # the same trick ingress.tf plays with filterPEM.
          template = {
            engineVersion = "v2"
            metadata = {
              labels = {
                "kargo.akuity.io/cred-type" = "git"
              }
            }
            data = {
              repoURL  = var.kargo_git_repo_url
              username = "{{ `{{ .username }}` }}"
              password = "{{ `{{ .password }}` }}"
            }
          }
        }
        # One JSON object in the vault, mapped through under its own keys —
        # the shape the Grafana Cloud credentials already use:
        #
        #   { "username": "<user or app id>", "password": "<PAT>" }
        dataFrom = [{
          extract = {
            key = var.kargo_git_credential_secret_name
          }
        }]
      }
    },
  ]
}

# --- The identity that reads the Git credential -------------------------------
# A platform identity of its own rather than a share of the ingress' or the
# collectors': the three components are independently deployable, and each one
# is granted exactly the secret it needs and nothing else. Built from the same
# Azure Verified Module as those two, so identity, federated credential and
# role assignment are one unit (ingress.tf says more about why).
#
# "Key Vault Secrets User" grants getSecret/readMetadata on the whole vault —
# every tenant's secrets and the platform wildcard's private key — so the ABAC
# condition narrows it to exactly the Git credential.
module "kargo_identity" {
  source  = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version = "0.5.2"
  count   = local.kargo_git_credential_enabled ? 1 : 0

  name                = "id-platform-kargo-${local.name}"
  location            = var.location
  resource_group_name = module.resource_group.name
  enable_telemetry    = var.enable_telemetry
  tags                = local.tags

  federated_identity_credentials = {
    aks = {
      name     = "aks-platform-kargo"
      audience = ["api://AzureADTokenExchange"]
      issuer   = module.aks.oidc_issuer_profile_issuer_url
      subject  = "system:serviceaccount:${local.kargo_shared_resources_namespace}:${local.kargo_secrets_service_account_name}"
    }
  }

  role_assignments = {
    git_credential_user = {
      role_definition_id_or_name = "Key Vault Secrets User"
      scope                      = local.key_vault_id
      description                = "Reads the Git credential a promotion pushes with, and nothing else in the vault."
      condition_version          = "2.0"
      condition                  = <<-EOT
        (
          (
            !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/getSecret/action'})
            AND
            !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})
          )
          OR
          (
            @Resource[Microsoft.KeyVault/vaults/secrets:name] StringEquals '${var.kargo_git_credential_secret_name}'
          )
        )
      EOT
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

# --- The admission webhooks server's certificate ------------------------------
# The release namespace, owned here rather than left to the Helm release's
# create_namespace: the certificate Secret has to exist in it *before* the
# chart is installed, since the webhooks server mounts it and the release
# waits for that Deployment to become ready.
resource "kubernetes_namespace_v1" "kargo" {
  count = local.kargo_enabled ? 1 : 0

  metadata {
    name = local.kargo_namespace
  }
}

resource "tls_private_key" "kargo_webhooks_server" {
  count = local.kargo_enabled ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 2048
}

# Self-signed, and its own trust anchor: the certificate below is both what the
# webhooks server presents and what the API server is told to trust, which is
# what cert-manager's selfSigned issuer produces too. There is no CA above it
# to rotate separately, and nothing but the API server ever sees it.
resource "tls_self_signed_cert" "kargo_webhooks_server" {
  count = local.kargo_enabled ? 1 : 0

  private_key_pem = tls_private_key.kargo_webhooks_server[0].private_key_pem

  subject {
    common_name = local.kargo_webhooks_server_dns_name
  }

  # The name the webhook entries point the API server at, and the fully
  # qualified form of it, because a resolver may hand back either.
  dns_names = [
    local.kargo_webhooks_server_dns_name,
    "${local.kargo_webhooks_server_dns_name}.cluster.local",
  ]

  # Ten years, replaced by an apply in the last month of them. A renewal is a
  # new key, a new Secret and a new caBundle in one apply — the webhooks server
  # reloads the mounted files, so no restart is needed.
  validity_period_hours = 87600
  early_renewal_hours   = 720

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

# The private key is in this stack's state, which the rest of Kargo carefully
# is not. It buys nothing to steal: it authenticates one ClusterIP Service to
# one API server, holds no permission of its own, and is replaced by an apply.
resource "kubernetes_secret_v1" "kargo_webhooks_server_cert" {
  count = local.kargo_enabled ? 1 : 0

  metadata {
    name      = local.kargo_webhooks_cert_secret_name
    namespace = kubernetes_namespace_v1.kargo[0].metadata[0].name
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_self_signed_cert.kargo_webhooks_server[0].cert_pem
    "tls.key" = tls_private_key.kargo_webhooks_server[0].private_key_pem
    "ca.crt"  = tls_self_signed_cert.kargo_webhooks_server[0].cert_pem
  }
}

resource "helm_release" "kargo" {
  count = local.kargo_enabled ? 1 : 0

  name       = "kargo"
  repository = "oci://ghcr.io/akuity/kargo-charts"
  chart      = "kargo"
  version    = var.kargo_chart_version
  namespace  = local.kargo_namespace

  # One document per concern rather than one merged object: Helm merges them in
  # order, so the OIDC block is simply absent when no app registration is
  # configured, and an environment's own overrides come last.
  values = concat(
    [yamlencode(local.kargo_values)],
    local.kargo_sso_enabled ? [yamlencode({ api = { oidc = local.kargo_oidc } })] : [],
    local.kargo_git_credential_enabled ? [yamlencode({ extraObjects = local.kargo_credential_objects })] : [],
    [yamlencode(var.kargo_extra_values)],
  )

  # Kargo's controller reconciles Argo CD Applications and its API server
  # sanity-checks the Argo CD CRDs at startup, so the extension has to be
  # installed first. The values carry the certificate but only the *name* of
  # the Secret it is read from, so that ordering is stated rather than inferred.
  depends_on = [
    azurerm_kubernetes_cluster_extension.argocd,
    kubernetes_secret_v1.kargo_webhooks_server_cert,
    # The External Secrets CRDs and webhook have to be up before the credential
    # objects above are applied, and the role assignment before the first read.
    helm_release.external_secrets,
    module.kargo_identity,
  ]
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
