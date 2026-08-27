variable "cloud" {
  description = "Which cloud this cluster is. It is the first label of every host the applications publish, the value of the onek8s.io/cloud label, and — because Secrets Manager is account-wide where the other backends are not — what decides how a tenant's secret names are spelled."
  type        = string

  validation {
    condition     = contains(["azure", "aws", "gcp", "oci"], var.cloud)
    error_message = "cloud must be one of: azure, aws, gcp, oci."
  }
}

variable "environment" {
  description = "Environment this foundation was deployed for (prototype, dev, staging, prod)."
  type        = string
}

variable "tenant" {
  description = "Tenant namespace the applications in the delivery-plane repository are released into. It must already exist on this cluster — the tenants stack creates it."
  type        = string
}

variable "domain" {
  description = "Wildcard domain the platform ingress serves. Application hosts are one label deep under it, '<cloud>-<app>.<domain>'."
  type        = string
}

variable "namespace" {
  description = "Namespace Flux runs in, and the namespace this ConfigMap is written to. It has to be the namespace the Flux Kustomizations live in: postBuild substitution only reads ConfigMaps beside the object being reconciled."
  type        = string
  default     = "flux-system"
}

variable "cluster_path" {
  description = "Path in the delivery-plane repository that holds THIS cluster's objects. Null derives it from the cloud ('clusters/<cloud>')."
  type        = string
  default     = null
}

variable "apps_repo_url" {
  description = "The applications repository whose charts the delivery plane deploys. Not read by Terraform at all: it is written into the ConfigMap, and the delivery-plane repository's manifests take it from there."
  type        = string
}

variable "apps_branch" {
  description = "Branch of the applications repository. A fetch hint only — what is actually checked out is the commit each application pins in its cluster's release ConfigMap."
  type        = string
}

variable "applier_service_account" {
  description = "ServiceAccount the delivery plane's Kustomizations and HelmReleases deploy as. On AKS this is the account the Flux extension creates and impersonates with (flux-applier); modules/fluxcd creates one of the same name so a manifest naming it works on either install."
  type        = string
  default     = "flux-applier"
}

variable "extra_cluster_vars" {
  description = "Extra entries for the ConfigMap, merged last so an environment can add or override one without editing this module. Declare it in the delivery-plane repository's platform-contract.yaml too, or its CI will not know it exists."
  type        = map(string)
  default     = {}
}

variable "labels" {
  description = "Labels put on the ConfigMap."
  type        = map(string)
  default     = {}
}
