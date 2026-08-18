variable "chart_version" {
  description = "grafana/k8s-monitoring Helm chart version."
  type        = string
  default     = "4.4.0"
}

variable "namespace" {
  description = "Namespace the collectors run in. It is also where the credentials Secret has to live, because an Alloy remote.kubernetes.secret reads it by name and namespace."
  type        = string
  default     = "observability"
}

variable "cluster_name" {
  description = "Value of the 'cluster' label on everything this cluster sends. It is the only thing separating four clusters inside one Grafana Cloud stack, so it must be unique across the platform — '<prefix>-<cloud>-<environment>'."
  type        = string
}

# --- Platform ----------------------------------------------------------------
variable "azure_aks" {
  description = "This cluster is Azure AKS. Annotates every Pod the chart deploys that talks to the API server with kubernetes.azure.com/set-kube-service-host-fqdn, which AKS' admission webhook turns into the API server's FQDN in KUBERNETES_SERVICE_HOST. The chart detects AKS on its own and refuses to install without it, so on Azure this is not optional; elsewhere it must stay false."
  type        = bool
  default     = false
}

# --- Grafana Cloud endpoints -------------------------------------------------
# Not secrets, and not derivable from the stack name: every Grafana Cloud stack
# is assigned its own cluster of hosted endpoints. They are on the stack's
# "Details" page, next to the instance ID each one authenticates with.
#
# They are defaulted here rather than per foundation because there is one stack
# behind all four clusters — the same reason var.cluster_name exists. A cluster
# that has to write somewhere else overrides them from its foundation, and
# because every one of these is nullable = false, a foundation whose own
# variable is null falls back to the default below instead of passing the null
# through.
variable "metrics_url" {
  description = "Prometheus remote-write endpoint of the Grafana Cloud stack. Defaults to the platform's stack."
  type        = string
  default     = "https://prometheus-prod-39-prod-eu-north-0.grafana.net/api/prom/push"
  nullable    = false
}

variable "logs_url" {
  description = "Loki push endpoint of the Grafana Cloud stack. Defaults to the platform's stack."
  type        = string
  default     = "https://logs-prod-025.grafana.net/loki/api/v1/push"
  nullable    = false
}

variable "traces_url" {
  description = "OTLP endpoint traces are sent to. Defaults to the platform's stack; it is var.enable_traces, not a null here, that removes the traces destination."
  type        = string
  default     = "https://tempo-prod-18-prod-eu-north-0.grafana.net/tempo"
  nullable    = false
}

variable "enable_traces" {
  description = "Define the traces destination at all. Off leaves metrics and logs untouched and is what a Grafana Cloud stack without a Tempo instance needs; enable_application_observability requires it."
  type        = bool
  default     = true
}

variable "traces_protocol" {
  description = "OTLP transport for var.traces_url: 'grpc' for the Tempo endpoint (port 443), 'http' for an OTLP gateway URL ending in /otlp."
  type        = string
  default     = "grpc"

  validation {
    condition     = contains(["grpc", "http"], var.traces_protocol)
    error_message = "traces_protocol must be either \"grpc\" or \"http\"."
  }
}

# --- Credentials -------------------------------------------------------------
# Nothing here holds a credential; it only says where in the cluster one will
# appear. Filling the Secret is the caller's job, the same way filling the
# ingress' certificate secret is (see var.extra_objects).
variable "credentials_secret_name" {
  description = "Kubernetes Secret in var.namespace holding the Grafana Cloud instance IDs and the access-policy token. The collectors read it live through Alloy's remote.kubernetes.secret, so a rotated token is picked up without restarting them."
  type        = string
  default     = "grafana-cloud-credentials"
}

variable "credentials_token_key" {
  description = "Key of var.credentials_secret_name holding the access-policy token. One token authenticates every signal; the instance ID is what differs per signal."
  type        = string
  default     = "token"
}

variable "metrics_username_key" {
  description = "Key of var.credentials_secret_name holding the metrics instance ID (the Prometheus 'username')."
  type        = string
  default     = "metrics-username"
}

variable "logs_username_key" {
  description = "Key of var.credentials_secret_name holding the logs instance ID."
  type        = string
  default     = "logs-username"
}

variable "traces_username_key" {
  description = "Key of var.credentials_secret_name holding the traces instance ID."
  type        = string
  default     = "traces-username"
}

# --- Features ----------------------------------------------------------------
# Each one is a chart feature plus, where it needs one, the workload that
# produces the data. Turning a feature off removes the collector it was the
# only user of, so a cluster only runs what it actually ships.
variable "enable_cluster_metrics" {
  description = "Scrape the Kubernetes control plane, the kubelets and kube-state-metrics. This is what the Grafana Cloud Kubernetes app is built on; without it the cluster shows up empty there."
  type        = bool
  default     = true
}

variable "enable_host_metrics" {
  description = "Deploy Node Exporter and scrape node-level CPU, memory, disk and network metrics."
  type        = bool
  default     = true
}

variable "enable_annotation_autodiscovery" {
  description = "Scrape any Pod or Service carrying the prometheus.io/scrape annotation, so a tenant publishes its own metrics without the platform being changed."
  type        = bool
  default     = true
}

variable "enable_cluster_events" {
  description = "Ship Kubernetes Events as logs."
  type        = bool
  default     = true
}

variable "enable_pod_logs" {
  description = "Ship the logs of every pod on the cluster. This is the largest single contributor to a Grafana Cloud bill on a chatty cluster."
  type        = bool
  default     = true
}

variable "enable_node_logs" {
  description = "Ship the nodes' own journald logs. Off by default: it needs a host mount and says little about the workloads."
  type        = bool
  default     = false
}

variable "enable_application_observability" {
  description = "Run an OTLP receiver (4317/4318) in the cluster for applications that emit their own traces, metrics and logs. Requires var.enable_traces."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_application_observability || var.enable_traces
    error_message = "enable_application_observability needs enable_traces: an OTLP receiver with nowhere to forward to drops everything it accepts."
  }
}

# --- Sizing and escape hatches -----------------------------------------------
variable "collector_preset" {
  description = "Chart sizing preset applied to every collector: small (up to ~50 nodes), medium, large or xlarge. The prototype clusters are one node, so small is the default."
  type        = string
  default     = "small"

  validation {
    condition     = contains(["small", "medium", "large", "xlarge"], var.collector_preset)
    error_message = "collector_preset must be one of small, medium, large, xlarge."
  }
}

variable "extra_objects" {
  description = "Extra manifests rendered with the release, as a list of objects. This is where the credential plumbing lives: the platform ServiceAccount, its ESO SecretStore and the ExternalSecret that fills var.credentials_secret_name."
  type        = any
  default     = []
}

variable "extra_values" {
  description = "Extra Helm values merged over the ones this module builds (top-level keys win outright — the merge is not deep)."
  type        = any
  default     = {}
}

variable "timeout" {
  description = "Seconds Helm waits for the release to become ready. The Alloy Operator has to come up and reconcile every Alloy object before the release settles."
  type        = number
  default     = 900
}
