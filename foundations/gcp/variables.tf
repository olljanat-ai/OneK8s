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
