variable "cloud" {
  description = "Which cloud this cluster is. It is the first label of every host the applications publish, the value of the onek8s.io/cloud label, and — because Secrets Manager is account-wide where the other backends are not — what decides how a tenant's secret names are spelled."
  type        = string

  validation {
    condition     = contains(["azure", "aws", "gcp", "oci"], var.cloud)
    error_message = "cloud must be one of: azure, aws, gcp, oci."
  }
}

variable "environment" {
  description = "Environment this foundation was deployed for (prototype, dev, staging, prod). Handed to the applications, and part of the secret key prefix on the clouds whose backend is account-wide."
  type        = string
}

variable "tenant" {
  description = "Tenant namespace the applications in the delivery-plane repository are released into. It must already exist on this cluster — the tenants stack creates it, and Flux is deliberately not asked to: a namespace without the tenant's quota, NetworkPolicy and SecretStore would defeat the point of having onboarded one."
  type        = string
  default     = "team-beta"
}

variable "domain" {
  description = "Wildcard domain the platform ingress serves. Application hosts are one label deep under it, '<cloud>-<app>.<domain>', which is all a *.<domain> certificate covers."
  type        = string
  default     = "onek8s.lol"
}

variable "namespace" {
  description = "Namespace Flux runs in. 'flux-system' is Flux's own convention and what every `flux` CLI command assumes; changing it buys nothing."
  type        = string
  default     = "flux-system"
}

variable "repo_url" {
  description = "The delivery-plane repository this cluster reconciles: OneK8s-fluxcd. Public, and read-only to the cluster — nothing here ever pushes."
  type        = string
  default     = "https://github.com/olljanat-ai/OneK8s-fluxcd.git"
}

variable "branch" {
  description = "Branch of that repository this cluster follows."
  type        = string
  default     = "main"
}

variable "cluster_path" {
  description = "Path in the delivery-plane repository that holds THIS cluster's objects. Null derives it from the cloud ('clusters/<cloud>'), which is the layout that repository documents; set it to point a second cluster of the same cloud somewhere else."
  type        = string
  default     = null
}

variable "apps_repo_url" {
  description = "The applications repository whose charts the delivery plane deploys. Not read by this module at all: it is written into cluster-vars, and the delivery-plane repository's manifests take it from there."
  type        = string
  default     = "https://github.com/olljanat-ai/OneK8s-hello.git"
}

variable "apps_branch" {
  description = "Branch of the applications repository. A fetch hint only — what is actually checked out is the commit each application pins in its cluster's release ConfigMap."
  type        = string
  default     = "main"
}

variable "git_credential_secret_name" {
  description = "Name of an existing Secret in var.namespace holding credentials for a PRIVATE delivery-plane repository (username/password, or identity/identity.pub/known_hosts for SSH). Null is right for a public repository: no credential is created, and none is needed."
  type        = string
  default     = null
}

variable "flux_chart_version" {
  description = "Version of the community 'flux2' chart, which is what pins the controllers and their CRDs."
  type        = string
  default     = "2.19.0"
}

variable "flux_sync_chart_version" {
  description = "Version of the community 'flux2-sync' chart — the two objects that point this cluster's Flux at the delivery-plane repository."
  type        = string
  default     = "1.15.0"
}

variable "source_interval" {
  description = "How often source-controller re-checks the delivery-plane repository for new commits. There is no webhook, so this is the whole latency of a merge reaching the cluster."
  type        = string
  default     = "1m"
}

variable "sync_interval" {
  description = "How often the root Kustomization re-applies this cluster's objects — the drift-correction loop, the counterpart of Argo CD's selfHeal."
  type        = string
  default     = "5m"
}

variable "enable_image_automation" {
  description = "Install the image-reflector and image-automation controllers. Off: nothing in the delivery-plane repository uses them, a release there is a commit somebody writes, and two idle controllers on a prototype node pool are two too many. Turning them on is what it would take for Flux to answer Kargo on its own terms — discovering builds and writing them back to Git."
  type        = bool
  default     = false
}

variable "enable_notifications" {
  description = "Install notification-controller. Off until something configures an Alert or a Provider: without one it reconciles nothing, and a failed sync is equally invisible either way."
  type        = bool
  default     = false
}

variable "controller_resources" {
  description = "Resource requests applied to every Flux controller. The chart's own defaults (100m CPU each) are sized for a real cluster; the prototype environments run one small node that already carries an ingress controller, External Secrets and the collectors."
  type = object({
    cpu    = optional(string, "25m")
    memory = optional(string, "64Mi")
  })
  default = {}
}

variable "extra_cluster_vars" {
  description = <<-EOT
    Extra entries for the "cluster-vars" ConfigMap — the facts this cluster
    hands to every manifest in the delivery-plane repository through Flux's
    postBuild substitution.

    The repository declares what it expects in platform-contract.yaml, and this
    is how an environment adds one without editing the module. Merged last, so
    it can override anything below.
  EOT
  type        = map(string)
  default     = {}
}

variable "extra_values" {
  description = "Extra Helm values for the flux2 chart, merged over this module's. The escape hatch for anything the variables above do not cover."
  type        = any
  default     = {}
}

variable "labels" {
  description = "Extra labels put on the objects this module creates."
  type        = map(string)
  default     = {}
}
