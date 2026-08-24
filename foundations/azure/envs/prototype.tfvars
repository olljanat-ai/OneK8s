environment = "prototype"
location    = "swedencentral"
name_prefix = "onek8s"

# --- One node, and everything that follows from it ----------------------------
# The defaults in variables.tf are what a cluster in a large enterprise estate
# is expected to have. This environment is a single-node lab on one
# subscription, so it opts each of them back down — and every opt-down below
# says what production uses instead, so the difference is a diff rather than a
# discovery.
#
# One burstable node, in whichever zone the region puts it. Production runs
# three nodes of Standard_D4s_v5 spread across zones 1-3, with the node disks
# encrypted on the host as well as at rest.
system_node_count                      = 1
system_node_vm_size                    = "Standard_B2s"
system_node_availability_zones         = []
system_node_encryption_at_host_enabled = false

# Free has no API server SLA and no cost analysis. Production runs Standard,
# or Premium where a Kubernetes minor has to stay supported past its community
# window.
aks_sku_tier = "Free"

# Gatekeeper's three pods do not fit beside Argo CD, Kargo, Portainer, Traefik,
# External Secrets and the Alloy collectors on one B2s. The initiative in
# policy.tf is still assigned — it just has nothing evaluating it here.
# Production leaves the add-on on and moves baseline_policy_effect to "deny"
# once its workloads are clean.
aks_azure_policy_enabled = false

# Defender for Containers is priced per vCPU-hour. Production leaves it on.
enable_defender = false

# The control plane's logs and the vault's audit trail still go to Log
# Analytics here — that is the record an incident is reconstructed from, and it
# is the one thing no in-cluster collector can see. Capped and short-retained
# rather than turned off: production keeps 90 days and no cap.
log_analytics_retention_days = 30
log_analytics_daily_quota_gb = 1

# A lab vault is torn down and rebuilt under the same name, which purge
# protection makes impossible. Production keeps purge protection on, 90 days of
# soft-delete retention, and the premium (HSM-backed) SKU.
key_vault_sku_name                   = "standard"
key_vault_purge_protection_enabled   = false
key_vault_soft_delete_retention_days = 7

# DNS is out of band on every cloud: the onek8s.lol zone lives outside this
# stack, and the record for each published host is pointed at the ingress
# load balancer by hand. See docs/getting-started.md.

# Argo CD: one node, so Redis stays single-replica. The host is covered by the
# platform wildcard certificate in this environment's Key Vault.
enable_argocd            = true
argocd_hostname          = "argocd.onek8s.lol"
argocd_high_availability = false

# Entra ID: the managed identity the Argo CD components federate as, and the
# app registration users sign in to. Both are created out of band — this stack
# holds no directory writes.
argocd_workload_identity_client_id = "eca6aad4-fd01-4c67-acb9-95b33d89c53b"
argocd_sso_client_id               = "6598a87b-227b-4f20-9f3b-dbdd74604492"

# Kargo: the promotion engine in front of Argo CD (docs/kargo.md). The host is
# covered by the same platform wildcard, and its A record is pointed at the
# ingress by hand like every other one.
#
# The controller is the part that matters and it runs either way. The UI and
# the API are only installed once there is a way to sign in to them, which is
# an Entra ID app registration created out of band — as Argo CD's is. It needs
# no federated credential and no client secret (Kargo only verifies the ID
# token), but both of its redirects are fussier than Argo CD's: the UI's on a
# "single-page application" platform, the CLI's loopback on a "mobile and
# desktop" one, and no groups scope anywhere. docs/kargo.md has the whole list,
# and the client IDs are the defaults in variables.tf.
#
# Until one is registered, promotions are `kubectl create` of a Promotion
# object (docs/kargo.md) — the gate in front of production holds regardless,
# because it is the Stage's promotion policy, not the UI.
enable_kargo   = true
kargo_hostname = "kargo.onek8s.lol"

# Entra group object ID -> Kargo system role. These are cluster-wide
# capabilities; who may promote the hello application to production is a Role
# in that Project's namespace, and lives in OneK8s-argocd beside the Stage it
# guards.
#
# The same group that is role:admin in Argo CD below, so one group administers
# the whole delivery plane rather than two lists drifting apart. Nothing else
# is mapped yet, and Kargo grants an unmapped identity nothing at all — not
# even the read that lists Projects, which is what a signed-in user with no
# entry here runs into first ("projects.kargo.akuity.io is forbidden"). The two
# remaining Argo CD groups are the obvious next entries when somebody who is
# not a platform admin needs the UI:
#
#   project_creators = ["59a92e0b-f653-4d5d-bdba-473eb331a5be"]  # role:org-admin
#   viewers          = ["4301eb89-fc3d-4836-95d1-41b497f102ad"]  # role:readonly
kargo_rbac_groups = {
  admins = ["46a1d986-c8a7-42d3-b2a4-a88f789f7ecc"]
}

# Azure SQL on the free offer: 100,000 vCore seconds and 32 GB a month, with
# the database auto-pausing rather than billing when that runs out. Entra-only
# authentication, so the server has no SQL login at all — the db-hello
# application connects as the tenant's managed identity, and the tenant's
# database user is created by the Bootstrap SQL workflow (docs/db-hello-app.md).
#
# The Entra administrator is left at its default: the service principal that
# deploys this stack, which is what lets that workflow create the user.
#
# The free offer excludes zone redundancy and geo-redundant backups, and asking
# for it overrides both rather than failing the apply. Production leaves
# sql_use_free_limit off and gets zone-redundant compute with geo-redundant
# backups.
enable_sql         = true
sql_database_name  = "appdb"
sql_use_free_limit = true

# Portainer Business Edition: the fleet console for all four clouds. The
# licence is read from this environment's Key Vault, so nothing is typed into
# the UI on a rebuild; the admin account is bootstrapped from Key Vault too,
# which is what the portainer/ stack then authenticates as to register the
# spokes. Both secrets are put in the vault out of band — see
# docs/getting-started.md.
enable_portainer                     = true
portainer_hostname                   = "portainer.onek8s.lol"
portainer_license_secret_name        = "portainer-license"
portainer_admin_password_secret_name = "portainer-admin-password"

# Entra group object ID -> Argo CD role. Anyone authenticated but unmapped
# falls through to argocd_rbac_default_role (read-only).
argocd_rbac_group_roles = {
  "46a1d986-c8a7-42d3-b2a4-a88f789f7ecc" = "role:admin"
  "59a92e0b-f653-4d5d-bdba-473eb331a5be" = "role:org-admin"
  "4301eb89-fc3d-4836-95d1-41b497f102ad" = "role:readonly"
}

# Grafana Cloud. This environment ships to the one stack every cloud writes to,
# whose endpoints are the defaults in modules/platform-observability, and
# enable_observability defaults to true — so there is nothing to set here. The
# credentials are not configuration and reach the cluster from the Key Vault:
# run the Publish Grafana Cloud Credentials workflow once before the first
# apply. See docs/observability.md.
#
# Uncomment to turn the collectors off, or to point this environment at a
# different stack:
#
# enable_observability      = false
# grafana_cloud_metrics_url = "https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push"
# grafana_cloud_logs_url    = "https://logs-prod-012.grafana.net/loki/api/v1/push"
# grafana_cloud_traces_url  = "https://tempo-prod-01-prod-eu-west-0.grafana.net:443"
