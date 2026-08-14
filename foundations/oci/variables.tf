variable "environment" {
  description = "Environment name (dev, staging, prod). Used in resource names and secret prefixes."
  type        = string
}

variable "tenancy_ocid" {
  description = "OCID of the tenancy (used to enumerate availability domains and as the identity root)."
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the compartment that holds the cluster, its network and the vault."
  type        = string
}

variable "region" {
  description = "OCI region for all regional resources, e.g. 'eu-frankfurt-1'."
  type        = string
}

variable "home_region" {
  description = "Tenancy home region. IAM resources can only be written there; defaults to var.region when the deployment region is the home region."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Prefix for all resource names, e.g. 'onek8s'."
  type        = string
  default     = "onek8s"
}

variable "kubernetes_version" {
  description = <<-EOT
    OKE Kubernetes version, including the leading 'v'. Give just the minor
    ("v1.36") to track the newest patch OKE offers, or an exact version
    ("v1.36.1") to pin one. Resolved against the region's supported list in
    oke.tf; the cluster, the node pool and the worker image all use the
    resolved value.
  EOT
  type        = string
  default     = "v1.36"

  validation {
    condition     = can(regex("^v?[0-9]+\\.[0-9]+(\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "kubernetes_version must look like v1.36 or v1.36.1."
  }
}

variable "vcn_cidr" {
  description = "CIDR block of the cluster VCN."
  type        = string
  default     = "10.40.0.0/16"
}

variable "services_cidr" {
  description = "CIDR block for Kubernetes Service ClusterIPs."
  type        = string
  default     = "10.96.0.0/16"
}

variable "cilium_pod_cidr" {
  description = "CIDR Cilium uses for its own cluster-pool identity allocation. Pod IPs themselves come from the VCN (VCN-native pod networking), so this must not overlap the VCN."
  type        = string
  default     = "100.64.0.0/16"
}

variable "api_allowed_cidr" {
  description = "CIDR allowed to reach the public Kubernetes API endpoint. Narrow this for production."
  type        = string
  default     = "0.0.0.0/0"
}

variable "node_shape" {
  description = "Compute shape of the default node pool. Flexible shapes (.Flex) additionally use node_ocpus/node_memory_gbs."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "node_ocpus" {
  description = "OCPUs per node. Applied only to flexible shapes (name ending in .Flex); ignored for fixed shapes, which carry their own sizing."
  type        = number
  default     = 2
}

variable "node_memory_gbs" {
  description = "Memory in GB per node. Applied only to flexible shapes (name ending in .Flex); ignored for fixed shapes, which carry their own sizing."
  type        = number
  default     = 16
}

variable "node_count" {
  description = "Number of worker nodes in the default node pool."
  type        = number
  default     = 2
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
  description = "Vault secret holding the platform wildcard certificate, as the Renew Certificate workflow's distribute mode writes it. Reserved 'platform-' prefix: no tenant identity can read it."
  type        = string
  default     = "platform-wildcard-onek8s-lol"
}

variable "ingress_load_balancer_min_mbps" {
  description = "Minimum bandwidth of the ingress load balancer's flexible shape, in Mbps. 10 is the floor OCI offers and what the shape is billed on."
  type        = number
  default     = 10
}

variable "ingress_load_balancer_max_mbps" {
  description = "Maximum bandwidth of the ingress load balancer's flexible shape, in Mbps."
  type        = number
  default     = 100
}

variable "freeform_tags" {
  description = "Extra freeform tags applied to taggable resources."
  type        = map(string)
  default     = {}
}

variable "ingress_dashboard_hostname" {
  description = "Host the Traefik dashboard and API are published on. Served UNAUTHENTICATED over the public load balancer — anyone who reaches it reads the cluster's whole routing configuration — so it is a lab convenience; set it to null to keep the dashboard reachable only through kubectl port-forward. Must be one label deep under the wildcard, and needs a DNS record pointed at the ingress load balancer."
  type        = string
  default     = "oci-traefik.onek8s.lol"
}
