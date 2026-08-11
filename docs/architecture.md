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
│  │  - workload identity/IRSA   │   state      │  - namespace (+quota,netpol)│     │
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
| Foundations | `foundations/{azure,aws,gcp}` | `foundations/<cloud>/<env>` | independently |
| Tenants | `tenants/{azure,aws,gcp}` | `tenants/<cloud>/<env>` | independently, **after** the foundation for that cloud+env exists |

Tenants consume foundation outputs via `terraform_remote_state` only.
Foundations never reference tenants — the dependency arrow points one way.
Each of the six stacks × three environments (dev/staging/prod) has its own
state file, selected with `-backend-config=backend/<env>.hcl` and
`-var-file=envs/<env>.tfvars`.

## Cloud mapping

| Capability | Azure | AWS | GCP |
|---|---|---|---|
| Cluster | AKS | EKS | GKE |
| Pod-level cloud identity | Workload Identity (OIDC issuer + FIC) | IRSA (IAM OIDC provider) | Workload Identity (`<project>.svc.id.goog`) |
| Networking | Azure CNI overlay + **Cilium data plane** | VPC CNI + **Cilium (chaining)** | **Dataplane V2** (Cilium-based) |
| Secret backend | Key Vault (RBAC + ABAC) | Secrets Manager (+ CMK) | Secret Manager |
| Tenant namespace | **Azure Managed Namespace** (azapi) | Namespace + quota + netpol | Namespace + quota + netpol |
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
- Azure Managed Namespaces are a preview API surface, addressed via `azapi`
  by design (`managed_namespace_api_version` variable).
