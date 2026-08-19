# External Secrets Operator, cluster-wide controller. Tenants get their own
# namespaced SecretStore; the operator itself holds no cloud credentials.
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.eso_chart_version
  namespace        = "external-secrets"
  create_namespace = true

  values = [yamlencode({
    installCRDs = true
    podLabels = {
      "azure.workload.identity/use" = "true"
    }
    webhook = {
      podLabels = {
        "azure.workload.identity/use" = "true"
      }
    }
  })]

  depends_on = [module.aks]
}
