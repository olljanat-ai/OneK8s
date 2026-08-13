# Dependency direction: tenants read foundation outputs, never the reverse.
# terraform_remote_state's backend type must be static, so one count-gated
# data source exists per cloud; exactly one is active.
data "terraform_remote_state" "azure" {
  count = var.cloud == "azure" ? 1 : 0

  backend = "azurerm"
  config  = merge(var.foundation_state, { use_azuread_auth = true })
}

data "terraform_remote_state" "aws" {
  count = var.cloud == "aws" ? 1 : 0

  backend = "s3"
  config  = var.foundation_state
}

data "terraform_remote_state" "gcp" {
  count = var.cloud == "gcp" ? 1 : 0

  backend = "gcs"
  config  = var.foundation_state
}

# OCI Object Storage speaks the S3 API, so the OCI foundation's state is read
# through the s3 backend with the compatibility flags in its backend/*.hcl.
data "terraform_remote_state" "oci" {
  count = var.cloud == "oci" ? 1 : 0

  backend = "s3"
  config  = var.foundation_state
}

locals {
  foundation = one(concat(
    data.terraform_remote_state.azure[*].outputs,
    data.terraform_remote_state.aws[*].outputs,
    data.terraform_remote_state.gcp[*].outputs,
    data.terraform_remote_state.oci[*].outputs,
  ))
}

module "tenant" {
  source   = "../modules/tenant-namespace"
  for_each = var.tenants

  # OCI's home-region alias must be passed explicitly (aliased configurations
  # are never inherited), and passing any provider turns off default
  # inheritance for the rest — so the whole set is listed.
  providers = {
    azurerm    = azurerm
    azapi      = azapi
    aws        = aws
    google     = google
    kubernetes = kubernetes
    oci        = oci
    oci.home   = oci.home
  }

  cloud       = var.cloud
  tenant_name = each.key
  environment = var.environment
  foundation  = local.foundation

  quota            = each.value.quota
  namespace_labels = each.value.labels
}
