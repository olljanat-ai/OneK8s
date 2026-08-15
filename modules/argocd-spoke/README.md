# argocd-spoke module

Registers one `foundations/<cloud>` cluster as a **spoke** of the Argo CD
**hub** that `foundations/azure` runs on AKS. The cloud is a variable, the
same way it is in `modules/tenant-namespace` — but unlike that module this one
has no per-cloud submodules, because a spoke is registered with plain
Kubernetes RBAC on every cloud — the private one included.

```
spoke cluster (kubernetes)              hub cluster (kubernetes.hub)
──────────────────────────────          ───────────────────────────────────────
ServiceAccount  argocd-manager
ClusterRole     argocd-manager-role     Secret cluster-<name>, labelled
  + ClusterRoleBinding                    argocd.argoproj.io/secret-type=cluster
  (or a RoleBinding per namespace)        onek8s.io/cloud=<aws|gcp|oci>
Secret          argocd-manager-token ──▶  data.config.bearerToken
```

Two `kubernetes` provider configurations therefore have to be passed: the
default one is the spoke, `kubernetes.hub` is the AKS cluster.

```hcl
module "spoke_aws" {
  source = "../modules/argocd-spoke"

  providers = {
    kubernetes     = kubernetes.aws
    kubernetes.hub = kubernetes.azure
  }

  cloud       = "aws"
  environment = var.environment
  foundation  = data.terraform_remote_state.spoke["aws"].outputs
  hub         = data.terraform_remote_state.hub.outputs
}
```

`foundation` is the whole outputs object of `foundations/aws` (it reads
`cluster_name`, `cluster_endpoint`, `cluster_ca_certificate`), and `hub` the
whole outputs object of `foundations/azure` (`argocd_namespace`, and
`argocd_url` to prove the extension is actually enabled). Both are validated
for emptiness with a message naming the cloud, the environment and the blob
key, so a missing foundation fails the same way it does in the tenants stack.

## Why a ServiceAccount token and not the cloud's kubeconfig

Argo CD supports cloud-native cluster credentials (`awsAuthConfig`,
`execProviderConfig`), but every one of them would need that cloud's
credentials *on the hub* — AWS keys, a GCP service account key, an OCI signing
key sitting in AKS — which is exactly the sprawl the platform avoids
everywhere else. The private cloud has no such mode at all: NKP hands out a
kubeconfig, and putting *that* on the hub would be handing it cluster-admin.
A ServiceAccount bearer token minted on the spoke:

- works identically on EKS, GKE, OKE and NKP, so there is one registration path
  rather than four;
- carries precisely the rights of the ClusterRole below and nothing else,
  where an admin kubeconfig carries the cloud's full control-plane rights;
- is revoked by deleting one ServiceAccount on one cluster.

The token comes from an explicitly created
`kubernetes.io/service-account-token` Secret. Kubernetes 1.24+ no longer mints
those automatically, and the tokens projected into pods are short-lived and
audience-bound, so neither is usable by a controller on another cluster;
`wait_for_service_account_token` holds the apply until the token controller
has filled the Secret in. It does not expire and nothing rotates it — see the
trade-offs in [../../docs/argocd.md](../../docs/argocd.md).

## Scoping what a spoke may run

| Variable | Effect |
|---|---|
| `cluster_role_rules` | Rules of the ClusterRole. Default: everything, which is what `argocd cluster add` grants — Argo CD has to be able to apply whatever a repository holds. |
| `namespaces` | Namespaces Argo CD may deploy into. Empty (default) means all. |
| `cluster_resources` | Whether cluster-scoped resources are in play. Only meaningful with `namespaces` set. |

`namespaces` + `cluster_resources = false` is enforced **twice**: Argo CD
refuses Applications targeting anything else, and the manager ServiceAccount
is bound with a `RoleBinding` per namespace instead of a `ClusterRoleBinding`,
so the API server refuses too. Any other combination binds at cluster scope.

## Labels are the fan-out surface

An `ApplicationSet` cluster generator selects on the labels of the cluster
Secret, so the labels this module sets are the API for "deploy this
everywhere" / "deploy this on AWS only":

| Label | Value |
|---|---|
| `argocd.argoproj.io/secret-type` | `cluster` — how Argo CD finds it at all |
| `onek8s.io/cloud` | `aws` \| `gcp` \| `oci` \| `nutanix` |
| `onek8s.io/environment` | the environment the foundations were deployed for |
| `onek8s.io/spoke` | the name Argo CD knows the cluster by (`{{name}}`) |

`var.labels` is merged last, so a spoke can carry extra selectors.

## Notes

- The hub cluster itself is never registered here: Argo CD always has the
  in-cluster `https://kubernetes.default.svc` entry, which is the AKS cluster.
- Only ordinary Kubernetes resources are used — no `kubernetes_manifest` — so
  both clusters have to be reachable at apply time but not at plan time.
- The bearer token is read back into Terraform state. That is the reason the
  state home is the only place it lives; see the trade-off note in
  [../../docs/architecture.md](../../docs/architecture.md).
