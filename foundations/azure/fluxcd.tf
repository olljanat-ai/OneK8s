# Flux on the AKS cluster — the platform's second delivery plane, running
# beside Argo CD rather than instead of it, and taken as the Azure-managed
# cluster extension for the same reasons Argo CD is (argocd.tf): Azure owns the
# manifests, the upgrades and the CVE patching, the install is visible in the
# portal's GitOps blade, and Azure Policy can audit it. AKS is what the real
# environments run; the other clouds run the community chart
# (modules/fluxcd) and are where the platform proves the delivery plane is not
# tied to Azure.
#
# This cluster therefore hosts both planes, and that is the experiment: the
# same application, from the same chart in the same repository, delivered two
# ways on one cluster and published on two hosts.
#
#   azure-hello.onek8s.lol    Argo CD, hub-and-spoke, tenant team-alpha,
#                             the build Kargo promoted into staging
#   azure-hello2.onek8s.lol   Flux, independent, tenant team-beta,
#                             the build somebody committed in OneK8s-fluxcd
#
# The topologies are opposites and that is the point. Argo CD runs here as a
# hub with EKS registered as a spoke (gitops/, modules/argocd-spoke), so one
# ApplicationSet reaches both clusters and losing this cluster stops delivery
# everywhere. Flux is installed once per cluster with nothing registered
# between them: each reads OneK8s-fluxcd itself, and neither knows the other
# exists. docs/fluxcd.md has the full comparison.
#
# Unlike the Argo CD extension, this one enforces Flux's multi-tenancy by
# default: an application's Flux objects all live in the configuration's
# namespace and the workload is placed in the tenant's with targetNamespace.
# The delivery-plane repository is written that way, and it costs the other
# clusters nothing — which is why the default is kept rather than opted out of.
module "fluxcd" {
  count  = var.enable_fluxcd ? 1 : 0
  source = "../../modules/fluxcd-aks"

  providers = {
    azurerm    = azurerm
    kubernetes = kubernetes
  }

  cluster_id  = azurerm_kubernetes_cluster.this.id
  environment = var.environment

  repo_url = var.fluxcd_repo_url
  branch   = var.fluxcd_branch
  tenant   = var.fluxcd_tenant
  domain   = var.fluxcd_domain

  release_train         = var.fluxcd_release_train
  extension_version     = var.fluxcd_extension_version
  enforce_multi_tenancy = var.fluxcd_enforce_multi_tenancy

  # Nothing here depends on External Secrets, but the applications Flux
  # delivers do — they read the tenant's test secret through the namespaced
  # SecretStore — and keeping the add-ons in a deterministic order keeps a cold
  # apply readable.
  depends_on = [helm_release.external_secrets]
}
