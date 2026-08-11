# Shared secret backend for the cluster: one Key Vault per cluster, secrets
# namespaced by naming convention "<tenant>-<secret>". Tenant isolation is
# enforced with Azure RBAC + ABAC conditions on the tenant role assignments
# (see modules/tenant-namespace/azure).
resource "random_string" "kv_suffix" {
  length  = 4
  special = false
  upper   = false
}

resource "azurerm_key_vault" "this" {
  # Key Vault names are globally unique, 3-24 chars, alphanumeric + dashes.
  name                = substr("kv-${var.name_prefix}-${var.environment}-${random_string.kv_suffix.result}", 0, 24)
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # RBAC (not access policies) is required for ABAC conditions.
  rbac_authorization_enabled = true

  purge_protection_enabled   = var.environment == "prod"
  soft_delete_retention_days = 7

  tags = local.tags
}

# The deploying principal manages secrets (seeding, rotation automation).
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}
