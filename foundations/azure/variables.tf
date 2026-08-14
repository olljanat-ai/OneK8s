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

variable "enable_ingress" {
  description = "Install Traefik as the cluster's ingress controller, with the Key Vault wildcard as its default certificate."
  type        = bool
  default     = true
}

variable "traefik_chart_version" {
  description = "Traefik Helm chart version."
  type        = string
  default     = "41.2.0"
}

variable "ingress_certificate_name" {
  description = "Key Vault certificate the ingress controller terminates TLS with, for every host that carries no certificate of its own. Reserved 'platform-' prefix: it is the wildcard the Renew Certificate workflow maintains."
  type        = string
  default     = "platform-wildcard-onek8s-lol"
}

variable "enable_argocd" {
  description = "Install the Microsoft-offered Argo CD cluster extension and publish its UI through the platform ingress."
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
  default     = ["default"]
}

variable "argocd_workload_identity_client_id" {
  description = "Client ID of the user-assigned managed identity the Argo CD components federate as, to reach Azure services (ACR, Azure DevOps) without stored credentials. Null disables workload identity."
  type        = string
  default     = null
}

variable "argocd_sso_client_id" {
  description = "Application (client) ID of the Entra ID app registration used for single sign-on to the Argo CD UI. Null leaves the built-in admin account as the only way in."
  type        = string
  default     = null

  validation {
    condition     = var.argocd_sso_client_id == null || var.argocd_workload_identity_client_id != null
    error_message = "argocd_sso_client_id requires argocd_workload_identity_client_id: the SSO app proves itself with the cluster's federated credential, not a client secret."
  }
}

variable "argocd_sso_tenant_id" {
  description = "Entra ID tenant that issues the SSO tokens (null = the tenant of the deploying identity, which is where the app registration normally lives)."
  type        = string
  default     = null
}

variable "argocd_rbac_default_role" {
  description = "Argo CD role given to an authenticated identity with no explicit binding in argocd_rbac_group_roles."
  type        = string
  default     = "role:readonly"
}

variable "argocd_rbac_policies" {
  description = "Custom Argo CD RBAC role definitions, one 'p, role:<name>, <resource>, <action>, <object>, allow' line per entry. The built-in admin/readonly roles need no definition."
  type        = list(string)
  default = [
    "p, role:org-admin, applications, *, */*, allow",
    "p, role:org-admin, clusters, get, *, allow",
    "p, role:org-admin, repositories, get, *, allow",
    "p, role:org-admin, repositories, create, *, allow",
    "p, role:org-admin, repositories, update, *, allow",
    "p, role:org-admin, repositories, delete, *, allow",
  ]
}

variable "argocd_rbac_group_roles" {
  description = "Entra ID group object ID -> Argo CD role, e.g. { \"<group-oid>\" = \"role:admin\" }. Roles are the built-ins or one defined in argocd_rbac_policies. Only meaningful with SSO enabled."
  type        = map(string)
  default     = {}
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

variable "ingress_dashboard_hostname" {
  description = "Host the Traefik dashboard and API are published on. Served UNAUTHENTICATED over the public load balancer — anyone who reaches it reads the cluster's whole routing configuration — so it is a lab convenience; set it to null to keep the dashboard reachable only through kubectl port-forward. Must be one label deep under the wildcard, and needs a DNS record pointed at the ingress load balancer."
  type        = string
  default     = "azure-traefik.onek8s.lol"
}
