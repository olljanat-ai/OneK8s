# Cilium in CNI-chaining mode on top of the AWS VPC CNI: pods keep VPC IPs
# while Cilium provides NetworkPolicy enforcement and observability. (Full
# ENI-mode replacement of aws-node is possible but more invasive; chaining is
# the low-risk production default.)
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_chart_version
  namespace  = "kube-system"

  values = [yamlencode({
    cni = {
      chainingMode = "aws-cni"
      exclusive    = false
    }
    enableIPv4Masquerade = false
    routingMode          = "native"
    endpointRoutes = {
      enabled = true
    }
    operator = {
      replicas = 1
    }
    envoy = {
      enabled = false
    }
    hubble = {
      enabled = false
    }
  })]

  depends_on = [aws_eks_node_group.default]
}

# External Secrets Operator, cluster-wide controller. Tenants get their own
# namespaced SecretStore authenticating via IRSA.
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

  depends_on = [helm_release.cilium]
}
