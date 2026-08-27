# The contract between this platform and the delivery-plane repository
# (OneK8s-fluxcd), as one ConfigMap.
#
# Every Flux Kustomization there substitutes its manifests from it
# (spec.postBuild.substituteFrom), which is what lets both clusters reconcile
# ONE shared application definition in which nothing names a cloud. It is the
# counterpart of the Helm values gitops/root-app.tf hands the Argo CD
# delivery-plane chart: the platform's environment-specific facts are passed
# down rather than committed per environment.
#
# This is a module of its own because the platform installs Flux two ways —
# the Microsoft.Flux extension on AKS (modules/fluxcd-aks) and the community
# chart everywhere else (modules/fluxcd) — and the ONE thing that must be
# identical on both is what the delivery plane is told about the cluster. Two
# copies of this map would be two contracts, and only one of them would be the
# one the repository's CI checks.
locals {
  cluster_path = coalesce(var.cluster_path, "clusters/${var.cloud}")

  # How THIS cloud's secret backend spells a tenant's slice of it, resolved
  # here and handed over finished so that no manifest in the delivery-plane
  # repository branches on the cloud it landed on. It is the same resolution
  # the Argo CD side does in OneK8s-argocd's values.yaml, and the reason it is
  # needed at all: Key Vault names are flat because every environment has its
  # own vault, while Secrets Manager is account-wide, so a tenant's IAM role
  # there is restricted to "<environment>/<tenant>/*"
  # (modules/tenant-namespace/aws/main.tf).
  secret_key_prefix = var.cloud == "aws" ? "${var.environment}/${var.tenant}/" : "${var.tenant}-"

  cluster_vars = merge({
    CLOUD             = var.cloud
    ENVIRONMENT       = var.environment
    TENANT            = var.tenant
    DOMAIN            = var.domain
    SECRET_KEY_PREFIX = local.secret_key_prefix
    APPS_REPO_URL     = var.apps_repo_url
    APPS_BRANCH       = var.apps_branch
    # The identity the delivery plane deploys as. It is a variable rather than
    # a constant in the repository because the two installs create it
    # differently — Azure's extension makes it, modules/fluxcd makes one to
    # match — and a manifest that names the wrong one fails as a permission
    # error at apply time rather than as anything a reviewer would see.
    FLUX_APPLIER = var.applier_service_account
    # Where Flux's own objects live. Under the AKS extension's multi-tenancy
    # every Kustomization, source and HelmRelease has to be in the
    # configuration's namespace — the workload goes elsewhere through
    # targetNamespace — so the repository needs to know the name.
    FLUX_NAMESPACE = var.namespace
  }, var.extra_cluster_vars)
}

# Written by Terraform, read by Flux at reconcile time. Nothing in it is a
# secret: names, a domain and a key prefix authorize nobody, and the tenant's
# actual secret is read by the workload through the namespaced SecretStore.
resource "kubernetes_config_map_v1" "cluster_vars" {
  metadata {
    name      = "cluster-vars"
    namespace = var.namespace
    labels    = var.labels
  }

  data = local.cluster_vars
}
