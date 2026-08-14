locals {
  namespace = coalesce(var.namespace, var.tenant_name)

  labels = merge({
    "onek8s.io/tenant"             = var.tenant_name
    "app.kubernetes.io/managed-by" = "terraform"
  }, var.namespace_labels)
}

# --- Namespace + guardrails (skipped when the cloud provides a managed
# --- namespace, as on Azure) -------------------------------------------------
resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name   = local.namespace
    labels = local.labels
  }
}

resource "kubernetes_resource_quota_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name      = "tenant-quota"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = var.quota.cpu_requests
      "limits.cpu"      = var.quota.cpu_limits
      "requests.memory" = var.quota.memory_requests
      "limits.memory"   = var.quota.memory_limits
      "pods"            = var.quota.pods
    }
  }
}

# Ingress is only allowed from within the tenant's own namespace; egress stays
# open (mirrors the Azure managed-namespace default of
# ingress=AllowSameNamespace / egress=AllowAll).
resource "kubernetes_network_policy_v1" "same_namespace_only" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name      = "allow-same-namespace-only"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {}
      }
    }
  }
}

# The one hole in "same namespace only": the platform ingress controller,
# which is what makes a tenant's Ingress reachable at all. NetworkPolicies are
# additive, so this is a separate object rather than a clause of the one above
# — which is what lets it apply on Azure too, where the namespace (and its
# AllowSameNamespace policy) is managed by AKS and not created here.
#
# The namespace is matched by kubernetes.io/metadata.name, the label the API
# server maintains itself, so nothing has to label the ingress namespace for
# this to hold.
resource "kubernetes_network_policy_v1" "allow_platform_ingress" {
  count = var.ingress_controller_namespace == "" ? 0 : 1

  metadata {
    name      = "allow-platform-ingress"
    namespace = local.namespace
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.ingress_controller_namespace
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# --- Tenant workload identity binding ---------------------------------------
resource "kubernetes_service_account_v1" "workload" {
  metadata {
    name        = var.service_account_name
    namespace   = local.namespace
    labels      = merge(local.labels, var.service_account_labels)
    annotations = var.service_account_annotations
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# --- Namespaced SecretStore --------------------------------------------------
# Deliberately a SecretStore (not ClusterSecretStore): it lives in the tenant
# namespace, can only be referenced by ExternalSecrets in that namespace, and
# authenticates exclusively with this tenant's ServiceAccount identity.
resource "kubernetes_manifest" "secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = "tenant-store"
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      provider = var.secret_store_provider
    }
  }

  depends_on = [
    kubernetes_namespace_v1.this,
    kubernetes_service_account_v1.workload,
  ]
}
