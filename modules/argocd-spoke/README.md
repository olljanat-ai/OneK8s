# `argocd-spoke`

Attaches one `foundations/<cloud>` cluster to the Argo CD hub that
`foundations/azure` runs on AKS, using
[argocd-agent](https://github.com/argoproj-labs/argocd-agent).

The module's name has not changed and neither has its place in the platform.
What changed is the direction of the arrow.

```
BEFORE                                     NOW
──────────────────────────────────────     ──────────────────────────────────────
hub ──── kubectl-equivalent calls ────▶    hub ◀──── one gRPC stream ──── spoke
          to the spoke's PUBLIC API                  opened BY the spoke
          with a cluster-admin token                 with a client certificate
                                                     that grants nothing anywhere
```

Nothing on the hub contacts the spoke any more, which is the point: a spoke's
Kubernetes API server no longer has to be reachable from outside its own
network for delivery to work.

## What it creates

```
spoke cluster (kubernetes, helm)             hub cluster (kubernetes.hub)
─────────────────────────────────────        ──────────────────────────────────
Namespace       argocd                       Secret cluster-<name> in argocd
Secret          argocd-agent-ca                argocd.argoproj.io/secret-type=cluster
                  (ca.crt only)                argocd-agent…/agent-name=<name>
Secret          argocd-agent-client-tls        argocd.argoproj.io/skip-reconcile
                  (CN = <name>)                data.server  = the principal's
Release         argo-cd                                       resource proxy
                  application-controller       data.config  = a client certificate
                  repo-server                                 for that proxy
                  redis
                  (no server, no dex,
                   no applicationset)
ClusterRole     argocd-application-controller-role
  + binding(s)
ClusterRole     argocd-agent-resources  (read-only, for the resource proxy)
Release         argocd-agent  (managed mode)  ──── dials the principal ────▶
```

Two certificates are issued per spoke, both signed by the hub's argocd-agent CA
and both with the agent's name as their common name. One is the agent's, and it
is the whole of its identity — the principal is configured with
`mtls:CN=([^,]+)`, so the certificate *is* the authentication. The other is Argo
CD's, for reaching the principal's resource proxy on the hub. Neither grants
anything on any Kubernetes API.

## Usage

```hcl
module "spoke_aws" {
  source = "../modules/argocd-spoke"

  providers = {
    kubernetes     = kubernetes.aws     # the spoke
    kubernetes.hub = kubernetes.azure   # AKS, where Argo CD and the principal run
    helm           = helm.aws           # the spoke, again
  }

  cloud       = "aws"
  environment = "prototype"
  foundation  = data.terraform_remote_state.aws.outputs
  principal   = local.principal          # from the hub's outputs
  ca          = local.argocd_agent_ca    # read from the hub's Secret
}
```

In practice it is called by `gitops/`, which builds `principal` and `ca` out of
the hub's foundation state and its `argocd-agent-ca` Secret. There is no reason
to call it directly.

## Managed mode, destination-based mapping

An agent can be *managed* (the hub is the source of truth) or *autonomous* (the
spoke is, and reports back). This platform uses managed, and could not
reasonably use anything else: the ApplicationSets that generate Applications and
the Kargo that promotes between them both live on the hub, and Kargo addresses
an `Application` by name and namespace through its own Kubernetes client
([ADR-0002](../../docs/adr/0002-one-argo-cd-on-the-hub.md)). An autonomous spoke
would need a copy of the delivery-plane repository, an ApplicationSet controller
and a Kargo of its own.

Routing is **destination-based**: the principal reads an Application's
`spec.destination.name` to decide which agent it belongs to. The alternative —
namespace-based, argocd-agent's default — would route on the Application's
namespace and require one namespace per agent on the hub. Destination-based
routing is why the delivery-plane repository needed no structural change at all:
an ApplicationSet already addresses a cluster by the name Argo CD knows it by,
and that name is now also the agent's name.

## Argo CD on a spoke

A managed agent does not apply anything itself. It hands the Application to a
local Argo CD, and that cluster's own `application-controller` reconciles it —
so the spoke needs a real, if trimmed, Argo CD:

| Component | On the spoke | Why |
|---|---|---|
| `application-controller` | **yes** | it is what applies manifests and reports health |
| `repo-server` | **yes** | renders the charts, fetching them itself |
| `redis` | **yes** | caches what those two produce |
| `server` (API/UI) | no | there is one UI and it is the hub's |
| `applicationset-controller` | no | Applications are generated on the hub |
| `dex`, `notifications` | no | nothing signs in here, nothing notifies from here |

The three absent components are set to zero replicas rather than removed,
because the upstream chart has no switch for them.

This is argocd-agent's *fully autonomous workload cluster* pattern, which is
what upstream recommends. The alternative shares the hub's repo-server and redis
and leaves only the controller on the spoke — cheaper, but it makes every sync
depend on the hub being up and needs more of the hub exposed. Here a hub outage
costs promotions and visibility, not reconciliation.

The cost is real and worth stating: roughly 1–2 vCPU and 2–4 GB per spoke, and
each spoke's repo-server fetches the applications repository over the internet
itself, so a spoke needs egress to GitHub that it did not need before.

## Scoping a spoke

`cluster_role_rules` defaults to everything, which is what the upstream chart
grants: Argo CD has to be able to apply whatever a repository holds. Two
variables narrow it, and they mean exactly what they always did:

```hcl
spokes = {
  aws = { namespaces = ["team-alpha", "team-beta"], cluster_resources = false }
}
```

That combination is enforced **twice** — Argo CD on the hub refuses Applications
targeting anything else, and the spoke's `application-controller` is bound with
a `RoleBinding` per namespace instead of a `ClusterRoleBinding`, so its own API
server refuses too. Any other combination binds at cluster scope.

The chart's own cluster-scoped RBAC is turned off (`createClusterRoles = false`)
so that this module is the only answer to "what may Argo CD do here".

`agent_cluster_role_rules` is a separate question: what the **agent** may read,
which is what fills the resource tree under an Application in the hub's UI. It
is read-only on everything by default. Widening it to read-write would make the
resource proxy a second path onto the cluster that no `Application` and no
`AppProject` constrains.

## The hybrid boundary

The hub runs a full Argo CD — it has to, it is also a deployment target: the
`hello` application's staging stage and `db-hello` both run there. So two
application-controllers exist in one delivery plane, and they are kept apart by
two mechanisms, both of which this module depends on:

- **A label.** The principal and every agent only look at Applications,
  AppProjects and repository Secrets carrying `principal.label_selector`.
  Everything without it stays the hub controller's. The delivery-plane chart
  puts it on the objects that belong to a spoke.
- **An annotation.** The cluster Secret written here carries
  `argocd.argoproj.io/skip-reconcile: "true"`, which tells the hub's controller
  to skip every Application targeting this cluster. **It requires Argo CD 3.4 or
  later on the hub.** On anything older the two controllers reconcile the same
  Application against each other.

## Known gaps

- **The CA private key is in Terraform state.** `gitops/<env>.tfstate` holds it
  while it signs each agent's certificates, and the hub holds it in a Secret.
  Anything with it can mint an identity for any agent. It is strictly less than
  what it replaced — a cluster-admin bearer token for every spoke, in the same
  state file — but it is now a single key rather than four separate ones.
- **Certificates are rotated by an apply.** They renew a month before expiry
  (`client_certificate_early_renewal_hours`), so an environment that is never
  applied will eventually have agents that cannot connect. Nothing warns first.
- **The two chart versions have to move together.** `agent_chart_version` here
  and `argocd_agent_chart_version` on the hub speak a versioned protocol to each
  other; nothing in Terraform checks that they agree.
- **A spoke fetches its own charts.** Egress to the applications repository is a
  new requirement on every spoke, and a private repository would need
  credentials distributed to each of them rather than held once on the hub.
