# fluxcd-aks module

Installs Flux on **AKS** as the Microsoft-offered cluster extension
(`microsoft.flux`) and points it at
[OneK8s-fluxcd](https://github.com/olljanat-ai/OneK8s-fluxcd) with an Azure
`fluxConfiguration`.

Same delivery plane as `modules/fluxcd` installs on every other cloud, same
repository, same contract — a different install. AKS is what the real
environments run, so Azure owns the manifests, the upgrades and the CVE
patching here, exactly as it does for the Argo CD extension in
`foundations/azure/argocd.tf`; the other clouds run the community chart and are
where the platform proves the delivery plane is not tied to Azure.

## What it creates

```
azurerm_kubernetes_cluster_extension  microsoft.flux
                                        source-, kustomize-, helm- and
                                        notification-controller, the Flux CRDs,
                                        fluxconfig-agent + fluxconfig-controller
module "cluster_vars"                 ConfigMap cluster-vars in flux-system
                                        (modules/fluxcd-cluster-vars)
azurerm_kubernetes_flux_configuration   GitRepository  flux-system -> the repository
                                        Kustomization  flux-system -> ./clusters/azure
```

```hcl
module "fluxcd" {
  source = "../../modules/fluxcd-aks"

  providers = {
    azurerm    = azurerm
    kubernetes = kubernetes
  }

  cluster_id  = azurerm_kubernetes_cluster.this.id
  environment = var.environment
  tenant      = "team-beta"
}
```

## Two names that are not free

- **`var.configuration_name` defaults to `flux-system`** because Azure names
  the `GitRepository` object it creates after the configuration, and the
  delivery-plane repository's `Kustomization`s name that source in their
  `sourceRef`. `modules/fluxcd` names its Helm release the same thing for the
  same reason, so one manifest serves both installs.
- **`flux-applier`** is the ServiceAccount the extension creates in the
  configuration's namespace and has the controllers impersonate.
  `modules/fluxcd` creates one of the same name on the other clouds, and the
  manifests name it — so "who deploys this" is the same sentence everywhere.

## Multi-tenancy is on, and the repository is written for it

The extension enforces Flux's multi-tenancy by default, which means two things:

1. **No cross-namespace source references.** An application's `GitRepository`,
   `Kustomization` and `HelmRelease` all live in the configuration's namespace
   (`flux-system`).
2. **The controllers deploy as `flux-applier`, not as themselves.** With
   `var.scope = "cluster"` — Azure's own word for it is *full access* — that
   account can reach the tenant's namespace, which is how a `HelmRelease` in
   `flux-system` puts a workload in `team-beta` through `targetNamespace`.

That is Microsoft's documented shape, and the community-chart install honours
it too, so both clusters still reconcile one shared definition.
`var.enforce_multi_tenancy = false` is the escape hatch if a manifest that
cannot be arranged that way ever has to be deployed; it makes the controllers
cluster-admin.

For a real tenant boundary the shape to reach for is a **namespace-scoped**
configuration per tenant — Flux objects in the tenant's own namespace, the
applier bound only there. `docs/fluxcd.md` records why this environment does
not do that yet.

## Notes

- **`configuration_settings` merge on update.** An extension update does not
  remove a key that is absent from the map Terraform sends — the same trap
  `argocd.tf` documents at length. Dropping a setting from
  `var.extra_configuration_settings` will not clear it from the cluster.
- **The image-automation and image-reflector controllers are not installed.**
  Nothing in the delivery-plane repository uses them: a release there is a
  commit somebody writes. Turning them on is what it would take for Flux to
  answer Kargo on its own terms.
- **The extension is always in `flux-system` and cannot be installed at
  namespace scope** — that is Azure's constraint, not a choice here.
