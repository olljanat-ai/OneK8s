# -----------------------------------------------------------------------------
# Portainer: ONE stack, ONE state file per environment, every cluster in one
# run. It onboards the clouds that are not the hub into the Portainer
# Business Edition server that foundations/azure runs on AKS, so an
# environment's fleet console is wired up with a single:
#
#   terraform init -backend-config=backend/prototype.hcl
#   terraform apply -var-file=envs/prototype.tfvars
#
# Same shape and same reasons as the gitops stack: the cloud is a parameter (a
# key of var.agents) rather than part of the deployment, one apply covers all
# of them, and ALL state lives in the Azure Storage "state home" —
# portainer/<env>.tfstate here, foundations/<cloud>/<env>.tfstate for the
# foundations this stack reads.
#
# Unlike the gitops stack it writes nothing to the hub cluster: the hub's half
# of the registration is an API call to Portainer itself, which is what the
# portainer provider is for. Azure credentials are still required for every
# run, because the state home is Azure Storage.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  backend "azurerm" {}

  required_providers {
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
    portainer = {
      source  = "portainer/portainer"
      version = "= 1.34.3"
    }
  }
}
