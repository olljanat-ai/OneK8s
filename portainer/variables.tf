variable "environment" {
  description = "Environment name (prototype, dev, staging, prod); must match the environment the foundations were deployed for."
  type        = string
}

variable "state_home" {
  description = <<-EOT
    Coordinates of the Azure Storage "state home" that holds every stack's
    state on every cloud. The foundation states this stack reads back are not
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

variable "agents" {
  description = <<-EOT
    Clusters to onboard into the Portainer server on the hub, keyed by cloud.
    The hub itself (AKS, foundations/azure) is never listed: Portainer runs on
    it and manages it directly, through the ServiceAccount its own chart binds
    to cluster-admin.

    Each entry registers one Portainer environment and installs one Edge Agent
    on that cluster. An empty object takes every default, which is what an
    environment normally wants:

      agents = {
        aws = {}
        gcp = { name = "gke-prototype" }
        oci = {}
      }

    An empty map onboards nothing, which is what an environment whose other
    foundations are not deployed yet wants.
  EOT
  type = map(object({
    # Display name in Portainer. Defaults to the cloud, like a gitops spoke.
    name = optional(string)
    # Portainer environment group (1 = Unassigned) and tags, for an
    # installation that organises its fleet.
    group_id = optional(number, 1)
    tag_ids  = optional(list(number))
    # Namespace the agent runs in on the target cluster.
    namespace = optional(string, "portainer")
    # Keep in step with the server; the Edge protocol is versioned with it.
    agent_version = optional(string, "2.39.6")
    # EDGE_INSECURE_POLL: only for a Portainer published with a certificate
    # the agent cannot chain, which the platform wildcard is not.
    insecure_poll = optional(bool, false)
    # What the agent may do on its cluster. See
    # modules/portainer-agent/README.md before narrowing it.
    cluster_role = optional(string, "cluster-admin")
    labels       = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for c in keys(var.agents) : contains(["aws", "gcp", "oci"], c)])
    error_message = "Agents are keyed by cloud, and the supported ones are: aws, gcp, oci. (azure is the hub: Portainer runs there and manages that cluster itself.)"
  }
}

variable "settings" {
  description = <<-EOT
    The Portainer server's own settings. Two of them are prerequisites for
    onboarding rather than preferences — Edge compute has to be enabled before
    an Edge environment can be registered, and the Edge Portainer URL (taken
    from the hub's own output, not configurable here) is where agents are told
    to report.

    Portainer's settings API replaces the whole object, so anything not set
    here returns to its zero value. Set enabled = false in an environment
    where Portainer's settings are managed elsewhere — then Edge compute has
    to be turned on by hand before this stack can register anything.
  EOT
  type = object({
    enabled = optional(bool, true)
    # 1 = internal user database, 2 = LDAP, 3 = OAuth. The admin account the
    # foundation bootstraps from Key Vault lives in the internal database.
    authentication_method        = optional(number, 1)
    enable_edge_compute_features = optional(bool, true)
    # Seconds between agent check-ins. Shorter means the UI notices a cluster
    # coming and going sooner, at the cost of more polling.
    edge_agent_checkin_interval = optional(number, 5)
    enable_telemetry            = optional(bool, false)
  })
  default = {}
}
