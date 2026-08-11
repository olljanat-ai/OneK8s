# Dependency direction: tenants read foundation outputs, never the reverse.
data "terraform_remote_state" "foundation" {
  backend = "azurerm"

  config = {
    resource_group_name  = var.foundation_state.resource_group_name
    storage_account_name = var.foundation_state.storage_account_name
    container_name       = var.foundation_state.container_name
    key                  = var.foundation_state.key
    use_azuread_auth     = true
  }
}

module "tenant" {
  source   = "../../modules/tenant-namespace/azure"
  for_each = var.tenants

  tenant_name         = each.key
  environment         = var.environment
  resource_group_name = data.terraform_remote_state.foundation.outputs.resource_group_name
  location            = data.terraform_remote_state.foundation.outputs.location
  aks_cluster_id      = data.terraform_remote_state.foundation.outputs.cluster_id
  oidc_issuer_url     = data.terraform_remote_state.foundation.outputs.oidc_issuer_url
  key_vault_id        = data.terraform_remote_state.foundation.outputs.key_vault_id
  key_vault_uri       = data.terraform_remote_state.foundation.outputs.key_vault_uri

  quota            = each.value.quota
  namespace_labels = each.value.labels
}
