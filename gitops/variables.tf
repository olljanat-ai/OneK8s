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
    condition     = alltrue([for c in keys(var.spokes) : contains(["aws", "gcp", "oci", "nutanix"], c)])
    error_message = "Spokes are keyed by cloud, and the supported spokes are: aws, gcp, oci, nutanix. (azure is the hub and registers itself.)"
  }
}

variable "platform_apps" {
  description = <<-EOT
    The Argo CD "root application": one Terraform-managed Application on the
    hub, pointing Argo CD at gitops/argocd/ in this repository.

    That directory is a Helm chart holding the platform's AppProject and its
    ApplicationSets, so everything Argo CD deploys — to the hub and to every
    spoke — is version-controlled here rather than configured in the UI. This
    stack bootstraps it and owns nothing else in Argo CD; after the first
    apply, adding or changing an application is a commit.

    The environment-specific values are passed down from here (environment,
    repository, revision, domain, tenant), which is why one copy of
    gitops/argocd/ serves every environment.

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
    # Repository Argo CD reads. Must be reachable by the hub's repo-server;
    # a private repository additionally needs credentials registered with
    # Argo CD (see docs/hello-app.md).
    repo_url        = optional(string, "https://github.com/olljanat-ai/OneK8s.git")
    target_revision = optional(string, "main")
    path            = optional(string, "gitops/argocd")
    # Wildcard domain the applications' hosts sit under: "<cloud>-<app>.<domain>".
    domain = optional(string, "onek8s.lol")
    # Tenant namespace the platform's example applications are released into.
    # It must already exist on every targeted cluster — the tenants stack
    # creates it, Argo CD is barred from doing so.
    tenant = optional(string, "team-alpha")
  })
  default = {}
}

variable "nkp_management_token" {
  description = <<-EOT
    Bearer token of a ServiceAccount on the NKP management cluster, used to
    read the private cloud's workload-cluster kubeconfig (the Cluster API
    Secret NKP keeps for it) so that this stack can register it as a spoke.
    Required only when "nutanix" is in var.spokes; supply it through the
    environment (TF_VAR_nkp_management_token), never in a tfvars file.

    Registration is a one-off privileged act on the spoke, exactly as it is on
    the other clouds — everything Argo CD does afterwards uses the
    argocd-manager token this stack creates there instead.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}
