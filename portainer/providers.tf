# One kubernetes provider per cluster this stack touches — every cloud that
# can carry an agent — plus the portainer provider for the server itself.
# Clouds not listed in var.agents are configured so that they never require
# credentials or network access (their resource counts are all zero), so a run
# needs credentials only for the clouds actually being onboarded.
#
# There is no azurerm provider and no kubernetes provider for the hub: nothing
# is created in Azure or on AKS here. Azure credentials are still needed for
# every run, because the state home and every foundation state read below live
# in Azure Storage — that is the backend's business, not a provider's.

# --- The server --------------------------------------------------------------
# Credentials come from the environment, never from a variable or a state
# file: PORTAINER_API_KEY, or PORTAINER_USER + PORTAINER_PASSWORD for the
# admin account the foundation bootstraps out of Key Vault. In CI they are
# GitHub secrets, the same way every cloud credential is.
#
# The endpoint falls back to a name that resolves nowhere when the hub has no
# Portainer, so that a run in that state fails the check above rather than in
# provider configuration.
provider "portainer" {
  endpoint = coalesce(local.portainer_url, "https://portainer.invalid")
}

# --- The clusters ------------------------------------------------------------
provider "aws" {
  # Guarded on local.wired.aws rather than just try(): other foundations also
  # export a "region" output, and this one has to be an AWS region name.
  region = local.wired.aws ? local.foundation.aws.region : "us-east-1"

  # Inert configuration without an AWS agent: mock static credentials and no
  # validation calls. With one, the normal credential chain (OIDC/env/profile)
  # is used and validated.
  skip_credentials_validation = !local.active.aws
  skip_requesting_account_id  = !local.active.aws
  skip_metadata_api_check     = !local.active.aws
  access_key                  = local.active.aws ? null : "unused"
  secret_key                  = local.active.aws ? null : "unused"
}

provider "google" {
  project = local.wired.gcp ? local.foundation.gcp.project_id : "unused"

  # Inert configuration without a GCP agent: a static (never used) token stops
  # the provider from looking up Application Default Credentials.
  access_token = local.active.gcp ? null : "unused"
}

data "aws_eks_cluster_auth" "agent" {
  count = local.wired.aws ? 1 : 0

  name = local.foundation.aws.cluster_name
}

data "google_client_config" "agent" {
  count = local.wired.gcp ? 1 : 0
}

provider "kubernetes" {
  alias = "aws"

  # EKS publishes a complete https URL.
  host                   = try(local.foundation.aws.cluster_endpoint, null)
  cluster_ca_certificate = try(base64decode(local.foundation.aws.cluster_ca_certificate), null)
  token                  = try(data.aws_eks_cluster_auth.agent[0].token, null)
}

provider "kubernetes" {
  alias = "gcp"

  # GKE publishes a bare host.
  host                   = try("https://${local.foundation.gcp.cluster_endpoint}", null)
  cluster_ca_certificate = try(base64decode(local.foundation.gcp.cluster_ca_certificate), null)
  token                  = try(data.google_client_config.agent[0].access_token, null)
}

# No "oci" provider block, and no oracle/oci in versions.tf: like the gitops
# stack this one creates nothing in OCI itself — the endpoint and CA come out
# of the foundation's state and the API token comes from the OCI CLI, which
# reads the same OCI_* environment variables the provider would.
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
