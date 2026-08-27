# Flux on one cluster, from the community chart — the portable half of the
# platform's second delivery plane.
#
# AKS takes Flux as the Azure-managed extension (modules/fluxcd-aks), because
# that is what the real environments run and Azure patches it. This module is
# the same delivery plane for every cluster that has no such extension to take:
# EKS today, GKE and OKE when they are registered. Both installs read the SAME
# repository, are told the same things about their cluster
# (modules/fluxcd-cluster-vars) and reconcile one shared application
# definition — which is the point of having a portable half at all. If an
# application only works on AKS, the platform has stopped being cloud-agnostic
# and this module is where that shows up.
#
#   helm_release "flux"       source-, kustomize- and helm-controller (+ CRDs)
#   flux-applier              the identity the delivery plane deploys as, and
#                             the counterpart of the ServiceAccount Azure's
#                             extension creates and impersonates with
#   cluster-vars (ConfigMap)  what this cluster tells the delivery plane about
#                             itself
#   helm_release "sync"       GitRepository -> the repository
#                             Kustomization -> clusters/<cloud>
#
# The topology is the other half of the experiment: no hub, nothing registered
# between clusters, every cluster reading Git for itself. See docs/fluxcd.md.
locals {
  cluster_path = coalesce(var.cluster_path, "clusters/${var.cloud}")

  labels = merge({
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = "onek8s"
    "onek8s.io/environment"        = var.environment
    "onek8s.io/cloud"              = var.cloud
  }, var.labels)

  # The flux2-sync chart stamps its own app.kubernetes.io/{instance,managed-by,
  # part-of} and helm.sh/chart labels on the two objects it renders and then
  # appends whatever it is given, verbatim. A key that collides is emitted
  # twice, and a manifest with a duplicate mapping key is not a manifest the
  # API server will take — so only the platform's own labels are handed to it.
  sync_labels = {
    for k, v in local.labels : k => v
    if !startswith(k, "app.kubernetes.io/") && !startswith(k, "helm.sh/")
  }

  # Requests only, and the same on every controller. Limits are left off on
  # purpose: a throttled kustomize-controller is a delivery plane that stops
  # reconciling under exactly the load that made it busy.
  controller = {
    resources = {
      requests = {
        cpu    = var.controller_resources.cpu
        memory = var.controller_resources.memory
      }
    }
  }
}

# --- The controllers ---------------------------------------------------------
# The community chart rather than the `flux` provider's bootstrap: bootstrapping
# with the provider means giving Terraform write access to the delivery-plane
# repository so it can commit Flux's own manifests into it, and this platform
# keeps Terraform on the cluster side of that line — the repository is written
# by people and by CI, never by an apply.
resource "helm_release" "flux" {
  name             = "flux"
  repository       = "https://fluxcd-community.github.io/helm-charts"
  chart            = "flux2"
  version          = var.flux_chart_version
  namespace        = var.namespace
  create_namespace = true

  values = [yamlencode(merge({
    installCRDs = true

    # The three that do the work here: a source, a Kustomization applier and a
    # Helm applier. Everything else is opt-in, because an idle controller is
    # still a Deployment on a node pool the prototype environments size for one
    # thing at a time.
    sourceController    = local.controller
    kustomizeController = local.controller
    helmController      = local.controller

    notificationController = merge(local.controller, {
      create = var.enable_notifications
    })
    imageAutomationController = merge(local.controller, {
      create = var.enable_image_automation
    })
    imageReflectionController = merge(local.controller, {
      create = var.enable_image_automation
    })

    watchAllNamespaces = true
  }, var.extra_values))]
}

# --- The identity the delivery plane deploys as -------------------------------
# Azure's Flux extension creates a "flux-applier" ServiceAccount in the
# configuration's namespace and has the controllers impersonate it; with the
# configuration at cluster scope it can reach a tenant's namespace. Nothing in
# the community chart does that, so the manifests in the delivery-plane
# repository would name a ServiceAccount that exists on AKS and nowhere else.
#
# One of the same name is created here instead, so a Kustomization or
# HelmRelease that says "serviceAccountName: flux-applier" means the same thing
# on both installs and the shared definition stays shared.
#
# It is cluster-admin, matching the AKS configuration's "cluster" scope — and
# it is where the tenant boundary would be narrowed if this plane ever needs
# one: a per-tenant applier, bound in that tenant's namespace only, with a
# namespace-scoped configuration to match (docs/fluxcd.md, Known gaps).
resource "kubernetes_service_account_v1" "applier" {
  metadata {
    name      = var.applier_service_account
    namespace = var.namespace
    labels    = local.labels
  }

  depends_on = [helm_release.flux]
}

resource "kubernetes_cluster_role_binding_v1" "applier" {
  metadata {
    name   = "onek8s-${var.applier_service_account}-${var.namespace}"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.applier.metadata[0].name
    namespace = var.namespace
  }
}

# --- This cluster's facts ----------------------------------------------------
# The one thing that must be identical on both installs, so it is one module
# rather than two copies: see modules/fluxcd-cluster-vars.
module "cluster_vars" {
  source = "../fluxcd-cluster-vars"

  cloud       = var.cloud
  environment = var.environment
  tenant      = var.tenant
  domain      = var.domain
  namespace   = var.namespace

  cluster_path            = local.cluster_path
  apps_repo_url           = var.apps_repo_url
  apps_branch             = var.apps_branch
  applier_service_account = var.applier_service_account

  extra_cluster_vars = var.extra_cluster_vars
  labels             = local.labels

  # The namespace is the chart's.
  depends_on = [helm_release.flux]
}

# --- The bootstrap ------------------------------------------------------------
# Two objects: the repository, and the one path in it this cluster reconciles.
# Named "flux-system" because that is the name Flux's own bootstrap uses, the
# name the delivery-plane repository's Kustomizations give as their sourceRef —
# and the name Azure gives the GitRepository its Flux configuration creates, so
# one manifest serves both installs.
#
# A Helm release rather than kubernetes_manifest, and that is not a style
# choice: GitRepository and Kustomization are CRDs installed by the release
# above, and kubernetes_manifest needs a resource's schema at PLAN time — so on
# a cold apply, with the CRDs not yet on the cluster, the plan itself fails.
# Helm renders client-side and applies after them.
resource "helm_release" "sync" {
  name       = "flux-system"
  repository = "https://fluxcd-community.github.io/helm-charts"
  chart      = "flux2-sync"
  version    = var.flux_sync_chart_version
  namespace  = var.namespace

  values = [yamlencode({
    gitRepository = {
      labels = local.sync_labels
      spec = {
        url      = var.repo_url
        interval = var.source_interval
        ref = {
          branch = var.branch
        }
        # Public repository: no credential, and nothing to rotate. A private
        # one takes a Secret created out of band and named here.
        secretRef = var.git_credential_secret_name == null ? {} : {
          name = var.git_credential_secret_name
        }
      }
    }

    kustomization = {
      labels = local.sync_labels
      spec = {
        path     = "./${local.cluster_path}"
        interval = var.sync_interval
        # Garbage collection. An object dropped from this cluster's directory
        # is deleted from the cluster, the same promise Argo CD's prune makes.
        prune = true
        # Deliberately NOT waiting: what this path applies is mostly further
        # Kustomizations, and waiting on their health would make the root sync
        # report the applications' status as its own. Each application's own
        # Kustomization waits for its own workload.
        wait = false
      }
    }
  })]

  # The CRDs, then the identity and the variables, then the objects that need
  # all three. Without the ConfigMap first, the first reconcile of an
  # application's Kustomization fails on a variable that is about to exist —
  # Flux would retry it, but a cold apply should not leave an error behind for
  # somebody to interpret.
  depends_on = [
    helm_release.flux,
    kubernetes_cluster_role_binding_v1.applier,
    module.cluster_vars,
  ]
}
