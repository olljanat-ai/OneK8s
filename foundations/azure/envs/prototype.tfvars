environment         = "prototype"
location            = "swedencentral"
name_prefix         = "onek8s"
system_node_count   = 1
system_node_vm_size = "Standard_B2s"

# The onek8s.lol zone lives outside this stack; handing it to the application
# routing add-on lets external-dns keep the record of every published Ingress
# host, "argocd.onek8s.lol" included.
ingress_dns_zone_ids = [
  "/subscriptions/54e30869-75a2-47ed-8b32-1057e61707f0/resourceGroups/rg-onek8s-argocd/providers/Microsoft.Network/dnsZones/onek8s.lol",
]

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

# Entra group object ID -> Argo CD role. Anyone authenticated but unmapped
# falls through to argocd_rbac_default_role (read-only).
argocd_rbac_group_roles = {
  "46a1d986-c8a7-42d3-b2a4-a88f789f7ecc" = "role:admin"
  "59a92e0b-f653-4d5d-bdba-473eb331a5be" = "role:org-admin"
  "4301eb89-fc3d-4836-95d1-41b497f102ad" = "role:readonly"
}
