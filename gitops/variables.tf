variable "environment" {
  description = "Environment name (prototype, dev, staging, prod); must match the environment the foundations were deployed for."
  type        = string
}

variable "state_home" {
  description = <<-EOT
    Coordinates of the Azure Storage "state home" that holds every stack's
    state on every cloud. The foundation states this stack reads back are not
    configured key by key: the key is derived from the convention
    "foundations/<cloud>/<environment>.tfstate", which is exactly what
    foundations/<cloud>/backend/<environment>.hcl writes. Keep the account,
    container and environment aligned and the keys cannot drift apart.
  EOT
  type = object({
    resource_group_name  = string
    storage_account_name = string
    container_name       = string
  })
}

variable "spokes" {
  description = <<-EOT
    Clusters to register with the Argo CD hub, keyed by cloud. The hub itself
    (AKS, foundations/azure) is never listed: Argo CD always has the
    in-cluster entry for the cluster it runs on.

    An empty object registers nothing, which is what an environment whose
    other foundations are not deployed yet wants:

      spokes = {
        aws = {}                                    # everything, everywhere
        gcp = { namespaces = ["team-alpha"], cluster_resources = false }
      }

    Every attribute is optional. "namespaces" plus "cluster_resources = false"
    is the only combination that narrows the spoke's RBAC as well as Argo CD's
    own view of it — see modules/argocd-spoke/README.md.
  EOT
  type = map(object({
    name              = optional(string)
    namespaces        = optional(list(string), [])
    cluster_resources = optional(bool, true)
    project           = optional(string)
    labels            = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for c in keys(var.spokes) : contains(["aws", "gcp", "oci"], c)])
    error_message = "Spokes are keyed by cloud, and the supported spokes are: aws, gcp, oci. (azure is the hub and registers itself.)"
  }
}

variable "platform_apps" {
  description = <<-EOT
    The Argo CD "root application": one Terraform-managed Application on the
    hub, pointing Argo CD at the delivery-plane repository (OneK8s-argocd).

    That repository holds a Helm chart with the platform's AppProject and its
    ApplicationSets, so everything Argo CD deploys — to the hub and to every
    spoke — is version-controlled there rather than configured in the UI. This
    stack bootstraps it and owns nothing else in Argo CD; after the first
    apply, adding or changing an application is a commit in that repository.

    Two repositories, because they change for different reasons: repo_url is
    the delivery plane (where and when an application is deployed) and
    apps_repo_url is the applications themselves (OneK8s-hello: their source,
    their charts, their images). The AppProject allows those two and nothing
    else.

    The environment-specific values are passed down from here (environment,
    repositories, revisions, domain, tenant), which is why one copy of the
    delivery-plane chart serves every environment.

    Set enabled = false for an environment that should register spokes but not
    run any platform application. It is also skipped automatically when the
    hub's foundation was applied with enable_argocd = false.
  EOT
  type = object({
    enabled = optional(bool, true)
    # Name of the root Application on the hub.
    name = optional(string, "platform-gitops")
    # Argo CD project the ROOT application belongs to. It cannot be the
    # project the chart creates — that one does not exist yet when the root
    # application is first reconciled.
    project = optional(string, "default")
    # The delivery-plane repository Argo CD reads. Must be reachable by the
    # hub's repo-server; a private repository additionally needs credentials
    # registered with Argo CD (see docs/argocd.md).
    repo_url        = optional(string, "https://github.com/olljanat-ai/OneK8s-argocd.git")
    target_revision = optional(string, "main")
    path            = optional(string, "argocd")
    # The applications' repository: the charts the ApplicationSets deploy. It
    # is not read by this stack at all — it is handed to the delivery-plane
    # chart, which puts it in the AppProject's sourceRepos and in every
    # Application's source.
    apps_repo_url        = optional(string, "https://github.com/olljanat-ai/OneK8s-hello.git")
    apps_target_revision = optional(string, "main")
    # Wildcard domain the applications' hosts sit under: "<cloud>-<app>.<domain>".
    domain = optional(string, "onek8s.lol")
    # Tenant namespace the platform's example applications are released into.
    # It must already exist on every targeted cluster — the tenants stack
    # creates it, Argo CD is barred from doing so.
    tenant = optional(string, "team-alpha")
  })
  default = {}
}
