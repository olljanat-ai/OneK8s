# fluxcd module

Installs **Flux on one cluster** and points it at the delivery-plane repository
[OneK8s-fluxcd](https://github.com/olljanat-ai/OneK8s-fluxcd). Used by
`foundations/azure` and `foundations/aws`; the cloud is a variable, like it is
in `modules/tenant-namespace`.

This is the platform's **second** delivery plane, and it is shaped as the
opposite of the first on purpose — the two run side by side on the same
clusters so they can be compared under load rather than on paper:

```
Argo CD                                   Flux (this module)
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
ConfigMap  cluster-vars   THIS cluster's facts, for Flux postBuild substitution:
                          CLOUD, ENVIRONMENT, TENANT, DOMAIN, SECRET_KEY_PREFIX,
                          APPS_REPO_URL, APPS_BRANCH
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

Nothing in OneK8s-fluxcd names a cloud. Every value that differs between
clusters is a `${VARIABLE}` substituted at reconcile time, half of them from
the `cluster-vars` ConfigMap this module writes — which is why that repository
declares what it expects in `platform-contract.yaml` and its CI renders every
cluster against those declarations.

Adding a variable is therefore a change in both repositories, deliberately: add
it to `var.extra_cluster_vars` or to `local.cluster_vars` here, and declare it
there. A key that only one side knows about is a Kustomization that stops
applying on the cluster with `variable not set`, which nothing else would
catch.

`SECRET_KEY_PREFIX` is the one that earns its keep. It is how *this* cloud's
secret backend spells a tenant's slice of it — `team-beta-` on Key Vault,
`prototype/team-beta/` on Secrets Manager, where a tenant's IAM role is
restricted by ARN prefix. Resolved here and handed over finished, so no
manifest in the delivery plane has an "if aws" in it.

## Prerequisites

- **The tenant namespace exists on this cluster.** The `tenants` stack creates
  it, with its quota, NetworkPolicy and namespaced `SecretStore`; Flux is not
  asked to create namespaces, exactly as Argo CD is not.
- **The tenant's test secret exists in this cloud's backend**, under the prefix
  above, if the deployed application reads one. The Renew Certificate workflow
  writes it — run it with `tenant: team-beta`.
- **A DNS record** for each host the applications publish, pointed at this
  cluster's ingress load balancer. Out of band, like every host here.
- **Helm and Kubernetes providers** configured for this cluster. Both are
  passed in; the module contacts nothing else.

## Notes

- **The controllers hold `cluster-admin`.** The chart's multi-tenancy lockdown
  is off, so anything committed in the delivery-plane repository can do
  anything to the cluster. Argo CD's side has a real boundary (an `AppProject`
  allowing two repositories, one namespace and no cluster-scoped resources);
  this one does not, and `docs/fluxcd.md` says so under "Known gaps" rather
  than leaving it to be discovered.
- **A Helm release, not `kubernetes_manifest`.** `GitRepository` and
  `Kustomization` are CRDs installed by the release above them, and
  `kubernetes_manifest` needs a schema at *plan* time — so a cold apply would
  fail to plan. The `flux2-sync` chart exists for exactly this.
- **The community chart, not the `flux` provider's bootstrap.** Bootstrapping
  the provider's way means giving Terraform write access to the delivery-plane
  repository so it can commit Flux's own manifests into it. That repository is
  written by people and by CI; an apply is not one of its authors.
- **Not the `Microsoft.Flux` AKS extension**, either, though `foundations/azure`
  takes Argo CD as an Azure extension. The point of this module is a delivery
  plane that is identical on both clusters — an Azure-managed install on one
  and a Helm install on the other would make every difference between the two
  clusters ambiguous.
