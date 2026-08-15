# Registers one foundations/<cloud> cluster as a spoke of the Argo CD hub that
# foundations/azure runs on AKS. Two clusters are touched in one module, which
# is why it takes two kubernetes provider configurations:
#
#   spoke (kubernetes)            hub (kubernetes.hub)
#   ─────────────────────────     ─────────────────────────────────
#   ServiceAccount argocd-manager
#   ClusterRole + binding          Secret "cluster-<name>", labelled
#   Secret (SA token) ────────────▶  argocd.argoproj.io/secret-type: cluster
#
# The credential is a ServiceAccount bearer token minted on the spoke itself,
# not the cloud's admin kubeconfig: it is the one authentication mode all the
# spoke clusters share (EKS access entries, GKE, OKE and NKP all speak plain
# Kubernetes RBAC), it carries exactly the rights granted below and nothing
# else, and revoking a spoke is deleting one ServiceAccount rather than
# rotating a cloud credential.
locals {
  name = coalesce(var.name, var.cloud)

  labels = merge({
    "app.kubernetes.io/managed-by" = "terraform"
    "onek8s.io/cloud"              = var.cloud
    "onek8s.io/environment"        = var.environment
    "onek8s.io/spoke"              = local.name
  }, var.labels)

  # GKE publishes a bare host where EKS, OKE and the NKP kubeconfig publish a
  # complete https URL — the same asymmetry the tenants stack's kubernetes
  # providers work around.
  server = var.cloud == "gcp" ? "https://${var.foundation.cluster_endpoint}" : var.foundation.cluster_endpoint

  # Namespace-scoped bindings are only possible when Argo CD is confined to a
  # namespace list *and* barred from cluster-scoped resources; anything else
  # needs the ClusterRoleBinding. Argo CD enforces the same split from its
  # side through the cluster Secret's namespaces/clusterResources fields, so
  # the two halves are configured from one pair of variables.
  namespace_scoped = length(var.namespaces) > 0 && !var.cluster_resources
}

# --- Spoke side: the identity Argo CD acts as -------------------------------
resource "kubernetes_service_account_v1" "manager" {
  metadata {
    name      = var.service_account_name
    namespace = var.service_account_namespace
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role_v1" "manager" {
  metadata {
    name   = "${var.service_account_name}-role"
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

resource "kubernetes_cluster_role_binding_v1" "manager" {
  count = local.namespace_scoped ? 0 : 1

  metadata {
    name   = "${var.service_account_name}-role-binding"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.manager.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.manager.metadata[0].name
    namespace = kubernetes_service_account_v1.manager.metadata[0].namespace
  }
}

# A RoleBinding may reference a ClusterRole: the same rules apply, but only
# inside the namespace holding the binding. One per allowed namespace, so the
# API server enforces the boundary Argo CD is also configured with.
resource "kubernetes_role_binding_v1" "manager" {
  for_each = local.namespace_scoped ? toset(var.namespaces) : toset([])

  metadata {
    name      = "${var.service_account_name}-role-binding"
    namespace = each.value
    labels    = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.manager.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.manager.metadata[0].name
    namespace = kubernetes_service_account_v1.manager.metadata[0].namespace
  }
}

# Kubernetes 1.24+ stopped minting a Secret per ServiceAccount, and the tokens
# projected into pods are short-lived and audience-bound — neither is usable by
# a controller on another cluster. An explicitly created
# "kubernetes.io/service-account-token" Secret is still honoured and is what
# `argocd cluster add` relies on: the token controller fills it in, and
# wait_for_service_account_token holds the apply until it has.
resource "kubernetes_secret_v1" "manager_token" {
  metadata {
    name      = "${var.service_account_name}-token"
    namespace = kubernetes_service_account_v1.manager.metadata[0].namespace
    labels    = local.labels

    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.manager.metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# --- Hub side: the cluster Argo CD sees --------------------------------------
# Argo CD discovers clusters by listing Secrets in its own namespace carrying
# the "cluster" secret-type label; there is no API to register one, so this is
# the registration. The labels are also the selector surface of an
# ApplicationSet cluster generator, which is how "deploy this to every cloud"
# (or to just the AWS one) stays a single object on the hub.
resource "kubernetes_secret_v1" "cluster" {
  provider = kubernetes.hub

  metadata {
    name      = "cluster-${local.name}"
    namespace = try(var.hub.argocd_namespace, "argocd")
    labels    = merge(local.labels, { "argocd.argoproj.io/secret-type" = "cluster" })

    annotations = {
      "onek8s.io/cluster-name" = var.foundation.cluster_name
    }
  }

  data = merge(
    {
      name   = local.name
      server = local.server

      # The CA comes from the foundation's own output rather than from the
      # token Secret's ca.crt: same certificate, but this way the hub trusts
      # what the cloud published for the API server, not what a pod inside it
      # was handed.
      config = jsonencode({
        bearerToken = kubernetes_secret_v1.manager_token.data["token"]
        tlsClientConfig = {
          insecure = false
          caData   = var.foundation.cluster_ca_certificate
        }
      })
    },
    length(var.namespaces) > 0 ? {
      namespaces       = join(",", var.namespaces)
      clusterResources = tostring(var.cluster_resources)
    } : {},
    var.project != null ? { project = var.project } : {},
  )

  # Deleting the binding before the hub stops using the token would leave Argo
  # CD hammering the spoke with 403s; ordering the Secret after the RBAC keeps
  # create and destroy in the sensible order.
  depends_on = [
    kubernetes_cluster_role_binding_v1.manager,
    kubernetes_role_binding_v1.manager,
  ]
}
