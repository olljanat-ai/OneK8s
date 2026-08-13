# Argo CD on AKS

GitOps on the Azure foundation runs on the **Microsoft-offered Argo CD
cluster extension** (`Microsoft.ArgoCD`), not on a self-managed Helm release.
It is deployed by `foundations/azure/argocd.tf` together with the ingress that
publishes its UI on `https://argocd.onek8s.lol`.

```
                       ┌──────────────── AKS (foundations/azure) ───────────────┐
 argocd.onek8s.lol     │                                                        │
  (A record, out       │  Traefik ──HTTP──▶ argocd-server                       │
   of band) ──────────▶│      │                                                 │
                       │      │ Ingress "argocd": a host and a backend,         │
                       │      │ no class and no TLS section                     │
                       │      ▼                                                 │
                       │  default TLSStore ──▶ Secret "platform-wildcard-tls"   │
                       │                            ▲                           │
                       │      External Secrets ─────┘                           │
                       └────────────│───────────────────────────────────────────┘
                                    │ platform ingress identity (UAMI + FIC)
                                    │ (Key Vault Secrets User + ABAC)
                                    ▼
                          Key Vault: platform-wildcard-onek8s-lol
```

## Why the extension rather than the upstream chart

- Azure owns the manifests, the upgrades and the CVE patching of the Argo CD
  components, and builds the images on Azure Linux. The alternative — a
  `helm_release` next to External Secrets Operator in `eso.tf` — would put
  that on us.
- It is the only path to the portal's **GitOps** blade and to the Entra ID
  integrations (workload identity for ACR/Azure DevOps, Entra SSO for the
  UI).
- Configuration is declarative through one flat map of Helm values on the
  extension resource, which keeps the whole install in Terraform.

The cost: the extension is in **public preview**, so it is pinned to the
`Preview` release train, and `var.enable_argocd` exists so an environment that
cannot take preview surface simply turns it off. Direct edits to the Argo CD
ConfigMaps are not supported — change `var.argocd_extra_configuration` (or
the defaults in `argocd.tf`) and re-apply, otherwise the extension reconciles
your edit away.

## How TLS gets onto the ingress

The `*.onek8s.lol` wildcard lives in this environment's Key Vault as
`platform-wildcard-onek8s-lol`, maintained by the Renew Certificate workflow
(see [architecture.md](architecture.md)). Nothing copies it into the cluster,
and — since the ingress moved to Traefik — nothing about it is specific to
Argo CD:

1. `ingress.tf` creates a user-assigned identity, federates it to the ingress'
   ServiceAccount (`traefik/platform-secrets`) and grants it `Key Vault
   Secrets User`, narrowed by an **ABAC condition** to the one certificate.
   Without that condition the role's `getSecret` would cover the whole vault —
   every tenant's secrets.
2. An ESO `SecretStore` (`azurekv`, `authType: WorkloadIdentity`) and an
   `ExternalSecret` read it. Key Vault returns a certificate as the PEM bundle
   that was imported, so the target template splits it with `filterPEM` into
   `Secret/platform-wildcard-tls`.
3. Traefik's **default TLSStore** serves that secret for every host that
   brings no certificate of its own.

No AKS add-on is involved in any of it: the same External Secrets install
that serves every tenant serves the platform, which is what makes this
identical to the AWS, GCP and OCI clusters.

So the `argocd` Ingress names no secret and no class at all — it is the same
four lines a tenant writes. Its TLS is the ingress' business. The certificate
is referenced without a version, so a renewal is picked up on the next
rotation poll (default two minutes) with no Terraform apply.

DNS stays out of the cluster's hands: no cluster on any cloud writes the
`onek8s.lol` zone, so `argocd.onek8s.lol` is an A record pointed at the
Traefik Service's address by hand, like every tenant host.

> Migrating off the application routing add-on: it took its own external-dns
> with it, so the `argocd` record it used to keep is stale (the add-on's load
> balancer is gone) and unmanaged. Repoint it at the new address and delete
> the `externaldns-…-argocd` TXT record that recorded the old ownership.

TLS terminates at Traefik and `configs.params.server.insecure` is `true`, so
`argocd-server` speaks plain HTTP inside the cluster. Without it, the two
redirect each other in a loop.

## Who gets in: Entra ID SSO and roles

Sign-in goes through Microsoft Entra ID. Three Entra objects are involved,
all created **out of band** — this stack holds no directory writes, so it
takes their identifiers as configuration rather than creating them:

| tfvars | What it is |
|---|---|
| `argocd_workload_identity_client_id` | User-assigned managed identity the Argo CD components federate as, to reach Azure (ACR, Azure DevOps) without stored credentials. |
| `argocd_sso_client_id` | App registration users sign in to. Its redirect URI must be `https://<argocd_hostname>/auth/callback`. |
| `argocd_rbac_group_roles` | Entra **group object ID** → Argo CD role. |

SSO is built on workload identity rather than a client secret: the app
registration proves itself with the cluster's federated credential
(`azure.useWorkloadIdentity: true` in the OIDC config), so there is no
credential to store or rotate. That is why setting `argocd_sso_client_id`
without `argocd_workload_identity_client_id` fails variable validation
instead of failing at runtime. The token tenant defaults to the tenant of the
deploying identity; `argocd_sso_tenant_id` overrides it.

Roles come out of two variables:

- `argocd_rbac_policies` — the `p, …` lines defining custom roles. The
  default defines `role:org-admin` (full application access, plus repository
  and cluster management). The built-in `role:admin` and `role:readonly` need
  no definition.
- `argocd_rbac_group_roles` — the `g, …` bindings, written as a map so the
  same group cannot be bound twice. An authenticated identity in none of the
  mapped groups falls through to `argocd_rbac_default_role`, `role:readonly`.

The built-in `admin` account still exists. Set
`argocd_extra_configuration = { "configs.cm.admin\\.enabled" = "false" }` to
close it once group access is proven to work — do that only after signing in
through Entra, since disabling it while SSO is broken locks everyone out.

## Operating it

```bash
az aks get-credentials -g rg-onek8s-prototype -n aks-onek8s-prototype

# extension health
az k8s-extension show --cluster-type managedClusters \
  -g rg-onek8s-prototype -c aks-onek8s-prototype -n argocd \
  --query "{state:provisioningState,version:currentVersion}" -o table

# the certificate actually landed (it is the ingress', not Argo CD's)
kubectl -n traefik get secret platform-wildcard-tls

# what the ingress is publishing, and where
kubectl -n argocd get ingress argocd
kubectl -n traefik get svc traefik

# the record for the ingress, which is maintained by hand
az network dns record-set a show -g rg-onek8s-argocd -z onek8s.lol -n argocd

# break-glass: the built-in admin account, when SSO is the thing that broke
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

The Argo CD CLI talks gRPC over the same host. Keep using gRPC-Web, which
works through any HTTP/1.1 proxy:

```bash
argocd login argocd.onek8s.lol --grpc-web
```

Redis HA is Azure's default and needs **four nodes**; `prototype` runs one, so
`argocd_high_availability` is `false` there. Node auto-provisioning is on for
this cluster, so the Argo CD pods pull in capacity by themselves — expect the
first apply to sit in `Pending` for a few minutes while a node is added.

## Known gaps

- **The Entra objects are not managed here.** The managed identity, the app
  registration (and its redirect URI, its group claim configuration) and the
  groups are created by hand; the stack only consumes their IDs. Nothing
  detects a deleted app registration or a group renamed out from under a
  binding — SSO simply stops working. Managing them would mean an `azuread`
  provider and directory write permission for the deploy identity, which is
  a deliberately larger grant than this stack asks for today.
- **The built-in admin account is still open.** It is the break-glass path
  while SSO settles; close it as described above once group sign-in works.
- **Preview auto-upgrade.** With `argocd_extension_version` unset Azure
  installs the latest build of the release train and upgrades it in place.
  The 0.0.x → 1.0.0-preview jump already changed every configuration key
  once; pin a version per environment if that risk is unacceptable.
- Argo CD has cluster-wide privileges on the cluster it runs on, which is a
  strictly larger blast radius than the per-tenant identities in
  [ADR-0001](adr/0001-per-tenant-identities-and-namespaced-secretstores.md).
  Nothing today restricts which repositories may be synced; add `AppProject`
  restrictions before opening it to tenants.

## Planned: AKS as the hub of a hub-spoke topology

Today this is a **single-cluster** install: Argo CD manages only the AKS
cluster it runs on (`https://kubernetes.default.svc`), and the other three
foundations have no GitOps at all.

The intended end state is **hub and spoke**, with the AKS cluster as the hub:

```
                     ┌─────────── hub: AKS (foundations/azure) ───────────┐
   Git / OCI ───────▶│  Argo CD extension  ── ApplicationSet (cluster gen) │
                     └───────┬──────────────┬──────────────┬──────────────┘
                             │              │              │
                        EKS (aws)      GKE (gcp)      OKE (oci)
                            spoke          spoke          spoke
```

- **One Argo CD, four clusters.** The spokes stay plain clusters: no Argo CD
  components on EKS/GKE/OKE, no per-cloud GitOps stack to keep in sync. This
  mirrors the choice already made for the tenants layer — one stack, all
  clouds — and gives one place to see what is deployed where.
- **Registration.** Each spoke is a `cluster` Secret in the hub's `argocd`
  namespace. The credential should be a dedicated in-cluster ServiceAccount
  per spoke with a scoped `ClusterRole` (not the cloud's admin kubeconfig),
  and the Secret itself should arrive through the mechanism the platform
  already has: an `ExternalSecret` reading a `platform-`-prefixed entry from
  Key Vault, so no cluster credential is written into Terraform state.
- **Fan-out.** An `ApplicationSet` with a cluster generator plus per-cloud
  labels (`cloud=aws|gcp|oci`) turns "deploy this to every cluster" into one
  object, with Kustomize/Helm overlays for the per-cloud differences that
  already exist in `modules/tenant-namespace`.
- **What has to be solved first.** Hub → spoke reachability (all four API
  servers are public today; a private-endpoint or peered-network story is
  needed for anything beyond prototype), the authentication mode for each
  spoke (EKS access entries, GKE/OKE equivalents), hub availability becoming
  a platform-wide dependency, and the boundary against the tenants stack —
  Argo CD must not fight Terraform over namespaces, quotas or SecretStores,
  so tenant onboarding stays in Terraform and only workloads move to GitOps.

None of that is implemented. The pieces this repository already has that make
it cheap — one wildcard certificate distributed to every cloud's secret
backend, one state home, one tenants stack — are described in
[architecture.md](architecture.md).
