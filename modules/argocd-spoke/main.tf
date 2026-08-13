locals {
  labels = merge({
    "app.kubernetes.io/part-of"    = "argocd-agent"
    "app.kubernetes.io/managed-by" = "terraform"
    "onek8s.io/agent"              = var.agent_name
  }, var.labels)

  # Release name of the spoke's Argo CD, and therefore the prefix of every
  # object it creates. Pinned rather than derived so the agent can be told
  # where redis is without reading it back out of the release.
  argocd_release = "argocd"

  service_account_name = "argocd-agent-agent"
}

resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name   = var.namespace
    labels = local.labels
  }
}

# -----------------------------------------------------------------------------
# The workload half of Argo CD.
#
# A managed agent is not a self-contained Argo CD: the application controller
# and repo server have to run *here*, next to the API server they reconcile
# against, and the agent feeds them Applications it receives from the hub. What
# does not run here is argocd-server — the UI/API is the hub's job, and leaving
# it out is what keeps the spoke free of any endpoint worth exposing.
#
# The community chart has no switch to leave a component out entirely, so the
# ones a spoke must not run are scaled to zero instead. Their Services and RBAC
# stay behind, which is inert; the pods are what matter.
# -----------------------------------------------------------------------------
resource "helm_release" "argocd" {
  count = var.install_argocd ? 1 : 0

  name       = local.argocd_release
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = var.namespace

  values = concat([yamlencode({
    fullnameOverride = local.argocd_release

    crds = {
      install = true
    }

    # No API server, no SSO, no notifications: the hub owns all three.
    server = {
      replicas = 0
    }
    dex = {
      enabled = false
    }
    notifications = {
      enabled = false
    }
    # ApplicationSets are generated on the hub; a managed agent must not create
    # Applications of its own.
    applicationSet = {
      replicas = 0
    }

    # What the agent actually needs on this side.
    controller = {
      replicas = 1
    }
    redis = {
      enabled = false
    }
  })], var.argocd_values == "" ? [] : [var.argocd_values])

  depends_on = [kubernetes_namespace_v1.this]
}

# -----------------------------------------------------------------------------
# mTLS material. The agent reads both out of the Kubernetes API at startup
# rather than from a mount, so these are plain secrets with the names the
# agent's parameters point at.
# -----------------------------------------------------------------------------
resource "kubernetes_secret_v1" "ca" {
  metadata {
    name      = "argocd-agent-ca"
    namespace = var.namespace
    labels    = local.labels
  }

  # The CA certificate only — the hub keeps the key, and nothing on a spoke
  # ever signs anything.
  data = {
    "ca.crt" = var.ca_cert_pem
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_secret_v1" "client_tls" {
  metadata {
    name      = "argocd-agent-client-tls"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "tls.crt" = var.client_cert_pem
    "tls.key" = var.client_key_pem
  }

  type = "kubernetes.io/tls"

  depends_on = [kubernetes_namespace_v1.this]
}

# -----------------------------------------------------------------------------
# The agent itself: the only component in this whole topology that opens a
# connection between clusters, and it opens it outbound.
# -----------------------------------------------------------------------------
resource "helm_release" "agent" {
  name       = "argocd-agent"
  repository = "oci://ghcr.io/argoproj-labs/argocd-agent"
  chart      = "argocd-agent-agent"
  version    = var.agent_chart_version
  namespace  = var.namespace

  values = [yamlencode({
    image = {
      repository = var.agent_image_repository
      tag        = var.agent_image_tag
    }

    serviceAccount = {
      create = true
      name   = local.service_account_name
    }

    agentMode = var.agent_mode

    # The agent's own credential identifier: for mTLS it carries no
    # configuration, because the identity *is* the client certificate. The
    # principal is the side that extracts the agent name from the subject.
    auth = "mtls:any"

    server     = var.principal_address
    serverPort = tostring(var.principal_port)

    tlsSecretName       = kubernetes_secret_v1.client_tls.metadata[0].name
    tlsRootCASecretName = kubernetes_secret_v1.ca.metadata[0].name
    tlsClientInSecure   = "false"

    logLevel          = var.log_level
    heartbeatInterval = var.heartbeat_interval

    # The spoke's own Argo CD cache. The agent publishes resource state here;
    # the hub reads it back through the principal's redis proxy.
    redisAddress          = "${local.argocd_release}-redis:6379"
    argoCdRedisSecretName = "${local.argocd_release}-redis"

    enableResourceProxy     = true
    destinationBasedMapping = var.destination_based_mapping
    createNamespace         = var.destination_based_mapping

    rbac = {
      create            = true
      createClusterRole = true
    }
  })]

  depends_on = [
    helm_release.argocd,
    kubernetes_secret_v1.ca,
    kubernetes_secret_v1.client_tls,
  ]
}

# -----------------------------------------------------------------------------
# Live resources.
#
# The agent chart grants access to Argo CD's own resources and nothing else,
# which is enough to sync but not to answer the API requests the hub's UI makes
# when someone opens an application's resource tree. Those arrive through the
# principal's resource proxy and are served by this agent against the local API
# server, so they need read access to what the applications actually deploy.
#
# Read-only on purpose: the application controller — not the agent — is what
# writes to this cluster, and it has its own permissions from the Argo CD
# install above.
# -----------------------------------------------------------------------------
resource "kubernetes_cluster_role_v1" "live_resources" {
  count = var.live_resources_rbac ? 1 : 0

  metadata {
    name   = "argocd-agent-live-resources"
    labels = local.labels
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "live_resources" {
  count = var.live_resources_rbac ? 1 : 0

  metadata {
    name   = "argocd-agent-live-resources"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.live_resources[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = local.service_account_name
    namespace = var.namespace
  }

  depends_on = [helm_release.agent]
}
