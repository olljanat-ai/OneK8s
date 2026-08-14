locals {
  namespace = var.tenant_name

  # Secrets in the shared Key Vault are namespaced by convention:
  # "<tenant>-<secret-name>". The ABAC condition below makes this convention
  # a hard security boundary.
  secret_prefix = "${var.tenant_name}-"

  # The managed namespace API accepts CPU only in milliCPU form ("2000m",
  # minimum "1m"), while the tenant-facing quota is written in plain Kubernetes
  # CPU units ("2") so the same value works on every cloud. Convert here, and
  # pass values that already carry the "m" suffix through untouched.
  cpu_millicores = {
    for k, v in {
      request = var.quota.cpu_requests
      limit   = var.quota.cpu_limits
    } : k => endswith(v, "m") ? v : "${ceil(tonumber(v) * 1000)}m"
  }
}

data "azurerm_client_config" "current" {}

# --- Azure Managed Namespace (via azapi, preview API) ------------------------
# The managed namespace carries its own default ResourceQuota, so the common
# module skips creating one in-cluster. Its network policy is deliberately not
# used — see defaultNetworkPolicy below.
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
        cpuRequest    = local.cpu_millicores.request
        cpuLimit      = local.cpu_millicores.limit
        memoryRequest = var.quota.memory_requests
        memoryLimit   = var.quota.memory_limits
      }
      # Ingress isolation for this namespace is NOT the managed namespace's
      # job: it is the two NetworkPolicies the common module writes
      # (allow-same-namespace-only + allow-platform-ingress), exactly as on
      # EKS, GKE and OKE.
      #
      # The built-in "AllowSameNamespace" cannot be widened by an additional
      # NetworkPolicy the way a plain namespace's own default-deny can, so
      # while it is set, Traefik — which runs in its own namespace on every
      # cloud — cannot reach a tenant's pods and every tenant Ingress on AKS
      # answers "connection refused". Microsoft documents the way out, and it
      # is this one: "If you need your Kubernetes Services, ingresses, or
      # gateways to be accessible from outside of the namespace where they're
      # deployed, for example from an ingress controller deployed in a
      # separate namespace, you need to select Allow all. You might then apply
      # your own network policy to restrict ingress to be from that namespace
      # only."
      # (learn.microsoft.com/azure/aks/concepts-managed-namespaces)
      #
      # So AllowAll here is not an open namespace, it is the ARM-managed
      # policy stepping out of the way of the platform's own — which is also
      # what makes the isolation model identical on all four clouds instead of
      # Azure-shaped. Verify after an apply that both policies are in place:
      #
      #   kubectl -n <tenant> get networkpolicy
      defaultNetworkPolicy = {
        ingress = "AllowAll"
        egress  = "AllowAll"
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
  name                      = "aks-${var.tenant_name}-${var.service_account_name}"
  user_assigned_identity_id = azurerm_user_assigned_identity.tenant.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${local.namespace}:${var.service_account_name}"
}

# --- Least-privilege vault access: RBAC + ABAC prefix condition --------------
# "Key Vault Secrets User" grants getSecret/readMetadata on the whole vault;
# the ABAC condition narrows it to secrets whose name starts with the tenant
# prefix. Any other tenant's secrets are invisible to this identity.
# Key Vault ABAC string operators are case-sensitive and there is no
# IgnoreCase variant, so the prefix must be matched exactly as written; tenant
# names are lowercase DNS labels, so the secret naming convention matches.
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
        @Resource[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '${local.secret_prefix}'
      )
    )
  EOT
}

# --- Kubernetes-side resources (SA + namespaced SecretStore) -----------------
module "common" {
  source = "../common"

  tenant_name      = var.tenant_name
  namespace        = local.namespace
  create_namespace = false # provided by the managed namespace above

  service_account_name = var.service_account_name

  ingress_controller_namespace = var.ingress_controller_namespace

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

  depends_on = [azapi_resource.managed_namespace]
}
