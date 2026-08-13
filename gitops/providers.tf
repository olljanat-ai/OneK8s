# One kubernetes provider per cluster this stack touches: the hub (AKS) plus
# every cloud that can be a spoke. Clouds not registered in this environment
# are configured so that they never require credentials or network access
# (their resource counts are all zero), so a run needs credentials only for
# the clouds actually listed in var.spokes.
#
# Azure credentials are always required — the hub runs on AKS and the state
# home is Azure Storage — which is why azurerm needs no "inert" special-casing.
provider "azurerm" {
  features {}
}

provider "aws" {
  # Guarded on local.wired.aws rather than just try(): other foundations also
  # export a "region" output, and this one has to be an AWS region name.
  region = local.wired.aws ? local.foundation.aws.region : "us-east-1"

  # Inert configuration without an AWS spoke: mock static credentials and no
  # validation calls. With the spoke registered the normal credential chain
  # (OIDC/env/profile) is used and validated.
  skip_credentials_validation = !local.active.aws
  skip_requesting_account_id  = !local.active.aws
  skip_metadata_api_check     = !local.active.aws
  access_key                  = local.active.aws ? null : "unused"
  secret_key                  = local.active.aws ? null : "unused"
}

# --- The hub -----------------------------------------------------------------
# The cluster Secret that registers a spoke is an ordinary Secret in the hub's
# Argo CD namespace, so this stack writes to AKS with the same cluster-local
# admin credentials the tenants stack and the foundation's own add-on
# bootstrap use.
data "azurerm_kubernetes_cluster" "hub" {
  count = local.hub_wired ? 1 : 0

  name                = local.hub.cluster_name
  resource_group_name = local.hub.resource_group_name
}

provider "kubernetes" {
  alias = "azure"

  host                   = try(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].host, null)
  cluster_ca_certificate = try(base64decode(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].cluster_ca_certificate), null)
  client_certificate     = try(base64decode(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].client_certificate), null)
  client_key             = try(base64decode(data.azurerm_kubernetes_cluster.hub[0].kube_config[0].client_key), null)
}

# --- The spokes --------------------------------------------------------------
# Registration is a one-off privileged act on the spoke (create a
# ServiceAccount, grant it, read its token); everything Argo CD does
# afterwards uses that token instead of these credentials.
data "aws_eks_cluster_auth" "spoke" {
  count = local.wired.aws ? 1 : 0

  name = local.foundation.aws.cluster_name
}

provider "kubernetes" {
  alias = "aws"

  # EKS publishes a complete https URL.
  host                   = try(local.foundation.aws.cluster_endpoint, null)
  cluster_ca_certificate = try(base64decode(local.foundation.aws.cluster_ca_certificate), null)
  token                  = try(data.aws_eks_cluster_auth.spoke[0].token, null)
}
