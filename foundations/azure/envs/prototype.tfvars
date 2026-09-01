environment         = "prototype"
location            = "swedencentral"
name_prefix         = "onek8s"
system_node_count   = 1
system_node_vm_size = "Standard_B2s"

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

# Kargo's cluster-wide roles are not listed here at all: they are derived from
# argocd_rbac_group_roles below through kargo_rbac_argocd_role_map, whose
# default translation is the one this environment wanted anyway —
#
#   46a1d986-…  role:admin      -> admins                      administers both
#   59a92e0b-…  role:org-admin  -> project_creators + viewers  reads, and may
#                                                              create Projects
#   4301eb89-…  role:readonly   -> viewers                     reads the
#                                                              release path
#
# — so a person granted access to the delivery plane is granted it once. The
# list used to be maintained twice and had already drifted: only the admins
# group was mapped, which left everybody else with a valid Kargo sign-in that
# could see nothing at all, since Kargo gives an unmapped identity not even the
# read that lists Projects ("projects.kargo.akuity.io is forbidden").
#
# Argo CD's other half of read-only — argocd_rbac_default_role, which catches
# an authenticated identity in none of these groups — has no Kargo counterpart:
# Kargo matches users to roles by ID token claim, so there is no "everybody"
# to bind. Whoever should read Kargo needs to be in a group that is mapped.
#
# kargo_rbac_groups remains, for a group only Kargo cares about:
#
#   kargo_rbac_groups = { viewers = ["<group object id>"] }
#
# Who may promote the hello application to production is not any of this: it is
# a Role in that Project's namespace, and lives in OneK8s-argocd beside the
# Stage it guards.

# Azure SQL on the free offer: 100,000 vCore seconds and 32 GB a month, with
# the database auto-pausing rather than billing when that runs out. Entra-only
# authentication, so the server has no SQL login at all — the db-hello
# application connects as the tenant's managed identity, and the tenant's
# database user is created by the Bootstrap SQL workflow (docs/db-hello-app.md).
#
# The Entra administrator is left at its default: the service principal that
# deploys this stack, which is what lets that workflow create the user.
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

# One setting this environment's extension carries that the stack no longer
# generates: the token-only "ci" account, from the days when promoting to
# production meant a workflow calling `argocd app sync` (docs/kargo.md).
# argocd_api_accounts is empty now — but an Azure extension update cannot
# remove a configuration setting, it merges — so the key stayed on the cluster,
# every plan since has proposed the same removal, and every apply has been a
# Helm upgrade of Argo CD that changed nothing and restarted the delivery
# plane. Declaring it here is what ends that.
#
# The account keeps the one capability it ever had, "apiKey", and no role: with
# no "g, ci, ..." line in the policy it falls through to
# argocd_rbac_default_role, so a token minted for it before can read and
# nothing else. To be rid of it for real the extension has to be reinstalled —
# docs/argocd.md, "Removing a configuration setting" — and this block dropped
# in the same change.
argocd_retained_configuration_settings = {
  "configs.cm.accounts\\.ci" = "apiKey"
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
