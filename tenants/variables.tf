variable "environment" {
  description = "Environment name (prototype, dev, staging, prod); must match the environment the foundations were deployed for."
  type        = string
}

variable "state_home" {
  description = <<-EOT
    Coordinates of the Azure Storage "state home" that holds every stack's
    state on every cloud. The foundation state this stack reads back is not
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

variable "tenants" {
  description = <<-EOT
    Every tenant of this environment, on every cloud, keyed by a unique id.
    The target cloud is a per-tenant parameter, so one apply onboards tenants
    across azure, aws, gcp and oci; the tenant syntax is identical everywhere.

    Map keys must be unique, so onboarding the same tenant name on more than
    one cloud means giving each entry its own key plus an explicit "name":

      azure-team-alpha = { cloud = "azure", name = "team-alpha" }
      aws-team-alpha   = { cloud = "aws",   name = "team-alpha" }

    "name" defaults to the key and is what the namespace, the cloud identity
    and the secret prefix are derived from.

    Every tenant namespace enforces the "restricted" Pod Security Standard,
    which is what keeps tenant workloads off root. "pod_security_standard"
    lowers it for one tenant that has a workload which genuinely cannot
    comply — an exception that then lives in Git, per tenant, rather than in
    the module.
  EOT
  type = map(object({
    cloud = string
    name  = optional(string)
    quota = optional(object({
      cpu_requests    = optional(string, "4")
      cpu_limits      = optional(string, "8")
      memory_requests = optional(string, "8Gi")
      memory_limits   = optional(string, "16Gi")
      pods            = optional(string, "50")
    }), {})
    labels                = optional(map(string), {})
    pod_security_standard = optional(string, "restricted")
  }))
  default = {}

  validation {
    condition     = alltrue([for t in var.tenants : contains(["azure", "aws", "gcp", "oci"], t.cloud)])
    error_message = "Every tenant's cloud must be one of: azure, aws, gcp, oci."
  }

  validation {
    condition     = alltrue([for t in var.tenants : contains(["privileged", "baseline", "restricted"], t.pod_security_standard)])
    error_message = "Every tenant's pod_security_standard must be one of: privileged, baseline, restricted."
  }
}
