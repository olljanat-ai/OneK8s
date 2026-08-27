variable "cluster_id" {
  description = "Resource ID of the AKS cluster the extension is installed on."
  type        = string
}

variable "environment" {
  description = "Environment this foundation was deployed for (prototype, dev, staging, prod)."
  type        = string
}

variable "tenant" {
  description = "Tenant namespace the applications are released into. It must already exist — the tenants stack creates it, and Flux is deliberately not asked to: a namespace without the tenant's quota, NetworkPolicy and SecretStore would defeat the point of having onboarded one."
  type        = string
  default     = "team-beta"
}

variable "domain" {
  description = "Wildcard domain the platform ingress serves. Application hosts are one label deep under it, '<cloud>-<app>.<domain>'."
  type        = string
  default     = "onek8s.lol"
}

variable "namespace" {
  description = "Namespace the Flux configuration is created in. The extension itself is always installed in flux-system and cannot be installed at namespace scope, so this is where the configuration's objects and its flux-applier ServiceAccount live."
  type        = string
  default     = "flux-system"
}

variable "configuration_name" {
  description = "Name of the Azure Flux configuration. It is NOT free: Azure names the GitRepository object it creates in the cluster after it, and the delivery-plane repository's Kustomizations name that source in their sourceRef. Changing it means changing them."
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
  description = "Path in the delivery-plane repository that holds THIS cluster's objects. Null derives it from the cloud ('clusters/azure')."
  type        = string
  default     = null
}

variable "apps_repo_url" {
  description = "The applications repository whose charts the delivery plane deploys. Handed to the delivery plane through cluster-vars; not read by this module."
  type        = string
  default     = "https://github.com/olljanat-ai/OneK8s-hello.git"
}

variable "apps_branch" {
  description = "Branch of the applications repository."
  type        = string
  default     = "main"
}

variable "release_train" {
  description = "Release train of the microsoft.flux extension. 'Stable' is Azure's supported train — unlike the Argo CD extension, Flux here is generally available rather than preview."
  type        = string
  default     = "Stable"
}

variable "extension_version" {
  description = "Pin the extension to a version (null = install the latest of the release train and let Azure auto-upgrade it, which is the reason for taking the extension in the first place)."
  type        = string
  default     = null
}

variable "scope" {
  description = <<-EOT
    Permission scope of the Flux operators, in Azure's terms: "cluster" is full
    access, "namespace" restricts them to var.namespace.

    Cluster, because the configuration lives in flux-system and deploys into a
    tenant's namespace: the account it impersonates has to be able to reach
    that namespace. A namespace-scoped configuration is the shape to reach for
    when a tenant should own its own Flux objects — one configuration per
    tenant, restricted to that tenant — see docs/fluxcd.md.
  EOT
  type        = string
  default     = "cluster"

  validation {
    condition     = contains(["cluster", "namespace"], var.scope)
    error_message = "scope must be either \"cluster\" or \"namespace\"."
  }
}

variable "enforce_multi_tenancy" {
  description = <<-EOT
    Keep the extension's multi-tenancy enforcement, which is on by default:
    Flux objects may not reference a source in another namespace, and the
    controllers deploy by impersonating the flux-applier ServiceAccount rather
    than as themselves.

    The delivery-plane repository is written for it — every Flux object of an
    application sits in this namespace and the workload is placed with
    targetNamespace — so leaving it on costs nothing. Setting it to false is
    the escape hatch if a manifest that cannot be arranged that way has to be
    deployed; it makes the controllers cluster-admin, as they are on the
    community-chart install.
  EOT
  type        = bool
  default     = true
}

variable "source_interval_seconds" {
  description = "How often the source is re-checked for new commits. There is no webhook, so this is the whole latency of a merge reaching the cluster."
  type        = number
  default     = 60
}

variable "sync_interval_seconds" {
  description = "How often the root Kustomization re-applies this cluster's objects — the drift-correction loop, the counterpart of Argo CD's selfHeal."
  type        = number
  default     = 300
}

variable "extra_configuration_settings" {
  description = "Extra configurationSettings for the extension, merged last. Note that an extension update MERGES these — a key dropped here is not removed from the cluster — which is the same trap foundations/azure documents for the Argo CD extension."
  type        = map(string)
  default     = {}
}

variable "extra_cluster_vars" {
  description = "Extra entries for the cluster-vars ConfigMap the delivery-plane repository substitutes from. Declare them in its platform-contract.yaml too."
  type        = map(string)
  default     = {}
}

variable "labels" {
  description = "Extra labels put on the objects this module creates in the cluster."
  type        = map(string)
  default     = {}
}
