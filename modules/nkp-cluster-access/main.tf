# Reads the credentials of an NKP-managed workload cluster out of the NKP
# management cluster, so that a stack which has to talk to that cluster does
# not need a kubeconfig file handed to it out of band.
#
# NKP manages workload clusters with Cluster API, and Cluster API publishes
# every cluster's admin credential as a Secret in the cluster's own namespace:
#
#   Secret <cluster>-kubeconfig  (type cluster.x-k8s.io/secret)
#     data.value: a complete kubeconfig for the workload cluster's API server
#
# That Secret is the private cloud's answer to `aws eks get-token`,
# `gcloud container clusters get-credentials` and
# `oci ce cluster generate-token`: there is no cloud IAM plane to mint a
# cluster token from, so the credential comes from the component that owns the
# cluster's lifecycle — which on a private cloud is NKP itself.
#
# The module is deliberately read-only. It creates nothing, and both stacks
# that use it (foundations/nutanix and gitops) configure their workload-cluster
# provider from its outputs.
data "kubernetes_secret_v1" "kubeconfig" {
  metadata {
    name      = coalesce(var.kubeconfig_secret_name, "${var.cluster_name}-kubeconfig")
    namespace = var.cluster_namespace
  }
}

locals {
  # Unknown until apply when the caller orders this module after the resources
  # that create the cluster (module-level depends_on), which is exactly what
  # foundations/nutanix does on a cold apply.
  kubeconfig = yamldecode(data.kubernetes_secret_v1.kubeconfig.data["value"])

  cluster = local.kubeconfig["clusters"][0]["cluster"]
  user    = local.kubeconfig["users"][0]["user"]

  # Cluster API mints a client certificate signed by the cluster CA. A
  # distribution that hands out a token instead is supported by returning
  # whichever of the two the kubeconfig actually carries; the caller passes
  # both through to its provider configuration and the unused one is null.
  client_certificate = try(local.user["client-certificate-data"], null)
  client_key         = try(local.user["client-key-data"], null)
  token              = try(local.user["token"], null)
}
