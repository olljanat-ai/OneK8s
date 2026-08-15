# All providers the tenant module can need are declared here. Clouds without
# tenants in this environment are configured so that they never require
# credentials or network access (their resource counts are all zero), so a run
# needs credentials only for the clouds actually listed in var.tenants.
#
# Azure credentials are always required — the state home is Azure Storage —
# which is also why azurerm/azapi need no "inert" special-casing.
provider "azurerm" {
  features {}
}

provider "azapi" {}

provider "aws" {
  # Guarded on local.wired.aws rather than just try(): the OCI foundation also
  # exports a "region" output, which is not an AWS region name.
  region = local.wired.aws ? local.foundation.aws.region : "us-east-1"

  # Inert configuration without AWS tenants: mock static credentials and no
  # validation calls, so no AWS credentials are needed to manage e.g. only
  # Azure tenants. With AWS tenants present the normal credential chain
  # (OIDC/env/profile) is used and validated.
  skip_credentials_validation = !local.active.aws
  skip_requesting_account_id  = !local.active.aws
  skip_metadata_api_check     = !local.active.aws
  access_key                  = local.active.aws ? null : "unused"
  secret_key                  = local.active.aws ? null : "unused"
}

provider "google" {
  project = local.wired.gcp ? local.foundation.gcp.project_id : "unused"

  # Inert configuration without GCP tenants: a static (never used) token stops
  # the provider from looking up Application Default Credentials.
  access_token = local.active.gcp ? null : "unused"
}

# No inert special-casing needed: the OCI provider resolves credentials lazily,
# so without OCI tenants (zero resources) it is never asked for any. A null
# region falls back to OCI_REGION / the ~/.oci/config profile.
provider "oci" {
  region = local.wired.oci ? local.foundation.oci.region : null
}

# IAM policies can only be written in the tenancy's home region.
provider "oci" {
  alias  = "home"
  region = local.wired.oci ? local.foundation.oci.home_region : null
}

# The private cloud's IAM plane. Its token comes from VAULT_TOKEN, never from
# configuration, and its address from the nutanix foundation's state — the same
# rule as everywhere else: coordinates out of state, credentials out of the
# environment.
#
# Inert configuration without Nutanix tenants: a mock token, no version probe
# and no child token, so the provider performs no I/O at all and needs no Vault
# to be reachable. skip_child_token stays on either way — the runs are short,
# and an operator token may not carry the create-child capability.
provider "vault" {
  address   = local.wired.nutanix ? local.foundation.nutanix.vault_address : "https://vault.invalid"
  namespace = try(local.foundation.nutanix.vault_namespace, "") == "" ? null : local.foundation.nutanix.vault_namespace

  token                  = local.active.nutanix ? null : "unused"
  skip_child_token       = true
  skip_get_vault_version = !local.active.nutanix
  vault_version_override = local.active.nutanix ? null : "1.21.0"
}

# --- Kubernetes access to the foundation clusters ----------------------------
# One provider alias per cloud, because one apply spans up to four clusters.
data "azurerm_kubernetes_cluster" "this" {
  count = local.wired.azure ? 1 : 0

  name                = local.foundation.azure.cluster_name
  resource_group_name = local.foundation.azure.resource_group_name
}

data "aws_eks_cluster_auth" "this" {
  count = local.wired.aws ? 1 : 0

  name = local.foundation.aws.cluster_name
}

data "google_client_config" "this" {
  count = local.wired.gcp ? 1 : 0
}

provider "kubernetes" {
  alias = "azure"

  host                   = try(data.azurerm_kubernetes_cluster.this[0].kube_config[0].host, null)
  cluster_ca_certificate = try(base64decode(data.azurerm_kubernetes_cluster.this[0].kube_config[0].cluster_ca_certificate), null)
  client_certificate     = try(base64decode(data.azurerm_kubernetes_cluster.this[0].kube_config[0].client_certificate), null)
  client_key             = try(base64decode(data.azurerm_kubernetes_cluster.this[0].kube_config[0].client_key), null)
}

provider "kubernetes" {
  alias = "aws"

  # EKS publishes a complete https URL.
  host                   = try(local.foundation.aws.cluster_endpoint, null)
  cluster_ca_certificate = try(base64decode(local.foundation.aws.cluster_ca_certificate), null)
  token                  = try(data.aws_eks_cluster_auth.this[0].token, null)
}

provider "kubernetes" {
  alias = "gcp"

  # GKE publishes a bare host.
  host                   = try("https://${local.foundation.gcp.cluster_endpoint}", null)
  cluster_ca_certificate = try(base64decode(local.foundation.gcp.cluster_ca_certificate), null)
  token                  = try(data.google_client_config.this[0].access_token, null)
}

# The private cloud has no cloud IAM to mint a cluster token from, so the
# workload cluster's credential comes from the component that owns its
# lifecycle: NKP publishes it as the Cluster API kubeconfig Secret, and
# modules/nkp-cluster-access reads it. Only the management cluster's own token
# has to be supplied, and it comes from the environment like every other
# credential here.
provider "kubernetes" {
  alias = "nkp"

  host                   = try(local.foundation.nutanix.nkp_management_host, null)
  token                  = var.nkp_management_token == "" ? null : var.nkp_management_token
  cluster_ca_certificate = try(local.foundation.nutanix.nkp_management_ca_certificate, "") == "" ? null : base64decode(local.foundation.nutanix.nkp_management_ca_certificate)
}

module "nutanix_cluster" {
  source = "../modules/nkp-cluster-access"
  count  = local.wired.nutanix ? 1 : 0

  providers = { kubernetes = kubernetes.nkp }

  cluster_name      = local.foundation.nutanix.cluster_name
  cluster_namespace = local.foundation.nutanix.cluster_namespace
}

provider "kubernetes" {
  alias = "nutanix"

  host                   = try(module.nutanix_cluster[0].host, null)
  cluster_ca_certificate = try(base64decode(module.nutanix_cluster[0].cluster_ca_certificate), null)
  client_certificate     = try(base64decode(module.nutanix_cluster[0].client_certificate), null)
  client_key             = try(base64decode(module.nutanix_cluster[0].client_key), null)
  token                  = try(module.nutanix_cluster[0].token, null)
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
