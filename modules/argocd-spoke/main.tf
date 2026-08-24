# Attaches one foundations/<cloud> cluster to the Argo CD hub that
# foundations/azure runs on AKS, using argocd-agent
# (https://github.com/argoproj-labs/argocd-agent).
#
# The direction of the connection is the whole point. The hub used to hold a
# cluster-admin bearer token for every spoke and call each spoke's Kubernetes
# API across the internet, which is what forced every spoke to publish a public
# API server. Here nothing on the hub ever contacts the spoke: the agent dials
# *out* to the principal and keeps one gRPC stream open, so the spoke's API
# server needs no inbound reachability at all.
#
#   spoke cluster                             hub cluster (AKS)
#   ────────────────────────────────────      ──────────────────────────────────
#   Argo CD: application-controller,          Argo CD extension (UI, repo-server,
#            repo-server, redis                        app-controller, redis)
#   argocd-agent agent  ──── gRPC/mTLS ─────▶ argocd-agent principal
#     (managed mode)          outbound        Secret "cluster-<name>", labelled
#                                               argocd.argoproj.io/secret-type
#
# An Application still lives on the hub — the ApplicationSets and Kargo are the
# hub's, unchanged — but it is *routed* to this cluster by its
# spec.destination.name rather than applied over the wire, and the copy the
# agent creates locally is reconciled by the spoke's own application-controller.
#
# Three variables of the old module survive with the same meaning, because they
# describe Argo CD's reach rather than how it connects: cluster_role_rules,
# namespaces and cluster_resources.
locals {
  name = coalesce(var.name, var.cloud)

  labels = merge({
    "app.kubernetes.io/managed-by" = "terraform"
    "onek8s.io/cloud"              = var.cloud
    "onek8s.io/environment"        = var.environment
    "onek8s.io/spoke"              = local.name
  }, var.labels)

  # Where the agent, the local Argo CD and their credentials go. The agent's
  # own namespace is also the namespace it creates Applications in, and it is
  # the namespace an Application carries down from the hub (they are rendered
  # into "argocd" there), so the two have to agree.
  namespace = var.agent_namespace

  # Namespace-scoped bindings are only possible when Argo CD is confined to a
  # namespace list *and* barred from cluster-scoped resources; anything else
  # needs the ClusterRoleBinding. Argo CD on the hub enforces the same split
  # from its side through the cluster Secret's namespaces/clusterResources
  # fields, so the two halves are configured from one pair of variables.
  namespace_scoped = length(var.namespaces) > 0 && !var.cluster_resources

  # Release names are pinned so the objects the two charts name each other by
  # line up: the agent's defaults address the local Argo CD as "argocd-redis"
  # and "argocd", which is what fullnameOverride below produces.
  argocd_release     = "argocd"
  argocd_fullname    = "argocd"
  controller_sa_name = "${local.argocd_fullname}-application-controller"
  # Named rather than derived: the chart would otherwise build it from the
  # release name, and the ClusterRoleBinding below has to name the same object.
  agent_sa_name        = "${var.agent_release_name}-sa"
  agent_client_secret  = "argocd-agent-client-tls"
  agent_ca_secret_name = "argocd-agent-ca"
}

# --- Spoke side: namespace ---------------------------------------------------
# Created here rather than by either Helm release, because both releases and
# the two credential Secrets below live in it and none of them owns it.
resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name   = local.namespace
    labels = local.labels
  }
}

# --- Spoke side: the credentials the agent connects with ---------------------
# mTLS in both directions. The agent proves itself to the principal with a
# client certificate whose common name IS the agent name — the principal's
# default auth mode is "mtls:CN=([^,]+)", so the certificate is the identity —
# and validates the principal against the same CA.
#
# What this replaces is a ServiceAccount bearer token with cluster-admin on the
# spoke, held on the hub. A leaked client certificate here authenticates one
# agent to one principal and grants nothing on any cluster; a leaked spoke
# token was cluster-admin on that spoke.
resource "kubernetes_secret_v1" "agent_ca" {
  metadata {
    name      = local.agent_ca_secret_name
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels    = local.labels
  }

  # Opaque with a single "ca.crt", which is what `argocd-agentctl pki
  # propagate` writes and what the agent reads: the CA certificate only, never
  # the CA key, which stays on the hub (and in the gitops state that mints
  # these leaves).
  type = "Opaque"

  data = {
    "ca.crt" = var.ca.cert_pem
  }
}

resource "tls_private_key" "agent_client" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "agent_client" {
  private_key_pem = tls_private_key.agent_client.private_key_pem

  subject {
    common_name = local.name
  }
}

resource "tls_locally_signed_cert" "agent_client" {
  cert_request_pem   = tls_cert_request.agent_client.cert_request_pem
  ca_private_key_pem = var.ca.private_key_pem
  ca_cert_pem        = var.ca.cert_pem

  validity_period_hours = var.client_certificate_validity_hours
  early_renewal_hours   = var.client_certificate_early_renewal_hours

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "client_auth",
  ]
}

resource "kubernetes_secret_v1" "agent_client" {
  metadata {
    name      = local.agent_client_secret
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels    = local.labels
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_locally_signed_cert.agent_client.cert_pem
    "tls.key" = tls_private_key.agent_client.private_key_pem
  }
}

# --- Spoke side: Argo CD, reconciler only ------------------------------------
# A managed agent needs a local Argo CD to do the actual work: the
# application-controller applies manifests and reports health, the repo-server
# renders the charts, and redis caches what both produce. What it does NOT need
# is an API server, an identity provider or an ApplicationSet controller —
# there is one UI and one place Applications are generated, and both are the
# hub's. Their replica counts are zeroed rather than deleted because the
# upstream chart has no switch for them.
#
# This is argocd-agent's "fully autonomous workload cluster" pattern: the spoke
# renders and reconciles by itself, so a hub outage costs promotions and
# visibility, not reconciliation. The price is that this cluster now fetches
# the applications repository over the internet itself.
resource "helm_release" "argocd" {
  name             = local.argocd_release
  repository       = var.argocd_chart_repository
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = kubernetes_namespace_v1.argocd.metadata[0].name
  create_namespace = false

  # The first apply pulls three images onto a node pool that may still be
  # scaling up.
  timeout = var.helm_timeout

  values = [yamlencode(merge({
    # Every object the agent addresses by name — "argocd-redis",
    # "argocd-repo-server", the controller ServiceAccount the RBAC below binds
    # — is derived from this. Without it the chart would prefix them with the
    # release name a second time.
    fullnameOverride = local.argocd_fullname

    crds = {
      install = true
      # An uninstall that took the CRDs would take every Application with
      # them, including the ones the agent is mid-sync on.
      keep = true
    }

    # The cluster-scoped half of the controller's RBAC is this module's
    # (below), so that var.namespaces and var.cluster_resources mean the same
    # thing they always did. The chart's namespaced Role is untouched: the
    # controller still needs it for its own namespace.
    createClusterRoles = false

    controller = {
      replicas = 1
    }

    repoServer = {
      replicas = var.repo_server_replicas
    }

    redis = {
      enabled = true
    }

    # No UI, no SSO, no notifications, no ApplicationSets on a spoke.
    server         = { replicas = 0 }
    applicationSet = { replicas = 0 }
    dex            = { enabled = false }
    notifications  = { enabled = false }
  }, var.argocd_extra_values))]

  depends_on = [kubernetes_namespace_v1.argocd]
}

# The rights Argo CD has on this cluster, and the one place they are decided.
#
# The default is what `argocd cluster add` used to grant and what the upstream
# chart grants: everything, because Argo CD has to be able to apply whatever a
# repository holds. Narrowing it is the same pair of variables as before.
resource "kubernetes_cluster_role_v1" "controller" {
  metadata {
    name   = "${local.controller_sa_name}-role"
    labels = local.labels
  }

  # Empty lists are passed as null so the attribute is left undeclared: the
  # provider requires at least one item in any of these it sees, and a
  # non-resource rule is exactly a rule with no api_groups and no resources —
  # the Kubernetes API rejects a rule that carries both those and
  # nonResourceURLs, so the two cannot be collapsed into one rule.
  dynamic "rule" {
    for_each = var.cluster_role_rules

    content {
      api_groups        = length(rule.value.api_groups) > 0 ? rule.value.api_groups : null
      resources         = length(rule.value.resources) > 0 ? rule.value.resources : null
      resource_names    = length(rule.value.resource_names) > 0 ? rule.value.resource_names : null
      non_resource_urls = length(rule.value.non_resource_urls) > 0 ? rule.value.non_resource_urls : null
      verbs             = rule.value.verbs
    }
  }
}

resource "kubernetes_cluster_role_binding_v1" "controller" {
  count = local.namespace_scoped ? 0 : 1

  metadata {
    name   = "${local.controller_sa_name}-role-binding"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.controller.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = local.controller_sa_name
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }
}

# A RoleBinding may reference a ClusterRole: the same rules apply, but only
# inside the namespace holding the binding. One per allowed namespace, so this
# cluster's API server enforces the boundary Argo CD is also configured with.
resource "kubernetes_role_binding_v1" "controller" {
  for_each = local.namespace_scoped ? toset(var.namespaces) : toset([])

  metadata {
    name      = "${local.controller_sa_name}-role-binding"
    namespace = each.value
    labels    = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.controller.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = local.controller_sa_name
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }
}

# What the agent itself may read, which is a different question from what Argo
# CD may apply. The agent answers the hub's live-resource queries — the tree
# under an Application in the UI, a pod's logs — by reading this cluster on the
# hub's behalf, and its own chart grants it only Argo CD's objects.
#
# Read-only by default, deliberately: it makes the UI complete without making
# the resource proxy a second write path onto the spoke. Widen it (or set
# enable_resource_proxy_rbac = false and lose the live view) per environment.
resource "kubernetes_cluster_role_v1" "agent_resources" {
  count = var.enable_resource_proxy_rbac ? 1 : 0

  metadata {
    name   = "${var.agent_release_name}-resources"
    labels = local.labels
  }

  dynamic "rule" {
    for_each = var.agent_cluster_role_rules

    content {
      api_groups        = length(rule.value.api_groups) > 0 ? rule.value.api_groups : null
      resources         = length(rule.value.resources) > 0 ? rule.value.resources : null
      resource_names    = length(rule.value.resource_names) > 0 ? rule.value.resource_names : null
      non_resource_urls = length(rule.value.non_resource_urls) > 0 ? rule.value.non_resource_urls : null
      verbs             = rule.value.verbs
    }
  }
}

resource "kubernetes_cluster_role_binding_v1" "agent_resources" {
  count = var.enable_resource_proxy_rbac ? 1 : 0

  metadata {
    name   = "${var.agent_release_name}-resources"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.agent_resources[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = local.agent_sa_name
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }
}

# --- Spoke side: the agent ---------------------------------------------------
resource "helm_release" "agent" {
  name             = var.agent_release_name
  repository       = var.agent_chart_repository
  chart            = "argocd-agent-agent"
  version          = var.agent_chart_version
  namespace        = kubernetes_namespace_v1.argocd.metadata[0].name
  create_namespace = false

  timeout = var.helm_timeout

  values = [yamlencode(merge({
    # Managed, not autonomous: the hub is the source of truth. Applications are
    # generated there by the ApplicationSets and promoted there by Kargo, and
    # this cluster only reconciles what it is handed. An autonomous agent would
    # need the delivery-plane repository, an ApplicationSet controller and a
    # Kargo of its own on every spoke.
    agentMode = "managed"

    # The identity is the client certificate's common name; "any" here means
    # "whatever the certificate says", which is this agent's name.
    auth = "mtls:any"

    tlsSecretName       = kubernetes_secret_v1.agent_client.metadata[0].name
    tlsRootCASecretName = kubernetes_secret_v1.agent_ca.metadata[0].name

    # The one outbound connection this cluster makes. It is a host name rather
    # than an address because the hub publishes it through Traefik with TLS
    # passthrough, and the principal's certificate is issued for that name.
    server     = var.principal.address
    serverPort = tostring(var.principal.port)

    # Route by spec.destination.name instead of by the Application's namespace.
    # That is what lets the hub's ApplicationSets stay exactly as they are —
    # they already address a cluster by the name Argo CD knows it by — and it
    # is what keeps an Application in the namespace it was created in on both
    # sides.
    destinationBasedMapping = true

    # The workload namespace belongs to the tenants stack, on this cluster as
    # on every other. An agent that created it would create it without the
    # quota, the NetworkPolicy or the SecretStore that make it a tenant.
    createNamespace   = false
    allowedNamespaces = var.agent_allowed_namespaces

    # The hybrid half. The hub runs a full Argo CD — it has to, it also deploys
    # to itself — so principal and agent both filter on this label and leave
    # everything without it to the hub's own application-controller. Without
    # it the two controllers would fight over every Application.
    labelSelector = var.principal.label_selector

    # The local Argo CD installed above.
    redisAddress          = "${local.argocd_fullname}-redis:6379"
    argoCdRedisSecretName = "${local.argocd_fullname}-redis"

    enableResourceProxy = var.enable_resource_proxy_rbac

    logLevel = var.agent_log_level

    serviceAccount = {
      create = true
      name   = local.agent_sa_name
    }

    rbac = {
      create            = true
      createClusterRole = true
    }
  }, var.agent_extra_values))]

  depends_on = [
    helm_release.argocd,
    kubernetes_secret_v1.agent_client,
    kubernetes_secret_v1.agent_ca,
  ]
}

# --- Hub side: the cluster Argo CD sees --------------------------------------
# Argo CD has no API for adding a cluster: it lists the Secrets in its own
# namespace carrying the "cluster" secret-type label, so writing the Secret is
# still the registration — but what it registers has changed shape.
#
#   server   no longer the spoke's API endpoint but the principal's resource
#            proxy on the hub, with the agent named in the query string. Every
#            live-resource request the UI makes goes there and out over the
#            agent's own connection.
#   config   a client certificate for that proxy, signed by the same CA, in
#            place of a cluster-admin bearer token for the spoke.
#
# The annotation is the other half of the hybrid arrangement: it tells the
# hub's application-controller to leave every Application targeting this
# cluster alone, because the spoke's controller owns them now. It needs Argo CD
# 3.4 or later; on anything older the two controllers reconcile the same
# Application against each other.
resource "tls_private_key" "resource_proxy_client" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "resource_proxy_client" {
  private_key_pem = tls_private_key.resource_proxy_client.private_key_pem

  subject {
    common_name = local.name
  }
}

resource "tls_locally_signed_cert" "resource_proxy_client" {
  cert_request_pem   = tls_cert_request.resource_proxy_client.cert_request_pem
  ca_private_key_pem = var.ca.private_key_pem
  ca_cert_pem        = var.ca.cert_pem

  validity_period_hours = var.client_certificate_validity_hours
  early_renewal_hours   = var.client_certificate_early_renewal_hours

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "client_auth",
  ]
}

resource "kubernetes_secret_v1" "cluster" {
  provider = kubernetes.hub

  metadata {
    name      = "cluster-${local.name}"
    namespace = var.principal.namespace
    labels = merge(local.labels, {
      "argocd.argoproj.io/secret-type" = "cluster"
      # How the principal maps this cluster entry to an agent. Written by
      # `argocd-agentctl agent create` too, and read by the principal's cluster
      # manager.
      "argocd-agent.argoproj-labs.io/agent-name" = local.name
    })

    annotations = {
      "onek8s.io/cluster-name" = var.foundation.cluster_name
      # Argo CD 3.4+: the hub's application-controller skips every Application
      # whose destination is this cluster. The agent's controller has them.
      "argocd.argoproj.io/skip-reconcile" = "true"
    }
  }

  data = merge(
    {
      name   = local.name
      server = "https://${var.principal.resource_proxy_address}?agentName=${local.name}"

      config = jsonencode({
        tlsClientConfig = {
          insecure = false
          certData = base64encode(tls_locally_signed_cert.resource_proxy_client.cert_pem)
          keyData  = base64encode(tls_private_key.resource_proxy_client.private_key_pem)
          caData   = base64encode(var.ca.cert_pem)
        }
      })
    },
    length(var.namespaces) > 0 ? {
      namespaces       = join(",", var.namespaces)
      clusterResources = tostring(var.cluster_resources)
    } : {},
    var.project != null ? { project = var.project } : {},
  )
}
