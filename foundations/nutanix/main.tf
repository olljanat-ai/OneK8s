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

  # One JWT auth mount per cluster, trusting exactly one issuer's signing keys.
  # A second cluster's "team-alpha/workload" therefore fails the signature and
  # the issuer check rather than logging in as this one's — the isolation the
  # OCI policies get by pinning request.principal.cluster_id, and that AWS gets
  # by naming one OIDC provider ARN in a trust policy.
  vault_auth_path = coalesce(var.vault_auth_path, "jwt-${local.name}")

  # The audience the ServiceAccount token is minted for, and the one every
  # Vault role requires. A token the cluster issued for anything else — the API
  # server itself included — fails the audience check, which is what stops a
  # token from being replayed against Vault. It is the same role "sts.amazonaws.com"
  # and "api://AzureADTokenExchange" play in the other clouds' trust policies.
  vault_audience = "vault"
}
