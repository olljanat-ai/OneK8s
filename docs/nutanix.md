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

### What the public clouds actually do

It is worth being precise about this, because the mechanism is not a cloud
feature at all. **The Kubernetes API server is an OIDC provider.** It signs
ServiceAccount tokens with its own key, publishes the matching *public* keys
at `/openid/v1/jwks`, advertises them at
`/.well-known/openid-configuration`, and stamps every token with three claims
that matter:

| Claim | Value |
|---|---|
| `iss` | the cluster's issuer |
| `sub` | `system:serviceaccount:<namespace>:<serviceaccount>` |
| `aud` | whatever audience the token was requested for |

What AKS, EKS, GKE and OKE add is **hosting and registration**: they serve
that discovery document at a public URL and register it as a trusted identity
provider in their IAM service. The exchange itself is ordinary OIDC
federation:

```
Pod ──▶ projected SA token (iss, sub, aud, ~1h)
          │
          ▼
   AWS STS / Entra ID / Google STS
          ├─ verify the signature against the cluster's published JWKS
          ├─ iss must be the registered provider
          ├─ aud must be sts.amazonaws.com / api://AzureADTokenExchange / …
          └─ sub must be what the role's trust policy names
          ▼
   short-lived cloud credential, scoped by the role's policy
```

**Nothing calls back into the cluster.** `AssumeRoleWithWebIdentity` does not
ask the API server whether a token is still valid; it verifies a signature and
matches strings. No credential for the cluster is stored anywhere in the cloud,
and no credential for the cloud is stored anywhere in the cluster.

### The same thing, with Vault as the relying party

Vault's **JWT auth method** is exactly that relying party, so the private
cloud gets the mechanism rather than an imitation of it:

```
Pod ──▶ SA token (aud "vault", 10 min, minted on demand by TokenRequest)
          │
          ▼
   Vault jwt mount
          ├─ verify the signature against this cluster's published JWKS
          ├─ iss must be this cluster        (bound_issuer)
          ├─ aud must be "vault"             (bound_audiences)
          └─ sub must be system:serviceaccount:team-alpha:workload
                                             (bound_subject)
          ▼
   Vault token whose policy reads "<mount>/data/team-alpha-*" and nothing else
```

Line for line, that is the AWS diagram with different proper nouns. The
`bound_subject` is character-for-character the string an IRSA trust policy
pins.

Four properties follow, and all four are shared with the public clouds:

1. **Vault holds no credential for the cluster, and has no permission in it.**
   It reads one unauthenticated endpoint — the same public keys AKS, EKS, GKE
   and OKE republish to the whole internet.
2. **The cluster holds no credential for Vault.** The login is a token the API
   server mints on demand, for the audience `vault`, valid ten minutes.
3. **The decision is made outside the cluster.** A cluster-admin mistake in a
   tenant namespace does not widen a tenant's secret access.
4. **The prefix is the boundary.** Vault allows a wildcard only as the last
   character of a path, so `<mount>/data/<tenant>-*` is a prefix match — the
   same rule the other four clouds' conditions express.

The one property it does *not* have is revocation-by-callback: a token stays
valid until it expires, because nobody asks the cluster about it. That is not
a shortcut — it is the same trade AWS, Azure and Google make, and it is why
the tokens are minted for ten minutes rather than hours.

> **An earlier draft of this used Vault's Kubernetes auth method instead**,
> which validates each login by calling the cluster's TokenReview API. It
> works, but it inverts the direction of trust: Vault needs a network path
> into the cluster and a long-lived `system:auth-delegator` ServiceAccount
> token to authenticate with, stored in Terraform state. No public cloud
> works that way, and the private cloud does not have to either.

### Publishing the cluster as an OIDC provider

The one thing a managed cloud genuinely does for free is *hosting* the
discovery document. Kubernetes ships the `system:service-account-issuer-discovery`
ClusterRole but binds it only to `system:serviceaccounts`, so the endpoints are
readable from inside the cluster and nowhere else. The foundation binds it to
`system:unauthenticated` — which is what HashiCorp's own
Kubernetes-as-an-OIDC-provider guide prescribes, and a far smaller exposure
than what the managed clouds do, since these endpoints carry an issuer URL and
public keys and nothing else:

```bash
# what the foundation creates, in kubectl terms
kubectl create clusterrolebinding onek8s-oidc-reviewer \
  --clusterrole=system:service-account-issuer-discovery \
  --group=system:unauthenticated
```

Three variables cover the three ways a private cloud usually settles this; all
three defaults suit a stock NKP cluster, where nothing about the API server has
to change:

| Variable | When |
|---|---|
| *(defaults)* | Vault fetches the JWKS from the API server's own `/openid/v1/jwks`, and the issuer is read out of the cluster's discovery document so it cannot drift |
| `cluster_oidc_discovery_url` | the cluster was configured with an externally resolvable `--service-account-issuer` — the "exactly like EKS" setup, where Vault runs full OIDC discovery |
| `cluster_issuer` + `cluster_jwks_url` | the discovery documents are published somewhere else (a static URL, the way EKS publishes them), or the API server runs with anonymous authentication disabled |

Note that the JWKS URL is deliberately **not** the `jwks_uri` from the
discovery document: that URL is derived from the issuer, and a stock cluster's
issuer is `https://kubernetes.default.svc.cluster.local`, which resolves only
inside the cluster.

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
| `vault_jwt_auth_backend` `jwt-<name_prefix>-<env>` | one JWT mount **per cluster**, bound to that cluster's issuer and signing keys |
| ClusterRoleBinding `onek8s-oidc-reviewer` | publishes the cluster's OIDC discovery endpoints, so Vault can fetch the public keys without holding any credential |
| `vault_policy` + role `platform-ingress-…` | the platform's own identity, scoped to `platform-*` |
| ESO, Traefik | the same two components every other foundation installs |

Note what is **not** in that list: no ServiceAccount for Vault, no RBAC for it,
no token anywhere. The only long-lived credential the private cloud adds is the
NKP management-cluster token the stacks read the workload kubeconfig with.

No CNI is installed: **NKP ships Cilium**, so the NetworkPolicy enforcement the
tenant module depends on is already there. Installing a second CNI would fight
it. If NKP's own Traefik platform application is enabled on the cluster, turn
it off — this foundation installs the platform's Traefik from
`modules/platform-ingress`, the same one the other four clouds run.

### What a tenant's ServiceAccount needs

Nothing. No annotation, no RBAC, no `system:auth-delegator`, no Secret. The
token the API server mints for it already carries everything Vault checks,
which is the same reason an IRSA pod's ServiceAccount carries only an
annotation naming its role.

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
3. **A Vault server** with a token that may create mounts, policies and auth
   roles. Vault's own deployment is out of scope here for the same reason
   Prism Central is: it is the platform's prerequisite, not one of its stacks.
   Three network paths matter, and only these three: the runner reaches Vault
   (to configure it), the cluster reaches Vault (External Secrets logging in),
   and Vault reaches the cluster's `/openid/v1/jwks` **once per key rotation**
   — an anonymous GET for public keys, with no credential involved. If that
   last path does not exist, publish the keys somewhere Vault can read and set
   `cluster_issuer` + `cluster_jwks_url`.
4. **MetalLB** (or another `type: LoadBalancer` implementation) for the
   ingress Service. `ingress_load_balancer_ip` pins the address the DNS
   records point at.

## Credentials

Coordinates come from configuration and state; credentials come from the
environment — the same rule as every other cloud.

| Variable | Where |
|---|---|
| `TF_VAR_nkp_management_token` | GitHub secret `NKP_MANAGEMENT_TOKEN`; used by `foundations/nutanix`, `tenants` and `gitops`. The only long-lived credential this cloud adds |
| `VAULT_TOKEN` | GitHub secret `VAULT_TOKEN`; read by the `vault` provider directly. A deploy-time credential — no workload ever uses one |
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

Naming is the platform's usual contract, and so is the *format*: a secret's
value is a JSON object of fields on every cloud. KV v2 is the one place that is
native rather than a convention — a Vault secret **is** a map of fields — which
is precisely why the platform settled on that format everywhere instead of
letting this cloud's manifests differ.

| | Path | Fields |
|---|---|---|
| Tenant secret | `<mount>/<tenant>-<name>` | whatever the secret needs |
| Platform wildcard | `<mount>/platform-wildcard-onek8s-lol` | `tls.crt`, `tls.key` |

```bash
# publish a tenant secret (as the platform, not as the tenant)
vault kv put onek8s-prototype/team-alpha-db-password password=…
# on the other four clouds the same thing is stored as {"password": "…"}
```

```yaml
# consume it from a tenant workload — byte-identical to the manifest a tenant
# writes on AKS, EKS, GKE and OKE
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
  dataFrom:
    - extract:
        key: team-alpha-db-password
```

The KV v2 secret's fields become the Kubernetes Secret's keys. On the other
four clouds the same manifest extracts a JSON object stored as the secret's
value — same result, same YAML, no `property` anywhere.

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
      remoteRef: { key: team-beta-test }
EOF
kubectl -n team-alpha get externalsecret cross-tenant
# SecretSyncedError — permission denied, from Vault, not from Kubernetes
```

Vault's audit log records the login and the denial with the tenant's role as
the principal, which is the private cloud's version of "per-tenant audit
trails for free".

To see the federation itself, mint a token the way External Secrets does and
watch Vault verify it:

```bash
kubectl -n team-alpha create token workload --audience vault --duration 10m > /tmp/sa.jwt
# the three claims Vault checks
cut -d. -f2 /tmp/sa.jwt | base64 -d 2>/dev/null | jq '{iss, sub, aud}'
vault write auth/jwt-onek8s-prototype/login \
  role=tenant-team-alpha-prototype jwt=@/tmp/sa.jwt
```

## Known limits

- **Vault is a component the platform now operates.** The four public clouds'
  secret backends are managed services; this one is a server someone has to
  keep sealed/unsealed, backed up and upgraded. A Vault outage stops secret
  refreshes on this cloud (running pods keep the Secrets they already have).
- **Revocation is by expiry, not by callback.** Vault verifies a signature
  instead of asking the cluster whether a token is still good, so deleting a
  ServiceAccount does not invalidate a token already issued to it — it lapses
  within `vault_token_expiration_seconds` (10 minutes). This is identical to
  IRSA and to Azure/GCP workload identity; the fix, if a tenant's access must
  be cut *now*, is to delete the Vault role, which takes effect on the next
  login.
- **Signing-key rotation is not automatic in every mode.** With the defaults
  Vault re-fetches the JWKS from the API server and picks up new keys by
  itself. With `cluster_jwks_url` pointed at a published copy, whoever
  publishes it owns keeping it current.
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
