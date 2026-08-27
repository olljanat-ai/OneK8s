# Flux on the AKS cluster — the platform's second delivery plane, running
# beside Argo CD rather than instead of it.
#
# This cluster therefore hosts both, and that is the experiment: the same
# application, from the same chart in the same repository, delivered two ways
# on one cluster and published on two hosts.
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
# Argo CD comes from the Microsoft-offered AKS extension (argocd.tf) while this
# is a plain Helm install of the community chart, and deliberately so: EKS has
# no such extension, and an Azure-managed Flux on one cluster against a Helm
# Flux on the other would make every difference between the two ambiguous.
module "fluxcd" {
  count  = var.enable_fluxcd ? 1 : 0
  source = "../../modules/fluxcd"

  providers = {
    helm       = helm
    kubernetes = kubernetes
  }

  cloud       = "azure"
  environment = var.environment

  repo_url = var.fluxcd_repo_url
  branch   = var.fluxcd_branch
  tenant   = var.fluxcd_tenant
  domain   = var.fluxcd_domain

  flux_chart_version      = var.fluxcd_chart_version
  flux_sync_chart_version = var.fluxcd_sync_chart_version

  # Nothing here depends on External Secrets, but the applications Flux
  # delivers do — they read the tenant's test secret through the namespaced
  # SecretStore — and keeping the add-ons in a deterministic order keeps a cold
  # apply readable.
  depends_on = [helm_release.external_secrets]
}
