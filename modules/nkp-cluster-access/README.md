# nkp-cluster-access module

Reads an **NKP-managed workload cluster's credentials out of the NKP
management cluster**, so a stack that has to talk to that cluster needs no
kubeconfig file handed to it out of band.

```
NKP management cluster (kubernetes provider passed in)
  └── Secret <cluster>-kubeconfig   (namespace: the cluster's workspace)
        data.value ──▶ host, cluster_ca_certificate, client_certificate, client_key
```

NKP manages workload clusters with Cluster API, and Cluster API publishes each
cluster's admin credential as a `<cluster>-kubeconfig` Secret in the cluster's
own namespace. That Secret is the private cloud's counterpart of
`aws eks get-token`, `gcloud container clusters get-credentials` and
`oci ce cluster generate-token`: there is no cloud IAM plane to mint a cluster
token from, so the credential comes from the component that owns the cluster's
lifecycle — NKP.

```hcl
module "cluster" {
  source = "../modules/nkp-cluster-access"

  providers = { kubernetes = kubernetes.nkp }

  cluster_name      = "onek8s-prototype"
  cluster_namespace = "kommander-default-workspace"
}

provider "kubernetes" {
  alias = "workload"

  host                   = module.cluster.host
  cluster_ca_certificate = base64decode(module.cluster.cluster_ca_certificate)
  client_certificate     = try(base64decode(module.cluster.client_certificate), null)
  client_key             = try(base64decode(module.cluster.client_key), null)
}
```

The module creates nothing — it is one data source and the parsing of what it
returns. Both `foundations/nutanix` and `gitops` use it, which is the point:
the layout of that Secret is known in one place.

## Outputs and sensitivity

| Output | Sensitive | Notes |
|---|---|---|
| `host` | no | API server URL, a complete `https://…` |
| `cluster_ca_certificate` | no | base64 PEM, as every other foundation publishes it |
| `client_certificate` / `client_key` | yes | the credential; null if the kubeconfig uses a token |
| `token` | yes | null if the kubeconfig uses a client certificate (Cluster API's default) |

The Secret's `data` is sensitive as a whole, so everything derived from it
inherits that mark. The address and the CA are unmarked deliberately: they are
not secret, and every other foundation publishes them as plain outputs.

## Notes

- On a cold apply the cluster may not exist yet. Order the module after
  whatever creates it (`depends_on` on the module block) and Terraform defers
  the read to apply time.
- The credential is a cluster-admin one, and reading it into Terraform means it
  lands in that stack's state — the same trade-off, and the same mitigation
  (the state home's RBAC), as the spoke tokens in `gitops/<env>.tfstate`.
  See [../../docs/architecture.md](../../docs/architecture.md), "Known
  trade-offs".
