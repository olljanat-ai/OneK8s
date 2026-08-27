# Flux on the EKS cluster — installed here, reading Git here, answering to no
# other cluster.
#
# This is the half of the comparison that could not be shown on AKS alone. On
# the Argo CD plane this cluster is a spoke: it runs no Argo CD at all, and
# everything deployed to it is decided on the hub, by an ApplicationSet on AKS
# and by a Kargo promotion nobody makes from here. On the Flux plane it is
# self-contained — the same module, the same charts and the same delivery-plane
# repository as AKS, pointed at clusters/aws instead of clusters/azure.
#
#   aws-hello.onek8s.lol    Argo CD from the hub, tenant team-alpha,
#                           the build somebody promoted to production
#   aws-hello2.onek8s.lol   Flux from this cluster, tenant team-beta,
#                           the build somebody committed in OneK8s-fluxcd
#
# The two planes overlap on this cluster and never touch: different tenants,
# different namespaces, different hosts, and the same chart from the same
# repository underneath both. See docs/fluxcd.md.
module "fluxcd" {
  count  = var.enable_fluxcd ? 1 : 0
  source = "../../modules/fluxcd"

  providers = {
    helm       = helm
    kubernetes = kubernetes
  }

  cloud       = "aws"
  environment = var.environment

  repo_url = var.fluxcd_repo_url
  branch   = var.fluxcd_branch
  tenant   = var.fluxcd_tenant
  domain   = var.fluxcd_domain

  flux_chart_version      = var.fluxcd_chart_version
  flux_sync_chart_version = var.fluxcd_sync_chart_version

  # Nothing here depends on External Secrets, but the applications Flux
  # delivers do — they read the tenant's test secret out of Secrets Manager
  # through the namespaced SecretStore — and keeping the add-ons in a
  # deterministic order keeps a cold apply readable.
  depends_on = [helm_release.external_secrets]
}
