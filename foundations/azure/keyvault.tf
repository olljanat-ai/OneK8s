# Shared secret backend for the cluster: one Key Vault per cluster, secrets
# namespaced by naming convention "<tenant>-<secret>". Tenant isolation is
# enforced with Azure RBAC + ABAC conditions on the tenant role assignments
# (see modules/tenant-namespace/azure).
#
# Built from the Azure Verified Module for Key Vault, which is also where the
# deploying principal's two role assignments live: they are properties of the
# vault, not resources that happen to point at it, so they are created and
# destroyed with it.
resource "random_string" "kv_suffix" {
  length  = 4
  special = false
  upper   = false
}

module "key_vault" {
  source  = "Azure/avm-res-keyvault-vault/azurerm"
  version = "0.11.0"

  # Key Vault names are globally unique, 3-24 chars, alphanumeric + dashes.
  name                = substr("kv-${var.name_prefix}-${var.environment}-${random_string.kv_suffix.result}", 0, 24)
  location            = var.location
  resource_group_name = module.resource_group.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  enable_telemetry    = var.enable_telemetry
  tags                = local.tags

  # Premium is HSM-backed. Nothing in this platform asks for an HSM key today,
  # but the SKU cannot be changed downward later and the difference is cents a
  # month, so the vault that would hold a customer-managed key is created able
  # to.
  sku_name = var.key_vault_sku_name

  # RBAC (not access policies) is required for the ABAC conditions every
  # identity in this stack is scoped with. The module gives RBAC unless legacy
  # access policies are asked for, and they never are.
  legacy_access_policies_enabled = false

  # Purge protection makes a deleted vault un-purgeable for the retention
  # window: the name stays taken and the secrets stay recoverable. That is the
  # right answer everywhere except a lab that is torn down and rebuilt under
  # the same name.
  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days

  # Open by default, and deliberately so: External Secrets in the cluster and
  # the deploy running on a hosted CI runner both reach the vault over its
  # public endpoint, neither has a fixed address, and this platform runs no
  # private DNS for a private endpoint to resolve through. An estate that has
  # both closes the vault with these two — and setting network_acls also puts
  # the Microsoft.KeyVault service endpoint on the AKS subnet (main.tf), so the
  # cluster can be allowed by subnet rather than by address.
  network_acls                  = var.key_vault_network_acls
  public_network_access_enabled = var.key_vault_public_network_access_enabled

  role_assignments = {
    # The deploying principal manages secrets (seeding, rotation automation).
    deployer_secrets_officer = {
      role_definition_id_or_name = "Key Vault Secrets Officer"
      principal_id               = data.azurerm_client_config.current.object_id
      description                = "Seeds and rotates platform and tenant secrets."
    }
    # Certificates are a separate RBAC surface from secrets: importing one
    # needs Certificates Officer even for a principal that may already write
    # secrets. The Renew Certificate workflow imports the Let's Encrypt
    # wildcard here.
    deployer_certificates_officer = {
      role_definition_id_or_name = "Key Vault Certificates Officer"
      principal_id               = data.azurerm_client_config.current.object_id
      description                = "Imports the platform wildcard certificate."
    }
  }

  # Key Vault's audit trail — who read which secret, and when — exists only as
  # a diagnostic setting. On a vault that holds every tenant's credentials it
  # is the log an incident is reconstructed from.
  diagnostic_settings = local.diagnostic_settings
}

locals {
  key_vault_id  = module.key_vault.resource_id
  key_vault_uri = module.key_vault.uri
}
