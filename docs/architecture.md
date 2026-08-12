# Architecture

## Overview

OneK8s provisions **cluster + secret-backend pairs** ("foundations") on
Azure, AWS and GCP, and onboards **tenants** onto those clusters with
hard, cloud-enforced secret isolation.

```
┌──────────────────────────── per cloud, per environment ───────────────────────────┐
│                                                                                   │
│  foundations/<cloud>                          tenants/<cloud>                     │
│  ┌─────────────────────────────┐              ┌─────────────────────────────┐     │
│  │ Cluster (AKS/EKS/GKE)       │   remote     │ for each tenant:            │     │
│  │  - workload identity/IRSA   │   state      │  - namespace (quota, limits,│     │
│  │                             │              │    network policy)          │     │
│  │  - Cilium / Dataplane V2    │ ──outputs──▶ │  - cloud identity           │     │
│  │  - External Secrets Operator│              │  - ServiceAccount           │     │
│  │  - policy guardrails        │              │  - namespaced SecretStore   │     │
│  │ Secret backend              │              │  - prefix-scoped IAM        │     │
│  │  (KV / SM / GSM) + KMS      │              └─────────────────────────────┘     │
│  └─────────────────────────────┘                                                  │
└───────────────────────────────────────────────────────────────────────────────────┘
```

## Layering and dependency direction

| Layer | Stacks | State | Deploys |
|---|---|---|---|
| Foundations | `foundations/{azure,aws,gcp}` | `foundations/<cloud>/<env>` in that cloud's backend | independently |
| Tenants | `tenants/` (one stack, `cloud` is a tfvars parameter) | `tenants/<cloud>/<env>` in the Azure Storage state home | independently, **after** the foundation for that cloud+env exists |

Tenants consume foundation outputs via `terraform_remote_state` only.
Foundations never reference tenants — the dependency arrow points one way.

Foundations select an environment with `-backend-config=backend/<env>.hcl`
and `-var-file=envs/<env>.tfvars`. The **single tenants stack** selects
cloud *and* environment the same way, via `<cloud>-<env>` files —
`envs/aws-dev.tfvars` contains `cloud = "aws"`, so the cloud is purely a
parameter in the file and the tenant syntax is identical everywhere. Inside
the stack, a dispatcher module (`modules/tenant-namespace`) instantiates
exactly one cloud implementation, and providers for unselected clouds are
configured inert (mock credentials, zero resources), so a run needs only
Azure credentials (state home) plus the selected cloud's credentials.

## Cloud mapping

| Capability | Azure | AWS | GCP |
|---|---|---|---|
| Cluster | AKS | EKS | GKE |
| Pod-level cloud identity | Workload Identity (OIDC issuer + FIC) | IRSA (IAM OIDC provider) | Workload Identity (`<project>.svc.id.goog`) |
| Networking | Azure CNI overlay + **Cilium data plane** | VPC CNI + **Cilium (chaining)** | **Dataplane V2** (Cilium-based) |
| Secret backend | Key Vault (RBAC + ABAC) | Secrets Manager (+ CMK) | Secret Manager |
| Tenant namespace | **Azure Managed Namespace** (azapi: quota + netpol) + LimitRange | Namespace + quota + netpol + LimitRange | Namespace + quota + netpol + LimitRange |
| Shared tenant Redis | **Azure Managed Redis** (azapi) | ElastiCache **Serverless** (Valkey) | **Memorystore for Redis** |
| Redis delegation | access key copied to KV as `<tenant>-redis-auth` | per-tenant password user (key-prefix ACL), password at `<env>/<tenant>/redis-auth` | AUTH string copied to SM as `<tenant>-redis-auth` |
| Guardrails | Azure Policy add-on + baseline initiative | (optional Kyverno/Gatekeeper) | (optional Kyverno/Gatekeeper) |

## Secret isolation (the core security invariant)

A tenant reaches secrets only through this chain, and every link is scoped
to that single tenant:

```
Pod ──(runs as)──▶ ServiceAccount ──(federated token)──▶ Cloud identity ──(prefix-scoped IAM)──▶ Shared backend
        ▲                     ▲                                  ▲
        │                     │ subject pinned to                │ ABAC / ARN prefix / IAM condition:
        │                     │ system:serviceaccount:<ns>:<sa>  │ only "<tenant>-…" / "<env>/<tenant>/…"
        └── ExternalSecret may only reference the SecretStore in its own namespace
```

Secret naming contract per tenant:

- Azure Key Vault: `"<tenant>-<name>"`
- AWS Secrets Manager: `"<env>/<tenant>/<name>"`
- GCP Secret Manager: `"<tenant>-<name>"`

Consuming a secret from a tenant workload:

```yaml
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
        key: team-alpha-db-password   # Azure/GCP; "dev/team-alpha/db-password" on AWS
```

## Shared managed Redis (opt-in per tenant)

Each foundation also deploys one shared managed Redis instance — Azure
Managed Redis, ElastiCache Serverless (Valkey) or Memorystore for Redis
Cluster. A tenant opts in with a single flag:

```hcl
tenants = {
  team-alpha = { redis_enabled = true }
}
```

The flag stores the Redis AUTH secret in the shared vault **under the
tenant's secret prefix** and delivers it through the platform's normal
ESO + workload-identity chain — so applications consume Redis with zero
cloud-specific code (see ADR-0002 for the trade-off):

- **Azure** — the Managed Redis access key is copied to Key Vault as
  `<tenant>-redis-auth`.
- **AWS** — the tenant gets its *own* password-authenticated ElastiCache
  user whose ACL is restricted to the `"<tenant>:"` key prefix (the Redis
  analogue of the secret-prefix model), associated into the cache's user
  group; the generated password lands at `<env>/<tenant>/redis-auth`,
  encrypted with the platform CMK.
- **GCP** — the Memorystore AUTH string is copied to Secret Manager as
  `<tenant>-redis-auth`. Note: one AUTH string per instance, so opted-in
  tenants share the keyspace.

Enabled tenants receive a `redis-connection` ConfigMap (host, port, TLS,
plus the ACL username/key prefix on AWS) and a `redis-auth` ExternalSecret
that syncs `REDIS_PASSWORD` into the namespace. Reading the AUTH secret
from the vault is gated by the same prefix-scoped identity boundaries as
every other tenant secret.

`examples/demo-app` is a .NET 10 app (StackExchange.Redis as its only
dependency — no cloud SDKs) that exercises vault and Redis consumption
from a tenant namespace, identically on all three clouds.

## CI/CD

- `pr-validation.yml` — fmt, per-stack validate, tflint, checkov, and (once
  `ENABLE_CLOUD_PLANS=true`) OIDC-authenticated dev plans for all six stacks.
- `deploy-foundations.yml` / `deploy-tenants.yml` — independent pipelines;
  merge to `main` auto-deploys dev on path changes, staging/prod go through
  `workflow_dispatch`. Both delegate to the reusable
  `_terraform-deploy.yml`, which binds each run to the GitHub environment
  `<cloud>-<env>` so protection rules (required reviewers, wait timers)
  gate production applies.
- Authentication is OIDC everywhere (azurerm `ARM_USE_OIDC`,
  `aws-actions/configure-aws-credentials`, `google-github-actions/auth`);
  the repo stores no cloud secrets. See `docs/getting-started.md` for the
  identities and repository variables to create.

## Known trade-offs

- The tenant SecretStore is applied with `kubernetes_manifest`, which needs
  cluster reachability and the ESO CRDs at *plan* time. This is inherent to
  the tenants-depend-on-foundations layering; plan tenants only where the
  foundation is deployed.
- AKS uses cluster-local accounts for CI bootstrap (Helm/add-ons). Harden to
  Entra-only + `kubelogin` once your CI identity has an AAD admin group.
- One NAT gateway per AWS VPC (cost-optimized); use one per AZ for prod HA.
- A Terraform working directory supports one backend type, so unifying
  tenants into a single stack means all tenant states — including AWS/GCP
  ones — live in the Azure Storage state home. Every tenant deploy therefore
  needs Azure credentials in addition to the target cloud's. If that
  coupling is unacceptable, split tenants back into per-cloud roots that
  call the same unified module.
- Azure Managed Namespaces are a preview API surface, addressed via `azapi`
  by design (`managed_namespace_api_version` variable).
