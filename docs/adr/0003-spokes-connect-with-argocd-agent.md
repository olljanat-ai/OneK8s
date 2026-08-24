# ADR-0003: Spokes connect to the hub, with argocd-agent

- Status: Accepted
- Date: 2026-08-24
- Amends [ADR-0002](0002-one-argo-cd-on-the-hub.md)

## Context

[ADR-0002](0002-one-argo-cd-on-the-hub.md) put one Argo CD on the AKS hub, with
Kargo beside it, and made every other cluster a spoke. That decision stands. How
a spoke was *reached* is what this records.

The original arrangement was the one `argocd cluster add` produces. Each spoke
had an `argocd-manager` ServiceAccount bound to a `ClusterRole` granting
everything, a long-lived bearer token for it, and a `Secret` on the hub holding
that token and the spoke's API endpoint. Argo CD's application-controller then
applied every manifest by calling that endpoint.

It worked. It also had one consequence that sat in *Known gaps* in
[argocd.md](../argocd.md) from the day it was written:

> **Every API server is public.** Hub → spoke traffic crosses the internet to a
> public endpoint. Anything beyond prototype wants private endpoints plus
> peering or a tunnel, which is a networking story none of the foundations has
> yet.

That is not a detail to be fixed later. It follows from the direction of the
connection: a control plane that reaches out must be able to reach. Making the
spokes' management APIs private, with a hub on a *different cloud*, would have
meant peering three VPC/VCN networks to one Azure VNet, or a tunnel per cloud —
a networking story with four vendors in it, maintained forever, so that one
controller can make outbound calls.

Two smaller consequences came with it. The hub held **cluster-admin on every
spoke**, and so did `gitops/<env>.tfstate`. And the hub was a hard runtime
dependency for reconciliation everywhere: with AKS down, nothing on any cloud
converged, because the only thing that could apply a manifest was on AKS.

## Decision

**Every spoke runs an [argocd-agent](https://github.com/argoproj-labs/argocd-agent)
agent that dials the hub, and nothing on the hub contacts a spoke.**

Concretely:

- The **principal** runs on the hub, in the Argo CD namespace
  (`foundations/azure/argocd-agent.tf`). It is published at
  `argocd-agent.onek8s.lol:8443` through a Traefik `IngressRouteTCP` with **TLS
  passthrough**, on the same load balancer as everything else.
- Each spoke runs an **agent in managed mode** plus a reconciler-only Argo CD —
  `application-controller`, `repo-server`, `redis`; no API server, no
  ApplicationSet controller (`modules/argocd-spoke`).
- Routing is **destination-based**: the principal reads an Application's
  `spec.destination.name` to decide which agent it belongs to.
- Authentication is **mTLS**, from a certificate authority minted in Terraform
  and held on the hub. An agent's identity is the common name of its client
  certificate.
- The hub keeps its own `application-controller`, because it is also a
  deployment target. The two are kept apart by argocd-agent's **hybrid**
  mechanisms: a label the principal and agents filter on, and
  `argocd.argoproj.io/skip-reconcile` on each spoke's cluster Secret.

Every foundation gains `cluster_endpoint_public_access`, which this decision is
what makes meaningful.

## Rationale

- **It removes the requirement, rather than working around it.** With no
  inbound call to a spoke, a spoke's API server needs no public endpoint for
  delivery. That is a property of the topology, not a firewall rule somebody has
  to keep correct.
- **The credential shrinks by a lot.** A spoke's agent authenticates with a
  client certificate that grants nothing on any Kubernetes API. What replaced
  four cluster-admin bearer tokens is one CA private key — less total credential,
  though concentrated rather than spread, which is the honest way to state it.
- **A hub outage stops less.** Each spoke's own controller keeps its cluster
  matching whatever it last received. Promotions, the UI and any *change* to
  what a spoke should run still stop; reconciliation does not.
- **The delivery plane did not have to change shape.** Destination-based mapping
  routes on `spec.destination.name`, which the ApplicationSets already used —
  a spoke's API endpoint was never a stable thing to address. The only addition
  to [OneK8s-argocd](https://github.com/olljanat-ai/OneK8s-argocd) is a label.
- **ADR-0002 survives intact.** Applications are still created on the hub, in
  `argocd`, in the same namespace as Kargo, so `argocd-update` still resolves
  them through its own Kubernetes client. Managed mode is what preserves that;
  autonomous mode would not.

## Consequences

- **A spoke is no longer a plain cluster.** It runs Argo CD — roughly 1–2 vCPU
  and 2–4 GB — where it previously ran none. "There is no Argo CD on that
  cluster" is no longer what healthy looks like.
- **Each spoke fetches its own charts.** Egress to the applications repository
  becomes a per-spoke requirement, and a private repository would need
  credentials on every spoke rather than once on the hub.
- **The hub carries a PKI.** Four Secrets, minted by Terraform rather than by
  `argocd-agentctl` so that an extension reinstall does not silently rotate the
  CA and orphan every agent. Recovery from one is `terraform apply` on both
  stacks.
- **Argo CD 3.4 or later is required on the hub.** The `skip-reconcile`
  annotation is what stops the hub's controller from fighting the agents; on
  older versions there is no safe hybrid.
- **Two chart versions must move together**, and nothing enforces it.
- **Terraform still needs the spokes' API servers.** This decision removes the
  always-on, cluster-admin-shaped dependency; it does not remove the deploy-time
  one. `cluster_endpoint_public_access` therefore defaults to `true`, and
  turning it off is gated on running the stacks from inside each network — a
  self-hosted runner or a bastion, which no environment has yet.
- **A second public port** on the ingress load balancer, and one host that is
  deliberately not covered by the platform wildcard certificate.

## Alternatives considered

**Keep the push model and make the API servers private with peering or
tunnels.** The direct answer to the gap, and rejected on maintenance rather than
on principle: three networks on three clouds peered or tunnelled to one Azure
VNet, with three vendors' quirks, forever, so that one controller can make
outbound calls. It also leaves the cluster-admin credentials exactly where they
were.

**Autonomous agents instead of managed.** Each spoke would own its Applications
and report status back for a fleet view. Rejected because it breaks ADR-0002:
the Application objects would live on the spokes, and Kargo — which resolves an
Application by name and namespace through its own client — would have nothing to
promote. It would mean the delivery-plane repository, an ApplicationSet
controller and a Kargo on every cluster, which is the fragmentation ADR-0002
declined.

**The low-footprint agent pattern**, where the spoke runs only an
application-controller and borrows the hub's repo-server and redis through the
principal. Cheaper spokes, and rejected for what it does to the failure mode: it
makes every sync depend on the hub being up, which gives up the main operational
benefit of the change, and it needs more of the hub exposed rather than less.

**Replace the AKS Argo CD extension with a self-managed chart**, so the hub
could drop its application-controller and follow argocd-agent's plain
(non-hybrid) shape. Rejected: the extension is what buys Azure-owned upgrades,
the GitOps blade and the Entra integrations, and the hub is a deployment target
regardless — `hello`'s staging stage and `db-hello` run there — so it would need
a controller either way. The hybrid arrangement is upstream-documented and costs
one label.

**A dedicated LoadBalancer Service for the principal** instead of a passthrough
route on the existing ingress. Simpler by one Traefik object, and rejected for a
second public IP and a second A record per environment, when
`modules/platform-ingress` already carries a raw TCP entrypoint for Portainer's
Edge tunnel and needed nothing new.
