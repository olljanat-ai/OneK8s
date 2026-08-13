# `argocd-spoke`

One workload cluster attached to the Argo CD hub, over a connection the
cluster itself opens.

The module is cloud-agnostic: everything it needs to know about the cluster
arrives through the `kubernetes` and `helm` providers the caller passes in, so
EKS, GKE and OKE instantiate exactly the same code. The caller
(`gitops/main.tf`) is where the per-cloud split lives, because provider
configurations cannot be chosen per `for_each` instance.

## What it installs

| Component | Why it is here |
|---|---|
| Argo CD application controller, repo server, redis | A managed agent is not a self-contained Argo CD. The controller has to run next to the API server it reconciles against, and the agent feeds it Applications received from the hub. |
| `argocd-agent` agent | The only component in the topology that opens a connection between clusters — and it opens it *outbound*, to the hub. |
| `argocd-agent-ca`, `argocd-agent-client-tls` | The spoke's half of the mTLS identity. The CA certificate verifies the hub; the client certificate, whose CN is `agent_name`, is what the hub authenticates. |
| `argocd-agent-live-resources` ClusterRole (optional) | Cluster-wide **read**, so the hub's UI can render resource trees for this cluster's applications. The agent's own chart only grants access to Argo CD's resources. |

What it deliberately does **not** install is `argocd-server`: the UI and API
are the hub's job, and leaving them out is what keeps the spoke free of any
endpoint worth exposing. The community chart has no switch to omit a component
entirely, so `argocd-server` and the ApplicationSet controller are scaled to
zero instead — their Services and RBAC remain, inert.

## Inbound reachability: none

Nothing in this module opens a listening port to the outside world, and the
hub never dials the spoke. The agent dials `principal_address:principal_port`
and everything — application delivery, status, live resource reads, pod logs —
rides back down that one connection. A spoke behind NAT, with no public
address and no inbound firewall rule, works exactly the same as one with a
public API server.

The one connection this module *does* need is Terraform's own, from wherever
the apply runs to the cluster's API server. That is a deploy-time dependency,
not a runtime one.

## Modes

`agent_mode = "managed"` (the default) puts the hub in charge: Applications
are created there and pushed down, and the spoke reports status back.
`"autonomous"` inverts it — the spoke owns its Applications from its own git
and the hub becomes a read-only mirror that can still sync, refresh and act on
resources.

`destination_based_mapping` (managed mode only) routes by
`spec.destination.name` rather than by which namespace an Application sits in
on the hub. It has to match the principal's setting.

## Usage

```hcl
module "spoke_aws" {
  source = "../modules/argocd-spoke"

  providers = {
    kubernetes = kubernetes.aws
    helm       = helm.aws
  }

  agent_name        = "aws-prototype"
  principal_address = "argocd-agent-aks-onek8s-prototype.swedencentral.cloudapp.azure.com"

  ca_cert_pem     = tls_self_signed_cert.ca.cert_pem
  client_cert_pem = tls_locally_signed_cert.agent["aws"].cert_pem
  client_key_pem  = tls_private_key.agent["aws"].private_key_pem
}
```

Then, on the hub:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd          # the hub's own namespace — no apps-in-any-namespace needed
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps
    path: guestbook
    targetRevision: HEAD
  destination:
    name: aws-prototype      # the agent_name above; this is the routing key
    namespace: guestbook
  syncPolicy:
    automated: {}
    syncOptions: [CreateNamespace=true]
```
