# portainer-agent module

Installs the **Portainer Edge Agent** on one cluster, so the Portainer
Business Edition server on the AKS hub (`foundations/azure/portainer.tf`) can
manage it. The `portainer/` stack calls this once per spoke, after creating
the environment on the server that hands out the `edge_id` / `edge_key` pair.

```
spoke cluster (kubernetes)                 AKS hub
─────────────────────────────────          ────────────────────────────────
Deployment      portainer-agent   ──poll──▶ https://portainer.onek8s.lol
ConfigMap       portainer-agent-edge         (EDGE_ID identifies which
Secret          portainer-agent-edge-key      environment is calling)
Service         portainer-agent (headless)
ServiceAccount  portainer-sa-clusteradmin
ClusterRoleBinding portainer-crb-clusteradmin ──tunnel──▶ portainer.onek8s.lol:8000
```

```hcl
module "agent_aws" {
  source = "../modules/portainer-agent"

  providers = { kubernetes = kubernetes.aws }

  cloud       = "aws"
  environment = var.environment
  edge_id     = portainer_environment.spoke["aws"].edge_id
  edge_key    = portainer_environment.spoke["aws"].edge_key
}
```

## Why the Edge Agent and not the standard one

Both agents give Portainer the same view of a cluster; they differ in who
dials whom.

- The **standard agent** is dialled *into*: the server opens a TLS connection
  to the agent's address. On EKS, GKE and OKE that means publishing an
  endpoint with cluster-admin behind it on each of them, and keeping it
  reachable from AKS. The platform's own ingress would be carrying a
  cluster-admin API on three clouds.
- The **Edge Agent** dials *out*: it polls the Portainer URL over HTTPS and,
  only while an operator is looking at that environment, opens a reverse
  tunnel back to the same host. Nothing on the spoke has to be reachable from
  anywhere, and the whole credential is one Edge key.

The Edge key is also the revocation story: deleting the environment on the
server invalidates it, and the agent that holds it can then do nothing.

## What it grants

`cluster-admin`, bound to the agent's ServiceAccount — which is what
Portainer's own published manifest does and what the product assumes. The
agent *is* the operator's hands on that cluster: it lists and edits every
namespaced object, streams logs, opens shells. Binding something narrower is
possible (`cluster_role = "view"`) and turns parts of the Portainer UI into
errors rather than into a read-only view, so it is a deliberate choice rather
than a default.

This is a wider grant than the `argocd-manager` ServiceAccount the Argo CD
spoke registration creates, and the reason is the same difference in purpose:
Argo CD applies a known set of manifests, Portainer is an interactive console.

## Inputs worth knowing

| Variable | Why it exists |
|---|---|
| `edge_id`, `edge_key` | Come from the server (`portainer_environment`), never invented here. Changing either restarts the agent — both are read at start-up only. |
| `insecure_poll` | `EDGE_INSECURE_POLL=1`, for a Portainer published with a certificate the agent cannot chain. Not needed behind the platform wildcard, and the first thing to reach for when an agent will not connect. |
| `agent_version` | Keep it in step with the server; the Edge protocol is versioned with it. |
| `cluster_role` | See above. |

## Known gaps

- The agent is a single replica. Portainer supports scaling it (the headless
  Service is how the replicas find each other), but nothing here does.
- Nothing rotates the Edge key. Re-creating the environment on the server
  issues a new one and this module rolls the agent onto it, which is the
  rotation path.
