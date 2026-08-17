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

variable "enable_sql" {
  description = "Create an Entra-only Azure SQL logical server and one database on the free offer, for the db-hello example application. The tenant's database user is NOT created here — the tenants deploy grants it, see docs/db-hello-app.md."
  type        = bool
  default     = true
}

variable "sql_database_name" {
  description = "Name of the database on the logical server. It is also the name the db-hello application connects to, passed down from this stack's outputs through the gitops stack."
  type        = string
  default     = "appdb"
}

variable "sql_admin_object_id" {
  description = "Object ID of the Entra principal that administers the server — a user, a group, or a managed identity. Null means the identity running the deploy, which is what makes the tenants deploy (same service principal) able to create tenants' database users."
  type        = string
  default     = null
}

variable "sql_admin_login_username" {
  description = "Login name recorded for the Entra administrator, normally that principal's display name. A label: authorization follows sql_admin_object_id, and this string is what the portal and sys.database_principals show."
  type        = string
  default     = "onek8s-deployer"
}

variable "sql_use_free_limit" {
  description = "Put the database on the Azure SQL free offer: 100,000 vCore seconds and 32 GB of storage free per month. Up to 10 free databases per subscription, and the first one fixes the region for the rest."
  type        = bool
  default     = true
}

variable "sql_free_limit_exhaustion_behavior" {
  description = "What happens when the month's free allowance runs out. AutoPause stops the database until the next month and never bills; BillOverUsage keeps it online and charges standard serverless rates."
  type        = string
  default     = "AutoPause"

  validation {
    condition     = contains(["AutoPause", "BillOverUsage"], var.sql_free_limit_exhaustion_behavior)
    error_message = "sql_free_limit_exhaustion_behavior must be AutoPause or BillOverUsage."
  }
}

variable "sql_sku" {
  description = "Compute for the database, in ARM's own shape. The free offer exists only on serverless General Purpose (GP_S_Gen5) and allows at most 4 vCores."
  type = object({
    name     = optional(string, "GP_S_Gen5")
    tier     = optional(string, "GeneralPurpose")
    family   = optional(string, "Gen5")
    capacity = optional(number, 2)
  })
  default = {}

  validation {
    condition     = !var.sql_use_free_limit || (var.sql_sku.name == "GP_S_Gen5" && var.sql_sku.capacity <= 4)
    error_message = "The free offer requires serverless General Purpose (sql_sku.name = \"GP_S_Gen5\") with at most 4 vCores. Set sql_use_free_limit = false to leave it."
  }
}

variable "sql_max_size_gb" {
  description = "Maximum database size. 32 GB is the free offer's ceiling; more than that is billed even with sql_use_free_limit set."
  type        = number
  default     = 32
}

variable "sql_auto_pause_delay_in_minutes" {
  description = "Idle minutes before a serverless database pauses (60 is the minimum; -1 disables it). Pausing is what keeps an idle lab database from spending the free allowance — the cost is a resume delay on the next request."
  type        = number
  default     = 60
}

variable "sql_min_capacity" {
  description = "vCores the database keeps allocated while it is awake."
  type        = number
  default     = 0.5
}

variable "sql_collation" {
  description = "Database collation."
  type        = string
  default     = "SQL_Latin1_General_CP1_CI_AS"
}

variable "sql_firewall_rules" {
  description = "Standing firewall exceptions on the logical server, keyed by rule name, e.g. { office = { start_ip_address = \"203.0.113.0\", end_ip_address = \"203.0.113.255\" } }. The cluster does not need one — it reaches the server through the AKS subnet's service endpoint — and the tenants deploy opens and closes its own."
  type = map(object({
    start_ip_address = string
    end_ip_address   = string
  }))
  default = {}
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
