# All providers the tenant module can need are declared here; the ones for
# unselected clouds are configured so that they never require credentials or
# network access (their resource counts are all zero).
#
# Azure credentials are always required — the state home is Azure Storage —
# which is also why azurerm/azapi need no "inert" special-casing.
provider "azurerm" {
  features {}
}

provider "azapi" {}

provider "aws" {
  region = try(local.foundation.region, "us-east-1")

  # Inert configuration when cloud != aws: mock static credentials and no
  # validation calls, so no AWS credentials are needed to manage e.g. Azure
  # tenants. With cloud = aws the normal credential chain (OIDC/env/profile)
  # is used and validated.
  skip_credentials_validation = var.cloud != "aws"
  skip_requesting_account_id  = var.cloud != "aws"
  skip_metadata_api_check     = var.cloud != "aws"
  access_key                  = var.cloud != "aws" ? "unused" : null
  secret_key                  = var.cloud != "aws" ? "unused" : null
}

provider "google" {
  project = try(local.foundation.project_id, "unused")

  # Inert configuration when cloud != gcp: a static (never used) token stops
  # the provider from looking up Application Default Credentials.
  access_token = var.cloud == "gcp" ? null : "unused"
}

# --- Kubernetes access to the foundation cluster -----------------------------
data "azurerm_kubernetes_cluster" "this" {
  count = var.cloud == "azure" ? 1 : 0

  name                = local.foundation.cluster_name
  resource_group_name = local.foundation.resource_group_name
}

data "aws_eks_cluster_auth" "this" {
  count = var.cloud == "aws" ? 1 : 0

  name = local.foundation.cluster_name
}

data "google_client_config" "this" {
  count = var.cloud == "gcp" ? 1 : 0
}

locals {
  kube_host = (
    var.cloud == "azure" ? try(data.azurerm_kubernetes_cluster.this[0].kube_config[0].host, null) :
    var.cloud == "aws" ? try(local.foundation.cluster_endpoint, null) :
    try("https://${local.foundation.cluster_endpoint}", null)
  )

  kube_ca = (
    var.cloud == "azure"
    ? try(base64decode(data.azurerm_kubernetes_cluster.this[0].kube_config[0].cluster_ca_certificate), null)
    : try(base64decode(local.foundation.cluster_ca_certificate), null)
  )

  kube_token = (
    var.cloud == "aws" ? try(data.aws_eks_cluster_auth.this[0].token, null) :
    var.cloud == "gcp" ? try(data.google_client_config.this[0].access_token, null) :
    null
  )

  kube_client_cert = var.cloud == "azure" ? try(base64decode(data.azurerm_kubernetes_cluster.this[0].kube_config[0].client_certificate), null) : null
  kube_client_key  = var.cloud == "azure" ? try(base64decode(data.azurerm_kubernetes_cluster.this[0].kube_config[0].client_key), null) : null
}

provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  token                  = local.kube_token
  client_certificate     = local.kube_client_cert
  client_key             = local.kube_client_key
}
