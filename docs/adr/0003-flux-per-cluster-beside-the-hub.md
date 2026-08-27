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

- Each cluster runs its own Flux (`modules/fluxcd`, from `foundations/<cloud>`)
  and reconciles its own directory of
  [OneK8s-fluxcd](https://github.com/olljanat-ai/OneK8s-fluxcd) —
  `clusters/azure`, `clusters/aws`. **Nothing is registered between clusters**:
  no hub, no cluster Secret, no credential pointing from one cluster at
  another.
- Flux delivers the same `hello` chart to a **different tenant**, `team-beta`,
  on hosts `<cloud>-hello2.onek8s.lol`. Argo CD keeps `team-alpha` and
  `<cloud>-hello.onek8s.lol`.
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

- **Two delivery planes to operate, secure and upgrade.** Argo CD on AKS is a
  Microsoft-managed extension; both Flux installs are ours, pinned by chart
  version in `foundations/<cloud>/variables.tf`.
- **The Flux plane has no tenant boundary today.** Its controllers hold
  `cluster-admin`, where the Argo CD plane confines its Applications to two
  repositories, one namespace and no cluster-scoped resources through the
  `onek8s-platform` `AppProject`. This is the sharpest known gap and it is
  recorded in [fluxcd.md](../fluxcd.md); anything committed in OneK8s-fluxcd
  should be read with it in mind.
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

**The `Microsoft.Flux` AKS extension on Azure, Helm on AWS.** Rejected: it
would make the Azure and AWS Flux installs differ in the very dimension being
measured. One module, two identical installs, is what makes a difference
between the clusters attributable to the cluster.
