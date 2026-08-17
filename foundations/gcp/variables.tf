variable "environment" {
  description = "Environment name (dev, staging, prod). Used in resource names and secret prefixes."
  type        = string
}

variable "project_id" {
  description = "GCP project ID hosting the cluster and Secret Manager."
  type        = string
}

variable "region" {
  description = "GCP region for the cluster."
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "GCP zone for the cluster."
  type        = string
  default     = "europe-north1-c"
}

variable "name_prefix" {
  description = "Prefix for all resource names, e.g. 'onek8s'."
  type        = string
  default     = "onek8s"
}

variable "node_machine_type" {
  description = "Machine type of the default node pool."
  type        = string
  default     = "e2-standard-4"
}

variable "node_count_per_zone" {
  description = "Node count per zone in the default node pool."
  type        = number
  default     = 1
}

variable "kubernetes_version" {
  description = "Minimum GKE control-plane version (minor, e.g. 1.36). Must be available in the cluster's release channel."
  type        = string
  default     = "1.36"
}

variable "eso_chart_version" {
  description = "External Secrets Operator Helm chart version."
  type        = string
  default     = "2.9.0"
}

variable "enable_ingress" {
  description = "Install Traefik as the cluster's ingress controller, with the distributed platform wildcard as its default certificate."
  type        = bool
  default     = true
}

variable "traefik_chart_version" {
  description = "Traefik Helm chart version."
  type        = string
  default     = "41.2.0"
}

variable "ingress_certificate_name" {
  description = "Secret Manager secret holding the platform wildcard certificate, as the Renew Certificate workflow's distribute mode writes it. Reserved 'platform-' prefix: no tenant identity can read it."
  type        = string
  default     = "platform-wildcard-onek8s-lol"
}

variable "deletion_protection" {
  description = "Protect the cluster from accidental terraform destroy."
  type        = bool
  default     = true
}

variable "ingress_dashboard_hostname" {
  description = "Host the Traefik dashboard and API are published on. Served UNAUTHENTICATED over the public load balancer — anyone who reaches it reads the cluster's whole routing configuration — so it is a lab convenience; set it to null to keep the dashboard reachable only through kubectl port-forward. Must be one label deep under the wildcard, and needs a DNS record pointed at the ingress load balancer."
  type        = string
  default     = "gcp-traefik.onek8s.lol"
}

variable "enable_monitoring" {
  description = "Install the Grafana k8s-monitoring collectors and ship this cluster's metrics, logs and events to Grafana Cloud. Off by default: it needs a Grafana Cloud stack's endpoints, and its credentials in Secret Manager under var.grafana_cloud_secret_name."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_monitoring || (var.grafana_cloud_metrics_url != null && var.grafana_cloud_logs_url != null)
    error_message = "enable_monitoring needs grafana_cloud_metrics_url and grafana_cloud_logs_url: both are on the Grafana Cloud stack's Details page and neither can be derived from the stack name."
  }
}

variable "k8s_monitoring_chart_version" {
  description = "grafana/k8s-monitoring Helm chart version."
  type        = string
  default     = "4.4.0"
}

variable "grafana_cloud_secret_name" {
  description = "Secret Manager secret holding the Grafana Cloud instance IDs and access-policy token as one JSON object. Reserved 'platform-' prefix: it is written and distributed by the Publish Grafana Cloud Credentials workflow."
  type        = string
  default     = "platform-grafana-cloud"
}

variable "grafana_cloud_metrics_url" {
  description = "Prometheus remote-write endpoint of the Grafana Cloud stack, e.g. 'https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push'."
  type        = string
  default     = null
}

variable "grafana_cloud_logs_url" {
  description = "Loki push endpoint of the Grafana Cloud stack, e.g. 'https://logs-prod-012.grafana.net/loki/api/v1/push'."
  type        = string
  default     = null
}

variable "grafana_cloud_traces_url" {
  description = "OTLP endpoint traces are sent to, e.g. 'https://tempo-prod-01-prod-eu-west-0.grafana.net:443'. Null configures no traces destination."
  type        = string
  default     = null
}

variable "monitoring_enable_pod_logs" {
  description = "Ship every pod's logs to Grafana Cloud. This is the largest single contributor to the bill on a chatty cluster; metrics and cluster events are unaffected by turning it off."
  type        = bool
  default     = true
}

variable "monitoring_collector_preset" {
  description = "Sizing preset applied to every Alloy collector: small (up to ~50 nodes), medium, large or xlarge."
  type        = string
  default     = "small"
}
