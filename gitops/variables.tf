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
    foundations/<cloud>/backend/<environment>.hcl writes.
  EOT
  type = object({
    resource_group_name  = string
    storage_account_name = string
    container_name       = string
  })
}

# --- Hub ---------------------------------------------------------------------

variable "hub_namespace" {
  description = "Namespace the hub's Argo CD runs in. The principal is installed beside it, because it reads and writes that Argo CD's own resources."
  type        = string
  default     = "argocd"
}

variable "hub_redis_address" {
  description = "Address of the hub Argo CD's redis, as the principal should reach it. The AKS Argo CD extension installs redis in HA mode by default, in which case this is \"argocd-redis-ha-haproxy:6379\" instead."
  type        = string
  default     = "argocd-redis:6379"
}

variable "hub_log_level" {
  description = "Principal log level (trace, debug, info, warn, error)."
  type        = string
  default     = "info"
}

variable "hub_redis_secret_name" {
  description = "Secret holding the hub Argo CD redis password."
  type        = string
  default     = "argocd-redis"
}

variable "principal_dns_label" {
  description = <<-EOT
    DNS label for the principal's public load balancer, which AKS turns into
    "<label>.<region>.cloudapp.azure.com". A label rather than a raw address
    because the name has to be known before the load balancer exists: it goes
    into the principal's server certificate, and into the address every agent
    is configured to dial. Defaults to "argocd-agent-<name_prefix>-<env>".
  EOT
  type        = string
  default     = null
}

variable "principal_address" {
  description = "Address agents dial to reach the principal. Defaults to the FQDN derived from principal_dns_label. Override to put your own name in front of the load balancer (e.g. argocd-agent.onek8s.lol), and add that name to principal_extra_dns_names so the certificate covers it."
  type        = string
  default     = null
}

variable "principal_port" {
  description = "Public port of the principal's gRPC service. Agents dial this; the container listens on 8443 behind it."
  type        = number
  default     = 443
}

variable "principal_extra_dns_names" {
  description = "Additional DNS names to put in the principal's server certificate — any name agents may dial it by."
  type        = list(string)
  default     = []
}

variable "principal_extra_ip_addresses" {
  description = "Additional IP addresses to put in the principal's server certificate. Only needed if agents dial an address rather than a name."
  type        = list(string)
  default     = []
}

variable "principal_service_annotations" {
  description = "Extra annotations for the principal's LoadBalancer Service, merged after the DNS label annotation this stack sets."
  type        = map(string)
  default     = {}
}

variable "principal_chart_version" {
  description = "Version of the argocd-agent-principal Helm chart."
  type        = string
  default     = "0.3.2"
}

variable "destination_based_mapping" {
  description = <<-EOT
    Route applications by spec.destination.name rather than by which namespace
    they sit in on the hub. This is what lets every Application live in the
    hub's own argocd namespace, which matters here: the AKS Argo CD extension
    does not support editing Argo CD's ConfigMaps directly, and namespace-based
    mapping would need apps-in-any-namespace turned on for one namespace per
    agent. Applies to managed agents.
  EOT
  type        = bool
  default     = true
}

# --- Spokes ------------------------------------------------------------------

variable "spokes" {
  description = <<-EOT
    The clusters that connect back to the hub, keyed by cloud (aws, gcp, oci).
    A cloud that is absent from this map is left completely alone: no
    foundation state is read, no cluster is contacted, its providers stay
    inert. Azure is not a spoke — it is the hub, and its Argo CD manages that
    cluster directly.

      spokes = {
        aws = {}
        gcp = { mode = "autonomous" }
      }

    "agent_name" defaults to "<cloud>-<environment>" and is what applications
    target with spec.destination.name.
  EOT
  type = map(object({
    agent_name         = optional(string)
    mode               = optional(string, "managed")
    install_argocd     = optional(bool, true)
    log_level          = optional(string, "info")
    heartbeat_interval = optional(string, "30s")
    argocd_values      = optional(string, "")
  }))
  default = {}

  validation {
    condition     = alltrue([for c in keys(var.spokes) : contains(["aws", "gcp", "oci"], c)])
    error_message = "Spokes may only be keyed by aws, gcp or oci. Azure hosts the hub."
  }

  validation {
    condition     = alltrue([for s in var.spokes : contains(["managed", "autonomous"], s.mode)])
    error_message = "Every spoke's mode must be either \"managed\" or \"autonomous\"."
  }
}

variable "spoke_namespace" {
  description = "Namespace the agent and the workload half of Argo CD run in on every spoke."
  type        = string
  default     = "argocd"
}

variable "agent_chart_version" {
  description = "Version of the argocd-agent-agent Helm chart used on every spoke."
  type        = string
  default     = "0.2.6"
}

variable "agent_image_repository" {
  description = "Container image for both the principal and the agents. Defaults to quay.io, which is where the project publishes release-tagged images; the ghcr.io mirror only carries commit tags."
  type        = string
  default     = "quay.io/argoprojlabs/argocd-agent"
}

variable "agent_image_tag" {
  description = "Image tag for both the principal and the agents. One variable for both halves on purpose — they speak a versioned protocol and are meant to move together."
  type        = string
  default     = "v0.8.1"
}

variable "argocd_chart_version" {
  description = "Version of the argo-cd Helm chart installed on the spokes. The hub's Argo CD is the AKS extension's and is not managed here."
  type        = string
  default     = "10.3.3"
}

variable "live_resources_rbac" {
  description = "Give agents cluster-wide read access so the hub's UI can render live resource trees for spoke applications."
  type        = bool
  default     = true
}

# --- PKI ---------------------------------------------------------------------

variable "ca_validity_days" {
  description = "Lifetime of the argocd-agent CA. Rotating it means reissuing every certificate below it, so it is deliberately long."
  type        = number
  default     = 3650
}

variable "certificate_validity_days" {
  description = "Lifetime of the leaf certificates (principal, resource proxy, redis proxy, agent clients)."
  type        = number
  default     = 365
}

variable "certificate_renewal_days" {
  description = "How long before expiry a leaf certificate is reissued. Reissuing happens on apply, so this has to be comfortably longer than the gap between applies."
  type        = number
  default     = 90

  validation {
    condition     = var.certificate_renewal_days < var.certificate_validity_days
    error_message = "certificate_renewal_days must be shorter than certificate_validity_days, or every apply reissues every certificate."
  }
}

# --- AKS Argo CD extension ---------------------------------------------------

variable "manage_hub_extension" {
  description = <<-EOT
    Manage the AKS Argo CD extension from this stack.

    Off by default because the extension is normally created out of band (the
    portal, or `az k8s-extension create`) and Terraform would refuse to create
    one that already exists. Turning it on requires importing the existing
    extension first — `terraform output hub_extension_import` prints the
    command.

    What it buys: the extension is the only supported way to change the hub
    Argo CD's configuration (direct ConfigMap edits are overwritten), and the
    hub's argocd-server has to be pointed at the principal's redis proxy before
    live resource views of spoke applications work. While this is off, that
    setting has to be applied by hand — `terraform output hub_extension_command`
    prints that too.
  EOT
  type        = bool
  default     = false
}

variable "hub_extension_name" {
  description = "Name of the AKS Argo CD extension resource."
  type        = string
  default     = "argocd"
}

variable "hub_extension_settings" {
  description = "Configuration settings for the AKS Argo CD extension. What this stack requires is merged in on top, so keep your own settings (SSO, RBAC, redis HA, workload identity) here and they survive."
  type        = map(string)
  default     = {}
}
