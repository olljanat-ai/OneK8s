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

# Grafana Cloud. This environment ships to the one stack every cloud writes
# to, so the endpoints and enable_observability = true are the defaults in
# variables.tf; the credentials are not configuration and reach the cluster
# from the Key Vault — run the Publish Grafana Cloud Credentials workflow once
# before the first apply. See docs/observability.md.
#
# Override here to point this environment somewhere else, or to turn the
# collectors off:
#
# enable_observability      = false
# grafana_cloud_metrics_url = "https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push"
# grafana_cloud_logs_url    = "https://logs-prod-012.grafana.net/loki/api/v1/push"
# grafana_cloud_traces_url  = "https://tempo-prod-01-prod-eu-west-0.grafana.net:443"
