variable "environment" {
  description = "Environment name (dev, staging, prod). Used in resource names and secret prefixes."
  type        = string
}

variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-west-1"
}

variable "name_prefix" {
  description = "Prefix for all resource names, e.g. 'onek8s'."
  type        = string
  default     = "onek8s"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block of the cluster VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "node_desired_size" {
  description = "Desired node count of the managed node group."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count of the managed node group."
  type        = number
  default     = 4
}

variable "eso_chart_version" {
  description = "External Secrets Operator Helm chart version."
  type        = string
  default     = "2.9.0"
}

variable "cilium_chart_version" {
  description = "Cilium Helm chart version."
  type        = string
  default     = "1.19.6"
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
  description = "Name of the platform wildcard certificate as the Renew Certificate workflow keeps it in Key Vault. On AWS it is distributed to Secrets Manager under '<environment>/platform/<name without the platform- prefix>'."
  type        = string
  default     = "platform-wildcard-onek8s-lol"
}

variable "ingress_dashboard_hostname" {
  description = "Host the Traefik dashboard and API are published on. Served UNAUTHENTICATED over the public load balancer — anyone who reaches it reads the cluster's whole routing configuration — so it is a lab convenience; set it to null to keep the dashboard reachable only through kubectl port-forward. Must be one label deep under the wildcard, and needs a DNS record pointed at the ingress load balancer."
  type        = string
  default     = "aws-traefik.onek8s.lol"
}

variable "enable_observability" {
  description = "Install the Grafana k8s-monitoring collectors and ship this cluster's metrics, logs and events to Grafana Cloud. Needs a Grafana Cloud stack's endpoints, and its credentials in Secrets Manager under var.grafana_cloud_secret_name."
  type        = bool
  default     = true

  validation {
    condition     = !var.enable_observability || (var.grafana_cloud_metrics_url != null && var.grafana_cloud_logs_url != null)
    error_message = "enable_observability needs grafana_cloud_metrics_url and grafana_cloud_logs_url: both are on the Grafana Cloud stack's Details page and neither can be derived from the stack name."
  }
}

variable "k8s_observability_chart_version" {
  description = "grafana/k8s-monitoring Helm chart version."
  type        = string
  default     = "4.4.0"
}

variable "grafana_cloud_secret_name" {
  description = "Name of the Grafana Cloud credentials object, written and distributed by the Publish Grafana Cloud Credentials workflow. Given in Key Vault's flat form; this stack translates it into Secrets Manager's '<env>/platform/<name>' layout the way it does for the wildcard certificate."
  type        = string
  default     = "platform-grafana-cloud"
}

variable "grafana_cloud_metrics_url" {
  description = "Prometheus remote-write endpoint of the Grafana Cloud stack"
  type        = string
  default     = "https://prometheus-prod-39-prod-eu-north-0.grafana.net/api/prom/push"
}

variable "grafana_cloud_logs_url" {
  description = "Loki push endpoint of the Grafana Cloud stack"
  type        = string
  default     = "https://logs-prod-025.grafana.net/loki/api/v1/push"
}

variable "grafana_cloud_traces_url" {
  description = "OTLP endpoint traces are sent to. Null configures no traces destination."
  type        = string
  default     = "https://tempo-prod-18-prod-eu-north-0.grafana.net/tempo"
}

variable "observability_enable_pod_logs" {
  description = "Ship every pod's logs to Grafana Cloud. This is the largest single contributor to the bill on a chatty cluster; metrics and cluster events are unaffected by turning it off."
  type        = bool
  default     = false
}

variable "observability_collector_preset" {
  description = "Sizing preset applied to every Alloy collector: small (up to ~50 nodes), medium, large or xlarge."
  type        = string
  default     = "small"
}
