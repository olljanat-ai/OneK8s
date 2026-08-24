terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # Two clusters, two provider configurations: the default "kubernetes" is
    # the spoke (where the agent, its Argo CD and its credentials are created)
    # and "kubernetes.hub" is the AKS cluster running Argo CD and the principal
    # (where the cluster Secret lands). Aliased configurations are never
    # inherited, so the caller has to pass both.
    kubernetes = {
      source                = "hashicorp/kubernetes"
      version               = ">= 3.0.0"
      configuration_aliases = [kubernetes.hub]
    }

    # The spoke only. Nothing is installed on the hub from here — the principal
    # is part of the hub's foundation.
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
    }

    # The two client certificates this agent is issued, signed by the hub's CA.
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }
}
