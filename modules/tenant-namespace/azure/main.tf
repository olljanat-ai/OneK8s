locals {
  namespace = var.tenant_name

  # Secrets in the shared Key Vault are namespaced by convention:
  # "<tenant>-<secret-name>". The ABAC condition below makes this convention
  # a hard security boundary.
  secret_prefix = "${var.tenant_name}-"
}

data "azurerm_client_config" "current" {}

# --- Azure Managed Namespace (via azapi, preview API) ------------------------
# The managed namespace carries its own default ResourceQuota and
# NetworkPolicy, so the common module skips creating them in-cluster.
resource "azapi_resource" "managed_namespace" {
  type      = "Microsoft.ContainerService/managedClusters/managedNamespaces@${var.managed_namespace_api_version}"
  name      = local.namespace
  parent_id = var.aks_cluster_id

  body = {
    location = var.location
    properties = {
      labels = merge({
        "onek8s.io/tenant" = var.tenant_name
      }, var.namespace_labels)
      annotations = {}
      defaultResourceQuota = {
        cpuRequest    = var.quota.cpu_requests
        cpuLimit      = var.quota.cpu_limits
        memoryRequest = var.quota.memory_requests
        memoryLimit   = var.quota.memory_limits
      }
      defaultNetworkPolicy = {
        ingress = var.network_policy.ingress
        egress  = var.network_policy.egress
      }
      adoptionPolicy = "Never"
      deletePolicy   = "Delete"
    }
  }
}

# --- Tenant identity: UAMI + federated credential ----------------------------
resource "azurerm_user_assigned_identity" "tenant" {
  name                = "id-tenant-${var.tenant_name}-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_federated_identity_credential" "tenant" {
  name                = "aks-${var.tenant_name}-${var.service_account_name}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.tenant.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.oidc_issuer_url
  subject             = "system:serviceaccount:${local.namespace}:${var.service_account_name}"
}

# --- Least-privilege vault access: RBAC + ABAC prefix condition --------------
# "Key Vault Secrets User" grants getSecret/readMetadata on the whole vault;
# the ABAC condition narrows it to secrets whose name starts with the tenant
# prefix. Any other tenant's secrets are invisible to this identity.
resource "azurerm_role_assignment" "tenant_secrets" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.tenant.principal_id

  condition_version = "2.0"
  condition         = <<-EOT
    (
      (
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/getSecret/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})
      )
      OR
      (
        @Resource[Microsoft.KeyVault/vaults/secrets].secretName StringStartsWithIgnoreCase '${local.secret_prefix}'
      )
    )
  EOT
}

# --- Optional shared Redis delegation ----------------------------------------
# Azure Managed Redis authenticates via Entra ID: assigning the built-in
# "default" access policy to the tenant identity is the whole delegation.
# It is a data-plane assignment on the shared database — the tenant gets
# Redis access, never ARM control-plane rights. The Redis username is the
# identity's object (principal) ID.
resource "azapi_resource" "redis_access" {
  count = var.redis_enabled ? 1 : 0

  type      = "Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@${var.redis_api_version}"
  name      = "tenant-${var.tenant_name}"
  parent_id = var.redis_database_id

  body = {
    properties = {
      accessPolicyName = "default"
      user = {
        objectId = azurerm_user_assigned_identity.tenant.principal_id
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.redis_database_id != null
      error_message = "redis_enabled = true but the foundation exports no managed_redis_database_id — deploy a foundation that includes Azure Managed Redis first."
    }
  }
}

# --- Kubernetes-side resources (SA + namespaced SecretStore) -----------------
module "common" {
  source = "../common"

  tenant_name      = var.tenant_name
  namespace        = local.namespace
  create_namespace = false # provided by the managed namespace above
  limit_range      = var.limit_range

  service_account_name = var.service_account_name
  service_account_annotations = {
    "azure.workload.identity/client-id" = azurerm_user_assigned_identity.tenant.client_id
    "azure.workload.identity/tenant-id" = data.azurerm_client_config.current.tenant_id
  }
  service_account_labels = {
    "azure.workload.identity/use" = "true"
  }

  secret_store_provider = {
    azurekv = {
      authType = "WorkloadIdentity"
      vaultUrl = var.key_vault_uri
      serviceAccountRef = {
        name = var.service_account_name
      }
    }
  }

  redis_connection = var.redis_enabled ? {
    REDIS_HOST = var.redis_hostname
    REDIS_PORT = tostring(var.redis_port)
    REDIS_TLS  = "true"
    # Entra auth: username = the identity's object ID, password = an Entra
    # access token acquired via workload identity.
    REDIS_USERNAME = azurerm_user_assigned_identity.tenant.principal_id
  } : null

  depends_on = [azapi_resource.managed_namespace]
}
