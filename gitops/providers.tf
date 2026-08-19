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

provider "google" {
  project = local.wired.gcp ? local.foundation.gcp.project_id : "unused"

  # Inert configuration without a GCP spoke: a static (never used) token stops
  # the provider from looking up Application Default Credentials.
  access_token = local.active.gcp ? null : "unused"
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

# AKS returns the cluster-local admin certificate under kube_admin_config on an
# Entra-integrated cluster and under kube_config on one that is not — and the
# block that does not apply comes back empty rather than absent. Picking the
# first non-empty one means this stack does not have to know which shape the
# foundation deployed.
locals {
  hub_kubeconfig = try(
    coalescelist(
      data.azurerm_kubernetes_cluster.hub[0].kube_admin_config,
      data.azurerm_kubernetes_cluster.hub[0].kube_config,
    )[0],
    null,
  )
}

provider "kubernetes" {
  alias = "azure"

  host                   = try(local.hub_kubeconfig.host, null)
  cluster_ca_certificate = try(base64decode(local.hub_kubeconfig.cluster_ca_certificate), null)
  client_certificate     = try(base64decode(local.hub_kubeconfig.client_certificate), null)
  client_key             = try(base64decode(local.hub_kubeconfig.client_key), null)
}

# --- The spokes --------------------------------------------------------------
# Registration is a one-off privileged act on the spoke (create a
# ServiceAccount, grant it, read its token); everything Argo CD does
# afterwards uses that token instead of these credentials.
data "aws_eks_cluster_auth" "spoke" {
  count = local.wired.aws ? 1 : 0

  name = local.foundation.aws.cluster_name
}

data "google_client_config" "spoke" {
  count = local.wired.gcp ? 1 : 0
}

provider "kubernetes" {
  alias = "aws"

  # EKS publishes a complete https URL.
  host                   = try(local.foundation.aws.cluster_endpoint, null)
  cluster_ca_certificate = try(base64decode(local.foundation.aws.cluster_ca_certificate), null)
  token                  = try(data.aws_eks_cluster_auth.spoke[0].token, null)
}

provider "kubernetes" {
  alias = "gcp"

  # GKE publishes a bare host; the module prefixes the same way for the URL it
  # writes into the cluster Secret.
  host                   = try("https://${local.foundation.gcp.cluster_endpoint}", null)
  cluster_ca_certificate = try(base64decode(local.foundation.gcp.cluster_ca_certificate), null)
  token                  = try(data.google_client_config.spoke[0].access_token, null)
}

# No "oci" provider block, and no oracle/oci in versions.tf: unlike the tenants
# stack this one creates nothing in OCI itself — the endpoint and CA come out
# of the foundation's state and the API token comes from the OCI CLI, which
# reads the same OCI_* environment variables the provider would. The tenancy's
# home-region alias is likewise unnecessary here, since no IAM policy is
# written.
provider "kubernetes" {
  alias = "oci"

  host                   = try(local.foundation.oci.cluster_endpoint, null)
  cluster_ca_certificate = try(base64decode(local.foundation.oci.cluster_ca_certificate), null)

  # OCI has no Terraform-native cluster token source (no equivalent of
  # aws_eks_cluster_auth), so the OCI CLI mints one. Requires `oci` on PATH.
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
