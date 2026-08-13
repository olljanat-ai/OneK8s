# Dependency direction: tenants read foundation outputs, never the reverse.
# Every foundation keeps its state in the Azure Storage state home whatever
# cloud it provisions, so one azurerm read serves all four clouds — the cloud
# only varies the key in var.foundation_state.
data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config  = merge(var.foundation_state, { use_azuread_auth = true })
}

locals {
  foundation = data.terraform_remote_state.foundation.outputs
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
