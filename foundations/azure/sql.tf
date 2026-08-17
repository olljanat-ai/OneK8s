# Azure SQL Database on the **free offer**, and one logical server to hold it.
#
# What matters here is mostly what is *absent*: there is no administrator
# login, no password, no connection string and no secret. The server is put
# into Microsoft Entra-only authentication mode, so the only way in is an Entra
# token — which is exactly what a tenant's workload identity already produces
# for Key Vault. The db-hello application (apps/db-hello) uses that same
# identity to reach this database, and carries no credential of any kind.
#
#   AKS pod  --(projected SA token)-->  Entra ID  --(access token)-->  Azure SQL
#     ^ tenant ServiceAccount              ^ tenant UAMI (federated credential)
#
# Two things this stack deliberately does NOT do:
#
#   * It does not create the tenant's database user. That is a data-plane act
#     (T-SQL), not an ARM one, so it lives where the platform's other
#     data-plane seeding lives — the "sql" job of the tenants deploy, which
#     runs the application's own bootstrap command once per Azure tenant.
#     See docs/db-hello-app.md.
#   * It writes nothing to the directory. The Entra administrator is a
#     principal that already exists — by default the identity running the
#     deploy — exactly as the Argo CD SSO app registration is.
#
# The database itself is created with azapi rather than azurerm, because the
# free offer is expressed by two ARM properties (useFreeLimit,
# freeLimitExhaustionBehavior) that the pinned azurerm provider does not carry.
# Same reason, and same shape, as the AKS managed namespace in
# modules/tenant-namespace/azure.

locals {
  sql_enabled = var.enable_sql

  # The deploying principal by default: it is already this vault's Secrets
  # Officer and the only identity guaranteed to exist at apply time. Anything
  # else — a break-glass Entra group, a DBA — is passed in.
  sql_admin_object_id = coalesce(var.sql_admin_object_id, data.azurerm_client_config.current.object_id)

  # Bytes, because ARM counts database size in bytes and nothing else here does.
  sql_max_size_bytes = var.sql_max_size_gb * 1024 * 1024 * 1024

  sql_server_fqdn = one(azurerm_mssql_server.this[*].fully_qualified_domain_name)
}

resource "random_string" "sql_suffix" {
  count = local.sql_enabled ? 1 : 0

  length  = 4
  special = false
  upper   = false
}

# Logical server names are globally unique, like Key Vault names, so they carry
# the same random suffix.
resource "azurerm_mssql_server" "this" {
  count = local.sql_enabled ? 1 : 0

  name                = "sql-${local.name}-${random_string.sql_suffix[0].result}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  version             = "12.0"
  minimum_tls_version = "1.2"

  # Public endpoint, but nothing may reach it by default: there are no firewall
  # rules unless var.sql_firewall_rules asks for them, and the cluster gets in
  # through the VNet rule below instead. A private endpoint would be the next
  # step up and is listed as a known gap in docs/db-hello-app.md — it needs
  # private DNS the platform does not run yet, and it would put the database
  # out of reach of the tenants deploy that bootstraps it.
  public_network_access_enabled = true

  # Entra-only. With this set, azurerm rejects an administrator_login /
  # administrator_login_password pair, which is the point: there is no SQL
  # login on this server to leak, rotate or forget.
  azuread_administrator {
    login_username              = var.sql_admin_login_username
    object_id                   = local.sql_admin_object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }

  tags = local.tags
}

# The free offer, in five properties.
#
#   useFreeLimit                 100,000 vCore seconds + 32 GB a month, free,
#                                for the lifetime of the subscription
#   freeLimitExhaustionBehavior  AutoPause: the database goes to sleep for the
#                                rest of the month instead of billing. That is
#                                the whole reason this is safe to leave running
#                                — BillOverUsage is the other option and it
#                                does what it says.
#   GP_S_Gen5 / capacity 2       serverless General Purpose, the only tier the
#                                free offer is available on (4 vCores max)
#   autoPauseDelay               60 minutes, the minimum: an idle lab database
#                                stops consuming the free budget by itself
#   maxSizeBytes                 32 GB, the free ceiling
#
# Auto-pause is visible from the application: the first request after an idle
# hour waits for a resume, which is why apps/db-hello retries and says so on
# the page rather than returning an error.
resource "azapi_resource" "sql_database" {
  count = local.sql_enabled ? 1 : 0

  type      = "Microsoft.Sql/servers/databases@2023-08-01"
  name      = var.sql_database_name
  parent_id = azurerm_mssql_server.this[0].id
  location  = azurerm_resource_group.this.location
  tags      = local.tags

  body = {
    sku = {
      name     = var.sql_sku.name
      tier     = var.sql_sku.tier
      family   = var.sql_sku.family
      capacity = var.sql_sku.capacity
    }
    properties = merge({
      collation      = var.sql_collation
      maxSizeBytes   = local.sql_max_size_bytes
      autoPauseDelay = var.sql_auto_pause_delay_in_minutes
      minCapacity    = var.sql_min_capacity
      zoneRedundant  = false
      # Local redundancy is not a choice on the free offer with AutoPause: geo
      # and zone redundant backups are not part of it.
      requestedBackupStorageRedundancy = "Local"
      }, var.sql_use_free_limit ? {
      useFreeLimit                = true
      freeLimitExhaustionBehavior = var.sql_free_limit_exhaustion_behavior
    } : {})
  }
}

# How the cluster gets in. The AKS subnet carries the Microsoft.Sql service
# endpoint (main.tf) and is allowed on the server — so pods reach the database
# over the Azure backbone from a source address the server recognises, and the
# public endpoint stays closed to everything else.
#
# Pods on Azure CNI overlay SNAT to their node's address, which is in this
# subnet, so a per-node rule is not needed and none of this depends on the pod
# CIDR.
resource "azurerm_mssql_virtual_network_rule" "aks" {
  count = local.sql_enabled ? 1 : 0

  name      = "aks-subnet"
  server_id = azurerm_mssql_server.this[0].id
  subnet_id = azurerm_subnet.aks.id
}

# Deliberately empty by default. The tenants deploy opens a rule for its own
# runner address and removes it again in the same run, so operating the database
# needs no standing exception; these are for the ones you want to keep (an
# office range, a jump host).
resource "azurerm_mssql_firewall_rule" "allowed" {
  for_each = local.sql_enabled ? var.sql_firewall_rules : {}

  name             = each.key
  server_id        = azurerm_mssql_server.this[0].id
  start_ip_address = each.value.start_ip_address
  end_ip_address   = each.value.end_ip_address
}
