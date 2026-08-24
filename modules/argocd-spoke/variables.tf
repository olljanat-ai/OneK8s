variable "cloud" {
  description = "Which cloud this spoke lives on: aws, gcp or oci. Azure is the hub and needs no agent — Argo CD deploys to the cluster it runs on as https://kubernetes.default.svc, and its own application-controller reconciles that."
  type        = string

  validation {
    condition     = contains(["aws", "gcp", "oci"], var.cloud)
    error_message = "cloud must be one of: aws, gcp, oci (azure is the hub)."
  }
}

variable "environment" {
  description = "Environment name (prototype, dev, staging, prod)."
  type        = string
}

variable "foundation" {
  description = <<-EOT
    The outputs object of the spoke's foundations/<cloud> stack (pass
    data.terraform_remote_state.<...>.outputs). Read for cluster_name only —
    the endpoint and CA are the gitops stack's business (it needs them to
    install the agent), and the hub never uses either.
  EOT
  type        = any

  # Same failure mode, and the same fix, as in modules/tenant-namespace: an
  # empty object means terraform_remote_state read a blob that does not exist
  # or one whose apply never wrote outputs. Naming the cloud, the environment
  # and the blob key here keeps that from surfacing as a pile of "Unsupported
  # attribute" errors that say nothing about which foundation is missing.
  validation {
    condition     = length(keys(var.foundation)) > 0
    error_message = "No outputs in the ${var.cloud} foundation state for environment ${var.environment}: blob key foundations/${var.cloud}/${var.environment}.tfstate in the state_home container. Deploy that foundation before attaching it as a spoke (cd foundations/${var.cloud} && terraform init -backend-config=backend/${var.environment}.hcl && terraform apply -var-file=envs/${var.environment}.tfvars); see docs/getting-started.md (Troubleshooting)."
  }

  validation {
    condition     = try(length(var.foundation.cluster_name), 0) > 0
    error_message = "The ${var.cloud} foundation state carries no cluster_name. Re-apply foundations/${var.cloud} for environment ${var.environment} so it publishes the outputs this module reads."
  }
}

variable "principal" {
  description = <<-EOT
    Where the argocd-agent principal is, and how this agent reaches it. Built
    by the gitops stack from the hub's foundation outputs:

      address                 host name the agent dials, published by the hub's
                              Traefik with TLS passthrough
      port                    port that host answers on
      namespace               namespace the principal runs in on the hub, and
                              where the cluster Secret goes ("argocd")
      resource_proxy_address  host:port of the principal's resource proxy, as
                              Argo CD on the hub addresses it in-cluster
      label_selector          the label principal and agent both filter on, so
                              the hub's own application-controller keeps the
                              Applications that are not an agent's
  EOT
  type = object({
    address                = string
    port                   = number
    namespace              = string
    resource_proxy_address = string
    label_selector         = string
  })

  validation {
    condition     = length(var.principal.address) > 0 && length(var.principal.resource_proxy_address) > 0
    error_message = "The azure foundation for environment ${var.environment} publishes no argocd-agent principal address. Apply it with enable_argocd_agent = true (and an argocd_agent_hostname) before attaching a spoke, or drop this cloud from var.spokes."
  }
}

variable "ca" {
  description = <<-EOT
    The argocd-agent certificate authority, read out of the hub's
    "argocd-agent-ca" Secret by the gitops stack. Both halves are needed here:
    the certificate is handed to the agent so it can validate the principal,
    and the private key signs this agent's two client certificates.

    It is the one credential in this design with real blast radius — anything
    holding it can mint an identity for any agent — which is why it is read
    from the cluster at apply time rather than passed through a foundation
    output, and why the gitops state is as sensitive as the hub itself.
  EOT
  type = object({
    cert_pem        = string
    private_key_pem = string
  })
  sensitive = true

  validation {
    condition     = length(var.ca.cert_pem) > 0 && length(var.ca.private_key_pem) > 0
    error_message = "The hub's argocd-agent CA Secret is empty or missing. Re-apply foundations/azure with enable_argocd_agent = true; the CA is created there."
  }
}

variable "name" {
  description = "Name Argo CD knows this cluster by — what an ApplicationSet renders as {{name}}, what an Application's spec.destination.name has to say, and the agent's own identity (the common name of its client certificate). Defaults to the cloud, so the four clusters read as azure/aws/gcp/oci."
  type        = string
  default     = null
}

variable "agent_namespace" {
  description = "Namespace on the spoke holding the agent, the local Argo CD and their credentials. It must be the namespace the hub renders Applications into — destination-based mapping preserves an Application's namespace across the connection — which is 'argocd' on both sides."
  type        = string
  default     = "argocd"
}

variable "agent_release_name" {
  description = "Helm release name of the agent on the spoke. Its ServiceAccount is named <release>-sa."
  type        = string
  default     = "argocd-agent"
}

variable "agent_chart_repository" {
  description = "Helm repository holding the argocd-agent agent chart."
  type        = string
  default     = "oci://ghcr.io/argoproj-labs/argocd-agent"
}

variable "agent_chart_version" {
  description = "Version of the argocd-agent agent chart. Pinned rather than floating, and pinned to the same generation as the principal's chart on the hub: the two speak a versioned protocol to each other."
  type        = string
  default     = "0.2.6"
}

variable "agent_log_level" {
  description = "Log level of the agent (trace, debug, info, warn, error)."
  type        = string
  default     = "info"
}

variable "agent_allowed_namespaces" {
  description = "Extra namespaces, as a comma-separated list of glob patterns, that the agent may manage Applications in beyond var.agent_namespace. Empty is the normal case: every Application arrives in the namespace the hub created it in, and the hub creates them all in 'argocd'."
  type        = string
  default     = ""
}

variable "agent_extra_values" {
  description = "Extra Helm values merged over the ones this module builds for the agent chart (top-level keys win outright — the merge is not deep)."
  type        = any
  default     = {}
}

variable "argocd_chart_repository" {
  description = "Helm repository holding the community Argo CD chart installed on the spoke. Note that this is NOT how the hub gets its Argo CD: the hub runs the Microsoft-offered AKS cluster extension (docs/argocd.md)."
  type        = string
  default     = "https://argoproj.github.io/argo-helm"
}

variable "argocd_chart_version" {
  description = "Version of the community Argo CD chart on the spoke. Its appVersion must be Argo CD 3.4 or later on the HUB side for the skip-reconcile annotation to be honoured; here it only has to be a version the agent supports."
  type        = string
  default     = "10.4.0"
}

variable "argocd_extra_values" {
  description = "Extra Helm values merged over the ones this module builds for the spoke's Argo CD (top-level keys win outright — the merge is not deep). This is where a spoke declares node selectors, resource requests or a private image registry."
  type        = any
  default     = {}
}

variable "repo_server_replicas" {
  description = "Repo-server replicas on the spoke. It renders every chart this cluster deploys, so it is the component to scale when a spoke carries many applications."
  type        = number
  default     = 1
}

variable "helm_timeout" {
  description = "Seconds Helm waits for either release on the spoke to become ready. The first apply pulls the Argo CD images onto a node pool that may still be scaling."
  type        = number
  default     = 900
}

variable "client_certificate_validity_hours" {
  description = "How long this agent's client certificates are valid. Two are issued from the hub's CA: one the agent authenticates with, one Argo CD on the hub uses against the resource proxy. Both are replaced by an apply."
  type        = number
  default     = 8760
}

variable "client_certificate_early_renewal_hours" {
  description = "How long before expiry an apply reissues the client certificates. The default renews them a month out, so an environment applied at any sane cadence never reaches an expired agent."
  type        = number
  default     = 720
}

variable "cluster_role_rules" {
  description = <<-EOT
    Rules of the ClusterRole the spoke's Argo CD application-controller is
    bound to. The default is what the upstream chart grants and what `argocd
    cluster add` used to grant on this cluster: everything, because Argo CD has
    to be able to apply whatever a repository contains. Narrow it (or narrow
    the binding with var.namespaces) for a spoke that only ever gets a known
    set of kinds.

    The chart's own cluster-scoped RBAC is turned off so that this is the only
    answer to "what may Argo CD do here".
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

variable "enable_resource_proxy_rbac" {
  description = "Whether the agent may read this cluster's resources on the hub's behalf. It is what fills the resource tree under an Application in the Argo CD UI; with it off, syncs work exactly the same and the UI shows an Application with nothing under it."
  type        = bool
  default     = true
}

variable "agent_cluster_role_rules" {
  description = <<-EOT
    Rules of the ClusterRole the AGENT is bound to, which is a different
    question from what Argo CD may apply: this is what the hub can see through
    the agent's resource proxy.

    Read-only on everything by default. Making it read-write would turn the
    proxy into a second path onto this cluster that no Application and no
    AppProject constrains — the UI's "delete this pod" would work, and so would
    anything else the hub asked for.
  EOT
  type = list(object({
    api_groups        = optional(list(string), [])
    resources         = optional(list(string), [])
    resource_names    = optional(list(string), [])
    non_resource_urls = optional(list(string), [])
    verbs             = list(string)
  }))
  default = [
    { api_groups = ["*"], resources = ["*"], verbs = ["get", "list", "watch"] },
    { api_groups = [""], resources = ["pods/log"], verbs = ["get", "list"] },
  ]
}

variable "namespaces" {
  description = <<-EOT
    Namespaces Argo CD may deploy into on this spoke. Empty (the default)
    means all of them. A non-empty list is enforced twice: Argo CD on the hub
    refuses Applications targeting anything else, and — when cluster_resources
    is false — the spoke's application-controller is bound with a RoleBinding
    per namespace instead of a ClusterRoleBinding, so its API server refuses
    too.
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
