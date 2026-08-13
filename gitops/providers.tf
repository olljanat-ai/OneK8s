# Providers for the hub and every possible spoke. Clouds without a spoke in
# this environment are configured so that they never require credentials or
# network access (their resource counts are all zero), so a run needs
# credentials only for the clouds actually listed in var.spokes.
#
# Azure credentials are always required: it hosts the state home *and* the hub.
provider "azurerm" {
  features {}
}

provider "aws" {
  # Guarded on local.wired.aws rather than just try(): the OCI foundation also
  # exports a "region" output, which is not an AWS region name.
  region = local.wired.aws ? local.foundation.aws.region : "us-east-1"

  # Inert configuration without an AWS spoke: mock static credentials and no
  # validation calls.
  skip_credentials_validation = !local.active.aws
  skip_requesting_account_id  = !local.active.aws
  skip_metadata_api_check     = !local.active.aws
  access_key                  = local.active.aws ? null : "unused"
  secret_key                  = local.active.aws ? null : "unused"
}

provider "google" {
  project = local.wired.gcp ? local.foundation.gcp.project_id : "unused"

  # Inert configuration without a GCP spoke: a static (never used) token stops
  # the provider from looking up Application Default Credentials.
  access_token = local.active.gcp ? null : "unused"
}

# No inert special-casing needed: the OCI provider resolves credentials lazily,
# so without an OCI spoke (zero resources) it is never asked for any.
provider "oci" {
  region = local.wired.oci ? local.foundation.oci.region : null
}

# --- Cluster access ----------------------------------------------------------
# One kubernetes and one helm alias per cluster, because a single apply spans
# the hub and up to three spokes.
#
# Every one of these is a connection *from wherever Terraform runs*, and none
# of them is how the hub reaches a spoke afterwards: once the agent is
# installed, the only path between clusters is the one the agent dials.
data "azurerm_kubernetes_cluster" "hub" {
  # Guarded even though the hub is mandatory: without the guard, a missing
  # Azure foundation surfaces as an "Unsupported attribute" here instead of as
  # the hub_foundation check's message.
  count = local.wired.azure ? 1 : 0

  name                = local.foundation.azure.cluster_name
  resource_group_name = local.foundation.azure.resource_group_name
}

data "aws_eks_cluster_auth" "spoke" {
  count = local.wired.aws ? 1 : 0

  name = local.foundation.aws.cluster_name
}

data "google_client_config" "spoke" {
  count = local.wired.gcp ? 1 : 0
}

provider "kubernetes" {
  alias = "azure"

  host                   = try(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].host, null)
  cluster_ca_certificate = try(base64decode(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].cluster_ca_certificate), null)
  client_certificate     = try(base64decode(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].client_certificate), null)
  client_key             = try(base64decode(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].client_key), null)
}

provider "helm" {
  alias = "azure"

  kubernetes = {
    host                   = try(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].host, null)
    cluster_ca_certificate = try(base64decode(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].cluster_ca_certificate), null)
    client_certificate     = try(base64decode(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].client_certificate), null)
    client_key             = try(base64decode(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].client_key), null)
  }
}

provider "kubernetes" {
  alias = "aws"

  # EKS publishes a complete https URL.
  host                   = try(local.foundation.aws.cluster_endpoint, null)
  cluster_ca_certificate = try(base64decode(local.foundation.aws.cluster_ca_certificate), null)
  token                  = try(data.aws_eks_cluster_auth.spoke[0].token, null)
}

provider "helm" {
  alias = "aws"

  kubernetes = {
    host                   = try(local.foundation.aws.cluster_endpoint, null)
    cluster_ca_certificate = try(base64decode(local.foundation.aws.cluster_ca_certificate), null)
    token                  = try(data.aws_eks_cluster_auth.spoke[0].token, null)
  }
}

provider "kubernetes" {
  alias = "gcp"

  # GKE publishes a bare host.
  host                   = try("https://${local.foundation.gcp.cluster_endpoint}", null)
  cluster_ca_certificate = try(base64decode(local.foundation.gcp.cluster_ca_certificate), null)
  token                  = try(data.google_client_config.spoke[0].access_token, null)
}

provider "helm" {
  alias = "gcp"

  kubernetes = {
    host                   = try("https://${local.foundation.gcp.cluster_endpoint}", null)
    cluster_ca_certificate = try(base64decode(local.foundation.gcp.cluster_ca_certificate), null)
    token                  = try(data.google_client_config.spoke[0].access_token, null)
  }
}

provider "kubernetes" {
  alias = "oci"

  host                   = try(local.foundation.oci.cluster_endpoint, null)
  cluster_ca_certificate = try(base64decode(local.foundation.oci.cluster_ca_certificate), null)

  # OCI has no Terraform-native cluster token source, so the OCI CLI mints one
  # (the equivalent of `aws eks get-token`). Requires `oci` on PATH.
  dynamic "exec" {
    for_each = local.wired.oci ? [1] : []

    content {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args = [
        "ce", "cluster", "generate-token",
        "--cluster-id", local.foundation.oci.cluster_id,
        "--region", local.foundation.oci.region,
      ]
    }
  }
}

provider "helm" {
  alias = "oci"

  kubernetes = {
    host                   = try(local.foundation.oci.cluster_endpoint, null)
    cluster_ca_certificate = try(base64decode(local.foundation.oci.cluster_ca_certificate), null)

    exec = local.wired.oci ? {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args = [
        "ce", "cluster", "generate-token",
        "--cluster-id", local.foundation.oci.cluster_id,
        "--region", local.foundation.oci.region,
      ]
    } : null
  }
}
