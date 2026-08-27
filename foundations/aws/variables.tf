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
  description = "Install the Grafana k8s-monitoring collectors and ship this cluster's metrics, logs and events to Grafana Cloud. Needs the credentials in Secrets Manager under var.grafana_cloud_secret_name; the endpoints come from modules/platform-observability."
  type        = bool
  default     = true
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

# Endpoint overrides for this cluster alone. Null — the default — takes the
# platform's Grafana Cloud stack from modules/platform-observability, which is
# where all four clusters write.
variable "grafana_cloud_metrics_url" {
  description = "Prometheus remote-write endpoint, when this cluster writes somewhere other than the platform's stack."
  type        = string
  default     = null
}

variable "grafana_cloud_logs_url" {
  description = "Loki push endpoint, when this cluster writes somewhere other than the platform's stack."
  type        = string
  default     = null
}

variable "grafana_cloud_traces_url" {
  description = "OTLP endpoint traces are sent to, when this cluster writes somewhere other than the platform's stack."
  type        = string
  default     = null
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

# --- Flux ---------------------------------------------------------------------
# The platform's second delivery plane. Unlike Argo CD, which reaches this
# cluster from the hub on AKS (gitops/, modules/argocd-spoke), Flux is
# installed here and reads the delivery-plane repository itself — this cluster
# is nobody's spoke on that plane. See docs/fluxcd.md.
variable "enable_fluxcd" {
  description = "Install Flux on this cluster and point it at the OneK8s-fluxcd repository. Independent of the Argo CD hub: this cluster keeps its spoke registration and gains a delivery plane of its own, which is exactly the arrangement being compared."
  type        = bool
  default     = true
}

variable "fluxcd_repo_url" {
  description = "Delivery-plane repository this cluster's Flux reconciles."
  type        = string
  default     = "https://github.com/olljanat-ai/OneK8s-fluxcd.git"
}

variable "fluxcd_branch" {
  description = "Branch of that repository this cluster follows."
  type        = string
  default     = "main"
}

variable "fluxcd_tenant" {
  description = "Tenant namespace the applications Flux delivers are released into. team-beta by default, where Argo CD's example applications go to team-alpha: two delivery planes on one cluster are much easier to tell apart when they do not share a namespace. The namespace must exist — the tenants stack creates it."
  type        = string
  default     = "team-beta"
}

variable "fluxcd_domain" {
  description = "Wildcard domain the applications Flux delivers are published under, as '<cloud>-<app>.<domain>'."
  type        = string
  default     = "onek8s.lol"
}

variable "fluxcd_chart_version" {
  description = "Version of the community 'flux2' chart, which pins the Flux controllers and their CRDs."
  type        = string
  default     = "2.19.0"
}

variable "fluxcd_sync_chart_version" {
  description = "Version of the community 'flux2-sync' chart — the GitRepository and Kustomization that bootstrap this cluster."
  type        = string
  default     = "1.15.0"
}
