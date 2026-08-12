locals {
  namespace = coalesce(var.namespace, var.tenant_name)

  labels = merge({
    "onek8s.io/tenant"             = var.tenant_name
    "app.kubernetes.io/managed-by" = "terraform"
  }, var.namespace_labels)

  # A direction set to AllowAll needs no NetworkPolicy at all: listing it in
  # policy_types would default-deny it instead.
  network_policy_types = concat(
    var.network_policy.ingress == "AllowAll" ? [] : ["Ingress"],
    var.network_policy.egress == "AllowAll" ? [] : ["Egress"],
  )
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

# Default tenant NetworkPolicy with the same semantics as the Azure
# managed-namespace defaultNetworkPolicy (defaults: ingress=AllowSameNamespace,
# egress=AllowAll). A direction is restricted by listing it in policy_types;
# AllowSameNamespace then re-opens it towards the tenant's own pods, DenyAll
# leaves it closed. Note that egress=AllowSameNamespace/DenyAll also blocks
# DNS to kube-system, matching the literal Azure semantics.
resource "kubernetes_network_policy_v1" "tenant_default" {
  count = var.create_namespace && length(local.network_policy_types) > 0 ? 1 : 0

  metadata {
    name      = "tenant-default"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = local.network_policy_types

    dynamic "ingress" {
      for_each = var.network_policy.ingress == "AllowSameNamespace" ? [1] : []
      content {
        from {
          pod_selector {}
        }
      }
    }

    dynamic "egress" {
      for_each = var.network_policy.egress == "AllowSameNamespace" ? [1] : []
      content {
        to {
          pod_selector {}
        }
      }
    }
  }
}

# Renamed from the fixed "allow-same-namespace-only" policy; keep state moves
# cheap for existing deployments (the in-cluster object is still replaced
# because its name changed).
moved {
  from = kubernetes_network_policy_v1.same_namespace_only
  to   = kubernetes_network_policy_v1.tenant_default
}

# Container-level defaults so the quota's limits.* entries do not reject pods
# that omit resources, and so no single container can request the whole quota.
# Created on every cloud: the Azure managed namespace brings quota + netpol
# but no LimitRange.
resource "kubernetes_limit_range_v1" "tenant_defaults" {
  metadata {
    name      = "tenant-defaults"
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    limit {
      type = "Container"

      default_request = {
        cpu    = var.limit_range.default_cpu_request
        memory = var.limit_range.default_memory_request
      }

      default = {
        cpu    = var.limit_range.default_cpu_limit
        memory = var.limit_range.default_memory_limit
      }

      max = (var.limit_range.max_cpu != null || var.limit_range.max_memory != null) ? merge(
        var.limit_range.max_cpu != null ? { cpu = var.limit_range.max_cpu } : {},
        var.limit_range.max_memory != null ? { memory = var.limit_range.max_memory } : {},
      ) : null
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

# --- Shared Redis connection details -----------------------------------------
# Published only for tenants whose Redis delegation exists, so workloads can
# mount/env-inject the endpoint without hardcoding it. Credentials are never
# in here — authentication is via the tenant's workload identity.
resource "kubernetes_config_map_v1" "redis_connection" {
  count = var.redis_connection != null ? 1 : 0

  metadata {
    name      = "redis-connection"
    namespace = local.namespace
    labels    = local.labels
  }

  data = var.redis_connection

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
