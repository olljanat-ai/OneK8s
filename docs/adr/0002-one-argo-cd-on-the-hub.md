# ADR-0002: One Argo CD on the hub, with Kargo beside it

- Status: Accepted
- Date: 2026-08-24

## Context

The platform runs four clusters — AKS, EKS, GKE, OKE — and delivers the same
applications to them along a release path: `staging` on Azure, `production` on
AWS. Two controllers do that work. Argo CD answers "is the cluster what Git
says it is"; [Kargo](../kargo.md) answers "which build belongs on which
cluster", and writes the answer to the delivery-plane repository as a commit.

Where those two controllers *run* is the question this records, and it is asked
in earnest the first time a promotion to production fails:

```
argocd-update: unable to find Argo CD Application "hello-production"
               in namespace "argocd"
```

That message invites the reading that Kargo is looking at the wrong cluster,
and from there the reasonable-sounding proposal: give each cluster its own Argo
CD and let one Kargo drive them all.

## Decision

**Argo CD runs on the AKS hub and nowhere else.** Every other cluster is
registered with it as a spoke — a `ServiceAccount` on the spoke, a cluster
`Secret` on the hub (`modules/argocd-spoke`) — and stays a plain cluster with
no Argo CD components of its own.

**Kargo runs on the same cluster as Argo CD**, which is what makes the release
path work at all:

> Kargo's `argocd-update` step addresses an Application by **name and
> namespace** and resolves it through the controller's own Kubernetes client.
> There is no cluster, kubeconfig or endpoint field on that step.

So Kargo and the `Application` objects it promotes have to share a cluster. The
*workloads* do not: an Application on the hub can name any registered cluster
as its destination, which is exactly how `hello-production` runs on EKS while
its Application object lives in `argocd` on AKS.

## Rationale

- **The Application is a hub object; the workload is a spoke object.** Those
  are different things in different places, and conflating them is what makes
  the failure above look like a routing problem. Kargo never talks to the
  spoke, and neither does anything else in the delivery plane except Argo CD's
  own sync loop.
- **One control plane to operate.** One SSO app registration, one RBAC policy,
  one ingress and certificate, one upgrade path — and on AKS the extension is
  Microsoft's to patch. An Argo CD per cloud multiplies all of that by four,
  including three installs the platform would own outright rather than
  consuming as a managed extension.
- **One place to see what is deployed where.** The value of a fleet delivery
  plane is the fleet view; four Argo CDs is four views to reconcile by hand.
- **The credential is minimal and symmetric.** A spoke is reached with a
  ServiceAccount bearer token that carries exactly its `ClusterRole` and
  nothing else — the same mechanism on EKS, GKE and OKE — rather than a cloud
  admin credential sitting on the hub. See
  [argocd.md](../argocd.md), *What registration is*.

## Consequences

- **The spoke registration is a live dependency, and its absence is silent.**
  No cluster `Secret` → the `ApplicationSet`'s cluster generator matches
  nothing → zero Applications are generated, which is not an error anybody
  logs → the first symptom is a promotion failing at `argocd-update`. This is
  the platform's most confusing failure mode and it is the price of this shape.
  It is diagnosed in [argocd.md](../argocd.md), *When a spoke disappears*.
- **Registration is applied, not reconciled.** The Secret holds a bearer token,
  so it cannot live in Git the way everything else in the delivery plane does;
  Terraform owns it. Re-apply the `gitops` stack whenever **either** side of
  the pair is rebuilt — the hub's Argo CD extension (a reinstall takes the
  release namespace and every cluster Secret in it) or the spoke's cluster.
- **The hub is a single point of failure for delivery, not for serving.** With
  the hub down, spokes keep running what they were last synced to; no promotion
  can happen and no drift is corrected until it is back.
- Argo CD holds cluster-admin-equivalent rights on every spoke, which is a
  larger blast radius than the per-tenant identities of
  [ADR-0001](0001-per-tenant-identities-and-namespaced-secretstores.md).
  `var.spokes` narrows it per spoke (`namespaces` + `cluster_resources =
  false`), and the platform's own Applications are additionally confined by the
  `onek8s-platform` `AppProject`.

## Alternatives considered

**An Argo CD per cluster, with one shared Kargo on the hub.** Rejected, and not
merely on cost: it does not work. The hub's Kargo cannot see `Application`
objects on another cluster, so a promotion to production would have to drop its
`argocd-update` step — losing the wait for "synced at this revision and
healthy" (a promotion would report success while the old pods still served) and
losing the `kargo.akuity.io/authorized-stage` check that stops one stage
syncing another's Application. It also gives the platform three Argo CD
installs to run, secure and upgrade itself, where AKS offers a managed
extension.

**An Argo CD per cluster, with a Kargo per cluster.** Works, and is the right
answer for a cluster that must survive without the hub — an air-gapped site, or
a hard tenancy boundary. It costs the thing this platform is for: the release
path fragments into one per cluster, "what is running where" becomes N UIs, and
promoting from staging to production stops being a single object anybody can
read. Reach for it when a cluster's independence is worth more than the fleet
view, and accept that Kargo goes with it.

**Point Kargo at the correct cluster.** There is no such setting, and the
premise is wrong: the Application Kargo cannot find is missing from the hub,
not present on the spoke. Fixing the registration is the fix.
