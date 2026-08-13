# -----------------------------------------------------------------------------
# GitOps: ONE stack, ONE state file per environment, every spoke in one run.
# It registers the other clouds' clusters with the Argo CD hub that
# foundations/azure runs on AKS, so an environment is wired up with a single:
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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
  }
}
