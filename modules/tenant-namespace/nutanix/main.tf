locals {
  namespace = var.tenant_name

  # Secrets in the shared KV v2 mount are namespaced by convention:
  # "<tenant>-<secret-name>". The Vault policy below makes this convention a
  # hard security boundary — the same convention, and the same kind of
  # boundary, as the Key Vault ABAC condition, the Secrets Manager ARN prefix,
  # the Secret Manager IAM condition and the OCI policy condition.
  secret_prefix = "${var.tenant_name}-"

  # One name for the tenant's policy and its role, so what a login gets is
  # readable from either side.
  vault_role_name = "tenant-${var.tenant_name}-${var.environment}"

  # The subject the cluster stamps into this tenant's ServiceAccount tokens,
  # and the only one this role accepts. It is the *identical string* the other
  # three federating clouds pin in their trust policies:
  #
  #   aws    "<issuer>:sub" = "system:serviceaccount:team-alpha:workload"
  #   azure  subject        = "system:serviceaccount:team-alpha:workload"
  #   gcp    <project>.svc.id.goog[team-alpha/workload]
  #   here   bound_subject  = "system:serviceaccount:team-alpha:workload"
  subject = "system:serviceaccount:${local.namespace}:${var.service_account_name}"
}

# --- Tenant identity: a Vault role that trusts one subject of one issuer -----
# There is no identity object to create on a private cloud — no UAMI, no IAM
# role, no GSA — and, unlike the OKE case it otherwise resembles, nothing
# queries the cluster either. The tenant's ServiceAccount token *is* the
# assertion: the API server signs it, Vault verifies that signature against the
# cluster's published public keys (foundations/nutanix configures the mount
# with them) and then matches three claims.
#
#   iss  the auth mount's bound_issuer — this cluster and no other
#   aud  bound_audiences — a token minted for anything else is refused
#   sub  bound_subject   — this namespace's ServiceAccount and no other
#
# That is exactly what AssumeRoleWithWebIdentity does with an IAM role's trust
# policy, which is why nothing here holds a credential: the trust is a public
# key and three strings.
resource "vault_jwt_auth_backend_role" "tenant" {
  backend   = var.vault_auth_path
  role_name = local.vault_role_name
  role_type = "jwt"

  bound_audiences = [var.vault_audience]
  bound_subject   = local.subject
  user_claim      = "sub"

  token_policies = [vault_policy.tenant.name]
  token_ttl      = var.vault_token_ttl
  # "default" stays in the token's policy set: it is what lets the holder renew
  # and revoke its own token, which External Secrets does. It grants no access
  # to any secret path.
  token_no_default_policy = false
}

# --- Least-privilege secret access: a path prefix -----------------------------
# KV v2 splits a secret into data/ (the value) and metadata/ (its versions), so
# reading one needs both. Note what is *not* granted:
#
#   - no "list" anywhere, so a tenant cannot enumerate the mount and discover
#     that other tenants exist — the same trade-off the OCI policy makes, and
#     the same consequence: ESO's dataFrom.find will not work, dataFrom.extract
#     will;
#   - no "create"/"update", so a tenant reads its secrets and never writes
#     them. Publishing into the vault is the platform's job, as it is on every
#     other cloud.
#
# Vault only allows a wildcard as the last character of a path, which is
# exactly the prefix match the other four clouds' conditions do.
resource "vault_policy" "tenant" {
  name = local.vault_role_name

  policy = <<-EOT
    path "${var.vault_mount_path}/data/${local.secret_prefix}*" {
      capabilities = ["read"]
    }

    path "${var.vault_mount_path}/metadata/${local.secret_prefix}*" {
      capabilities = ["read"]
    }
  EOT
}

# --- Kubernetes-side resources (namespace, SA, namespaced SecretStore) -------
module "common" {
  source = "../common"

  tenant_name      = var.tenant_name
  namespace        = local.namespace
  create_namespace = true
  namespace_labels = var.namespace_labels
  quota            = var.quota

  service_account_name = var.service_account_name

  ingress_controller_namespace = var.ingress_controller_namespace

  # No annotation on the ServiceAccount, and no RBAC of any kind: the token the
  # API server mints for it already carries everything Vault checks. A tenant
  # needs no rights over the TokenReview API — nothing reviews anything.
  secret_store_provider = {
    vault = merge(
      {
        server  = var.vault_address
        path    = var.vault_mount_path
        version = "v2"
        # External Secrets asks the API server for a short-lived token with
        # the audience this role requires (TokenRequest, not the SA's own
        # long-lived secret) and posts it to the JWT mount. The exchange is
        # the same one an IRSA-enabled pod makes against STS.
        auth = {
          jwt = {
            path = var.vault_auth_path
            role = vault_jwt_auth_backend_role.tenant.role_name
            kubernetesServiceAccountToken = {
              serviceAccountRef = {
                name = var.service_account_name
              }
              audiences         = [var.vault_audience]
              expirationSeconds = var.vault_token_expiration_seconds
            }
          }
        }
      },
      # A private CA is the normal case; Vault namespaces are Enterprise only.
      var.vault_ca_bundle == "" ? {} : { caBundle = var.vault_ca_bundle },
      var.vault_namespace == "" ? {} : { namespace = var.vault_namespace },
    )
  }
}
