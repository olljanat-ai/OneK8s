variable "agent_name" {
  description = "Name this spoke registers under on the hub. It is the CN of the agent's client certificate, the name of its Argo CD cluster on the hub, and the value applications target with spec.destination.name. RFC 1123 label."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.agent_name)) && length(var.agent_name) <= 63
    error_message = "agent_name must be a lowercase RFC 1123 DNS label of at most 63 characters."
  }
}

variable "namespace" {
  description = "Namespace the spoke's Argo CD and agent run in."
  type        = string
  default     = "argocd"
}

variable "create_namespace" {
  description = "Create var.namespace. Set false if something else already owns it."
  type        = bool
  default     = true
}

variable "principal_address" {
  description = "Hostname or IP the agent dials to reach the hub's principal. This is the only direction traffic ever flows, which is why the spoke needs no inbound reachability of its own."
  type        = string
}

variable "principal_port" {
  description = "Port the hub's principal gRPC service listens on."
  type        = number
  default     = 443
}

variable "agent_mode" {
  description = "\"managed\" (the hub owns the Applications and pushes them down) or \"autonomous\" (the spoke owns them from its own git and the hub only observes)."
  type        = string
  default     = "managed"

  validation {
    condition     = contains(["managed", "autonomous"], var.agent_mode)
    error_message = "agent_mode must be either \"managed\" or \"autonomous\"."
  }
}

variable "destination_based_mapping" {
  description = "Route applications by spec.destination.name instead of by the namespace they sit in on the hub. Must match the principal's setting. Managed mode only."
  type        = bool
  default     = true
}

variable "ca_cert_pem" {
  description = "PEM of the hub's argocd-agent CA. The agent verifies the principal's server certificate against it."
  type        = string
}

variable "client_cert_pem" {
  description = "PEM of this agent's client certificate (CN = var.agent_name), signed by the hub CA. Half of the mTLS identity the principal authenticates."
  type        = string
}

variable "client_key_pem" {
  description = "PEM of the private key for client_cert_pem."
  type        = string
  sensitive   = true
}

variable "install_argocd" {
  description = "Install the workload half of Argo CD (application controller, repo server, redis) on the spoke. Set false only if the cluster already runs a suitable Argo CD in var.namespace."
  type        = bool
  default     = true
}

variable "argocd_chart_version" {
  description = "Version of the argo-cd Helm chart used for the spoke's Argo CD."
  type        = string
  default     = "10.3.3"
}

variable "argocd_values" {
  description = "Extra values merged into the spoke's argo-cd Helm release, after the module's own values."
  type        = string
  default     = ""
}

variable "agent_chart_version" {
  description = "Version of the argocd-agent-agent Helm chart."
  type        = string
  default     = "0.2.6"
}

variable "agent_image_repository" {
  description = "Container image for the agent. Defaults to quay.io, which is where the project publishes release-tagged images (the ghcr.io mirror only carries commit tags)."
  type        = string
  default     = "quay.io/argoprojlabs/argocd-agent"
}

variable "agent_image_tag" {
  description = "Image tag for the agent. Keep it in step with the hub's principal — the two speak a versioned protocol."
  type        = string
  default     = "v0.8.1"
}

variable "log_level" {
  description = "Agent log level (trace, debug, info, warn, error)."
  type        = string
  default     = "info"
}

variable "heartbeat_interval" {
  description = "Application-level heartbeat on the gRPC stream. HTTP/2 pings do not reset request-based idle timers, so anything between the agent and the hub that ages out idle connections (cloud load balancers, proxies) needs this instead. Empty disables it."
  type        = string
  default     = "30s"
}

variable "live_resources_rbac" {
  description = "Grant the agent cluster-wide read access so the hub's Argo CD UI can show live resources through the principal's resource proxy. The agent's own chart only grants access to Argo CD's resources, which is not enough to render a resource tree."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to the resources this module creates directly."
  type        = map(string)
  default     = {}
}
