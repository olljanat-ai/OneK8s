# The one Argo CD object Terraform owns.
#
# Everything else Argo CD runs — the AppProject, the ApplicationSets, and every
# Application they generate — is YAML in the OneK8s-argocd repository, and the
# applications those deploy are charts in OneK8s-hello. This resource is the
# bootstrap that points Argo CD at the first of those and then gets out of the
# way ("app of apps"): after the first apply, adding an application, or moving
# one along its stages, is a commit in a repository this stack never reads, and
# nothing about the delivery plane is configured by hand in the UI.
#
#   root-app.tf ──▶ Application "platform-gitops"
#                     └── OneK8s-argocd, path argocd
#                           ├── AppProject onek8s-platform
#                           ├── Kargo Project onek8s-hello
#                           │     ├── Warehouse hello       watches image + chart
#                           │     ├── Stage staging         azure, auto-promoted
#                           │     └── Stage production      aws, promoted by hand
#                           ├── ApplicationSet hello-staging     azure
#                           ├── ApplicationSet hello-production  aws
#                           └── ApplicationSet db-hello          azure only
#
# Both hello Applications are auto-synced: what reaches production is decided
# before Argo CD sees it, by Kargo, which writes the promoted revision into the
# same repository (docs/kargo.md). Argo CD stays a sync loop.
#
# The environment-specific facts (which environment's spokes to select, which
# repositories and revisions to sync, which domain the hosts sit under) are
# passed down as Helm values rather than committed per environment, so
# prototype, dev, staging and prod all share one copy of that chart.
#
# Note the two meanings of "staging" that meet here and stay apart: an
# environment is a set of foundations (this stack's var.environment), while a
# stage is one step of an application's release path across the clusters of one
# environment. The stages are the delivery plane's business and are not
# configured here.
locals {
  argocd_namespace = try(local.hub.argocd_namespace, "argocd")

  # Argo CD has to exist before anything can be planted in it. The hub's
  # argocd_url output is null when foundations/azure was applied with
  # enable_argocd = false, and local.hub is empty when the hub's state has not
  # been written at all — both are "there is no delivery plane here yet"
  # rather than an error, since a spoke-only run is still meaningful.
  platform_apps_enabled = (
    var.platform_apps.enabled
    && local.hub_wired
    && try(local.hub.argocd_url, null) != null
  )

  # The Azure SQL database the db-hello application uses, if this environment's
  # Azure foundation built one. Empty strings when it did not (enable_sql =
  # false, or a foundation applied before SQL existed), which is what stops the
  # db-hello ApplicationSet from rendering — the application follows the
  # database rather than a switch of its own.
  #
  # Passing the coordinates down rather than committing them matters because
  # the server name carries a random suffix: a rebuilt foundation reaches the
  # application on the next gitops apply, with nothing to edit.
  # Kargo on the hub, if this environment's foundation installed it. The
  # delivery-plane chart renders the Kargo Project, Warehouse and Stages of the
  # hello application only when it did — the alternative, promotion objects
  # nothing reconciles, would look like a release path and be a pile of inert
  # YAML.
  hub_kargo = {
    enabled = (
      var.platform_apps.kargo_enabled
      && try(local.hub.kargo_namespace, null) != null
    )
    namespace = try(local.hub.kargo_namespace, "kargo")
    # Empty when Kargo runs controller-only (no UI configured). It is only ever
    # a link on a Stage, never something the chart needs to reach.
    url = try(local.hub.kargo_url, null) == null ? "" : local.hub.kargo_url
  }

  hub_sql = {
    server   = try(local.hub.sql_server_fqdn, null) == null ? "" : local.hub.sql_server_fqdn
    database = try(local.hub.sql_database_name, null) == null ? "" : local.hub.sql_database_name
  }

  # Values handed to the delivery-plane chart's values.yaml. Keys must match it.
  platform_apps_values = {
    environment        = var.environment
    repoURL            = var.platform_apps.repo_url
    targetRevision     = var.platform_apps.target_revision
    appsRepoURL        = var.platform_apps.apps_repo_url
    appsTargetRevision = var.platform_apps.apps_target_revision
    argocdNamespace    = local.argocd_namespace
    domain             = var.platform_apps.domain
    tenant             = var.platform_apps.tenant
    sql                = local.hub_sql
    kargo              = local.hub_kargo
  }
}

# kubernetes_manifest rather than a typed resource, because Application is a
# CRD — the same trade-off the tenant module makes for the ESO SecretStore, and
# with the same prerequisite: the CRDs must already be installed on the hub at
# plan time. They are, since the Argo CD extension is part of the foundation
# and gitops is always applied after it.
resource "kubernetes_manifest" "root_app" {
  count    = local.platform_apps_enabled ? 1 : 0
  provider = kubernetes.azure

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = var.platform_apps.name
      namespace = local.argocd_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "onek8s"
        "onek8s.io/environment"        = var.environment
      }
      # Deleting the root Application takes its children with it, so
      # `terraform destroy` leaves no orphaned ApplicationSets or workloads on
      # the spokes.
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      # "default", not the project this chart creates: the AppProject is one of
      # the things the root Application deploys, so it cannot be its own
      # prerequisite.
      project = var.platform_apps.project

      source = {
        repoURL        = var.platform_apps.repo_url
        targetRevision = var.platform_apps.target_revision
        path           = var.platform_apps.path

        helm = {
          # A YAML string rather than a structured values object: Argo CD types
          # this field as a plain string, which is the one shape
          # kubernetes_manifest can carry through without a schema for what is
          # inside it.
          values = yamlencode(local.platform_apps_values)
        }
      }

      destination = {
        # The hub is always the local cluster from Argo CD's point of view.
        server    = "https://kubernetes.default.svc"
        namespace = local.argocd_namespace
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        # A cold apply plants objects that depend on a namespace another
        # controller is still creating: the Kargo Project is cluster-scoped and
        # its namespace appears only once Kargo reconciles it, so the Warehouse
        # and the Stages inside it can lose that race by a few seconds. Retry
        # rather than leave the delivery plane half-applied until somebody
        # notices.
        retry = {
          limit = 5
          backoff = {
            duration    = "15s"
            factor      = 2
            maxDuration = "3m"
          }
        }
      }
    }
  }

  # The extension owns the namespace and the CRDs this object needs; on a cold
  # apply the spokes are usually registered in the same run, but neither
  # depends on the other.
  depends_on = [data.azurerm_kubernetes_cluster.hub]
}
