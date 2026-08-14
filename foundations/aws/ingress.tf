# Traefik as the platform ingress controller, the same one every other cloud
# runs (modules/platform-ingress), plus the one thing that is genuinely
# AWS-shaped: reading the platform wildcard certificate out of Secrets
# Manager.
#
# This is the consumer the Renew Certificate workflow's "distribute" mode was
# built for. The certificate is written there as a single JSON value holding
# tls.crt and tls.key, under the reserved "platform" tenant's prefix, so it
# reaches the cluster the same way a tenant's own secrets do:
#
#   Secrets Manager <env>/platform/wildcard-…
#     --(SecretStore + ExternalSecret, IRSA)-->
#       Secret platform-wildcard-tls (kubernetes.io/tls)
#         --(Traefik default TLSStore)--> every websecure router
locals {
  ingress_namespace               = "traefik"
  ingress_class_name              = "traefik"
  ingress_tls_secret_name         = "platform-wildcard-tls"
  ingress_service_account_name    = "platform-secrets"
  ingress_secret_store_name       = "platform-store"
  ingress_platform_secret_prefix  = "${var.environment}/platform/"
  ingress_certificate_secret_name = "${var.environment}/platform/${trimprefix(var.ingress_certificate_name, "platform-")}"

  # "https://oidc.eks.<region>.amazonaws.com/id/XXXX" -> the condition key
  # prefix used in the trust policy.
  ingress_oidc_issuer = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# --- Platform identity: IAM role trusted via IRSA ----------------------------
# Same shape as a tenant identity in modules/tenant-namespace/aws, pinned to
# the ingress namespace's own ServiceAccount and to the reserved "platform"
# prefix. No tenant identity can read that prefix, and this one can read no
# tenant's.
data "aws_iam_policy_document" "ingress_trust" {
  count = var.enable_ingress ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.ingress_oidc_issuer}:sub"
      values   = ["system:serviceaccount:${local.ingress_namespace}:${local.ingress_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.ingress_oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingress_secrets" {
  count = var.enable_ingress ? 1 : 0

  name               = "platform-ingress-${local.name}"
  assume_role_policy = data.aws_iam_policy_document.ingress_trust[0].json
}

data "aws_iam_policy_document" "ingress_secrets" {
  count = var.enable_ingress ? 1 : 0

  statement {
    sid = "ReadPlatformSecretsOnly"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    # The trailing "*" is required even for an exact name: Secrets Manager
    # appends a random six-character suffix to every secret ARN.
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${local.ingress_platform_secret_prefix}*",
    ]
  }

  statement {
    sid       = "DecryptViaSecretsManagerOnly"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.secrets.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ingress_secrets" {
  count = var.enable_ingress ? 1 : 0

  name   = "platform-secrets-prefix"
  role   = aws_iam_role.ingress_secrets[0].id
  policy = data.aws_iam_policy_document.ingress_secrets[0].json
}

# --- The controller ----------------------------------------------------------
module "ingress" {
  source = "../../modules/platform-ingress"
  count  = var.enable_ingress ? 1 : 0

  chart_version                   = var.traefik_chart_version
  namespace                       = local.ingress_namespace
  ingress_class_name              = local.ingress_class_name
  default_certificate_secret_name = local.ingress_tls_secret_name
  dashboard_hostname              = var.ingress_dashboard_hostname

  service_annotations = {
    # A network load balancer rather than the classic one: it is the cheaper
    # and current default, and it preserves the client's protocol untouched
    # up to Traefik, which terminates TLS itself.
    "service.beta.kubernetes.io/aws-load-balancer-type"   = "nlb"
    "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
  }

  # The certificate plumbing is applied with the release rather than as
  # kubernetes_manifest resources, which would need the External Secrets CRDs
  # to exist at *plan* time — before this stack has ever been applied.
  extra_objects = [
    {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        name = local.ingress_service_account_name
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.ingress_secrets[0].arn
        }
      }
    },
    {
      apiVersion = "external-secrets.io/v1"
      kind       = "SecretStore"
      metadata = {
        name = local.ingress_secret_store_name
      }
      spec = {
        provider = {
          aws = {
            service = "SecretsManager"
            region  = var.region
            auth = {
              jwt = {
                serviceAccountRef = {
                  name = local.ingress_service_account_name
                }
              }
            }
          }
        }
      }
    },
    {
      apiVersion = "external-secrets.io/v1"
      kind       = "ExternalSecret"
      metadata = {
        name = "platform-wildcard"
      }
      spec = {
        # The distribution run is manual, so an hour of staleness after a
        # renewal is the worst case; the certificate has 30 days left when
        # the renewal starts.
        refreshInterval = "1h"
        secretStoreRef = {
          kind = "SecretStore"
          name = local.ingress_secret_store_name
        }
        target = {
          name           = local.ingress_tls_secret_name
          creationPolicy = "Owner"
          template = {
            type = "kubernetes.io/tls"
          }
        }
        # dataFrom/extract rather than two remoteRefs with a property: the
        # stored value is exactly {"tls.crt": …, "tls.key": …}, and extracting
        # it maps both fields through under their own names without a
        # property path having to quote the dots in them.
        dataFrom = [{
          extract = {
            key = local.ingress_certificate_secret_name
          }
        }]
      }
    },
  ]

  # The External Secrets CRDs and webhook have to be up before the objects
  # above are applied.
  depends_on = [helm_release.external_secrets]
}
