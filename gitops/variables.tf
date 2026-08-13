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
    condition     = alltrue([for c in keys(var.spokes) : contains(["aws", "gcp"], c)])
    error_message = "Spokes are keyed by cloud, and the supported spokes today are: aws, gcp. (azure is the hub and registers itself.)"
  }
}
