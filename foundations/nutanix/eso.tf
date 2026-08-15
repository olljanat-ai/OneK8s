# External Secrets Operator, cluster-wide controller. Tenants get their own
# namespaced SecretStore authenticating through Vault's JWT auth method, so
# the operator itself holds no Vault credentials — it only asks the API server
# for a short-lived token for the tenant's own ServiceAccount and hands it to
# Vault, which verifies the cluster's signature and decides what that identity
# may read.
#
# No CNI is installed here, unlike the AWS and OCI foundations: NKP ships
# Cilium as the cluster's CNI, so the NetworkPolicy enforcement the tenant
# module relies on is already in place. Installing a second one would fight it.
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.eso_chart_version
  namespace        = "external-secrets"
  create_namespace = true

  values = [yamlencode({
    installCRDs = true
  })]
}
