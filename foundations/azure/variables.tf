variable "environment" {
  description = "Environment name (dev, staging, prod). Used in resource names and secret prefixes."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "swedencentral"
}

variable "name_prefix" {
  description = "Prefix for all resource names, e.g. 'onek8s'."
  type        = string
  default     = "onek8s"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes minor version (null = latest default for the region)."
  type        = string
  default     = "1.36"
}

variable "system_node_count" {
  description = "Number of nodes in the default (system) node pool."
  type        = number
  default     = 2
}

variable "system_node_vm_size" {
  description = "VM size for the system node pool."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "vnet_cidr" {
  description = "Address space of the cluster VNet."
  type        = string
  default     = "10.10.0.0/16"
}

variable "pod_cidr" {
  description = "Pod CIDR for Azure CNI overlay."
  type        = string
  default     = "192.168.0.0/16"
}

variable "eso_chart_version" {
  description = "External Secrets Operator Helm chart version."
  type        = string
  default     = "2.9.0"
}

variable "ingress_certificate_name" {
  description = "Key Vault certificate the application routing ingress terminates TLS with. Reserved 'platform-' prefix: it is the wildcard the Renew Certificate workflow maintains."
  type        = string
  default     = "platform-wildcard-onek8s-lol"
}

variable "enable_argocd" {
  description = "Install the Microsoft-offered Argo CD cluster extension and publish its UI through the application routing ingress."
  type        = bool
  default     = true
}

variable "argocd_hostname" {
  description = "Public host name of the Argo CD UI. Must be covered by var.ingress_certificate_name and have a DNS record pointing at the cluster's ingress load balancer."
  type        = string
  default     = "argocd.onek8s.lol"
}

variable "argocd_release_train" {
  description = "Release train of the Argo CD extension. The extension is in public preview, so 'Preview' is the only train that carries it today."
  type        = string
  default     = "Preview"
}

variable "argocd_extension_version" {
  description = "Pin the Argo CD extension to a version (null = install the latest of the release train and let Azure auto-upgrade it)."
  type        = string
  default     = null
}

variable "argocd_high_availability" {
  description = "Run the extension's Redis in HA mode. Azure's default, but it needs at least four nodes; keep it off on small clusters."
  type        = bool
  default     = false
}

variable "argocd_application_namespaces" {
  description = "Namespaces besides 'argocd' in which Application/ApplicationSet objects are honoured ('applications in any namespace'). Empty keeps them argocd-only."
  type        = list(string)
  default     = []
}

variable "argocd_extra_configuration" {
  description = "Extra Argo CD extension configuration settings (flat Helm values; dots inside a ConfigMap key are backslash-escaped). Merged last, so it overrides the defaults set in argocd.tf."
  type        = map(string)
  default     = {}
}

variable "enable_baseline_policy" {
  description = "Assign the AKS pod security baseline policy initiative to the resource group."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
