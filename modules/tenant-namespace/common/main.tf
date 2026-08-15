locals {
  namespace = coalesce(var.namespace, var.tenant_name)

  labels = merge({
    "onek8s.io/tenant"             = var.tenant_name
    "app.kubernetes.io/managed-by" = "terraform"
  }, var.namespace_labels)

  # Pod Security admission: the API server's own guardrail, switched on by
  # labels on the namespace and applied to every pod created in it, whoever
  # creates it — Argo CD, a tenant's kubectl, or a controller acting on their
  # behalf. Nothing has to be installed for it; it is built into Kubernetes.
  #
  # "restricted" is the platform default because it is the only built-in level
  # that requires a non-root user: "baseline" blocks the obvious escapes but
  # still admits a container running as UID 0. Under "restricted" a pod that
  # has not said who it runs as — runAsNonRoot, no privilege escalation, all
  # capabilities dropped, a seccomp profile — is refused at admission instead
  # of quietly starting as root against the node's kernel.
  #
  # All three modes at the same level, because they answer at different
  # moments: "enforce" rejects the pod, while "warn" and "audit" evaluate the
  # object that would create it, so applying a Deployment whose template
  # violates the level says so immediately rather than leaving a Deployment
  # that will never produce a pod.
  #
  # Deliberately no *-version labels, which leaves all three at "latest": the
  # level tracks the API server, so a cluster upgrade tightens the check
  # rather than holding it at whatever the standard meant on the day the
  # namespace was created.
  pod_security_labels = {
    "pod-security.kubernetes.io/enforce" = var.pod_security_standard
    "pod-security.kubernetes.io/warn"    = var.pod_security_standard
    "pod-security.kubernetes.io/audit"   = var.pod_security_standard
  }

  # Merged last, so a tenant's own labels cannot turn the guardrail off by
  # spelling one of these keys: those labels are descriptive, and this set is
  # not. Only the namespace carries them — they mean nothing on the
  # ServiceAccount or the SecretStore.
  namespace_labels = merge(local.labels, local.pod_security_labels)
}

# --- Namespace + guardrails (skipped when the cloud provides a managed
# --- namespace, as on Azure) -------------------------------------------------
resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name   = local.namespace
    labels = local.namespace_labels
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

# --- Ingress isolation -------------------------------------------------------
# Two policies on every cloud, Azure included: pods answer their own namespace
# and the platform ingress controller, and nothing else. Egress stays open.
#
# On AKS the namespace is an ARM-managed object that can carry a network policy
# of its own, and it deliberately does not: its built-in "AllowSameNamespace"
# cannot be widened from the Kubernetes API, so a tenant Ingress would be
# unreachable from the ingress namespace. azure/main.tf leaves it at AllowAll
# and these two policies are the whole of the namespace's ingress isolation
# there, the same as everywhere else.
resource "kubernetes_network_policy_v1" "same_namespace_only" {
  metadata {
    name      = "allow-same-namespace-only"
    namespace = local.namespace
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

  depends_on = [kubernetes_namespace_v1.this]
}

# The policy above used to be conditional on this module creating the
# namespace, which is what left AKS relying on the managed namespace's own
# policy. Dropping that condition changes its address, and a tenant that
# already exists on EKS, GKE or OKE should keep its policy rather than have it
# deleted and rebuilt. (No-op on Azure, where there was no instance to move.)
moved {
  from = kubernetes_network_policy_v1.same_namespace_only[0]
  to   = kubernetes_network_policy_v1.same_namespace_only
}

# The one hole in "same namespace only": the platform ingress controller,
# which is what makes a tenant's Ingress reachable at all. NetworkPolicies are
# additive, so this is a separate object rather than a clause of the one above,
# and a cluster with no ingress controller simply leaves it out.
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
