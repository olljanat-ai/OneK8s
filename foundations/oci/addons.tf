# Cilium chained onto the OCI VCN-native CNI: pods keep their VCN IPs while
# Cilium supplies NetworkPolicy enforcement (OKE's own CNI has none, and the
# tenant module relies on NetworkPolicy being enforced). Same posture as the
# AWS foundation, which chains Cilium onto the VPC CNI.
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_chart_version
  namespace  = "kube-system"

  values = [yamlencode({
    cni = {
      chainingTarget = "oci"
      exclusive      = false
    }
    routingMode          = "native"
    enableIPv4Masquerade = false
    kubeProxyReplacement = false
    ipam = {
      mode = "cluster-pool"
      operator = {
        clusterPoolIPv4PodCIDRList = [var.cilium_pod_cidr]
      }
    }
  })]

  depends_on = [oci_containerengine_node_pool.default]
}

# External Secrets Operator, cluster-wide controller. Tenants get their own
# namespaced SecretStore authenticating via OKE Workload Identity, so the
# operator itself holds no OCI credentials.
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
