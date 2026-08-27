# fluxcd-cluster-vars module

One ConfigMap: **what a cluster tells the delivery plane about itself.**

Every Flux `Kustomization` in
[OneK8s-fluxcd](https://github.com/olljanat-ai/OneK8s-fluxcd) substitutes its
manifests from `cluster-vars` in `flux-system`
(`spec.postBuild.substituteFrom`), which is what lets both clusters reconcile
**one shared application definition** in which nothing names a cloud. It is the
counterpart of the Helm values `gitops/root-app.tf` hands the Argo CD
delivery-plane chart.

```
CLOUD              azure | aws
ENVIRONMENT        prototype
TENANT             team-beta
DOMAIN             onek8s.lol
SECRET_KEY_PREFIX  team-beta-   |   prototype/team-beta/
APPS_REPO_URL      OneK8s-hello
APPS_BRANCH        main
FLUX_APPLIER       flux-applier
FLUX_NAMESPACE     flux-system
```

## Why it is a module of its own

Because the platform installs Flux **two ways** — the Azure-managed
`microsoft.flux` extension on AKS (`modules/fluxcd-aks`) and the community
chart everywhere else (`modules/fluxcd`) — and the one thing that must be
identical on both is what the delivery plane is told. Two copies of this map
would be two contracts, and only one of them would be the one the repository's
CI checks against its `platform-contract.yaml`.

`SECRET_KEY_PREFIX` is the entry that earns its keep: Key Vault names are flat
because every environment has its own vault, while Secrets Manager is
account-wide, so a tenant's IAM role there is restricted to
`<environment>/<tenant>/*`. Resolving it here and handing it over finished is
what keeps an `if aws` out of a manifest a team owns.

## Sequencing

The namespace belongs to whichever install created it, and the objects that
*read* this ConfigMap are created after it, so the caller sequences all three:

```
install (extension | chart)  ──▶  this module  ──▶  the Flux configuration
```

Both callers pass `depends_on` accordingly. Nothing else here needs ordering:
it is one ConfigMap and a handful of `locals`.

## Adding a variable

Two repositories, deliberately: add it here (or through
`var.extra_cluster_vars`), and declare it in the delivery-plane repository's
`platform-contract.yaml`. Its CI renders every cluster against those
declarations, so a key only one side knows about fails a pull request there
instead of stopping a reconciliation nobody is watching:

```
variable substitution failed: variable not set: SECRET_KEY_PREFIX
```
