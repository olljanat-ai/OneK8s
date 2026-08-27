# Flux, and what running it beside Argo CD is for

The platform now delivers applications two ways at once. Argo CD has been the
delivery plane since the beginning: one hub on AKS, every other cluster
registered with it as a spoke, and [Kargo](kargo.md) deciding which build
belongs on which cluster. **Flux is the second**, installed on AKS and EKS as
two independent copies that know nothing about each other and nothing about the
hub.

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
| Tenant boundary | `AppProject`: two repositories, one namespace, no cluster-scoped resources. | None — the controllers hold `cluster-admin`. See **Known gaps**. |
| Who owns the install | Azure, on AKS (the `Microsoft.ArgoCD` extension). | We do, on both clusters (the community `flux2` chart). |

Why it is Flux rather than a second Argo CD: an "Argo CD per cluster" is
already written down as the alternative that was rejected in
[ADR-0002](adr/0002-one-argo-cd-on-the-hub.md), and re-litigating it with the
same tool would only re-derive that decision. Independence is worth measuring
with a tool that is *built* for it. The decision to run both, and what it
deliberately does not decide, is [ADR-0003](adr/0003-flux-per-cluster-beside-the-hub.md).

## What is installed, and by what

`modules/fluxcd`, called by `foundations/azure/fluxcd.tf` and
`foundations/aws/fluxcd.tf` with `cloud` as the only difference. Three
resources per cluster:

```
helm_release "flux"       flux2 chart: source-, kustomize- and helm-controller
                          (+ their CRDs). Notification and image-automation
                          controllers are opt-in, and off.
ConfigMap  cluster-vars   this cluster's facts, in flux-system
helm_release "sync"       flux2-sync chart:
                            GitRepository  flux-system -> OneK8s-fluxcd @ main
                            Kustomization  flux-system -> ./clusters/<cloud>
```

That is the entire bootstrap, and it is the exact counterpart of the single
root `Application` that `gitops/root-app.tf` plants on the hub: Terraform
points a controller at a repository and then owns nothing else. From
`clusters/<cloud>` down, the cluster is Git.

Three deliberate choices are worth knowing before changing any of it:

- **The community chart, not `flux bootstrap`.** Flux's own bootstrap commits
  its manifests into the delivery-plane repository, which means giving
  Terraform write access to it. That repository is written by people and by CI;
  an apply is not one of its authors.
- **A Helm release, not `kubernetes_manifest`.** `GitRepository` and
  `Kustomization` are CRDs installed by the release above them, and
  `kubernetes_manifest` needs a resource's schema at *plan* time — so a cold
  apply would fail before it created anything. The `flux2-sync` chart exists
  for exactly this.
- **Not the `Microsoft.Flux` AKS extension**, even though Argo CD *is* taken as
  an Azure extension on AKS. EKS has no such extension, and an Azure-managed
  install on one cluster against a Helm install on the other would make every
  difference between the two clusters ambiguous — which is the one thing this
  experiment cannot afford.

## How a value reaches a manifest

Nothing in `OneK8s-fluxcd` names a cloud: both clusters reconcile the *same*
`apps/hello2` directory, and everything that differs arrives as a variable at
reconcile time, from two ConfigMaps in `flux-system`:

```
cluster-vars      written by Terraform (modules/fluxcd), never committed
  CLOUD                azure | aws
  ENVIRONMENT          prototype
  TENANT               team-beta
  DOMAIN               onek8s.lol
  SECRET_KEY_PREFIX    team-beta-   |   prototype/team-beta/
  APPS_REPO_URL        OneK8s-hello
  APPS_BRANCH          main

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

```bash
# what this cluster is reconciling, and whether it is
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

# what actually landed in the tenant's namespace
kubectl -n team-beta get helmrelease,ingress,externalsecret,pods
```

Two failures are worth recognising on sight:

| Symptom | Cause |
|---|---|
| `Kustomization` not ready: `variable not set: X` | `cluster-vars` does not carry `X`. Terraform writes it — the fix is `modules/fluxcd`, not the repository. |
| `HelmRelease` not ready: `namespaces "team-beta" not found` | The tenants stack has not been applied to this cluster yet. Flux is deliberately not allowed to create the namespace; apply `tenants/` and it recovers on its own. |
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

- **The Flux controllers hold `cluster-admin`.** The chart's multi-tenancy
  lockdown is off, so anything committed in `OneK8s-fluxcd` can do anything to
  either cluster. The Argo CD plane has a real boundary — an `AppProject`
  allowing two repositories, one namespace and no cluster-scoped resources —
  and this is the sharpest difference between them today. Closing it means
  `spec.serviceAccountName` on every `Kustomization` plus a tenant
  `ServiceAccount` with deploy rights in its own namespace, which
  `modules/tenant-namespace` does not grant.
- **No image automation.** The image-reflector and image-automation controllers
  are not installed, so nothing discovers a new build for you. Until they are,
  the comparison with Kargo is between an engine and a person, not between two
  engines — worth remembering before drawing conclusions from it.
- **No notifications.** `notification-controller` is not installed either
  (`enable_notifications = false`): without an `Alert` and a `Provider` it
  reconciles nothing, and a failed sync is equally invisible with or without
  it. Turning it on is the first thing to do if this plane ever carries
  something that matters.
- **No UI.** Argo CD's and Kargo's UIs are published on the platform wildcard;
  Flux has none by default (Weave GitOps is a separate install). "What is
  deployed where" on this plane is `kubectl`, per cluster.
- **The observability of the two planes is not comparable yet.** Both export
  Prometheus metrics and the collectors scrape neither specifically, so
  "which plane noticed drift faster" is not currently a question the platform
  can answer with data.
