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
    labels = optional(map(string), {})
    # Pod Security Admission. Every tenant namespace is "restricted" unless it
    # says otherwise here, which is the only place it can: relaxing a level is
    # a line in this file, in a pull request, next to the tenant it applies to.
    pod_security = optional(object({
      enforce = optional(string, "restricted")
      audit   = optional(string, "restricted")
      warn    = optional(string, "restricted")
      version = optional(string, "latest")
    }), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for t in var.tenants : contains(["azure", "aws", "gcp", "oci"], t.cloud)])
    error_message = "Every tenant's cloud must be one of: azure, aws, gcp, oci."
  }

  validation {
    condition = alltrue(flatten([
      for t in var.tenants : [
        for level in [t.pod_security.enforce, t.pod_security.audit, t.pod_security.warn] :
        contains(["privileged", "baseline", "restricted"], level)
      ]
    ]))
    error_message = "Every tenant's pod_security enforce/audit/warn must each be one of: privileged, baseline, restricted."
  }
}
