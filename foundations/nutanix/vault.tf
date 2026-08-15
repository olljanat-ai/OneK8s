# The secret-backend half of the foundation pair, and the private cloud's
# answer to "where does workload identity come from when there is no cloud IAM
# plane?".
#
# Vault's Kubernetes auth method is that answer, and it is the same shape as
# the four public clouds' federation:
#
#   Pod ──runs as──▶ ServiceAccount ──projected token (aud=vault)──▶ Vault
#         ──TokenReview against THIS cluster──▶ role ──policy──▶ "<tenant>-*"
#
# Vault, not Kubernetes, decides what the resulting token may read, so the
# boundary is enforced outside the cluster exactly as Key Vault ABAC, an IAM
# ARN prefix, a Secret Manager IAM condition and an OCI policy condition are.
# Two things are created here and nothing else: the environment's KV v2 mount
# (its "vault"), and the auth mount that trusts this one cluster. Per-tenant
# roles and policies belong to modules/tenant-namespace/nutanix.

# --- The vault ---------------------------------------------------------------
resource "vault_mount" "secrets" {
  path        = local.vault_mount_path
  type        = "kv"
  options     = { version = "2" }
  description = "OneK8s ${var.environment} secrets: '<tenant>-<name>' per tenant, 'platform-<name>' for the platform"
}

# --- Trusting the cluster ----------------------------------------------------
# Vault runs outside the cluster, so it cannot use a token of its own to call
# the TokenReview API: it needs a reviewer credential. That is this
# ServiceAccount, and system:auth-delegator is the entirety of what it may do
# — ask "whose token is this?" and nothing else.
#
# Doing it this way is what keeps tenants out of it: with a reviewer credential
# configured on the mount, a tenant's own ServiceAccount needs no TokenReview
# rights to log in. (Vault's alternative is to review each login with the
# client's own token, which would mean granting system:auth-delegator to every
# tenant.)
resource "kubernetes_namespace_v1" "vault_auth" {
  metadata {
    name   = local.token_reviewer_namespace
    labels = local.labels
  }
}

resource "kubernetes_service_account_v1" "token_reviewer" {
  metadata {
    name      = local.token_reviewer_name
    namespace = kubernetes_namespace_v1.vault_auth.metadata[0].name
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role_binding_v1" "token_reviewer" {
  metadata {
    name   = "${local.token_reviewer_name}-auth-delegator"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.token_reviewer.metadata[0].name
    namespace = kubernetes_service_account_v1.token_reviewer.metadata[0].namespace
  }
}

# Kubernetes 1.24+ mints no Secret per ServiceAccount, and the tokens projected
# into pods are short-lived — neither is usable by a server outside the
# cluster. An explicitly created service-account-token Secret still is, and
# wait_for_service_account_token holds the apply until the token controller has
# filled it in. This is the same mechanism modules/argocd-spoke uses for the
# hub's spoke credential, with the same consequence: the token is long-lived,
# it lands in this stack's state, and nothing rotates it.
resource "kubernetes_secret_v1" "token_reviewer" {
  metadata {
    name      = "${local.token_reviewer_name}-token"
    namespace = kubernetes_service_account_v1.token_reviewer.metadata[0].namespace
    labels    = local.labels

    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.token_reviewer.metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

resource "vault_auth_backend" "kubernetes" {
  type        = "kubernetes"
  path        = local.vault_auth_path
  description = "OneK8s ${var.environment}: logins from the NKP cluster ${local.cluster_name}"
}

resource "vault_kubernetes_auth_backend_config" "this" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = module.cluster.host
  kubernetes_ca_cert = base64decode(module.cluster.cluster_ca_certificate)
  token_reviewer_jwt = kubernetes_secret_v1.token_reviewer.data["token"]

  # The issuer claim is not a security control here — the token is validated by
  # asking the cluster's own API server about it, and the audience is what pins
  # a login to Vault. Leaving issuer validation on only breaks the mount when a
  # cluster's issuer string changes, which is why Vault turns it off by default.
  disable_iss_validation = true

  # Vault is outside the cluster, so there is no local CA or local token to
  # fall back on: both come from the configuration above.
  disable_local_ca_jwt = true
}

# --- The platform's own identity ---------------------------------------------
# The counterpart of a tenant's role, for the ingress controller: pinned to the
# ingress namespace's ServiceAccount, scoped to the reserved "platform-" prefix
# that no tenant may claim. It reads the wildcard certificate and nothing else;
# no tenant identity can read that prefix, and this one can read no tenant's.
resource "vault_policy" "ingress" {
  count = var.enable_ingress ? 1 : 0

  name = "platform-ingress-${local.name}"

  # KV v2 puts a secret's value under data/ and its versions under metadata/,
  # so both are needed to read one; neither grants "list" on the mount, so
  # there is nothing to enumerate even inside the prefix.
  policy = <<-EOT
    path "${vault_mount.secrets.path}/data/${local.platform_secret_prefix}*" {
      capabilities = ["read"]
    }

    path "${vault_mount.secrets.path}/metadata/${local.platform_secret_prefix}*" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "ingress" {
  count = var.enable_ingress ? 1 : 0

  backend   = vault_auth_backend.kubernetes.path
  role_name = "platform-ingress-${local.name}"

  bound_service_account_names      = [local.ingress_service_account_name]
  bound_service_account_namespaces = [local.ingress_namespace]

  # Required from Vault 1.21 on, and a control in its own right: a token the
  # cluster minted for any other audience is refused.
  audience = local.vault_audience

  token_policies = [vault_policy.ingress[0].name]
  token_ttl      = var.vault_token_ttl
  # "default" stays in the token's policy set: it is what lets the holder
  # renew and revoke its own token, which External Secrets does.
  token_no_default_policy = false
}
