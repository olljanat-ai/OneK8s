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
    across azure, aws, gcp, oci and nutanix — the private cloud — and the
    tenant syntax is identical everywhere.

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
  }))
  default = {}

  validation {
    condition     = alltrue([for t in var.tenants : contains(["azure", "aws", "gcp", "oci", "nutanix"], t.cloud)])
    error_message = "Every tenant's cloud must be one of: azure, aws, gcp, oci, nutanix."
  }
}

variable "nkp_management_token" {
  description = <<-EOT
    Bearer token of a ServiceAccount on the NKP management cluster, used to
    read the private cloud's workload-cluster kubeconfig (the Cluster API
    Secret NKP keeps for it). Required only when this environment has nutanix
    tenants; supply it through the environment (TF_VAR_nkp_management_token),
    never in a tfvars file.

    The other four clouds need no equivalent because their cluster tokens come
    from cloud IAM — which is exactly what a private cloud does not have.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}
