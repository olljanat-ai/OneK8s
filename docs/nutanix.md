# The private cloud: NKP + HashiCorp Vault

OneK8s' fifth cloud is not a cloud. `foundations/nutanix` is a **Nutanix
Kubernetes Platform (NKP)** workload cluster paired with a **HashiCorp Vault**
KV v2 mount, and it carries exactly the same tenant contract as AKS, EKS, GKE
and OKE: a namespace with a quota and two NetworkPolicies, a dedicated
identity pinned to that namespace's ServiceAccount, a **namespaced**
`SecretStore`, and a **prefix-scoped** grant on the shared secret backend that
is enforced *outside* Kubernetes.

```hcl
# tenants/envs/prototype.tfvars — the private cloud is just a tenant attribute
tenants = {
  azure-team-alpha   = { cloud = "azure",   name = "team-alpha" }
  nutanix-team-alpha = { cloud = "nutanix", name = "team-alpha" }
}
```

NKP **Starter** is what this is built against, because it is included with NCI
Pro and Ultimate — no separate purchase, and nothing here depends on a Pro or
Ultimate feature. Starter is supported on Nutanix AHV only, which is exactly
the "private cloud" case this foundation is for.

## Why Vault is the identity plane, not just the secret store

On the four public clouds the tenant boundary is a *cloud IAM* rule: a Key
Vault ABAC condition, a Secrets Manager ARN prefix, a Secret Manager IAM
condition, an OCI policy condition. A private cloud has no such plane —
Nutanix has no per-pod identity service, and Kubernetes RBAC alone would put
the boundary back inside the cluster, which is precisely what
[ADR-0001](adr/0001-per-tenant-identities-and-namespaced-secretstores.md)
rejects.

Vault's **Kubernetes auth method** is the missing plane, and it has the same
shape as workload identity federation:

```
Pod ──runs as──▶ ServiceAccount
                   │  token projected by ESO, audience "vault"
                   ▼
                 Vault  ──TokenReview against THIS cluster──▶  role
                   │            bound_service_account_names/_namespaces
                   ▼
                 policy: read "<mount>/data/<tenant>-*"  and nothing else
```

Three things follow, and they are the reasons this is the design rather than,
say, a Vault token in a Kubernetes Secret:

1. **The decision is made outside the cluster.** Vault, not the API server,
   decides what a token may read. A cluster-admin mistake in a tenant
   namespace does not widen a tenant's secret access, exactly as it does not
   on the public clouds.
2. **There is no credential to leak.** Nothing is stored anywhere: the login
   is a ServiceAccount token the cluster mints on demand, for the audience
   `vault`, and Vault verifies it by asking that same cluster's TokenReview
   API about it.
3. **The prefix is the boundary, again.** The tenant's policy grants `read` on
   `<mount>/data/<tenant>-*` and `<mount>/metadata/<tenant>-*`. Vault allows a
   wildcard only as the last character of a path, so this is a prefix match —
   the same rule the other four clouds' conditions express.

What a tenant policy deliberately does *not* grant:

| Not granted | Consequence |
|---|---|
| `list` anywhere | a tenant cannot enumerate the mount, so it cannot discover that other tenants exist. ESO's `dataFrom.find` will not work; `dataFrom.extract` and `remoteRef.key` will — the same trade-off as OCI |
| `create` / `update` | a tenant reads its secrets and never writes them. Publishing into the vault is the platform's job on every cloud |
| any path outside `<tenant>-` | including `platform-`, which holds the wildcard certificate's private key |

## What the foundation creates

```
foundations/nutanix
├── nkp.tf        the cluster: optional Cluster API manifests + reading its kubeconfig
├── vault.tf      the vault: KV v2 mount, Kubernetes auth mount, platform role
├── eso.tf        External Secrets Operator
├── ingress.tf    Traefik + the platform wildcard, read out of Vault
└── outputs.tf    what tenants/ and gitops/ consume
```

| Object | What it is |
|---|---|
| `vault_mount` `<name_prefix>-<env>` | the environment's KV v2 mount — this cloud's "vault" |
| `vault_auth_backend` `kubernetes-<name_prefix>-<env>` | one Kubernetes auth mount **per cluster**, so a role name means one cluster's assertions |
| `vault-auth/vault-token-reviewer` (+ `system:auth-delegator`) | the credential Vault presents when it asks the cluster whose token a login is |
| `vault_policy` + role `platform-ingress-…` | the platform's own identity, scoped to `platform-*` |
| ESO, Traefik | the same two components every other foundation installs |

No CNI is installed: **NKP ships Cilium**, so the NetworkPolicy enforcement the
tenant module depends on is already there. Installing a second CNI would fight
it. If NKP's own Traefik platform application is enabled on the cluster, turn
it off — this foundation installs the platform's Traefik from
`modules/platform-ingress`, the same one the other four clouds run.

### Why the token reviewer exists

Vault runs outside the cluster, so it cannot use a token of its own to call
TokenReview; it needs a reviewer credential. The alternative Vault supports —
reviewing each login with the *client's* own token — would mean granting
`system:auth-delegator` to every tenant ServiceAccount. Configuring one
reviewer instead keeps tenants out of the TokenReview API entirely.

The cost is a long-lived ServiceAccount token in `foundations/nutanix`'s state,
which is the same trade (and the same mitigation — the state home's RBAC) as
the spoke tokens in `gitops/<env>.tfstate`.

## Prerequisites

1. **An NKP management cluster**, and a ServiceAccount on it whose token can
   read the workload cluster's namespace. Nothing else about Nutanix is
   configured here: Prism Central credentials belong to NKP, which holds them
   in the Secret its own cluster manifests reference.
2. **A workload cluster** managed by that NKP. Create it the way NKP is meant
   to be used:

   ```bash
   nkp create cluster nutanix \
     --cluster-name onek8s-prototype \
     --control-plane-endpoint-ip <vip> \
     --namespace kommander-default-workspace \
     ...
   ```

   Terraform then **attaches** to it — the default, and what CI does. To have
   this stack create it instead, generate the manifests and point
   `cluster_manifests_dir` at them:

   ```bash
   nkp create cluster nutanix --cluster-name onek8s-prototype ... \
     --dry-run -o yaml > foundations/nutanix/cluster/prototype.yaml
   ```

   The manifests are generated rather than written by hand on purpose: the
   shape of an NKP cluster belongs to the product and would drift from a
   hand-rolled copy. **They contain the Prism Central credential Secret**, so
   `foundations/nutanix/cluster/` is git-ignored — that path is for a local
   apply, not for CI.

   Either way the credentials come from the same place afterwards: the Cluster
   API `<cluster>-kubeconfig` Secret on the management cluster, read by
   [`modules/nkp-cluster-access`](../modules/nkp-cluster-access/README.md).
   That Secret is this cloud's `aws eks get-token`.
3. **A Vault server** reachable from the runner *and* from the cluster, with a
   token that may create mounts, policies and auth roles. Vault's own
   deployment is out of scope here for the same reason Prism Central is: it is
   the platform's prerequisite, not one of its stacks. It must be **Vault
   1.21 or newer**, or the audience the roles require is not enforced.
4. **MetalLB** (or another `type: LoadBalancer` implementation) for the
   ingress Service. `ingress_load_balancer_ip` pins the address the DNS
   records point at.

## Credentials

Coordinates come from configuration and state; credentials come from the
environment — the same rule as every other cloud.

| Variable | Where |
|---|---|
| `TF_VAR_nkp_management_token` | GitHub secret `NKP_MANAGEMENT_TOKEN`; used by `foundations/nutanix`, `tenants` and `gitops` |
| `VAULT_TOKEN` | GitHub secret `VAULT_TOKEN`; read by the `vault` provider directly |
| `vault_address`, `nkp_management_host`, … | `envs/<env>.tfvars` in the foundation, and its **outputs** for the other two stacks |

```bash
cd foundations/nutanix
export TF_VAR_nkp_management_token="$(kubectl -n kube-system create token onek8s-deployer --duration=1h)"
export VAULT_TOKEN=...
terraform init -backend-config=backend/prototype.hcl
terraform apply -var-file=envs/prototype.tfvars
```

**Nothing here is reachable from a GitHub-hosted runner.** The management
cluster, the workload cluster and Vault all sit on an internal network, so the
`nutanix` foundation job runs on whatever the repository variable
`NUTANIX_RUNNER` names, and the all-clouds `tenants`/`gitops` jobs — which now
cover the private cloud too — run on `ONEK8S_RUNNER`. Both default to
`ubuntu-latest`, which is correct until a private cloud exists.

## Secrets

Naming is the platform's usual contract, with one wrinkle that comes from KV
v2: a Vault secret is a **map of fields**, not an opaque value.

| | Path | Fields |
|---|---|---|
| Tenant secret | `<mount>/<tenant>-<name>` | whatever the secret needs |
| Platform wildcard | `<mount>/platform-wildcard-onek8s-lol` | `tls.crt`, `tls.key` |

```bash
# publish a tenant secret (as the platform, not as the tenant)
vault kv put onek8s-prototype/team-alpha-db-password password=…
```

```yaml
# consume it from a tenant workload — the only cloud-specific line is "property"
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-db
  namespace: team-alpha
spec:
  secretStoreRef:
    kind: SecretStore
    name: tenant-store
  target:
    name: app-db
  data:
    - secretKey: password
      remoteRef:
        key: team-alpha-db-password
        property: password
```

The wildcard certificate is published by the Renew Certificate workflow's
`distribute` mode, which writes `{tls.crt, tls.key}` as one KV v2 secret —
the same single atomic version the other three clouds get, so the ingress
`ExternalSecret` uses `dataFrom.extract` here exactly as it does there.

## Argo CD

The cluster is registered as an ordinary **spoke** of the AKS hub: a
`argocd-manager` ServiceAccount and a scoped ClusterRole on the cluster, and a
labelled `cluster` Secret on the hub holding its token. Nothing about it is
private-cloud-shaped — a spoke is registered with plain Kubernetes RBAC
everywhere — except how `gitops/` reaches the cluster in the first place,
which is the same NKP kubeconfig Secret again.

```hcl
# gitops/envs/prototype.tfvars
spokes = {
  aws     = {}
  gcp     = {}
  oci     = {}
  nutanix = {}
}
```

The `hello` ApplicationSet picks it up with no change at all: its cluster
generator selects on `onek8s.io/environment`, so the new spoke produces
`hello-nutanix` on `https://nutanix-hello.onek8s.lol` the moment it is
registered.

## Verifying the boundary

```bash
# the tenant's own secret: works
kubectl -n team-alpha get externalsecret hello -o jsonpath='{.status.conditions[0]}'

# another tenant's: Vault refuses, and the ExternalSecret says so
kubectl -n team-alpha apply -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: cross-tenant, namespace: team-alpha }
spec:
  secretStoreRef: { kind: SecretStore, name: tenant-store }
  target: { name: cross-tenant }
  data:
    - secretKey: x
      remoteRef: { key: team-beta-test, property: test }
EOF
kubectl -n team-alpha get externalsecret cross-tenant
# SecretSyncedError — permission denied, from Vault, not from Kubernetes
```

Vault's audit log records the login and the denial with the tenant's role as
the principal, which is the private cloud's version of "per-tenant audit
trails for free".

## Known limits

- **Vault is a component the platform now operates.** The four public clouds'
  secret backends are managed services; this one is a server someone has to
  keep sealed/unsealed, backed up and upgraded. A Vault outage stops secret
  refreshes on this cloud (running pods keep the Secrets they already have).
- **The reviewer token is long-lived and unrotated**, and lives in the
  foundation's state. See above.
- **The workload cluster's kubeconfig is a cluster-admin credential** and is
  read into `tenants`' and `gitops`' state as well. The alternative — a
  narrower ServiceAccount per stack, created on the cluster out of band —
  would mean a credential this platform does not otherwise have.
- **No cluster lifecycle in Terraform by default.** `cluster_manifests_dir` is
  opt-in and its input is generated by the NKP CLI; the honest reading is that
  NKP owns cluster lifecycle and OneK8s owns the platform layer above it.
- **Prefix collision.** `team-alpha-*` also matches a tenant literally named
  `team-alpha-x`. That is inherited from the naming convention every cloud
  here uses, not specific to Vault.
- **A cold apply that also creates the cluster may need a second run.** Cluster
  API writes the kubeconfig Secret as soon as it has minted the cluster CA,
  which is well before the API server answers, so the Helm releases in the same
  apply can hit a cluster that is not up yet. Re-running the apply once the
  cluster is `Ready` is the whole fix — and it does not arise in the default
  attach mode, where the cluster was already running before Terraform saw it.
