# external-dns, so that publishing an Ingress still creates its record.
#
# The application routing add-on used to bring its own external-dns; running
# Traefik instead means running one. It is Azure-only by design: the
# onek8s.lol zone lives in Azure DNS, and giving the EKS/GKE/OKE clusters
# Azure credentials to write it would be the first stored cross-cloud
# credential on the platform. Those three clusters get records pointed at
# their load balancer by hand — see docs/architecture.md.
#
# The identity is a workload-identity federation of the external-dns
# ServiceAccount, granted DNS Zone Contributor on the listed zones only. An
# empty var.ingress_dns_zone_ids leaves DNS out of band and creates none of
# this.
locals {
  enable_external_dns = var.enable_ingress && length(var.ingress_dns_zone_ids) > 0

  external_dns_namespace       = "external-dns"
  external_dns_service_account = "external-dns"

  # /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/dnsZones/<zone>
  dns_zone_parts = [for id in var.ingress_dns_zone_ids : split("/", id)]

  dns_zone_names           = [for parts in local.dns_zone_parts : element(parts, length(parts) - 1)]
  dns_zone_subscription_id = try(local.dns_zone_parts[0][2], null)
  dns_zone_resource_group  = try(local.dns_zone_parts[0][4], null)
}

resource "azurerm_user_assigned_identity" "external_dns" {
  count = local.enable_external_dns ? 1 : 0

  name                = "id-external-dns-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "external_dns" {
  count = local.enable_external_dns ? 1 : 0

  name                      = "aks-external-dns"
  user_assigned_identity_id = azurerm_user_assigned_identity.external_dns[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${local.external_dns_namespace}:${local.external_dns_service_account}"
}

# Listing a zone is not enough on its own: writing records is a role
# assignment. Without it external-dns logs authorization failures and no
# record ever appears.
resource "azurerm_role_assignment" "external_dns_zone_contributor" {
  for_each = local.enable_external_dns ? toset(var.ingress_dns_zone_ids) : toset([])

  scope                = each.value
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.external_dns[0].principal_id
}

# The namespace is created here rather than by Helm so that the credential
# file below can be written into it before the release starts.
resource "kubernetes_namespace_v1" "external_dns" {
  count = local.enable_external_dns ? 1 : 0

  metadata {
    name = local.external_dns_namespace
  }

  depends_on = [azurerm_kubernetes_cluster.this]
}

# external-dns reads its Azure settings from a config file, not flags. The
# file holds no credential: useWorkloadIdentityExtension makes it exchange
# the ServiceAccount token for the identity above.
resource "kubernetes_secret_v1" "external_dns_azure" {
  count = local.enable_external_dns ? 1 : 0

  metadata {
    name      = "external-dns-azure"
    namespace = kubernetes_namespace_v1.external_dns[0].metadata[0].name
  }

  data = {
    "azure.json" = jsonencode({
      tenantId                     = data.azurerm_client_config.current.tenant_id
      subscriptionId               = local.dns_zone_subscription_id
      resourceGroup                = local.dns_zone_resource_group
      useWorkloadIdentityExtension = true
    })
  }
}

resource "helm_release" "external_dns" {
  count = local.enable_external_dns ? 1 : 0

  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.external_dns_chart_version
  namespace  = kubernetes_namespace_v1.external_dns[0].metadata[0].name

  values = [yamlencode({
    provider = {
      name = "azure"
    }

    # Ingress objects only: Traefik publishes its load balancer address into
    # every Ingress it serves, so one source covers platform and tenant hosts
    # alike, and a Service of type LoadBalancer never becomes a record by
    # accident.
    sources = ["ingress"]

    domainFilters = local.dns_zone_names

    # Ownership is recorded in a TXT record per name. Records created by
    # something else — the application routing add-on's external-dns, for
    # instance — carry a different owner and are left alone, which is why a
    # migration has to delete those by hand.
    txtOwnerId = azurerm_kubernetes_cluster.this.name

    # upsert-only: a deleted Ingress leaves its record behind rather than
    # having this controller remove records in a zone it shares with the
    # certificate workflow.
    policy = "upsert-only"

    serviceAccount = {
      name = local.external_dns_service_account
      annotations = {
        "azure.workload.identity/client-id" = azurerm_user_assigned_identity.external_dns[0].client_id
      }
    }

    podLabels = {
      "azure.workload.identity/use" = "true"
    }

    extraVolumes = [{
      name = "azure-config"
      secret = {
        secretName = kubernetes_secret_v1.external_dns_azure[0].metadata[0].name
      }
    }]

    extraVolumeMounts = [{
      name      = "azure-config"
      mountPath = "/etc/kubernetes"
      readOnly  = true
    }]
  })]

  depends_on = [
    azurerm_federated_identity_credential.external_dns,
    azurerm_role_assignment.external_dns_zone_contributor,
  ]
}
