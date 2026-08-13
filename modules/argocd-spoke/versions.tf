# -----------------------------------------------------------------------------
# One spoke of the Argo CD hub-spoke topology: the workload half of Argo CD
# plus the argocd-agent agent, on a cluster that is never reached from the hub.
#
# The module is cloud-agnostic on purpose — everything it needs about the
# cluster arrives through the kubernetes/helm providers the caller passes in,
# so EKS, GKE and OKE instantiate exactly the same code.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
  }
}
