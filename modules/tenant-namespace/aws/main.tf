locals {
  namespace = var.tenant_name

  # Secrets Manager names are hierarchical by convention:
  # "<environment>/<tenant>/<secret-name>". The IAM resource restriction
  # below makes this convention a hard security boundary.
  secret_prefix = "${var.environment}/${var.tenant_name}/"

  # "https://oidc.eks.<region>.amazonaws.com/id/XXXX" -> hostname/path used in
  # trust policy condition keys.
  oidc_issuer = replace(var.oidc_issuer_url, "https://", "")
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
}
