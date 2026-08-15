variable "cloud" {
  description = "Which cloud this spoke lives on: aws, gcp, oci or nutanix (the private cloud). Azure is the hub and needs no registration — Argo CD reaches its own cluster as https://kubernetes.default.svc."
  type        = string

  validation {
    condition     = contains(["aws", "gcp", "oci", "nutanix"], var.cloud)
    error_message = "cloud must be one of: aws, gcp, oci, nutanix (azure is the hub)."
  }
}

variable "environment" {
  description = "Environment name (prototype, dev, staging, prod)."
  type        = string
}

variable "foundation" {
  description = <<-EOT
    The outputs object of the spoke's foundations/<cloud> stack (pass
    data.terraform_remote_state.<...>.outputs). Required keys on every cloud:
    cluster_name, cluster_endpoint, cluster_ca_certificate.
  EOT
  type        = any

  # Same failure mode, and the same fix, as in modules/tenant-namespace: an
  # empty object means terraform_remote_state read a blob that does not exist
  # or one whose apply never wrote outputs. Naming the cloud, the environment
  # and the blob key here keeps that from surfacing as a pile of "Unsupported
  # attribute" errors that say nothing about which foundation is missing.
  validation {
    condition     = length(keys(var.foundation)) > 0
    error_message = "No outputs in the ${var.cloud} foundation state for environment ${var.environment}: blob key foundations/${var.cloud}/${var.environment}.tfstate in the state_home container. Deploy that foundation before registering it as a spoke (cd foundations/${var.cloud} && terraform init -backend-config=backend/${var.environment}.hcl && terraform apply -var-file=envs/${var.environment}.tfvars); see docs/getting-started.md (Troubleshooting)."
  }

  validation {
    condition     = try(length(var.foundation.cluster_endpoint), 0) > 0 && try(length(var.foundation.cluster_ca_certificate), 0) > 0
    error_message = "The ${var.cloud} foundation state carries no cluster_endpoint/cluster_ca_certificate. Re-apply foundations/${var.cloud} for environment ${var.environment} so it publishes the outputs this module reads."
  }
}

variable "hub" {
  description = <<-EOT
    The outputs object of the hub's foundations/azure stack. Read for
    argocd_namespace (where the cluster Secret goes) and argocd_url (which is
    null when the Argo CD extension is disabled, i.e. there is no hub).
  EOT
  type        = any

  validation {
    condition     = length(keys(var.hub)) > 0
    error_message = "No outputs in the azure foundation state for environment ${var.environment}: blob key foundations/azure/${var.environment}.tfstate in the state_home container. The Argo CD hub runs on AKS, so that foundation has to be deployed before any spoke can be registered."
  }

  validation {
    condition     = try(var.hub.argocd_url, null) != null
    error_message = "The azure foundation for environment ${var.environment} was applied with enable_argocd = false, so there is no Argo CD to register a spoke with. Enable the extension on the hub first, or drop this cloud from var.spokes."
  }
}

variable "name" {
  description = "Name Argo CD knows this cluster by — what an ApplicationSet renders as {{name}}. Defaults to the cloud, so the four clusters read as azure/aws/gcp/oci."
  type        = string
  default     = null
}

variable "service_account_namespace" {
  description = "Namespace on the spoke holding the Argo CD manager ServiceAccount. kube-system is what `argocd cluster add` uses."
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  description = "Name of the manager ServiceAccount created on the spoke."
  type        = string
  default     = "argocd-manager"
}

variable "cluster_role_rules" {
  description = <<-EOT
    Rules of the ClusterRole the manager ServiceAccount is bound to. The
    default is what `argocd cluster add` grants: everything, because Argo CD
    has to be able to apply whatever a repository contains. Narrow it (or
    narrow the binding with var.namespaces) for a spoke that only ever gets a
    known set of kinds.
  EOT
  type = list(object({
    api_groups        = optional(list(string), [])
    resources         = optional(list(string), [])
    resource_names    = optional(list(string), [])
    non_resource_urls = optional(list(string), [])
    verbs             = list(string)
  }))
  default = [
    { api_groups = ["*"], resources = ["*"], verbs = ["*"] },
    { non_resource_urls = ["*"], verbs = ["*"] },
  ]
}

variable "namespaces" {
  description = <<-EOT
    Namespaces Argo CD may deploy into on this spoke. Empty (the default)
    means all of them. A non-empty list is enforced twice: Argo CD refuses
    Applications targeting anything else, and — when cluster_resources is
    false — the manager ServiceAccount is bound with a RoleBinding per
    namespace instead of a ClusterRoleBinding, so the API server refuses too.
  EOT
  type        = list(string)
  default     = []
}

variable "cluster_resources" {
  description = "Whether Argo CD may manage cluster-scoped resources on this spoke. Only meaningful together with var.namespaces; with no namespace list the spoke is unrestricted either way."
  type        = bool
  default     = true
}

variable "project" {
  description = "Argo CD AppProject the cluster is restricted to. Null (the default) leaves it usable by any project."
  type        = string
  default     = null
}

variable "labels" {
  description = "Extra labels for the cluster Secret. Labels are what an ApplicationSet cluster generator selects on, so this is how a spoke opts into (or out of) a fan-out."
  type        = map(string)
  default     = {}
}
