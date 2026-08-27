# ADR-0003: Flux per cluster, running beside the Argo CD hub

- Status: Accepted
- Date: 2026-08-27

## Context

[ADR-0002](0002-one-argo-cd-on-the-hub.md) put one Argo CD on the AKS hub and
registered every other cluster with it as a spoke, with Kargo beside it on the
same cluster. Its "Alternatives considered" already names the arrangement this
one is about:

> **An Argo CD per cluster, with a Kargo per cluster.** Works, and is the right
> answer for a cluster that must survive without the hub. […] Reach for it when
> a cluster's independence is worth more than the fleet view.

That trade was recorded but never measured. Both halves of it are real — the
hub is a single point of delivery for every cluster, and the fleet view is the
reason the hub exists — and which one matters more is a property of an
organisation, not of a tool. Arguing it from documentation produces an opinion;
running it produces an answer.

The platform is also, by design, a place where such things can be run: two
clusters that are kept up, a tenant model that isolates by namespace and
identity, and an example application whose chart is deliberately free of
anything cloud- or plane-specific.

## Decision

**Flux is installed on AKS and on EKS as two independent per-cluster
delivery planes, alongside the Argo CD hub, and both planes stay.**

- Each cluster runs its own Flux, installed from its own foundation, and
  reconciles its own directory of
  [OneK8s-fluxcd](https://github.com/olljanat-ai/OneK8s-fluxcd) —
  `clusters/azure`, `clusters/aws`. **Nothing is registered between clusters**:
  no hub, no cluster Secret, no credential pointing from one cluster at
  another.
- Flux delivers the same `hello` chart to a **different tenant**, `team-beta`,
  on hosts `<cloud>-hello2.onek8s.lol`. Argo CD keeps `team-alpha` and
  `<cloud>-hello.onek8s.lol`.
- **The install is per cloud, the delivery plane is not.** AKS takes the
  Azure-managed `microsoft.flux` extension (`modules/fluxcd-aks`); the clouds
  that have no such extension install the same plane from the community chart
  (`modules/fluxcd`). Both are handed their cluster's facts by ONE module
  (`modules/fluxcd-cluster-vars`), produce a `GitRepository` and a
  `Kustomization` under the same names, and reconcile the same shared
  application definition.
- **ADR-0002 is unchanged.** Argo CD remains the hub, Kargo remains the
  promotion engine, and the release path for `team-alpha` is untouched.
- The two planes never manage the same object. They overlap only in that they
  read the same applications repository and run on the same clusters.

## Rationale

- **The comparison has to run to be worth anything.** Both planes on the same
  clusters, same chart, same secret backends, same ingress and the same
  wildcard: the difference on the cluster is the delivery plane and nothing
  else. Nothing about the result is then an artefact of a lab.
- **Independence is best measured with a tool built for it.** A second Argo CD
  per cluster would re-derive ADR-0002 rather than test it, and would carry the
  hub's assumptions into the experiment.
- **AKS is the destination, the other clouds are the proof.** The real
  environments this platform is a starting point for are AKS. Flux there should
  therefore be what an AKS environment would actually run — a Microsoft-managed
  extension Azure patches, visible in the portal's GitOps blade and auditable by
  Azure Policy — for the same reasons `foundations/azure` takes Argo CD as an
  extension. The community-chart install on the other clouds is what keeps the
  claim of cloud-agnosticism testable rather than asserted: if an application
  only works under the extension, that is a finding, and it surfaces on EKS.
- **Different tenants, so neither plane can quietly heal or fight the other.**
  Two controllers with `prune` and `selfHeal` on one namespace would produce a
  loop that teaches nothing. `team-beta` already existed on both clusters.
- **The cost is bounded and visible.** Three Terraform resources per cluster,
  three controllers per cluster, and a repository whose CI checks the contract
  between it and Terraform. Turning it off is `enable_fluxcd = false`.
- **Flux delivering to a tenant is a second, independent check on the tenant
  model.** The chart is unchanged, the namespaced `SecretStore` is unchanged,
  and the workload authenticates the same way. That it works with a completely
  different delivery plane is evidence about `modules/tenant-namespace`, not
  just about Flux.

## Consequences

- **Two delivery planes to operate, and Flux itself installed two ways.** Argo
  CD on AKS and Flux on AKS are both Microsoft-managed extensions; the Flux on
  every other cloud is ours, pinned by chart version in
  `foundations/<cloud>/variables.tf`. Two installs can drift — in version, in
  defaults, in what they enforce — and the one thing that must not drift, what
  the delivery plane is told about a cluster, is a single module both call.
- **The AKS extension's multi-tenancy shapes the repository.** It is enforced by
  default and kept: an application's Flux objects live in the configuration's
  namespace, the workload is placed with `targetNamespace`, and everything
  deploys as the `flux-applier` account Azure creates. That costs the
  community-chart install nothing — `modules/fluxcd` creates the same account —
  so one definition still serves both clusters, but manifests written for a
  plain Flux install do not drop in unchanged.
- **The Flux plane still has no tenant boundary.** Nothing deploys as a
  controller any more — multi-tenancy is enforced and the applier is named —
  but that applier is cluster-scoped, because one configuration in
  `flux-system` has to reach a tenant's namespace. The Argo CD plane confines
  its Applications to two repositories, one namespace and no cluster-scoped
  resources through the `onek8s-platform` `AppProject`; this one does not.
  What closes it is now a known, small step rather than a redesign — a
  namespace-scoped configuration per tenant — and it is written up in
  [fluxcd.md](../fluxcd.md) with what it would additionally need from
  `modules/tenant-namespace`.
- **"Deploy this everywhere" costs one commit per cluster** on the Flux plane,
  against one commit on the Argo CD plane. That asymmetry is data, not a defect
  to engineer away — flattening it by adding a fan-out layer would rebuild the
  hub and lose the thing being measured.
- **There is no fleet view of the Flux plane.** "What is deployed where" is
  `kubectl` per cluster; there is no UI and no aggregating controller.
- **The comparison is not symmetric yet, and conclusions drawn now would be
  wrong.** Kargo discovers builds and gates promotions; Flux's image-automation
  controllers are not installed, so its side of "what runs where" is a person
  writing a commit. That is a fair comparison of *this platform's* two
  configurations, not of the two projects' capabilities.
- **A third cluster does not scale the way the hub does.** Onboarding GKE or
  OKE to the Flux plane is a foundation change plus a new `clusters/<cloud>`
  directory and one release file per application — where the hub picks up a new
  spoke through a label selector.

## Alternatives considered

**Replace Argo CD with Flux.** Rejected outright: it would answer nothing.
Losing the hub *and* Kargo in one change makes every observed difference
unattributable, and it throws away a working release path to make a point that
has not been demonstrated.

**Run Flux on one cluster only.** Cheaper, and it would show that Flux
deploys — which was never in doubt. The question is about topology, and a
topology of one cluster is not one.

**Deliver the same tenant with both planes.** Rejected: two reconcilers with
`prune` and `selfHeal` over one set of objects fight, and the fight is the only
thing anybody would learn from. Different tenants keep the comparison about
delivery rather than about conflict resolution.

**Flux in hub-and-spoke, with `spec.kubeConfig` on the Kustomizations.** Flux
can drive a remote cluster with a kubeconfig Secret, which would make the two
planes topologically identical and the comparison a pure tool comparison.
Rejected for now because the platform already knows what hub-and-spoke costs
and does not know what independence costs; and because that shape needs a
long-lived cluster credential on the hub, where `modules/argocd-spoke` uses a
ServiceAccount token minted on the spoke itself. Worth revisiting as a third
configuration once the first two have been run for a while.

**One install everywhere — the community chart on AKS too.** Rejected, though
it was the first shape this took. Identical installs make any AKS-vs-EKS
difference attributable to the cluster rather than to the packaging, which is
worth something to the experiment; but it also means the cluster the real
environments run is configured in a way those environments would not choose,
and it gives up Azure-owned patching, the portal's GitOps blade and Azure Policy
auditing on exactly the cluster where they matter. The platform already takes
Argo CD as an extension on AKS for those reasons, and taking Flux any other way
would have been inconsistent with its own precedent.

The cost is real and is accepted: the two installs can differ in version and in
defaults, and one of those defaults — multi-tenancy — shaped the delivery-plane
repository. It is contained by giving both installs one contract module and one
set of object names, and by the repository's CI asserting the rules that
default imposes.
