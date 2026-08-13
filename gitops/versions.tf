# -----------------------------------------------------------------------------
# GitOps: ONE stack, ONE state file per environment, hub and every spoke in one
# run — the same shape as the tenants stack, for the same reason. The hub is
# the AKS cluster's Argo CD; the spokes are the EKS, GKE and OKE clusters,
# which are reached through the agents they themselves dial out with.
#
#   terraform init -backend-config=backend/prototype.hcl
#   terraform apply -var-file=envs/prototype.tfvars
#
# State lives in the Azure Storage "state home" alongside every other stack,
# under gitops/<env>.tfstate. Azure credentials are therefore required for
# every deploy, plus the credentials of every cloud that has a spoke.
#
# NOTE: this stack's state contains the argocd-agent CA private key and every
# agent's client key, the same way the tenants stack contains cluster
# credentials. Whatever protects the state home protects these.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.0.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.58.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "= 7.44.0"
    }
    oci = {
      source  = "oracle/oci"
      version = "= 8.26.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.3.0"
    }
  }
}
