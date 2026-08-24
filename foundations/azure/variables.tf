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

variable "enable_telemetry" {
  description = "Let the Azure Verified Modules this stack is built from report anonymous deployment telemetry to Microsoft (aka.ms/avm/telemetryinfo). It identifies the modules and their versions, never the resources they create. Turn it off in an estate whose deployments are not allowed to reach anything outside the tenant."
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "AKS Kubernetes minor version (null = latest default for the region)."
  type        = string
  default     = "1.36"
}

variable "system_node_count" {
  description = "Number of nodes in the default (system) node pool. Three is the floor for a pool that has to survive a node being upgraded and a zone being lost at the same time; the prototype runs one."
  type        = number
  default     = 3
}

variable "system_node_vm_size" {
  description = "VM size for the system node pool."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "system_node_availability_zones" {
  description = "Availability zones the system node pool is spread across. Empty places the nodes wherever the region does, which is the only option in a region without zones and the only sensible one on a single node."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "system_node_os_sku" {
  description = "OS image of the system nodes. Ubuntu is what AKS has always defaulted to and what every node-level tool assumes; AzureLinux is Microsoft's own and the smaller attack surface of the two."
  type        = string
  default     = "Ubuntu"

  validation {
    condition     = contains(["AzureLinux", "Ubuntu"], var.system_node_os_sku)
    error_message = "system_node_os_sku must be AzureLinux or Ubuntu."
  }
}

variable "system_node_os_disk_type" {
  description = "OS disk of the system nodes: Ephemeral (local to the VM, faster, free) or Managed. Ephemeral needs a VM size with a local disk at least as large as the OS disk — a 'd' size such as Standard_D4ds_v5 — which neither the default size nor the burstable ones a lab runs on have."
  type        = string
  default     = "Managed"

  validation {
    condition     = contains(["Ephemeral", "Managed"], var.system_node_os_disk_type)
    error_message = "system_node_os_disk_type must be Ephemeral or Managed."
  }
}

variable "system_node_encryption_at_host_enabled" {
  description = "Encrypt the node OS and temp disks on the host itself, on top of the platform-managed encryption of the disk at rest. Needs the EncryptionAtHost feature registered on the subscription and a VM size that supports it."
  type        = bool
  default     = true
}

# --- Cluster shape ------------------------------------------------------------
variable "aks_sku_tier" {
  description = "AKS control plane tier. Free carries no financially backed API server SLA and cannot report cost analysis; Standard is the floor for a cluster something depends on; Premium adds long-term support for a Kubernetes minor past its community window."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.aks_sku_tier)
    error_message = "aks_sku_tier must be Free, Standard or Premium."
  }
}

variable "aks_local_accounts_enabled" {
  description = "Keep the cluster's local (certificate) admin accounts. This stack's own Helm provider bootstraps the add-ons with them — External Secrets has to exist before anything can read the vault, and there is no identity to federate as until the cluster exists. Set it false once CI reaches the API server as an Entra principal instead; Entra ID with Azure RBAC is already configured either way."
  type        = bool
  default     = true
}

variable "aks_entra_authentication_enabled" {
  description = "Integrate the cluster with Entra ID and use Azure RBAC for Kubernetes authorization, so that who may reach the API server is a directory role assignment rather than cluster state. Note that AKS cannot un-integrate a cluster afterwards: this is a one-way change on a cluster that already exists."
  type        = bool
  default     = true
}

variable "aks_admin_group_object_ids" {
  description = "Entra ID group object IDs whose members are cluster administrators. With Azure RBAC for Kubernetes authorization on, everyone else needs an Azure role assignment on the cluster to reach the API server at all, and access is revoked by removing somebody from a group rather than by touching the cluster."
  type        = list(string)
  default     = []
}

variable "aks_authorized_ip_ranges" {
  description = "CIDRs allowed to reach the API server. Empty leaves it reachable from anywhere, which is what deploys from hosted CI runners need; an estate with fixed egress addresses lists them here and the API server stops answering everyone else."
  type        = list(string)
  default     = []
}

variable "aks_upgrade_channel" {
  description = "Which upgrades Azure applies without an apply. 'patch' keeps the cluster on a supported patch of the minor version pinned in kubernetes_version; 'stable'/'rapid' move minors on their own, and 'none' means every upgrade is a deliberate change here."
  type        = string
  default     = "patch"

  validation {
    condition     = contains(["node-image", "none", "patch", "rapid", "stable"], var.aks_upgrade_channel)
    error_message = "aks_upgrade_channel must be one of node-image, none, patch, rapid or stable."
  }
}

variable "aks_node_os_upgrade_channel" {
  description = "How node OS updates are applied. NodeImage rolls the whole node image on Azure's weekly cadence; SecurityPatch applies security updates without changing the image; None leaves the nodes alone."
  type        = string
  default     = "NodeImage"

  validation {
    condition     = contains(["NodeImage", "None", "SecurityPatch", "Unmanaged"], var.aks_node_os_upgrade_channel)
    error_message = "aks_node_os_upgrade_channel must be one of NodeImage, None, SecurityPatch or Unmanaged."
  }
}

variable "aks_maintenance_window" {
  description = "When Azure is allowed to apply the upgrades the channels above ask for. Both the cluster upgrade (weekly) and the node OS upgrade (daily) windows start here, so an unattended upgrade never lands in the middle of a business day."
  type = object({
    day_of_week    = optional(string, "Sunday")
    start_time     = optional(string, "01:00")
    duration_hours = optional(number, 4)
    utc_offset     = optional(string, "+00:00")
  })
  default = {}

  validation {
    condition     = var.aks_maintenance_window.duration_hours >= 4 && var.aks_maintenance_window.duration_hours <= 24
    error_message = "aks_maintenance_window.duration_hours must be between 4 and 24."
  }
}

variable "aks_azure_policy_enabled" {
  description = "Install the Azure Policy add-on (Gatekeeper). It is what evaluates the initiative assigned in policy.tf: without it the assignment reports nothing at all. Its three pods do not fit on a single burstable node, which is the only reason an environment turns it off."
  type        = bool
  default     = true
}

variable "aks_image_cleaner_interval_hours" {
  description = "How often Image Cleaner sweeps unreferenced images off the nodes. A node that has pulled a year of image tags is a year of unpatched userland sitting on disk."
  type        = number
  default     = 168
}

variable "aks_node_resource_group_restriction_level" {
  description = "Lockdown of the cluster's own node resource group. ReadOnly stops anything but AKS from changing the scale sets, load balancer and disks in it — an edit there is either reverted by the cluster's reconciler or, worse, kept."
  type        = string
  default     = "ReadOnly"

  validation {
    condition     = contains(["ReadOnly", "Unrestricted"], var.aks_node_resource_group_restriction_level)
    error_message = "aks_node_resource_group_restriction_level must be ReadOnly or Unrestricted."
  }
}

# --- Azure-native diagnostics -------------------------------------------------
variable "enable_log_analytics" {
  description = "Create a Log Analytics workspace and send the AKS control plane's logs and Key Vault's audit events to it. This is the half of observability no in-cluster collector can see — Grafana Cloud (monitoring.tf) still collects everything that runs inside the cluster."
  type        = bool
  default     = true
}

variable "log_analytics_sku" {
  description = "Pricing SKU of the Log Analytics workspace."
  type        = string
  default     = "PerGB2018"
}

variable "log_analytics_retention_days" {
  description = "How long the workspace keeps ingested data. 90 days is the usual floor for an audit trail an investigation might have to reach back into; 30 is the cheapest useful setting."
  type        = number
  default     = 90

  validation {
    condition     = var.log_analytics_retention_days >= 30 && var.log_analytics_retention_days <= 730
    error_message = "log_analytics_retention_days must be between 30 and 730."
  }
}

variable "log_analytics_daily_quota_gb" {
  description = "Ceiling on daily ingestion, in GB. Null means no cap, which is the right answer for an audit trail that has to be complete; a number stops ingestion for the rest of the day once it is reached, which caps the bill instead."
  type        = number
  default     = null
}

variable "aks_diagnostic_log_categories" {
  description = "AKS control plane log categories sent to the workspace. Deliberately not 'allLogs': that adds kube-audit, which is every API call every controller makes — gigabytes a day, and almost entirely duplicated by kube-audit-admin, the same trail with the read verbs dropped."
  type        = list(string)
  default = [
    "kube-apiserver",
    "kube-audit-admin",
    "kube-controller-manager",
    "kube-scheduler",
    "cluster-autoscaler",
    "guard",
  ]
}

variable "enable_defender" {
  description = "Turn on Microsoft Defender for Containers on the cluster: runtime threat detection, reported into the same workspace as the control plane's logs. Priced per vCPU per hour, which is why it is a switch rather than always-on."
  type        = bool
  default     = true

  validation {
    condition     = !var.enable_defender || var.enable_log_analytics
    error_message = "enable_defender needs enable_log_analytics: Defender reports into the Log Analytics workspace, and asking for it without one silently does nothing."
  }
}

# --- Key Vault ----------------------------------------------------------------
variable "key_vault_sku_name" {
  description = "Key Vault SKU. Premium is HSM-backed; nothing in this platform asks for an HSM key today, but the SKU cannot be lowered afterwards and the difference is cents a month."
  type        = string
  default     = "premium"

  validation {
    condition     = contains(["standard", "premium"], var.key_vault_sku_name)
    error_message = "key_vault_sku_name must be standard or premium."
  }
}

variable "key_vault_purge_protection_enabled" {
  description = "Make a deleted vault un-purgeable for the retention window: the name stays taken and the secrets stay recoverable. That is the right answer everywhere except a lab that is torn down and rebuilt under the same name."
  type        = bool
  default     = true
}

variable "key_vault_soft_delete_retention_days" {
  description = "How long a deleted vault (and its secrets) can still be recovered. Between 7 and 90."
  type        = number
  default     = 90

  validation {
    condition     = var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90
    error_message = "key_vault_soft_delete_retention_days must be between 7 and 90."
  }
}

variable "key_vault_public_network_access_enabled" {
  description = "Leave the vault reachable over its public endpoint. External Secrets in the cluster and the deploy running on a hosted CI runner both need it today; turning it off needs a private endpoint and the private DNS this platform does not run yet."
  type        = bool
  default     = true
}

variable "key_vault_network_acls" {
  description = "Firewall on the vault's public endpoint. Null — the default — means no firewall, which is what a cluster and a CI runner without fixed addresses need. Setting it also puts the Microsoft.KeyVault service endpoint on the AKS subnet, so the cluster can be allowed by subnet rather than by address."
  type = object({
    bypass                     = optional(string, "AzureServices")
    default_action             = optional(string, "Deny")
    ip_rules                   = optional(list(string), [])
    virtual_network_subnet_ids = optional(list(string), [])
  })
  default = null
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

variable "enable_observability" {
  description = "Install the Grafana k8s-monitoring collectors and ship this cluster's metrics, logs and events to Grafana Cloud. Needs the credentials in the Key Vault as var.grafana_cloud_secret_name; the endpoints come from modules/platform-observability."
  type        = bool
  default     = true
}

variable "k8s_observability_chart_version" {
  description = "grafana/k8s-monitoring Helm chart version."
  type        = string
  default     = "4.4.0"
}

variable "grafana_cloud_secret_name" {
  description = "Key Vault secret holding the Grafana Cloud instance IDs and access-policy token as one JSON object. Reserved 'platform-' prefix: it is written and distributed by the Publish Grafana Cloud Credentials workflow."
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

variable "argocd_api_accounts" {
  description = "Argo CD local API accounts -> the role bound to each. Every account is created token-only ('apiKey'): it can carry tokens minted with `argocd account generate-token --account <name>`, and has no password and no way into the UI. The role is a built-in or one defined in argocd_rbac_policies."
  type        = map(string)
  # Empty, and that is the point: nothing outside the cluster syncs an
  # application any more. Promotion belongs to Kargo, which writes the
  # Application objects through the Kubernetes API as a controller, so there is
  # no Argo CD API account behind it, no bearer token to mint and hand to CI,
  # and no token to rotate when somebody leaves.
  default = {}

  validation {
    condition     = alltrue([for account in keys(var.argocd_api_accounts) : can(regex("^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$", account))])
    error_message = "Account names become argocd-cm keys ('accounts.<name>') and RBAC subjects, so they must be lowercase alphanumeric, optionally separated by '.', '_' or '-'."
  }

  validation {
    condition     = !contains(keys(var.argocd_api_accounts), "admin")
    error_message = "'admin' is the built-in account and is not configured this way; toggle it with argocd_extra_configuration's \"configs.cm.admin\\.enabled\"."
  }
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

# --- Kargo --------------------------------------------------------------------
variable "enable_kargo" {
  description = "Install Kargo on the hub: the promotion engine that moves an application's Freight along its stages and commits the result to the delivery-plane repository. Skipped automatically when enable_argocd is false — every Stage's health and last promotion step is an Argo CD Application."
  type        = bool
  default     = true
}

variable "kargo_hostname" {
  description = "Public hostname of the Kargo UI and API. Must be covered by the platform wildcard certificate, and its A record is pointed at the ingress by hand."
  type        = string
  default     = "kargo.onek8s.lol"
}

variable "kargo_chart_version" {
  description = "Version of the upstream Kargo Helm chart (oci://ghcr.io/akuity/kargo-charts/kargo). Pinned rather than floating: a promotion engine that upgrades itself unannounced is a promotion engine nobody can reason about."
  type        = string
  default     = "1.11.2"
}

variable "kargo_admin_password_hash" {
  description = "bcrypt hash of the Kargo admin account's password, e.g. `htpasswd -bnBC 10 \"\" '<password>' | tr -d ':\\n'`. Null (the default) disables the account, leaving Entra ID SSO as the only way in. Only the hash is configuration: the password itself never reaches this stack, and the key that signs the tokens it mints is generated in kargo.tf."
  type        = string
  default     = null
  sensitive   = true
}

variable "kargo_sso_client_id" {
  description = "Application (client) ID of the Entra ID app registration users sign in to for the Kargo UI. Null leaves SSO off, in which case kargo_admin_password_hash is the only way in. Unlike Argo CD's, this registration needs no federated credential: Kargo verifies ID tokens rather than calling Graph, so it holds no client secret either — but its redirect URI has to sit on a 'single-page application' platform, because the UI redeems its code in the browser (docs/kargo.md)."
  type        = string
  default     = "b2533a51-853d-426f-aa1c-e4e2663563be"
}

variable "kargo_sso_cli_client_id" {
  description = "Client ID `kargo login` uses. Defaults to kargo_sso_client_id, which is right when that registration also declares a 'mobile and desktop' platform with the loopback redirect the CLI needs; give a second registration here when it does not."
  type        = string
  default     = "f17b5094-6151-4f76-8c49-7128017cea65"
}

variable "kargo_sso_tenant_id" {
  description = "Entra ID tenant that issues Kargo's ID tokens. Defaults to the deploy identity's tenant; set it for a multi-tenant app registration."
  type        = string
  default     = null
}

variable "kargo_rbac_groups" {
  description = <<-EOT
    Entra ID group object IDs bound to each of Kargo's four system roles. These
    are cluster-wide capabilities — "may create Projects", "may see
    everything" — and deliberately not the answer to "who may promote to
    production": that is a Role in the Project's own namespace, which lives in
    the delivery-plane repository beside the Stage it guards, so a change to it
    is a reviewed commit rather than a `terraform apply`.

    An unmapped but authenticated user gets nothing at all, which is Kargo's
    default and is left alone.
  EOT
  type = object({
    admins           = optional(list(string), [])
    project_creators = optional(list(string), [])
    users            = optional(list(string), [])
    viewers          = optional(list(string), [])
  })
  default = {}
}

variable "kargo_git_credential_secret_name" {
  description = "Key Vault secret holding the Git credential a promotion pushes with, as one JSON object: { \"username\": \"<user or app id>\", \"password\": \"<PAT or installation token>\" }. Read at run time by External Secrets, so it never reaches this stack's state and a rotation needs no apply. Reserved 'platform-' prefix, like the wildcard and the Grafana Cloud token. Null skips the whole credential plumbing, leaving a Secret created by hand in the shared-resources namespace as the alternative."
  type        = string
  default     = "platform-kargo-git"
}

variable "kargo_git_repo_url" {
  description = "Delivery-plane repository the Git credential above is valid for. Must agree with repoURL in the OneK8s-argocd chart's values, which is what every Stage passes to the promotion task; Kargo lowercases both sides and strips a trailing '.git' before comparing them. Not a secret, which is why it is configuration here rather than a field of the vault object."
  type        = string
  default     = "https://github.com/olljanat-ai/OneK8s-argocd.git"
}

variable "kargo_extra_values" {
  description = "Extra Helm values for the Kargo chart, merged last so an environment can override anything kargo.tf sets."
  type        = any
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
  description = "Put the database on the Azure SQL free offer: 100,000 vCore seconds and 32 GB of storage free per month. Up to 10 free databases per subscription, and the first one fixes the region for the rest. The offer excludes zone redundancy and geo-redundant backups, so asking for it overrides sql_zone_redundant and sql_backup_storage_redundancy rather than failing the apply."
  type        = bool
  default     = false
}

variable "sql_public_network_access_enabled" {
  description = "Leave the logical server reachable over its public endpoint. Nothing may actually connect through it unless a firewall rule says so — the cluster gets in through the AKS subnet's service endpoint instead — but the tenants deploy, which bootstraps the database users, has no other route to it today."
  type        = bool
  default     = true
}

variable "sql_zone_redundant" {
  description = "Spread the database's replicas across availability zones. Ignored when sql_use_free_limit is set, which excludes it."
  type        = bool
  default     = true
}

variable "sql_backup_storage_redundancy" {
  description = "Where backups are kept: Geo (paired region), GeoZone, Zone or Local. Ignored when sql_use_free_limit is set, which allows only Local."
  type        = string
  default     = "Geo"

  validation {
    condition     = contains(["Geo", "GeoZone", "Local", "Zone"], var.sql_backup_storage_redundancy)
    error_message = "sql_backup_storage_redundancy must be one of Geo, GeoZone, Local or Zone."
  }
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

variable "enable_portainer" {
  description = "Install Portainer Business Edition on this cluster — the platform's fleet console for all four clouds — and publish it through the platform ingress."
  type        = bool
  default     = true
}

variable "portainer_hostname" {
  description = "Public host name of the Portainer UI. Must be covered by var.ingress_certificate_name and have a DNS record pointing at the cluster's ingress load balancer. Edge Agents also reach the tunnel at this name on port 8000, because Portainer derives the tunnel address from the host of its own URL."
  type        = string
  default     = "portainer.onek8s.lol"
}

variable "portainer_chart_version" {
  description = "Portainer Helm chart version. The chart pins the Business Edition image tag, so this is the one place the server version is set."
  type        = string
  default     = "239.6.0"
}

variable "portainer_license_secret_name" {
  description = "Key Vault secret holding the Portainer Business Edition licence key. It is passed to the server as --license-key at boot, so a rebuilt cluster comes up licensed. Read at apply time: on a brand-new environment, whose vault this same apply creates, apply once with enable_portainer = false and add the secret first."
  type        = string
  default     = "portainer-license"
}

variable "portainer_admin_password_secret_name" {
  description = "Key Vault secret holding the password of Portainer's initial 'admin' account, used once at first start. Null leaves the account to be created in the browser instead — but the portainer/ stack authenticates as that account, so an unattended install sets this."
  type        = string
  default     = null
}

variable "portainer_storage_size" {
  description = "Size of the Portainer data volume. It holds the Portainer database: users, environments and their Edge keys."
  type        = string
  default     = "10Gi"
}

variable "portainer_storage_class" {
  description = "StorageClass of the Portainer data volume (null = the cluster's default class, which on AKS reclaims with Delete). The claim itself is annotated helm.sh/resource-policy: keep, so it survives a Helm uninstall; a class with reclaimPolicy: Retain would also keep the disk if the claim itself is ever deleted."
  type        = string
  default     = null
}

variable "portainer_resources" {
  description = "Resource requests/limits of the Portainer container."
  type        = any
  default = {
    requests = {
      cpu    = "50m"
      memory = "256Mi"
    }
    limits = {
      memory = "1Gi"
    }
  }
}

variable "portainer_extra_flags" {
  description = "Extra Portainer server command-line arguments, appended after --license-key (the chart renders them verbatim), e.g. [\"--log-level=DEBUG\"]."
  type        = list(string)
  default     = []
}

variable "enable_baseline_policy" {
  description = "Assign the AKS pod security baseline policy initiative to the resource group. It is evaluated by the Azure Policy add-on (var.aks_azure_policy_enabled): assigned without it, the initiative reports nothing."
  type        = bool
  default     = true
}

variable "baseline_policy_effect" {
  description = "What the baseline initiative does with a non-compliant workload. 'audit' records it; 'deny' refuses to admit it. Start on audit, and move an environment to deny once its own workloads are clean."
  type        = string
  default     = "audit"

  validation {
    condition     = contains(["audit", "deny", "disabled"], var.baseline_policy_effect)
    error_message = "baseline_policy_effect must be audit, deny or disabled."
  }
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
