locals {
  name         = "${var.name_prefix}-${var.environment}"
  cluster_name = coalesce(var.cluster_name, local.name)

  labels = merge({
    "app.kubernetes.io/managed-by" = "terraform"
    "onek8s.io/cloud"              = "nutanix"
    "onek8s.io/environment"        = var.environment
  }, var.labels)

  # The KV v2 mount is this cloud's "vault": one per environment, holding every
  # tenant's secrets under "<tenant>-…" and the platform's own under
  # "platform-…", exactly like the Key Vault, the Secrets Manager account, the
  # Secret Manager project and the OCI Vault do.
  vault_mount_path = coalesce(var.vault_mount_path, local.name)

  # One Kubernetes auth mount per cluster. Vault matches a login against the
  # (namespace, service account) pair asserted by *this* cluster's TokenReview
  # API, so a second cluster's "team-alpha/workload" is a different principal
  # rather than the same one — the isolation the OCI policies get by pinning
  # request.principal.cluster_id.
  vault_auth_path = coalesce(var.vault_auth_path, "kubernetes-${local.name}")

  # The audience the ServiceAccount token is minted for, and the one the Vault
  # role requires. Vault 1.21 rejects a login against a role with no audience,
  # and a token minted for a different audience is refused — so this is also
  # what stops a token the cluster issued for something else from being
  # replayed against Vault.
  vault_audience = "vault"

  # Vault's counterpart of a cloud's TokenReview-equivalent trust: the
  # ServiceAccount whose token Vault presents when it asks this cluster
  # "whose token is this?".
  token_reviewer_namespace = "vault-auth"
  token_reviewer_name      = "vault-token-reviewer"
}
