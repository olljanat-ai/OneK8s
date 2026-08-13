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
                       │      │ no TLS section, no certificate                  │
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

So the `argocd` Ingress names no certificate and no secret — its TLS is the
ingress' business, the same way a tenant's is. (It does name the class, only
because a Terraform-managed Ingress that leaves it out would see the API
server's default-class mutation as drift on every plan.) The certificate is
referenced without a version, so a renewal is picked up on ESO's next hourly
refresh rather than by an apply here.

The extension's own Ingress is turned off (`server.ingress.enabled = false`)
and `argocd.tf` owns the object instead. Two Ingresses for one host would
race, and it is also how an Azure-specific annotation creeps back in — an
Ingress annotated for the application routing add-on makes that add-on
generate a `SecretProviderClass`, which is exactly what blocks disabling the
Key Vault secrets provider add-on (see
[getting-started.md](getting-started.md), Troubleshooting).

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

## AKS as the hub of a hub-spoke topology

Argo CD runs on AKS and nowhere else. The other clouds' clusters are
registered with it as **spokes**, so there is one delivery plane for all four
clouds rather than one Argo CD per cloud — the same "one stack, all clouds"
shape the tenants layer already has, and one place to see what is deployed
where.

```
                     ┌─────────── hub: AKS (foundations/azure) ───────────┐
   Git / OCI ───────▶│  Argo CD extension  ── ApplicationSet (cluster gen) │
                     └───────┬──────────────┬──────────────┬──────────────┘
                             │ SA token     │              │
                        EKS (aws)      GKE (gcp)      OKE (oci)
                            spoke          spoke          spoke
```

| Spoke | Cluster | Registered as | Status |
|---|---|---|---|
| `aws` | EKS, `foundations/aws` | Secret `cluster-aws` in `argocd` | registered by `gitops/` |
| `gcp` | GKE, `foundations/gcp` | — | not yet |
| `oci` | OKE, `foundations/oci` | — | not yet |

The spokes stay plain clusters: no Argo CD components on EKS/GKE/OKE and no
per-cloud GitOps stack to keep in sync.

### The `gitops/` stack

Registration is its own layer, deployed after the foundations and
independently of the tenants stack:

```bash
cd gitops
terraform init -backend-config=backend/prototype.hcl
terraform apply -var-file=envs/prototype.tfvars
```

One state file per environment (`gitops/<env>.tfstate` in the same Azure
Storage state home as everything else), and the cloud is a key of
`var.spokes` rather than part of the deployment:

```hcl
spokes = {
  aws = {}                                                    # unrestricted
  # gcp = { namespaces = ["team-alpha"], cluster_resources = false }
}
```

A cloud left out is untouched — its foundation state is never read, its
cluster is never contacted and its provider stays inert — so a run needs
credentials only for the clouds actually listed, plus Azure for the hub and
the state home.

It has to be a layer of its own rather than something `foundations/aws` does:
a foundation may not reference another foundation, or the four of them stop
being independently deployable. `gitops/` reads `foundations/azure` (the hub)
and each spoke's `foundations/<cloud>` through `terraform_remote_state`, the
same one-way dependency the tenants stack has.

### What registration is

Per spoke, `modules/argocd-spoke` creates two things on two clusters:

```
spoke cluster                            hub cluster (AKS)
─────────────────────────────────        ────────────────────────────────────
ServiceAccount  argocd-manager           Secret cluster-<cloud> in argocd, with
ClusterRole     argocd-manager-role        argocd.argoproj.io/secret-type=cluster
  + ClusterRoleBinding                     data.server = the API endpoint
  (or a RoleBinding per namespace)         data.config.bearerToken = the token
Secret          argocd-manager-token ────▶ data.config.tlsClientConfig.caData
```

Argo CD has no API for adding a cluster: it lists the Secrets in its own
namespace carrying that label, so writing the Secret *is* the registration.

The credential is a ServiceAccount bearer token minted on the spoke, not the
cloud's admin kubeconfig. Argo CD does support cloud-native credentials
(`awsAuthConfig`, `execProviderConfig`), but each of them would need that
cloud's credentials sitting on the hub — AWS keys, a GCP service account key,
an OCI signing key inside AKS — which is exactly the sprawl the platform
avoids elsewhere. A ServiceAccount token works identically on EKS, GKE and
OKE, carries precisely the rights of the ClusterRole and nothing else, and is
revoked by deleting one ServiceAccount.

Kubernetes 1.24+ no longer mints a Secret per ServiceAccount, and the tokens
projected into pods are short-lived and audience-bound, so neither is usable
from another cluster. The module creates an explicit
`kubernetes.io/service-account-token` Secret — what `argocd cluster add` does
— and waits for the token controller to fill it in.

### Scoping a spoke

`cluster_role_rules` defaults to everything, which is what `argocd cluster
add` grants: Argo CD has to be able to apply whatever a repository holds. Two
variables narrow it:

```hcl
spokes = {
  aws = { namespaces = ["team-alpha", "team-beta"], cluster_resources = false }
}
```

That combination is enforced **twice** — Argo CD refuses Applications
targeting anything else, and the manager ServiceAccount is bound with a
`RoleBinding` per namespace instead of a `ClusterRoleBinding`, so the API
server refuses too. Any other combination binds at cluster scope.

### Fanning out

The cluster Secret's labels are the selector surface of an `ApplicationSet`
cluster generator, which is how "deploy this to every cloud" stays one
object:

| Label | Value |
|---|---|
| `argocd.argoproj.io/secret-type` | `cluster` |
| `onek8s.io/cloud` | `aws` \| `gcp` \| `oci` |
| `onek8s.io/environment` | the environment the foundations were deployed for |
| `onek8s.io/spoke` | the name Argo CD knows the cluster by (`{{name}}`) |

```yaml
generators:
  - clusters:
      selector:
        matchLabels:
          onek8s.io/environment: prototype     # every spoke of this environment
```

The hub itself is *not* labelled — Argo CD's built-in
`https://kubernetes.default.svc` entry has no Secret — so a cluster-generator
selector like the above hits the spokes only. Match on
`argocd.argoproj.io/secret-type: cluster` with no further labels to include
the hub as well.

### Operating it

```bash
# what the hub thinks it has
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster \
  -L onek8s.io/cloud,onek8s.io/environment
argocd cluster list --grpc-web

# from the spoke's side: who the hub is acting as, and what it may do
kubectl -n kube-system get sa argocd-manager
kubectl auth can-i --list --as system:serviceaccount:kube-system:argocd-manager

# revoke a spoke without touching Terraform state
kubectl -n kube-system delete sa argocd-manager
```

### Known gaps

- **The token never expires and nothing rotates it.** A
  `kubernetes.io/service-account-token` Secret is a long-lived credential;
  rotating it means tainting `kubernetes_secret_v1.manager_token` in the
  `gitops` state and re-applying. Bound, short-lived tokens would need
  something on the hub to refresh them, which is a controller this platform
  does not have.
- **The token is in Terraform state.** Terraform has to read it to write the
  hub's Secret, so it lands in `gitops/<env>.tfstate`. That state file is
  therefore as sensitive as a cluster admin credential for every spoke — the
  state home's RBAC is what protects it. The alternative sketched earlier —
  CI writing the token into Key Vault and an `ExternalSecret` assembling the
  cluster Secret on the hub — moves the credential out of state but adds a
  workflow that mints and rotates tokens out of band; it is the natural next
  step if the state home's blast radius becomes unacceptable.
- **Every API server is public.** Hub → spoke traffic crosses the internet to
  a public endpoint. Anything beyond prototype wants private endpoints plus
  peering or a tunnel, which is a networking story none of the foundations
  has yet.
- **The hub is now a platform-wide dependency.** Losing the AKS cluster
  stops delivery on all four clouds. Argo CD keeps no state a spoke needs at
  runtime, so workloads keep running, but nothing syncs until it is back.
- **The boundary against the tenants stack is a convention, not a
  mechanism.** Tenant onboarding (namespaces, quotas, SecretStores) stays in
  Terraform and only workloads belong in GitOps. Nothing stops an Application
  from managing a namespace and fighting Terraform over it; `namespaces` +
  `cluster_resources = false` on a spoke is the blunt instrument that does.
