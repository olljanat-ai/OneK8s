# Azure SQL: one Entra-only logical server, and one database on it.
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
# The server comes from the Azure Verified Module for SQL servers, which also
# owns its firewall rules and its audit diagnostics. The database does not: it
# is created with azapi, because the free offer is expressed by two ARM
# properties (useFreeLimit, freeLimitExhaustionBehavior) that neither the
# azurerm provider nor the AVM module's `databases` input carries. Same reason,
# and same shape, as the AKS managed namespace in modules/tenant-namespace/azure.
# A production database with no free offer to express fits the module's own
# `databases` input and belongs there instead.

locals {
  sql_enabled = var.enable_sql

  # The deploying principal by default: it is already this vault's Secrets
  # Officer and the only identity guaranteed to exist at apply time. Anything
  # else — a break-glass Entra group, a DBA — is passed in.
  sql_admin_object_id = coalesce(var.sql_admin_object_id, data.azurerm_client_config.current.object_id)

  # Bytes, because ARM counts database size in bytes and nothing else here does.
  sql_max_size_bytes = var.sql_max_size_gb * 1024 * 1024 * 1024

  # Zone redundancy and geo-redundant backups are what a production database
  # is expected to have, and are also exactly what the free offer does not
  # include — so the offer, when it is asked for, wins over both rather than
  # failing the apply with an ARM error that says neither.
  sql_zone_redundant            = var.sql_use_free_limit ? false : var.sql_zone_redundant
  sql_backup_storage_redundancy = var.sql_use_free_limit ? "Local" : var.sql_backup_storage_redundancy
  # The module's `resource` output is the whole azurerm_mssql_server and is
  # marked sensitive, but a host name is not a secret and every consumer of
  # this stack reads it out of the state. Unwrapping it inside the comprehension
  # keeps `null` — not an error — as the answer when SQL is off.
  sql_server_fqdn = one([for server in module.sql_server : nonsensitive(server.resource.fully_qualified_domain_name)])
  sql_server_id   = one(module.sql_server[*].resource_id)
  sql_server_name = one(module.sql_server[*].resource_name)

  # The free-offer properties, as a list of either one object or none.
  #
  # The obvious spelling — `var.sql_use_free_limit ? { … } : {}` inline in the
  # body — is a conditional between two *different* object types, and Terraform
  # resolves that by converting both sides to a map. A map has one element
  # type, so the boolean and the string unify to string and `useFreeLimit`
  # becomes `"true"`: ARM stores the boolean it was sent, the configuration
  # holds a string, and every plan from then on reports
  #
  #   ~ useFreeLimit = true -> "true"
  #
  # for a database nobody has touched. A list of zero or one object has no such
  # unification to do, so the attribute types survive and
  # `merge(…, local.sql_free_limit_properties...)` folds it into the body.
  sql_free_limit_properties = [
    for _ in range(var.sql_use_free_limit ? 1 : 0) : {
      useFreeLimit                = true
      freeLimitExhaustionBehavior = var.sql_free_limit_exhaustion_behavior
    }
  ]
}

resource "random_string" "sql_suffix" {
  count = local.sql_enabled ? 1 : 0

  length  = 4
  special = false
  upper   = false
}

# Logical server names are globally unique, like Key Vault names, so they carry
# the same random suffix.
module "sql_server" {
  source  = "Azure/avm-res-sql-server/azurerm"
  version = "0.2.1"
  count   = local.sql_enabled ? 1 : 0

  name                = "sql-${local.name}-${random_string.sql_suffix[0].result}"
  location            = var.location
  resource_group_name = module.resource_group.name
  server_version      = "12.0"
  enable_telemetry    = var.enable_telemetry
  tags                = local.tags

  # Public endpoint, but nothing may reach it by default: there are no firewall
  # rules unless var.sql_firewall_rules asks for them, and the cluster gets in
  # through the VNet rule below instead. A private endpoint would be the next
  # step up and is listed as a known gap in docs/db-hello-app.md — it needs
  # private DNS the platform does not run yet, and it would put the database
  # out of reach of the tenants deploy that bootstraps it.
  public_network_access_enabled = var.sql_public_network_access_enabled

  # Entra-only. With this set there is no SQL login on this server to leak,
  # rotate or forget, and the module omits the administrator_login pair.
  azuread_administrator = {
    login_username              = var.sql_admin_login_username
    object_id                   = local.sql_admin_object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }

  # Deliberately empty by default. The tenants deploy opens a rule for its own
  # runner address and removes it again in the same run, so operating the
  # database needs no standing exception; these are for the ones you want to
  # keep (an office range, a jump host).
  firewall_rules = var.sql_firewall_rules

  # No diagnostic_settings here on purpose. Azure exposes no diagnostic log
  # categories on a logical server — they live on the databases under it, and
  # this stack's one database is created with azapi below because of the free
  # offer. A production database created through the module's own `databases`
  # input carries its diagnostics there.
}

# The database, and the free offer, in five properties.
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
  parent_id = local.sql_server_id
  location  = var.location
  tags      = local.tags

  body = {
    sku = {
      name     = var.sql_sku.name
      tier     = var.sql_sku.tier
      family   = var.sql_sku.family
      capacity = var.sql_sku.capacity
    }
    properties = merge({
      collation                        = var.sql_collation
      maxSizeBytes                     = local.sql_max_size_bytes
      autoPauseDelay                   = var.sql_auto_pause_delay_in_minutes
      minCapacity                      = var.sql_min_capacity
      zoneRedundant                    = local.sql_zone_redundant
      requestedBackupStorageRedundancy = local.sql_backup_storage_redundancy
    }, local.sql_free_limit_properties...)
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
#
# No AVM module covers this: the SQL server module owns firewall rules but not
# virtual network rules, so it stays a provider resource.
resource "azurerm_mssql_virtual_network_rule" "aks" {
  count = local.sql_enabled ? 1 : 0

  name      = "aks-subnet"
  server_id = local.sql_server_id
  subnet_id = local.aks_subnet_id
}
