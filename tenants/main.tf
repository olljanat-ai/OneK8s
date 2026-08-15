locals {
  clouds = ["azure", "aws", "gcp", "oci"]

  # The cloud is a per-tenant parameter, so one apply covers all of them. The
  # tenants are grouped by cloud here because a module's providers are static:
  # each group is passed its own cluster's kubernetes provider alias below.
  tenants_by_cloud = {
    for c in local.clouds : c => {
      for key, t in var.tenants : key => t if t.cloud == c
    }
  }

  # Clouds nobody deploys a tenant to are left completely alone: no foundation
  # state is read, no cluster is contacted and their providers stay inert, so
  # this stack only needs credentials for the clouds actually in use (plus
  # Azure, which hosts the state home).
  active = { for c in local.clouds : c => length(local.tenants_by_cloud[c]) > 0 }
}

# Dependency direction: tenants read foundation outputs, never the reverse.
# Every foundation keeps its state in the Azure Storage state home whatever
# cloud it provisions, so one azurerm backend serves all four — only the blob
# key differs, and it is derived rather than configured so that it cannot
# drift away from foundations/<cloud>/backend/<env>.hcl.
data "terraform_remote_state" "foundation" {
  for_each = toset([for c in local.clouds : c if local.active[c]])

  backend = "azurerm"
  config = merge(var.state_home, {
    key              = "foundations/${each.key}/${var.environment}.tfstate"
    use_azuread_auth = true
  })
}

locals {
  # Keyed by cloud, always complete: inactive clouds map to {}. An *active*
  # cloud mapping to {} means its foundation state blob is missing or holds no
  # outputs — the tenant module turns that into one actionable error.
  foundation = {
    for c in local.clouds : c => try(data.terraform_remote_state.foundation[c].outputs, {})
  }

  # Wired = there is something to deploy and something to deploy it against.
  # Provider and cluster-lookup wiring is gated on this so that a missing
  # foundation surfaces as the module's validation message rather than as a
  # pile of "Unsupported attribute" errors from provider configuration.
  wired = { for c in local.clouds : c => local.active[c] && length(local.foundation[c]) > 0 }
}

# A foundation deployed for a different environment is the other half of the
# same failure mode, and one this stack can only warn about.
check "foundation_environment" {
  assert {
    condition = alltrue([
      for c in local.clouds : try(local.foundation[c].environment, var.environment) == var.environment
    ])
    error_message = "A foundation state read by this stack was deployed for a different environment than var.environment (${var.environment}). Check that the foundations were applied with envs/${var.environment}.tfvars and backend/${var.environment}.hcl."
  }
}

# -----------------------------------------------------------------------------
# One module block per cloud. They differ only in which cluster's kubernetes
# provider they get: provider configurations cannot be selected per for_each
# instance, so the per-cloud split has to happen here rather than inside the
# module.
#
# OCI's home-region alias must be passed explicitly (aliased configurations are
# never inherited), and passing any provider turns off default inheritance for
# the rest — so every block lists the whole set.
# -----------------------------------------------------------------------------
module "tenants_azure" {
  source   = "../modules/tenant-namespace"
  for_each = local.tenants_by_cloud.azure

  providers = {
    azurerm    = azurerm
    azapi      = azapi
    aws        = aws
    google     = google
    kubernetes = kubernetes.azure
    oci        = oci
    oci.home   = oci.home
  }

  cloud       = "azure"
  tenant_name = coalesce(each.value.name, each.key)
  environment = var.environment
  foundation  = local.foundation.azure

  quota            = each.value.quota
  namespace_labels = each.value.labels
  pod_security     = each.value.pod_security
}

module "tenants_aws" {
  source   = "../modules/tenant-namespace"
  for_each = local.tenants_by_cloud.aws

  providers = {
    azurerm    = azurerm
    azapi      = azapi
    aws        = aws
    google     = google
    kubernetes = kubernetes.aws
    oci        = oci
    oci.home   = oci.home
  }

  cloud       = "aws"
  tenant_name = coalesce(each.value.name, each.key)
  environment = var.environment
  foundation  = local.foundation.aws

  quota            = each.value.quota
  namespace_labels = each.value.labels
  pod_security     = each.value.pod_security
}

module "tenants_gcp" {
  source   = "../modules/tenant-namespace"
  for_each = local.tenants_by_cloud.gcp

  providers = {
    azurerm    = azurerm
    azapi      = azapi
    aws        = aws
    google     = google
    kubernetes = kubernetes.gcp
    oci        = oci
    oci.home   = oci.home
  }

  cloud       = "gcp"
  tenant_name = coalesce(each.value.name, each.key)
  environment = var.environment
  foundation  = local.foundation.gcp

  quota            = each.value.quota
  namespace_labels = each.value.labels
  pod_security     = each.value.pod_security
}

module "tenants_oci" {
  source   = "../modules/tenant-namespace"
  for_each = local.tenants_by_cloud.oci

  providers = {
    azurerm    = azurerm
    azapi      = azapi
    aws        = aws
    google     = google
    kubernetes = kubernetes.oci
    oci        = oci
    oci.home   = oci.home
  }

  cloud       = "oci"
  tenant_name = coalesce(each.value.name, each.key)
  environment = var.environment
  foundation  = local.foundation.oci

  quota            = each.value.quota
  namespace_labels = each.value.labels
  pod_security     = each.value.pod_security
}
