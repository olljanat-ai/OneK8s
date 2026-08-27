# fluxcd module

Installs Flux on **one cluster** from the community `flux2` chart and points it
at [OneK8s-fluxcd](https://github.com/olljanat-ai/OneK8s-fluxcd). Used by
`foundations/aws`, and by GKE/OKE when they are registered; the cloud is a
variable, like it is in `modules/tenant-namespace`.

**AKS does not use this module.** It takes Flux as the Azure-managed extension
(`modules/fluxcd-aks`), because that is what the real environments run and
Azure patches it there. This is the *portable* half of the same delivery plane:
same repository, same contract (`modules/fluxcd-cluster-vars`), same shared
application definition. If an application ever only works on AKS, this module
is where that shows up.

The platform's *other* delivery plane, Argo CD, is shaped as the opposite of
both — the two run side by side on the same clusters so they can be compared
under load rather than on paper:

```
Argo CD                                   Flux (this module, and fluxcd-aks)
────────────────────────────────────      ──────────────────────────────────
one hub on AKS                            one install per cluster
spokes registered with a cluster Secret   nothing registered, nothing to register
  (modules/argocd-spoke, gitops/)
ApplicationSet fans one template out      each cluster reconciles its own path
Kargo promotes a build between clusters   a person commits, per cluster
hub unavailable -> nothing deploys        one cluster stops; the others do not
```

## What it creates

```
helm_release "flux"       flux2 chart: source-, kustomize- and helm-controller
                          (+ their CRDs). Notifications and image automation
                          are opt-in and off.
ServiceAccount            flux-applier (+ cluster-admin binding) — the identity
                          the delivery plane deploys as, matching the account
                          Azure's extension creates and impersonates on AKS
module "cluster_vars"     ConfigMap cluster-vars: THIS cluster's facts
helm_release "sync"       flux2-sync chart:
                            GitRepository flux-system -> var.repo_url @ branch
                            Kustomization flux-system -> ./clusters/<cloud>
```

That is the whole bootstrap — the counterpart of the single root `Application`
`gitops/root-app.tf` plants on the Argo CD hub. From `clusters/<cloud>` down,
the cluster is Git.

```hcl
module "fluxcd" {
  source = "../../modules/fluxcd"

  providers = {
    helm       = helm
    kubernetes = kubernetes
  }

  cloud       = "aws"
  environment = var.environment
  tenant      = "team-beta"
}
```

## The contract with the delivery-plane repository

Nothing in OneK8s-fluxcd names a cloud, and nothing in it names an install
either. Every value that differs is a `${VARIABLE}` substituted at reconcile
time from the `cluster-vars` ConfigMap — written by
`modules/fluxcd-cluster-vars`, which both installs call so the two contracts
cannot drift. That repository declares what it expects in
`platform-contract.yaml` and its CI renders every cluster against those
declarations.

Adding a variable is a change in both repositories, deliberately. A key that
only one side knows about is a Kustomization that stops applying on the cluster
with `variable not set`, which nothing else would catch.

## Why this install, on the clouds that have no extension

- **The community chart, not `flux bootstrap`.** Flux's own bootstrap commits
  its manifests into the delivery-plane repository, which means giving
  Terraform write access to it. That repository is written by people and by CI;
  an apply is not one of its authors.
- **A Helm release, not `kubernetes_manifest`.** `GitRepository` and
  `Kustomization` are CRDs installed by the release above them, and
  `kubernetes_manifest` needs a resource's schema at *plan* time — so a cold
  apply would fail before it created anything. The `flux2-sync` chart exists
  for exactly this.
- **`flux-applier` with `cluster-admin`.** Not because this install needs an
  impersonated identity — its controllers are cluster-admin anyway — but
  because AKS's manifests name one, and a shared definition that only works on
  one install is not shared. It is also where a real tenant boundary would be
  narrowed: a per-tenant applier bound in that tenant's namespace only
  (`docs/fluxcd.md`, *Known gaps*).

## Prerequisites

- **The tenant namespace exists on this cluster.** The `tenants` stack creates
  it, with its quota, NetworkPolicy and namespaced `SecretStore`; Flux is not
  asked to create namespaces, exactly as Argo CD is not.
- **The tenant's test secret exists in this cloud's backend**, under
  `SECRET_KEY_PREFIX`, if the deployed application reads one. The Renew
  Certificate workflow writes it — run it with `tenant: team-beta`.
- **A DNS record** for each host the applications publish, pointed at this
  cluster's ingress load balancer. Out of band, like every host here.
- **Helm and Kubernetes providers** configured for this cluster. Both are
  passed in; the module contacts nothing else.
