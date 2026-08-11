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

locals {
  foundation = one(concat(
    data.terraform_remote_state.azure[*].outputs,
    data.terraform_remote_state.aws[*].outputs,
    data.terraform_remote_state.gcp[*].outputs,
  ))
}

module "tenant" {
  source   = "../modules/tenant-namespace"
  for_each = var.tenants

  cloud       = var.cloud
  tenant_name = each.key
  environment = var.environment
  foundation  = local.foundation

  quota            = each.value.quota
  namespace_labels = each.value.labels
}
