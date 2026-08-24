# Azure Verified Modules in `foundations/azure`

`foundations/azure` is built from [Azure Verified Modules][avm] — Microsoft's
own, supported Terraform modules — rather than from hand-written `azurerm`
resources. This page says which module owns what, what is deliberately *not* a
module, what that choice costs, and how an environment that was deployed
before the change is moved onto it.

[avm]: https://azure.github.io/Azure-Verified-Modules/

## What each module owns

| Resource | Module | Version | Where |
|---|---|---|---|
| Resource group | `Azure/avm-res-resources-resourcegroup/azurerm` | 0.4.0 | `main.tf` |
| VNet + the AKS subnet | `Azure/avm-res-network-virtualnetwork/azurerm` | 0.22.1 | `main.tf` |
| AKS cluster, its system pool, its maintenance windows | `Azure/avm-res-containerservice-managedcluster/azurerm` | 0.8.1 | `aks.tf` |
| Key Vault + the deployer's role assignments | `Azure/avm-res-keyvault-vault/azurerm` | 0.11.0 | `keyvault.tf` |
| Ingress / collector / Kargo identities | `Azure/avm-res-managedidentity-userassignedidentity/azurerm` | 0.5.2 | `ingress.tf`, `monitoring.tf`, `kargo.tf` |
| SQL logical server + firewall rules | `Azure/avm-res-sql-server/azurerm` | 0.2.1 | `sql.tf` |
| Log Analytics workspace | `Azure/avm-res-operationalinsights-workspace/azurerm` | 0.5.1 | `diagnostics.tf` |

The identity module is the one that changes the shape of the code most. A
platform identity here is three things that have to agree — the identity, the
federated credential that lets one Kubernetes ServiceAccount become it, and the
ABAC-scoped role assignment that says which single secret it may read. The
module takes all three as inputs, so they are one block that is created,
changed and destroyed together instead of three resources wired to each other
by ID.

## What is not a module, and why

| Resource | Why |
|---|---|
| `azapi_resource.sql_database` (`sql.tf`) | The Azure SQL free offer is two ARM properties (`useFreeLimit`, `freeLimitExhaustionBehavior`) that neither `azurerm` nor the module's `databases` input carries. A production database with no free offer to express belongs in the module's own `databases` input. |
| `azurerm_mssql_virtual_network_rule.aks` (`sql.tf`) | The SQL server module owns firewall rules but not virtual network rules. |
| `azurerm_resource_group_policy_assignment.aks_baseline` (`policy.tf`) | No AVM module covers a resource-group policy assignment. |
| `azurerm_kubernetes_cluster_extension.argocd` (`argocd.tf`) | No AVM module covers cluster extensions. |
| Everything in `eso.tf`, `ingress.tf`, `kargo.tf`, `portainer.tf` below the identity | Helm releases and Kubernetes objects — not Azure resources at all. |

## The provider pin moved back to 4.x

`versions.tf` pins `hashicorp/azurerm` at `= 4.81.0`, not 5.x. Three of the
modules above still declare `azurerm < 5.0.0` (managed identity, SQL server,
Log Analytics), and the Key Vault module's floor is `>= 4.81`, so 4.81.0 is the
one release every module accepts. Move the pin forward when they have.

`Azure/modtm` and `hashicorp/time` are declared for the same reason every other
provider is: the modules use them, and this stack pins what it uses. `modtm`
reports anonymous AVM deployment telemetry, which `var.enable_telemetry = false`
turns off everywhere at once.

## Production defaults, and what the prototype opts out of

The defaults in `variables.tf` are what a cluster in a large enterprise estate
is expected to have. `envs/prototype.tfvars` opts back down for cost, and each
opt-down there says what production uses instead.

| Setting | Default | `prototype` |
|---|---|---|
| System pool | 3 × `Standard_D4s_v5`, zones 1-3, encryption at host | 1 × `Standard_B2s`, no zone, no host encryption |
| Control plane tier | `Standard` (SLA + cost analysis) | `Free` |
| Upgrades | `patch` channel + `NodeImage`, inside a weekly window | same |
| Entra ID + Azure RBAC | on | on |
| Azure Policy add-on | on | off — Gatekeeper does not fit on one B2s |
| Defender for Containers | on | off |
| Log Analytics | 90 days, no ingestion cap | 30 days, 1 GB/day |
| Key Vault | `premium`, purge protection, 90-day soft delete | `standard`, no purge protection, 7 days |
| Azure SQL | zone-redundant, geo-redundant backups | the free offer, which excludes both |

Two of those are one-way doors on a cluster that already exists, and are called
out in their variable descriptions: Entra ID integration cannot be removed from
an AKS cluster afterwards, and a Key Vault's SKU cannot be lowered.

`aks_local_accounts_enabled` stays `true` even in production. This stack's own
Helm provider bootstraps External Secrets with the cluster admin certificate,
and there is nothing to federate as until the cluster that issues the tokens
exists. Entra ID with Azure RBAC is configured either way, so the remaining
change is CI reaching the API server as an Entra principal.

## Azure-native diagnostics

`diagnostics.tf` adds a Log Analytics workspace, and points the AKS control
plane and Key Vault at it. This is not a second copy of the Grafana Cloud
story in `monitoring.tf`: Grafana Cloud collects what runs *inside* the cluster
on all four clouds, and this holds the part no in-cluster collector can see —
the API server's own logs, the admin audit trail, the vault's audit events. It
is also where Defender for Containers reports, which is why `enable_defender`
requires `enable_log_analytics`.

The AKS log categories are chosen rather than taken wholesale
(`var.aks_diagnostic_log_categories`). `allLogs` includes `kube-audit`, which is
every API call every controller makes — gigabytes a day, and almost entirely
duplicated by `kube-audit-admin`, the same trail with the read verbs dropped.

The SQL *server* gets no diagnostic setting: Azure exposes diagnostic
categories on databases, not on the logical server.

## Migrating an environment that already exists

This is not an in-place refactor. Two things make it a rebuild rather than a
`terraform state mv` exercise:

* The resource group, the VNet and the AKS cluster are `azapi_resource` inside
  their AVM modules, where they were `azurerm_*` before. There is no `moved`
  block across provider resource types.
* The `azurerm` pin goes from 5.0.1 back to 4.81.0. State written by a newer
  provider is not readable by an older one.

For the `prototype` environment the supported path is to rebuild it — which is
what it is for, and every secret it depends on already lives outside it (the
Key Vault contents, the certificate, the Grafana Cloud token) or is recreated
by the deploy.

```bash
cd foundations/azure
terraform init -backend-config=backend/prototype.hcl
terraform destroy -var-file=envs/prototype.tfvars     # on the old revision
git checkout <this branch>
rm -rf .terraform
terraform init -backend-config=backend/prototype.hcl
terraform apply -var-file=envs/prototype.tfvars
```

Then re-run, in order: **Publish Grafana Cloud Credentials**, **Renew
Certificate**, and the seeding of `portainer-license` /
`portainer-admin-password` described in `docs/getting-started.md`, since the
vault is new. `gitops/` and `tenants/` need no change beyond a re-apply: they
read this stack's outputs, and every output name is unchanged.

For an environment that cannot be rebuilt, the resources that stay on `azurerm`
in both revisions (the Key Vault, the managed identities, the SQL server) can be
moved with `terraform state mv` into their module addresses, and the rest
imported with `terraform import` into the `azapi` addresses — but the AKS
cluster's `agentPoolProfiles` and the `azurerm` downgrade both need care, and
the exercise is only worth it where a rebuild genuinely is not an option.
