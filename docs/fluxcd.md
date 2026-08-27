# Flux, and what running it beside Argo CD is for

The platform now delivers applications two ways at once. Argo CD has been the
delivery plane since the beginning: one hub on AKS, every other cluster
registered with it as a spoke, and [Kargo](kargo.md) deciding which build
belongs on which cluster. **Flux is the second**, installed on AKS and EKS as
two independent copies that know nothing about each other and nothing about the
hub — the Azure-managed extension on AKS, the community chart on EKS, one
repository and one contract behind both.

Both are installed on purpose, and both stay. The question being answered is
not "which tool wins" but a narrower and more useful one:

> On the same two clusters, deploying the same chart to the same kind of
> tenant, what does a hub-and-spoke delivery plane with a promotion engine
> actually buy over independent per-cluster reconcilers — and what does it
> cost?

Two hosts per cluster is the whole user interface of that experiment:

| Cluster | Argo CD delivers | Flux delivers |
|---|---|---|
| AKS (`azure`) | `https://azure-hello.onek8s.lol` — tenant `team-alpha` | `https://azure-hello2.onek8s.lol` — tenant `team-beta` |
| EKS (`aws`) | `https://aws-hello.onek8s.lol` — tenant `team-alpha` | `https://aws-hello2.onek8s.lol` — tenant `team-beta` |

Same application, same chart, same repository ([OneK8s-hello](https://github.com/olljanat-ai/OneK8s-hello)),
different plane and different tenant. GKE and OKE run neither today; the
comparison is between the two clusters the platform actually keeps up.

## The two topologies

```
Argo CD                                    Flux
─────────────────────────────────────      ────────────────────────────────────
        OneK8s-argocd                          OneK8s-fluxcd
              │                                   │        │
              ▼                            ┌──────┘        └──────┐
   ┌───────────────────┐                   ▼                      ▼
   │   AKS   (the hub) │            ┌───────────┐          ┌───────────┐
   │  Argo CD + Kargo  │            │    AKS    │          │    EKS    │
   └─────────┬─────────┘            │   Flux    │          │   Flux    │
             │ cluster Secret       │clusters/  │          │clusters/  │
             ▼                      │  azure    │          │   aws     │
   ┌───────────────────┐            └───────────┘          └───────────┘
   │   EKS  (a spoke)  │
   │  no Argo CD at all│            no hub, no registration, no shared object
   └───────────────────┘
```

The same EKS cluster is a **spoke** on one plane and **self-contained** on the
other. That is the comparison, stated as infrastructure rather than as opinion.

| | Argo CD (`OneK8s-argocd`) | Flux (`OneK8s-fluxcd`) |
|---|---|---|
| Where the controller runs | AKS only. EKS runs no delivery-plane component. | Every cluster runs its own. |
| How a cluster is reached | A `ServiceAccount` token on the spoke, held as a cluster `Secret` on the hub (`modules/argocd-spoke`). | It is not reached. Each cluster pulls for itself. |
| Fan-out | One `ApplicationSet`; a cluster generator turns it into one `Application` per matching cluster. | None. One `Kustomization` per cluster, pointing at one shared definition. |
| Per-cluster values | Helm parameters rendered by the delivery-plane chart on the hub. | `${VARIABLE}` substitution from a `cluster-vars` ConfigMap Terraform writes. |
| What runs where | Kargo: a `Warehouse` freezes each build as Freight, `staging` takes it automatically, `production` takes only what staging ran, when a person promotes. | A pull request editing `clusters/<cloud>/hello2-release.yaml`. |
| "Deploy this everywhere" | One commit. | One commit per cluster. |
| Delivery plane unavailable | Nothing deploys anywhere; spokes keep serving what they last synced. | One cluster stops reconciling; the other never notices. |
| Tenant boundary | `AppProject`: two repositories, one namespace, no cluster-scoped resources. | Multi-tenancy enforced: one namespace for Flux's objects, deployment as `flux-applier` — but that account has full access. See **Known gaps**. |
| Who owns the install | Azure, on AKS (the `Microsoft.ArgoCD` extension). | Azure on AKS (`microsoft.flux`); we do on the clouds that have no such extension (the community `flux2` chart). |

Why it is Flux rather than a second Argo CD: an "Argo CD per cluster" is
already written down as the alternative that was rejected in
[ADR-0002](adr/0002-one-argo-cd-on-the-hub.md), and re-litigating it with the
same tool would only re-derive that decision. Independence is worth measuring
with a tool that is *built* for it. The decision to run both, and what it
deliberately does not decide, is [ADR-0003](adr/0003-flux-per-cluster-beside-the-hub.md).

## What is installed, and by what

Not the same way on every cluster, and deliberately so. **AKS is what the real
environments run**, so Flux there is the Microsoft-offered cluster extension —
Azure owns the manifests, the upgrades and the CVE patching, exactly as it does
for Argo CD in `argocd.tf`. The other clouds install the same delivery plane
from the community chart, and are where the platform proves it is not tied to
Azure.

```
AKS   foundations/azure/fluxcd.tf        EKS   foundations/aws/fluxcd.tf
      modules/fluxcd-aks                       modules/fluxcd
─────────────────────────────────        ────────────────────────────────────
azurerm_kubernetes_cluster_extension     helm_release "flux"  (flux2 chart)
  microsoft.flux                           source-, kustomize-, helm-controller
  source-, kustomize-, helm- and
  notification-controller, the CRDs,     ServiceAccount flux-applier
  fluxconfig-agent/-controller             (+ cluster-admin binding)

        ── modules/fluxcd-cluster-vars: ConfigMap cluster-vars ──
              the one thing that must be identical on both

azurerm_kubernetes_flux_configuration    helm_release "sync"  (flux2-sync chart)
  GitRepository  flux-system               GitRepository  flux-system
  Kustomization  ./clusters/azure          Kustomization  ./clusters/aws
```

Both produce the same two objects, under the same names, from the same
repository — which is what lets one directory in OneK8s-fluxcd serve both. That
is the entire bootstrap, and the exact counterpart of the single root
`Application` that `gitops/root-app.tf` plants on the hub: Terraform points a
controller at a repository and then owns nothing else.

The contract is one module (`modules/fluxcd-cluster-vars`) rather than a copy
per install, because two copies would be two contracts and only one of them
would be the one the repository's CI checks.

Choices worth knowing before changing any of it:

- **The extension on AKS, and its defaults kept.** Including multi-tenancy —
  see the next section, which is the one place this costs something.
- **The community chart elsewhere, not `flux bootstrap`.** Flux's own bootstrap
  commits its manifests into the delivery-plane repository, which means giving
  Terraform write access to it. That repository is written by people and by CI;
  an apply is not one of its authors.
- **A Helm release, not `kubernetes_manifest`, for the chart install.**
  `GitRepository` and `Kustomization` are CRDs installed by the release above
  them, and `kubernetes_manifest` needs a resource's schema at *plan* time — so
  a cold apply would fail before it created anything. The `flux2-sync` chart
  exists for exactly this.
- **The Azure configuration is named `flux-system`.** Not cosmetic: Azure names
  the `GitRepository` object after the configuration, and the repository's
  `Kustomization`s name that source in their `sourceRef`. The chart install
  names its release the same thing for the same reason.

## Multi-tenancy, and why the objects are laid out oddly

The AKS extension enforces Flux's multi-tenancy by default, and this platform
keeps that default rather than opting out (`multiTenancy.enforce`). Two rules
follow, and they are the reason an application's objects are not where you
would first put them:

1. **No cross-namespace source references**, and every Flux object of an
   application lives in the *configuration's* namespace — `flux-system`. A
   `HelmRelease` in the tenant's namespace is refused there outright: there is
   no applier ServiceAccount in it.
2. **The controllers deploy as `flux-applier`**, the ServiceAccount Azure
   creates in that namespace and impersonates with, rather than as themselves.

So an application looks like this: `GitRepository` + `HelmRelease` in
`flux-system`, `serviceAccountName: flux-applier`, and the workload placed in
the tenant's namespace by the `HelmRelease`'s `targetNamespace`. That is
Microsoft's documented shape, and the reason it works at all is
`scope = "cluster"` on the configuration — Azure's own word for that scope is
*full access*, which is what lets an applier in `flux-system` reach
`team-beta`.

None of it costs the community-chart install anything: `modules/fluxcd` creates
a `flux-applier` of its own so the same manifest deploys the same way there.
One shape, both clusters — and the repository's CI asserts both rules, because
breaking either is invisible until a cluster quietly stops reconciling.

## How a value reaches a manifest

Nothing in `OneK8s-fluxcd` names a cloud: both clusters reconcile the *same*
`apps/hello2` directory, and everything that differs arrives as a variable at
reconcile time, from two ConfigMaps in `flux-system`:

```
cluster-vars      written by Terraform (modules/fluxcd-cluster-vars), never committed
  CLOUD                azure | aws
  ENVIRONMENT          prototype
  TENANT               team-beta
  DOMAIN               onek8s.lol
  SECRET_KEY_PREFIX    team-beta-   |   prototype/team-beta/
  APPS_REPO_URL        OneK8s-hello
  APPS_BRANCH          main
  FLUX_NAMESPACE       flux-system
  FLUX_APPLIER         flux-applier

hello2-release    committed in clusters/<cloud>/, beside the cluster it is for
  HELLO2_IMAGE_TAG        sha-41a1c13
  HELLO2_CHART_REVISION   7eac6f6b...
```

`SECRET_KEY_PREFIX` is the one that earns its keep, and it is the same string
the Argo CD side resolves in its chart's `values.yaml`: Key Vault names are
flat because every environment has its own vault, while Secrets Manager is
account-wide, so a tenant's IAM role there is restricted to
`<environment>/<tenant>/*`. Resolving it in Terraform and handing it over
finished is what keeps an `if aws` out of a manifest a team owns.

The contract is written down on the side that depends on it —
`platform-contract.yaml` in `OneK8s-fluxcd` — and its CI renders every cluster
against those declarations. A variable Terraform stops writing therefore fails
a pull request there, instead of stopping one cluster's reconciliation with a
message nobody is watching for:

```
variable substitution failed: variable not set: SECRET_KEY_PREFIX
```

Adding a variable is a change in both repositories. That is the cost of the
contract, and it is the reason it is checkable.

## Making a release

There is no promotion engine on this plane. A build reaches a cluster when
somebody says so, in a pull request against `OneK8s-fluxcd`:

1. Find the build. The `OneK8s-hello` build workflow publishes one immutable
   `sha-<short>` tag per merge and no moving tag at all.
2. Edit `clusters/<cloud>/hello2-release.yaml`: `HELLO2_IMAGE_TAG`, and
   `HELLO2_CHART_REVISION` if the chart itself moved.
3. Merge. That cluster's Flux picks it up within the source interval (1m), or
   at once with `flux reconcile kustomization hello2 --with-source`.

Moving one cluster moves nothing else, and nothing enforces that the second
cluster ever follows. Compare [kargo.md](kargo.md), where `production` can only
run what `staging` has already run: there the gate is an engine's and the
sequence is an object; here both are review.

## Operating it

Everything below needs a kubeconfig for the cluster in question — there is no
hub to ask, which is itself one of the findings.

On AKS the extension adds an Azure-side view of the same thing, which is half
of why it is the extension there — `az k8s-configuration flux show` and the
portal's GitOps blade answer "is it syncing" without a kubeconfig at all:

```bash
# AKS only: the configuration and the extension, from Azure's side
az k8s-configuration flux show -t managedClusters -c <cluster> -g <rg> -n flux-system
az k8s-extension show      -t managedClusters -c <cluster> -g <rg> -n flux

# ...and the same from inside either cluster
kubectl -n flux-system get gitrepositories,kustomizations
kubectl -n flux-system get helmreleases -A

# with the flux CLI, if it is installed
flux get all -A

# why a Kustomization is not ready (unset variable, missing namespace, ...)
kubectl -n flux-system describe kustomization hello2

# what this cluster was told about itself
kubectl -n flux-system get configmap cluster-vars -o yaml

# pull now instead of at the next interval
flux reconcile kustomization hello2 --with-source

# what actually landed in the tenant's namespace (the HelmRelease itself is
# in flux-system — see Multi-tenancy above)
kubectl -n team-beta get ingress,externalsecret,pods
kubectl -n flux-system get helmrelease
```

Two failures are worth recognising on sight:

| Symptom | Cause |
|---|---|
| `Kustomization` not ready: `variable not set: X` | `cluster-vars` does not carry `X`. Terraform writes it — the fix is `modules/fluxcd-cluster-vars`, not the repository. |
| `HelmRelease` not ready: `namespaces "team-beta" not found` | The tenants stack has not been applied to this cluster yet. Flux is deliberately not allowed to create the namespace; apply `tenants/` and it recovers on its own. |
| `HelmRelease` not ready: `serviceaccounts "flux-applier" not found`, or a `forbidden` on the tenant's namespace | The object is in the wrong namespace, or the applier is missing. On AKS the extension owns that account; on the other clouds `modules/fluxcd` creates it. |
| A `Kustomization` or `HelmRelease` never reconciles and nothing is logged against it | Multi-tenancy refused it: an object outside `flux-system`, or a `sourceRef` naming another namespace. The delivery-plane repository's CI catches both before merge. |
| `ExternalSecret` `SecretSyncedError` | The tenant's `test` secret does not exist in this cloud's backend under the prefix above. Run the Renew Certificate workflow with `tenant: team-beta`. |

## Deployment order

Flux is part of the foundation, so it is installed before the tenant namespace
it deploys into exists. That is not a mistake and needs no coordination: the
`HelmRelease` fails, Flux retries, and the application appears once `tenants/`
has been applied. The order for a cold environment is unchanged —
`foundations/<cloud>` → `tenants/` → `gitops/` — with one addition before the
hosts serve anything: an `A` record for `<cloud>-hello2.onek8s.lol`, pointed at
that cluster's ingress load balancer by hand, like every other host here.

## Known gaps

- **The applier has full access.** Multi-tenancy is enforced, so nothing
  deploys as a controller — but `flux-applier` is cluster-scoped, because one
  configuration in `flux-system` has to reach a tenant's namespace. Anything
  committed in `OneK8s-fluxcd` can therefore still do anything to either
  cluster, where the Argo CD plane has a real boundary in its `AppProject`.
  This is the sharpest remaining difference between the two planes.

  The shape that closes it is now one step away rather than a redesign: a
  **namespace-scoped** Flux configuration per tenant (`scope = "namespace"`,
  `namespace = <tenant>`), which puts that tenant's Flux objects in its own
  namespace with an applier bound only there. It needs a tenant
  `ServiceAccount` with deploy rights that `modules/tenant-namespace` does not
  grant today, and it means one configuration per tenant per cluster — which is
  the right trade for a real environment and overkill for this one.
- **No image automation.** The image-reflector and image-automation controllers
  are installed by neither the extension nor the chart, so nothing discovers a
  new build for you. Until they are,
  the comparison with Kargo is between an engine and a person, not between two
  engines — worth remembering before drawing conclusions from it.
- **No notifications configured.** The AKS extension installs
  `notification-controller` (it is not optional there) and the chart install is
  told not to (`enable_notifications = false`), but neither cluster has an
  `Alert` or a `Provider` — so a failed sync is invisible either way.
  Configuring one is the first thing to do if this plane ever carries something
  that matters.
- **No UI, except what Azure gives AKS.** Argo CD's and Kargo's UIs are
  published on the platform wildcard; Flux has none of its own (Weave GitOps is
  a separate install). On AKS the portal's GitOps blade shows the configuration
  and its sync state, which is a real difference between the two installs and
  worth weighing when the comparison is judged: on EKS, "what is deployed here"
  is `kubectl`.
- **The observability of the two planes is not comparable yet.** Both export
  Prometheus metrics and the collectors scrape neither specifically, so
  "which plane noticed drift faster" is not currently a question the platform
  can answer with data.
