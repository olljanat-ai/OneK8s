# Flux on AKS, as the Azure-managed cluster extension.
#
# Same delivery plane as modules/fluxcd installs everywhere else, and the same
# repository — but Azure owns the install: the manifests, the upgrades and the
# CVE patching of the Flux controllers, exactly as foundations/azure takes Argo
# CD as an extension rather than as a Helm release of its own (argocd.tf). AKS
# is what the real environments run; the other clouds are where the platform
# proves it is not tied to one.
#
#   microsoft.flux (extension)    source-, kustomize-, helm- and
#                                 notification-controller, the Flux CRDs, and
#                                 Azure's own fluxconfig-agent/controller
#   cluster-vars (ConfigMap)      what this cluster tells the delivery plane
#                                 about itself (modules/fluxcd-cluster-vars)
#   fluxConfiguration             GitRepository -> OneK8s-fluxcd @ branch
#                                 Kustomization -> ./clusters/azure
#
# The last two are the same two objects modules/fluxcd creates with the
# flux2-sync chart; here Azure creates them from an ARM resource instead, which
# is what makes them visible in the portal's GitOps blade and what lets Azure
# Policy audit them.
#
# One thing is genuinely different, and the delivery-plane repository is
# written for it: the extension enforces Flux's MULTI-TENANCY by default.
# Sources may not be referenced across namespaces, and the controllers deploy
# by impersonating the flux-applier ServiceAccount Azure creates in the
# configuration's namespace rather than as themselves. So an application's Flux
# objects — its GitRepository, its Kustomization, its HelmRelease — all live in
# flux-system, and the workload is placed in the tenant's namespace with the
# HelmRelease's targetNamespace. That is Microsoft's documented shape, and it
# happens to be one the community-chart install honours too, so both clusters
# still reconcile one shared definition.
locals {
  cluster_path = coalesce(var.cluster_path, "clusters/azure")

  labels = merge({
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = "onek8s"
    "onek8s.io/environment"        = var.environment
    "onek8s.io/cloud"              = "azure"
  }, var.labels)

  configuration_settings = merge({
    # On by default in the extension; stated here so that turning it off is a
    # decision somebody made in Terraform rather than a default nobody read.
    "multiTenancy.enforce" = tostring(var.enforce_multi_tenancy)
  }, var.extra_configuration_settings)
}

# --- The extension ------------------------------------------------------------
resource "azurerm_kubernetes_cluster_extension" "flux" {
  name           = "flux"
  cluster_id     = var.cluster_id
  extension_type = "microsoft.flux"

  # Leaving the version unset lets Azure install the latest of the train and
  # keep it patched, which is the whole reason for taking the extension rather
  # than installing the chart ourselves; pin var.extension_version to freeze an
  # environment on a known build.
  release_train = var.release_train
  version       = var.extension_version

  configuration_settings = local.configuration_settings

  # The image-automation and image-reflector controllers are not installed:
  # nothing in the delivery-plane repository uses them, and a release there is
  # a commit somebody writes. Turning them on
  # ("image-automation-controller.enabled") is what it would take for Flux to
  # answer Kargo on its own terms — see docs/fluxcd.md.
}

# --- This cluster's facts -----------------------------------------------------
# After the extension, because the extension is what creates the namespace this
# is written into; before the configuration, because the Kustomizations that
# configuration applies substitute from it.
module "cluster_vars" {
  source = "../fluxcd-cluster-vars"

  cloud       = "azure"
  environment = var.environment
  tenant      = var.tenant
  domain      = var.domain
  namespace   = var.namespace

  cluster_path  = local.cluster_path
  apps_repo_url = var.apps_repo_url
  apps_branch   = var.apps_branch

  extra_cluster_vars = var.extra_cluster_vars
  labels             = local.labels

  depends_on = [azurerm_kubernetes_cluster_extension.flux]
}

# --- The bootstrap ------------------------------------------------------------
# The one path in the repository this cluster reconciles. Everything below it —
# the applications, what each one runs, and the Kustomizations that apply them
# — is Git, exactly as everything below the Argo CD root Application is.
resource "azurerm_kubernetes_flux_configuration" "this" {
  name       = var.configuration_name
  cluster_id = var.cluster_id
  namespace  = var.namespace
  scope      = var.scope

  # Azure re-reads the repository and re-applies on its own schedule; without
  # this a configuration is applied once and then only on update.
  continuous_reconciliation_enabled = true

  git_repository {
    url                      = var.repo_url
    reference_type           = "branch"
    reference_value          = var.branch
    sync_interval_in_seconds = var.source_interval_seconds
    # Public repository: no credential, and nothing to rotate. A private one
    # takes an https_user + https_key_base64, or an SSH key, here.
  }

  kustomizations {
    name = "clusters"
    path = "./${local.cluster_path}"

    sync_interval_in_seconds = var.sync_interval_seconds
    # Garbage collection: an object dropped from this cluster's directory is
    # deleted from the cluster — the same promise Argo CD's prune makes, under
    # Azure's own name for it.
    garbage_collection_enabled = true
    # Deliberately not waiting: what this path applies is mostly further
    # Kustomizations, and waiting on their health would make the root report
    # the applications' status as its own. Each application's own Kustomization
    # waits for its own workload.
    wait = false
  }

  depends_on = [
    azurerm_kubernetes_cluster_extension.flux,
    module.cluster_vars,
  ]
}
