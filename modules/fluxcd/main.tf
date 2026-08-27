# Flux, installed on ONE cluster, answering to nothing but Git.
#
# This is the second delivery plane of the platform, and it is deliberately not
# shaped like the first. Argo CD is a hub: it runs on AKS, every other cluster
# is registered with it as a spoke (modules/argocd-spoke), and one
# ApplicationSet on the hub fans an application out over all of them. Flux here
# is the opposite arrangement — every cluster runs its own, reads the
# delivery-plane repository itself, and knows about no other cluster:
#
#   Argo CD                                Flux (this module)
#   ───────────────────────────────        ─────────────────────────────────
#   one hub (AKS) + spoke Secrets          one install per cluster, no Secrets
#   ApplicationSet fans out                each cluster reads its own path
#   Kargo promotes between clusters        a person commits, per cluster
#   hub down = nothing deploys anywhere    one cluster stops; the rest do not
#
# Both planes deploy the same chart from the same applications repository, to
# the same clusters, so the difference on the cluster is the delivery plane and
# nothing else. See docs/fluxcd.md.
#
# What this module installs is the bootstrap and only the bootstrap — the exact
# counterpart of the single root Application that gitops/root-app.tf plants on
# the Argo CD hub:
#
#   helm_release "flux"          the controllers and their CRDs
#   ConfigMap    cluster-vars    this cluster's own facts, for postBuild
#                                substitution in the delivery-plane repository
#   helm_release "sync"          GitRepository -> the repository
#                                Kustomization -> clusters/<cloud>
#
# After the first apply, what this cluster runs is a commit in OneK8s-fluxcd.
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

  # The variables every Flux Kustomization in the delivery-plane repository
  # substitutes from. They are the cluster's own answer to "where did this
  # land", which is exactly why they are not committed there: they differ per
  # cluster and per environment, while one copy of an application definition
  # serves all of them.
  #
  # The repository declares what it expects in platform-contract.yaml, and its
  # CI renders every cluster against those declarations — so a key dropped here
  # fails a pull request there rather than stopping a reconciliation nobody is
  # watching.
  cluster_vars = merge({
    CLOUD             = var.cloud
    ENVIRONMENT       = var.environment
    TENANT            = var.tenant
    DOMAIN            = var.domain
    SECRET_KEY_PREFIX = local.secret_key_prefix
    APPS_REPO_URL     = var.apps_repo_url
    APPS_BRANCH       = var.apps_branch
  }, var.extra_cluster_vars)

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

    # Cluster-wide, which is what lets one Kustomization in flux-system deploy
    # into a tenant's namespace. The narrower alternative — the chart's
    # multi-tenancy lockdown, where every Kustomization must name a
    # ServiceAccount in the namespace it deploys to — needs a tenant
    # ServiceAccount with deploy rights that modules/tenant-namespace does not
    # grant today. It is the one boundary the Argo CD side has and this one
    # does not, and it is written down as such in docs/fluxcd.md rather than
    # left to be discovered.
    watchAllNamespaces = true
  }, var.extra_values))]
}

# --- This cluster's facts ----------------------------------------------------
# Written by Terraform, read by every Kustomization in the delivery-plane
# repository (spec.postBuild.substituteFrom). The parallel on the Argo CD side
# is gitops/root-app.tf handing the delivery-plane chart its Helm values:
# environment, repositories, domain and tenant come from the platform, not from
# a per-environment copy of the manifests.
resource "kubernetes_config_map_v1" "cluster_vars" {
  metadata {
    name      = "cluster-vars"
    namespace = var.namespace
    labels    = local.labels
  }

  data = local.cluster_vars

  # The namespace is the chart's.
  depends_on = [helm_release.flux]
}

# --- The bootstrap ------------------------------------------------------------
# Two objects: the repository, and the one path in it this cluster reconciles.
# Named "flux-system" because that is the name Flux's own bootstrap uses and
# what the delivery-plane repository's Kustomizations name as their sourceRef.
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

  # The CRDs, then the variables, then the objects that need both. Without the
  # ConfigMap first, the first reconcile of an application's Kustomization
  # fails on a variable that is about to exist — Flux would retry it, but a
  # cold apply should not leave an error behind for somebody to interpret.
  depends_on = [
    helm_release.flux,
    kubernetes_config_map_v1.cluster_vars,
  ]
}
