terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # Two clusters, two provider configurations: the default "kubernetes" is
    # the spoke (where the ServiceAccount and its RBAC are created) and
    # "kubernetes.hub" is the AKS cluster running Argo CD (where the cluster
    # Secret lands). Aliased configurations are never inherited, so the caller
    # has to pass both.
    kubernetes = {
      source                = "hashicorp/kubernetes"
      version               = ">= 3.0.0"
      configuration_aliases = [kubernetes.hub]
    }
  }
}
