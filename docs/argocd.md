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

## What gets in without a person: the `ci` account

SSO covers people. A pipeline has no browser to be redirected to Entra with, so
callers that are not people get a **local API account** instead, configured
through `argocd_api_accounts` (account name → role):

```hcl
argocd_api_accounts = {
  ci = "role:ci"
}
```

Each entry becomes an `accounts.<name>` key in `argocd-cm` with the single
capability `apiKey`, and a `g, <name>, <role>` binding in the RBAC policy. The
`ci` account is the default, because the delivery plane already expects it: the
`Promote to production` workflow in
[OneK8s-argocd](https://github.com/olljanat-ai/OneK8s-argocd) authenticates as
it to diff and sync the production stage after a human approves the run.

Two things `apiKey` deliberately does not include:

- **No password.** The other capability, `login`, would give the account one and
  a way into the UI. A machine account with a password is a shared password, so
  the only credential these accounts have is a bearer token.
- **No self-service tokens.** `role:ci` grants no `accounts` actions, so the
  account cannot mint tokens for itself — an admin does that, once, out of band.

`role:ci` is defined in `argocd_rbac_policies` alongside `role:org-admin`, and
is scoped to what the promotion workflow actually does:

| Rule | What it is for |
|---|---|
| `applications, get, */*` | `argocd app get`, `app diff`, `app wait` |
| `applications, sync, onek8s-platform/*` | `argocd app sync`, for platform applications only |

The sync rule's object is `<project>/<application>`, and `onek8s-platform` is
the `AppProject` the delivery-plane chart creates — so the account can promote
an application the root Application brought in, but not the root Application
itself, which lives in `default`. Repositories, clusters and accounts are not
in the role at all.

### Minting the token

The account is configuration; the token is not. Nothing in Terraform generates
one, so no Argo CD token is ever written to state. Sign in as a member of a
group mapped to `role:admin` (`role:org-admin` is not enough — it has no
`accounts` actions) and generate it:

```bash
argocd login argocd.onek8s.lol --grpc-web --sso
argocd account generate-token --account ci --grpc-web
```

Add `--expires-in 90d` to get a token that expires, then put the value in the
consuming repository's `secrets.ARGOCD_AUTH_TOKEN`. Revoking is
`argocd account delete-token --account ci <id>`, with the IDs from
`argocd account get --account ci`; removing the account from
`argocd_api_accounts` and applying invalidates every token it has.

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
- **The `ci` account's token is minted and rotated by hand.** The account is
  declarative, the credential is not: it is generated once with the CLI and
  pasted into a repository secret, and nothing here notices when it expires or
  is leaked. Automating it would mean this stack holding an Argo CD admin
  credential and writing tokens into state, which is worse than the manual
  step it replaces.
- **Preview auto-upgrade.** With `argocd_extension_version` unset Azure
  installs the latest build of the release train and upgrades it in place.
  The 0.0.x → 1.0.0-preview jump already changed every configuration key
  once; pin a version per environment if that risk is unacceptable.
- Argo CD has cluster-wide privileges on the cluster it runs on, which is a
  strictly larger blast radius than the per-tenant identities in
  [ADR-0001](adr/0001-per-tenant-identities-and-namespaced-secretstores.md).
  Applications brought in by the root Application are confined by the
  `onek8s-platform` `AppProject` (the platform's own two repositories only, one
  namespace, no cluster-scoped resources — see [OneK8s-argocd](https://github.com/olljanat-ai/OneK8s-argocd)), but
  the built-in `default` project is still wide open, so anything created
  outside that root Application is unrestricted.

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
| `gcp` | GKE, `foundations/gcp` | Secret `cluster-gcp` in `argocd` | registered by `gitops/` |
| `oci` | OKE, `foundations/oci` | Secret `cluster-oci` in `argocd` | registered by `gitops/` |

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

### Per-cloud differences

There are only two, and both are about the *registration run*, not about what
Argo CD does afterwards — once the Secret exists every spoke is the same
bearer token against the same Kubernetes API:

| Cloud | Endpoint the foundation publishes | How Terraform authenticates to bootstrap the spoke |
|---|---|---|
| `aws` | complete `https://` URL | `aws_eks_cluster_auth` token (EKS access entries / `aws-auth`) |
| `gcp` | bare host, prefixed with `https://` | `google_client_config` access token of the deploy service account |
| `oci` | complete `https://` URL | `oci ce cluster generate-token`, exec'd by the provider — the OCI CLI must be on `PATH` |

The deploy identity therefore needs cluster-admin-ish rights on the spoke for
that one run — on GKE the deploy service account needs
`roles/container.admin` (or at least the ability to create ClusterRoles), on
AWS it needs an access entry that maps to a cluster admin, on OCI it needs
`manage cluster-family` in the compartment. Argo CD itself never uses those
credentials: everything after registration goes through the `argocd-manager`
token.

OCI is the one cloud whose Terraform provider this stack does not configure
at all. Nothing is created in OCI itself — the endpoint and CA come from the
foundation's state and the token from the CLI — so there is no `oci` provider
and no home-region alias here, unlike in the tenants stack where per-tenant
IAM policies force both.

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
selector like the above hits the spokes only. Deploying to the hub means naming
it in a one-element `list` generator instead, which is what the `hello`
application's staging stage does in
[OneK8s-argocd](https://github.com/olljanat-ai/OneK8s-argocd/blob/main/argocd/templates/applicationset-hello.yaml).

### What Argo CD deploys, and where that is configured

Argo CD's own configuration is version-controlled rather than clicked
together, on the "app of apps" pattern — and it is version-controlled
*elsewhere*. This repository builds the clusters and plants one Application on
the hub; what runs on them lives in two repositories of its own:

| Repository | Owns |
|---|---|
| **OneK8s** (here) | The clusters, the tenants, the hub, and the root `Application` — `gitops/root-app.tf` |
| [OneK8s-argocd](https://github.com/olljanat-ai/OneK8s-argocd) | Where and when an application is deployed: the `AppProject`, the ApplicationSets, the release stages |
| [OneK8s-hello](https://github.com/olljanat-ai/OneK8s-hello) | What is deployed: the example applications, their charts and their images |

```
root-app.tf ──▶ Application "platform-gitops"  (project: default)
                  └── OneK8s-argocd, path argocd
                        ├── AppProject onek8s-platform
                        ├── ApplicationSet hello-staging     ──▶ hello-staging     (azure, in-cluster)
                        ├── ApplicationSet hello-production  ──▶ hello-production  (aws, spoke)
                        └── ApplicationSet db-hello          ──▶ db-hello-azure    (hub only)
```

That chart is a Helm chart, and the root Application supplies its values from
`var.environment` and `var.platform_apps` — the environment, both repositories
and revisions to sync, the wildcard domain, the tenant namespace and the Azure
SQL coordinates read out of the hub's foundation state. That is what lets one
copy of it serve every environment: the cluster generators' selectors, the
applications' hostnames and the database they talk to follow the environment
rather than being committed per environment.

The `hello` application is released along **two stages**, which is the reason
there are two ApplicationSets rather than one fan-out:

| Stage | Cloud | Cluster | Sync |
|---|---|---|---|
| `staging` | `azure` | AKS, the hub (`in-cluster`) | automated: prune + selfHeal |
| `production` | `aws` | EKS, a registered spoke | **manual** — the Application carries no `syncPolicy.automated` |

Nothing reaches the AWS cluster until a human syncs it, from the UI, with
`argocd app sync hello-production`, or through the approval-gated *Promote to
production* workflow in OneK8s-argocd, which binds to a GitHub environment with
required reviewers. Removing `aws` from `var.spokes` removes production
altogether: the cluster generator finds no cluster and generates no Application.

`db-hello` has no stages, because it is deployed to Azure and nowhere else, and
it is not rendered at all in an environment whose Azure foundation was applied
with `enable_sql = false` — the application follows the database instead of a
switch of its own.

Terraform owns nothing else in Argo CD. After the first apply, adding an
application or changing one is a commit in one of the other two repositories;
`terraform apply` is only needed to move the delivery plane to a different
repository, revision or environment. `platform_apps = { enabled = false }`
registers spokes without deploying anything, and the root Application is
skipped automatically when the hub was applied with `enable_argocd = false`.

The applications deployed today are the `hello` example on Azure and AWS
([docs/hello-app.md](https://github.com/olljanat-ai/OneK8s-hello/blob/main/docs/hello-app.md)) and the Azure-only
`db-hello` ([docs/db-hello-app.md](https://github.com/olljanat-ai/OneK8s-hello/blob/main/docs/db-hello-app.md)).

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
- **A repository the hub cannot reach stops delivery.** The AppProject allows
  exactly two repositories, and both are public GitHub repositories the hub's
  repo-server fetches over the internet. Making either private means
  registering credentials with Argo CD; renaming one means a `terraform apply`
  here as well as a commit there.
- **The boundary against the tenants stack is a convention, not a
  mechanism.** Tenant onboarding (namespaces, quotas, SecretStores) stays in
  Terraform and only workloads belong in GitOps. Nothing stops an Application
  from managing a namespace and fighting Terraform over it; `namespaces` +
  `cluster_resources = false` on a spoke is the blunt instrument that does.
