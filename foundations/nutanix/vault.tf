# The secret-backend half of the foundation pair, and the private cloud's
# answer to "where does workload identity come from when there is no cloud IAM
# plane?".
#
# The answer is the same mechanism the four public clouds use, because it is
# not really a cloud mechanism at all: **the Kubernetes API server is an OIDC
# provider**. It signs ServiceAccount tokens with its own key, publishes the
# matching public keys at /openid/v1/jwks, and stamps each token with
# iss (this cluster), sub (system:serviceaccount:<ns>:<sa>) and aud.
#
# What AKS, EKS, GKE and OKE add is only *hosting*: they publish that discovery
# document at a public URL and register it as a trusted identity provider in
# their IAM service. Nothing about it calls back into the cluster —
# AssumeRoleWithWebIdentity verifies a signature and matches claims:
#
#   Pod ──▶ SA token (iss, sub, aud, 10 min)
#             │
#             ▼
#           AWS STS / Entra / Google STS  ──verifies signature against JWKS──▶
#             role whose trust policy pins sub + aud
#
# Vault's **JWT auth method** is precisely that relying party, so the private
# cloud gets the same design rather than an imitation of it:
#
#   Pod ──▶ SA token (aud "vault") ──▶ Vault jwt mount
#             ├─ signature checked against the cluster's published JWKS
#             ├─ iss must be this cluster (bound_issuer)
#             ├─ aud must be "vault"  (bound_audiences)
#             └─ sub must be system:serviceaccount:<ns>:<sa> (bound_subject)
#                  ──▶ policy: read "<mount>/data/<tenant>-*"
#
# Consequences worth naming, all of them shared with the public clouds:
#
#   * Vault holds NO credential for this cluster, and needs no permission in
#     it. It reads one public, unauthenticated endpoint — the same one the
#     clouds republish to the whole internet.
#   * Nothing in the cluster holds a Vault credential either. The login is a
#     10-minute token the API server mints on demand for the audience "vault".
#   * The trust is one-directional and cryptographic. Revocation is by
#     expiry, not by callback — exactly as it is on AWS, Azure and GCP, and
#     the reason the tokens are short-lived.

# --- The vault ---------------------------------------------------------------
resource "vault_mount" "secrets" {
  path        = local.vault_mount_path
  type        = "kv"
  options     = { version = "2" }
  description = "OneK8s ${var.environment} secrets: '<tenant>-<name>' per tenant, 'platform-<name>' for the platform"
}

# --- Publishing the cluster as an OIDC provider ------------------------------
# Kubernetes ships the ClusterRole but binds it only to `system:serviceaccounts`,
# so the discovery documents are readable from inside the cluster and nowhere
# else. This is the binding HashiCorp's own Kubernetes-as-an-OIDC-provider
# guide prescribes, and it is what the managed clouds do on a far larger scale:
# what it exposes is the issuer URL and a set of **public keys**, which AKS,
# EKS, GKE and OKE all serve unauthenticated on the public internet by design.
# No token, no claim and no cluster data is reachable through it.
resource "kubernetes_cluster_role_binding_v1" "issuer_discovery" {
  count = var.publish_issuer_discovery ? 1 : 0

  metadata {
    name   = "onek8s-oidc-reviewer"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:service-account-issuer-discovery"
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "system:unauthenticated"
  }
}

# The issuer string tokens from this cluster actually carry. It is read rather
# than configured because it is the cluster's to decide (kubeadm and NKP default
# to https://kubernetes.default.svc.cluster.local, a name that resolves only
# inside the cluster), and because a mismatch between it and bound_issuer is the
# one failure mode that would otherwise surface as an opaque "invalid issuer" at
# every tenant login.
data "http" "openid_configuration" {
  count = var.cluster_issuer == null ? 1 : 0

  url         = "${module.cluster.host}/.well-known/openid-configuration"
  ca_cert_pem = base64decode(module.cluster.cluster_ca_certificate)

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "The API server of ${local.cluster_name} answered ${self.status_code} for /.well-known/openid-configuration. With publish_issuer_discovery = true this should be readable anonymously; a 401/403 means the cluster runs with anonymous-auth disabled, in which case publish the discovery documents somewhere Vault can read them and set cluster_issuer + cluster_jwks_url. See docs/nutanix.md."
    }
  }

  depends_on = [kubernetes_cluster_role_binding_v1.issuer_discovery]
}

locals {
  # What the cluster says about itself, unless overridden.
  cluster_issuer = coalesce(
    var.cluster_issuer,
    try(jsondecode(data.http.openid_configuration[0].response_body)["issuer"], null),
  )

  # Deliberately NOT the jwks_uri out of the discovery document: that URL is
  # built from the issuer, so on a default cluster it is an in-cluster name
  # Vault cannot resolve. The keys are fetched from the endpoint this stack
  # already reaches the API server on. Overriding it is how a cluster whose
  # JWKS is published elsewhere (the way EKS publishes to a public URL) is
  # wired up.
  cluster_jwks_url = coalesce(var.cluster_jwks_url, "${module.cluster.host}/openid/v1/jwks")

  # Fetching keys and running OIDC discovery are mutually exclusive in Vault.
  # Discovery is only possible when the issuer is a URL Vault can resolve,
  # which on a private cloud means the cluster was deliberately configured with
  # an external --service-account-issuer.
  use_oidc_discovery = var.cluster_oidc_discovery_url != null
}

# --- Trusting the cluster ----------------------------------------------------
# One JWT mount per cluster: a role name then means one cluster's assertions,
# the way an IAM trust policy names one cloud's OIDC provider.
resource "vault_jwt_auth_backend" "cluster" {
  type        = "jwt"
  path        = local.vault_auth_path
  description = "OneK8s ${var.environment}: ServiceAccount tokens issued by the NKP cluster ${local.cluster_name}"

  # Where the public keys come from. Either way Vault performs an anonymous
  # HTTPS GET and holds no credential for this cluster.
  jwks_url    = local.use_oidc_discovery ? null : local.cluster_jwks_url
  jwks_ca_pem = local.use_oidc_discovery ? null : base64decode(module.cluster.cluster_ca_certificate)

  oidc_discovery_url    = var.cluster_oidc_discovery_url
  oidc_discovery_ca_pem = local.use_oidc_discovery ? base64decode(module.cluster.cluster_ca_certificate) : null

  # The first half of "this token came from our cluster". The second half is
  # the signature check above; a token from any other issuer fails both.
  bound_issuer = local.cluster_issuer
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
  # so both are needed to read one; neither grants "list", so there is nothing
  # to enumerate even inside the prefix.
  policy = <<-EOT
    path "${vault_mount.secrets.path}/data/${local.platform_secret_prefix}*" {
      capabilities = ["read"]
    }

    path "${vault_mount.secrets.path}/metadata/${local.platform_secret_prefix}*" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_jwt_auth_backend_role" "ingress" {
  count = var.enable_ingress ? 1 : 0

  backend   = vault_jwt_auth_backend.cluster.path
  role_name = "platform-ingress-${local.name}"
  role_type = "jwt"

  # The same three claims every cloud's trust policy pins, in the same order of
  # importance: who signed it (the mount), who it was minted for, and who it
  # was minted as.
  bound_audiences = [local.vault_audience]
  bound_subject   = "system:serviceaccount:${local.ingress_namespace}:${local.ingress_service_account_name}"
  user_claim      = "sub"

  token_policies = [vault_policy.ingress[0].name]
  token_ttl      = var.vault_token_ttl
  # "default" stays in the token's policy set: it is what lets the holder renew
  # and revoke its own token, which External Secrets does. It grants no access
  # to any secret path.
  token_no_default_policy = false
}
