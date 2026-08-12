locals {
  namespace = var.tenant_name

  # Secrets Manager names are hierarchical by convention:
  # "<environment>/<tenant>/<secret-name>". The IAM resource restriction
  # below makes this convention a hard security boundary.
  secret_prefix = "${var.environment}/${var.tenant_name}/"

  # "https://oidc.eks.<region>.amazonaws.com/id/XXXX" -> hostname/path used in
  # trust policy condition keys.
  oidc_issuer = replace(var.oidc_issuer_url, "https://", "")

  # The keyspace of the shared cache is sliced per tenant by ACL key pattern,
  # mirroring the secret-prefix model.
  redis_user_id    = "tenant-${var.tenant_name}-${var.environment}"
  redis_key_prefix = "${var.tenant_name}:"
}

# --- Tenant identity: IAM role trusted via IRSA ------------------------------
# The trust policy pins BOTH the audience and the exact ServiceAccount
# subject, so only pods running as this tenant's SA can assume the role.
data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${local.namespace}:${var.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tenant" {
  name               = "tenant-${var.tenant_name}-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# --- Least-privilege secret access: ARN prefix restriction -------------------
# Note the trailing "*": Secrets Manager appends a random 6-character suffix
# to secret ARNs, so the wildcard is required even for exact names.
data "aws_iam_policy_document" "secrets" {
  statement {
    sid = "ReadOwnSecretsOnly"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${local.secret_prefix}*",
    ]
  }

  statement {
    sid       = "DecryptViaSecretsManagerOnly"
    actions   = ["kms:Decrypt"]
    resources = [var.secrets_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "secrets" {
  name   = "tenant-secrets-prefix"
  role   = aws_iam_role.tenant.id
  policy = data.aws_iam_policy_document.secrets.json
}

# --- Optional shared Redis delegation ----------------------------------------
# A per-tenant, password-authenticated ElastiCache user whose ACL restricts
# it to the tenant's "<tenant>:" key slice, associated into the foundation's
# user group (which attaches it to the shared serverless cache). The password
# is stored in Secrets Manager under the tenant's secret prefix (encrypted
# with the platform CMK the tenant may decrypt via Secrets Manager) and
# reaches the workload through the "redis-auth" ExternalSecret created in
# common — no cloud-specific code in the app.
resource "random_password" "redis" {
  count = var.redis_enabled ? 1 : 0

  # ElastiCache passwords: 16-128 printable chars; stay alphanumeric to
  # avoid the disallowed specials.
  length  = 32
  special = false
}

resource "aws_elasticache_user" "redis" {
  count = var.redis_enabled ? 1 : 0

  user_id       = local.redis_user_id
  user_name     = local.redis_user_id
  engine        = "valkey"
  access_string = "on ~${local.redis_key_prefix}* +@all -@admin -@dangerous"

  authentication_mode {
    type      = "password"
    passwords = [random_password.redis[0].result]
  }

  lifecycle {
    precondition {
      condition     = var.redis_user_group_id != null
      error_message = "redis_enabled = true but the foundation exports no redis_user_group_id — deploy a foundation that includes the shared ElastiCache cache first."
    }
  }
}

resource "aws_elasticache_user_group_association" "redis" {
  count = var.redis_enabled ? 1 : 0

  user_group_id = var.redis_user_group_id
  user_id       = aws_elasticache_user.redis[0].user_id
}

resource "aws_secretsmanager_secret" "redis_auth" {
  count = var.redis_enabled ? 1 : 0

  name       = "${local.secret_prefix}redis-auth"
  kms_key_id = var.secrets_kms_key_arn
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  count = var.redis_enabled ? 1 : 0

  secret_id     = aws_secretsmanager_secret.redis_auth[0].id
  secret_string = random_password.redis[0].result
}

# --- Kubernetes-side resources (namespace, SA, namespaced SecretStore) -------
module "common" {
  source = "../common"

  tenant_name      = var.tenant_name
  namespace        = local.namespace
  create_namespace = true
  namespace_labels = var.namespace_labels
  quota            = var.quota
  network_policy   = var.network_policy
  limit_range      = var.limit_range

  service_account_name = var.service_account_name
  service_account_annotations = {
    "eks.amazonaws.com/role-arn" = aws_iam_role.tenant.arn
  }

  secret_store_provider = {
    aws = {
      service = "SecretsManager"
      region  = var.region
      auth = {
        jwt = {
          serviceAccountRef = {
            name = var.service_account_name
          }
        }
      }
    }
  }

  redis_connection = var.redis_enabled ? {
    REDIS_HOST = var.redis_endpoint_address
    REDIS_PORT = tostring(var.redis_endpoint_port)
    REDIS_TLS  = "true"
    # RBAC: AUTH as the tenant's own ElastiCache user; the password arrives
    # via the "redis-auth" ExternalSecret.
    REDIS_USERNAME   = local.redis_user_id
    REDIS_KEY_PREFIX = local.redis_key_prefix
  } : null
  redis_auth_remote_key = var.redis_enabled ? "${local.secret_prefix}redis-auth" : null
}
