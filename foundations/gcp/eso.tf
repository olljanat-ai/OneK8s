# External Secrets Operator, cluster-wide controller. Tenants get their own
# namespaced SecretStore authenticating via GKE Workload Identity.
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

  depends_on = [google_container_node_pool.default]
}
