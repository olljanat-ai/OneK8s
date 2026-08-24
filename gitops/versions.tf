# -----------------------------------------------------------------------------
# GitOps: ONE stack, ONE state file per environment, every spoke in one run.
# It attaches the other clouds' clusters to the Argo CD hub that
# foundations/azure runs on AKS — by installing an argocd-agent agent on each
# of them, not by handing the hub a credential for each of them — so an
# environment is wired up with a single:
#
#   terraform init -backend-config=backend/prototype.hcl
#   terraform apply -var-file=envs/prototype.tfvars
#
# Same shape and same reasons as the tenants stack: the cloud is a parameter
# (a key of var.spokes) rather than part of the deployment, one apply covers
# all of them, and ALL state lives in the Azure Storage "state home" —
# gitops/<env>.tfstate here, foundations/<cloud>/<env>.tfstate for the
# foundations this stack reads. Azure credentials are therefore required for
# every run, plus the credentials of every cloud registered as a spoke.
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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
    # The agent and the Argo CD it needs beside it are Helm releases on the
    # spoke; there is nothing to install on the hub from here, because the
    # principal is part of the hub's own foundation.
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
    # Each agent's client certificates, signed by the argocd-agent CA the hub
    # holds. This is where the old ServiceAccount bearer token used to come
    # from — a credential the spoke minted and this stack copied to the hub.
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.1.0"
    }
  }
}
