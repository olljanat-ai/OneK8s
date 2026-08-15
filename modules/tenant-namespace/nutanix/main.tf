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
}

# --- Tenant identity: a Vault role bound to one namespace + ServiceAccount ---
# There is no identity object to create on a private cloud — no UAMI, no IAM
# role, no GSA. The principal is the (cluster, namespace, service account)
# tuple, exactly as it is on OKE: the cluster asserts it, Vault verifies it
# against that cluster's TokenReview API through the auth mount the foundation
# configured, and the binding lives entirely in Vault.
#
# The auth mount is per cluster, so "team-alpha/workload" on another cluster is
# a different principal even though the tuple reads the same.
resource "vault_kubernetes_auth_backend_role" "tenant" {
  backend   = var.vault_auth_path
  role_name = local.vault_role_name

  bound_service_account_names      = [var.service_account_name]
  bound_service_account_namespaces = [local.namespace]

  # Required from Vault 1.21 on, and a control in its own right: a token the
  # cluster minted for any other audience is refused, so a token issued to this
  # ServiceAccount for some other service cannot be replayed against Vault.
  audience = var.vault_audience

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

  # No annotation on the ServiceAccount: there is no cloud identity to point it
  # at. Nor does it need system:auth-delegator — the foundation configured the
  # auth mount with its own reviewer credential, so a tenant needs no rights
  # over the TokenReview API to log in.
  secret_store_provider = {
    vault = merge(
      {
        server  = var.vault_address
        path    = var.vault_mount_path
        version = "v2"
        auth = {
          kubernetes = {
            mountPath = var.vault_auth_path
            role      = vault_kubernetes_auth_backend_role.tenant.role_name
            serviceAccountRef = {
              name      = var.service_account_name
              audiences = [var.vault_audience]
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
