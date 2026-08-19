# Authentication: use environment variables (ARM_CLIENT_ID, ARM_TENANT_ID,
# ARM_SUBSCRIPTION_ID, ARM_CLIENT_SECRET) so that GitHub Actions can log in
# with a service principal stored in GitHub secrets. Locally, `az login`
# works too.
provider "azurerm" {
  resource_provider_registrations = "none"
  features {
    key_vault {
      # A destroyed vault is left soft-deleted rather than purged, so the
      # secrets in it survive a mistaken `terraform destroy` for the retention
      # window (var.key_vault_soft_delete_retention_days). Rebuilding an
      # environment under the same vault name needs the leftover purged by
      # hand — which is exactly the confirmation step this is here to force.
      purge_soft_delete_on_destroy = false
    }
  }
}

provider "azapi" {}

# Anonymous AVM deployment telemetry. It is turned off wholesale with
# var.enable_telemetry, which is what every AVM module in this stack passes on.
provider "modtm" {}

# The cluster's admin credentials, as the AVM module hands them back: one
# kubeconfig document rather than the four separate attributes the azurerm
# resource exposed. Splitting it here keeps the provider blocks below reading
# the same as their counterparts on the other three clouds.
#
# try() is not defensiveness about the shape — it is what makes a plan possible
# before the cluster exists, when the whole document is still unknown.
locals {
  aks_admin_kubeconfig = try(yamldecode(module.aks.kube_admin_config), null)

  aks_host                   = try(local.aks_admin_kubeconfig.clusters[0].cluster.server, null)
  aks_cluster_ca_certificate = try(base64decode(local.aks_admin_kubeconfig.clusters[0].cluster["certificate-authority-data"]), null)
  aks_client_certificate     = try(base64decode(local.aks_admin_kubeconfig.users[0].user["client-certificate-data"]), null)
  aks_client_key             = try(base64decode(local.aks_admin_kubeconfig.users[0].user["client-key-data"]), null)
}

# Helm talks to the AKS cluster we create in this same stack. Local accounts
# are enabled on the cluster specifically so that CI can bootstrap add-ons
# (ESO) without a separate Entra ID login dance.
provider "helm" {
  kubernetes = {
    host                   = local.aks_host
    client_certificate     = local.aks_client_certificate
    client_key             = local.aks_client_key
    cluster_ca_certificate = local.aks_cluster_ca_certificate
  }
}

# Same credentials as the helm provider, for the handful of plain Kubernetes
# objects this stack owns (the Argo CD ingress). Only ordinary resources are
# used, never kubernetes_manifest, so the cluster has to be reachable at apply
# time but not at plan time.
provider "kubernetes" {
  host                   = local.aks_host
  client_certificate     = local.aks_client_certificate
  client_key             = local.aks_client_key
  cluster_ca_certificate = local.aks_cluster_ca_certificate
}
