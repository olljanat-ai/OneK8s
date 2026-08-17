# Grafana Cloud observability, the same module every other cloud runs
# (modules/platform-observability), plus the one thing that is AWS-shaped: reading
# the Grafana Cloud credentials out of Secrets Manager.
#
# The credentials arrive there the way the wildcard certificate does — written
# to Key Vault and distributed by a workflow, under the reserved "platform"
# tenant's prefix — so they reach the cluster the same way a tenant's own
# secrets do:
#
#   Secrets Manager <env>/platform/grafana-cloud
#     --(SecretStore + ExternalSecret, IRSA)-->
#       Secret grafana-cloud-credentials
#         --(Alloy remote.kubernetes.secret)--> Grafana Cloud
locals {
  observability_namespace            = "observability"
  observability_service_account_name = "platform-observability"
  observability_secret_store_name    = "platform-store"
  observability_credentials_secret   = "grafana-cloud-credentials"

  # Secrets Manager names are hierarchical, so the flat Key Vault name becomes
  # a path under the reserved "platform" tenant — the same translation
  # ingress.tf does for the certificate.
  observability_credentials_remote_key = "${var.environment}/platform/${trimprefix(var.grafana_cloud_secret_name, "platform-")}"

  # One Grafana Cloud stack holds all four clusters, told apart only by this
  # label, so it carries both the cloud and the environment.
  observability_cluster_name = "${var.name_prefix}-aws-${var.environment}"

  # "https://oidc.eks.<region>.amazonaws.com/id/XXXX" -> the condition key
  # prefix used in the trust policy.
  observability_oidc_issuer = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# --- Platform identity: IAM role trusted via IRSA ----------------------------
# A second platform identity rather than a share of the ingress': the two
# components are independently deployable, and each reads exactly one secret.
data "aws_iam_policy_document" "observability_trust" {
  count = var.enable_observability ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.observability_oidc_issuer}:sub"
      values   = ["system:serviceaccount:${local.observability_namespace}:${local.observability_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.observability_oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "observability_secrets" {
  count = var.enable_observability ? 1 : 0

  name               = "platform-observability-${local.name}"
  assume_role_policy = data.aws_iam_policy_document.observability_trust[0].json
}

data "aws_iam_policy_document" "observability_secrets" {
  count = var.enable_observability ? 1 : 0

  statement {
    sid = "ReadGrafanaCloudCredentialsOnly"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    # The trailing "*" is required even for an exact name: Secrets Manager
    # appends a random six-character suffix to every secret ARN.
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${local.observability_credentials_remote_key}-*",
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

resource "aws_iam_role_policy" "observability_secrets" {
  count = var.enable_observability ? 1 : 0

  name   = "platform-grafana-cloud"
  role   = aws_iam_role.observability_secrets[0].id
  policy = data.aws_iam_policy_document.observability_secrets[0].json
}

# --- The collectors ----------------------------------------------------------
module "observability" {
  source = "../../modules/platform-observability"
  count  = var.enable_observability ? 1 : 0

  chart_version           = var.k8s_observability_chart_version
  namespace               = local.observability_namespace
  cluster_name            = local.observability_cluster_name
  credentials_secret_name = local.observability_credentials_secret
  collector_preset        = var.observability_collector_preset

  metrics_url = var.grafana_cloud_metrics_url
  logs_url    = var.grafana_cloud_logs_url
  traces_url  = var.grafana_cloud_traces_url

  enable_pod_logs = var.observability_enable_pod_logs

  # The credential plumbing is applied with the release rather than as
  # kubernetes_manifest resources, which would need the External Secrets CRDs
  # to exist at *plan* time — before this stack has ever been applied.
  extra_objects = [
    {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        name = local.observability_service_account_name
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.observability_secrets[0].arn
        }
      }
    },
    {
      apiVersion = "external-secrets.io/v1"
      kind       = "SecretStore"
      metadata = {
        name = local.observability_secret_store_name
      }
      spec = {
        provider = {
          aws = {
            service = "SecretsManager"
            region  = var.region
            auth = {
              jwt = {
                serviceAccountRef = {
                  name = local.observability_service_account_name
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
        name = "grafana-cloud"
      }
      spec = {
        # An hour of staleness after a token rotation, on every cloud. The
        # collectors keep using the token they hold until then, so a rotation
        # is only visible as remote writes failing once the old token is
        # actually revoked.
        refreshInterval = "1h"
        secretStoreRef = {
          kind = "SecretStore"
          name = local.observability_secret_store_name
        }
        target = {
          name           = local.observability_credentials_secret
          creationPolicy = "Owner"
        }
        # The stored value is one JSON object of instance IDs and the token,
        # and extract maps every field through under its own name — so adding
        # a signal is a new field in the backend, not a change here.
        dataFrom = [{
          extract = {
            key = local.observability_credentials_remote_key
          }
        }]
      }
    },
  ]

  # The External Secrets CRDs and webhook have to be up before the objects
  # above are applied.
  depends_on = [helm_release.external_secrets]
}
