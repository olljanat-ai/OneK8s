# Architecture

## Overview

OneK8s provisions **cluster + secret-backend pairs** ("foundations") on
Azure, AWS, GCP and OCI, and onboards **tenants** onto those clusters with
hard, cloud-enforced secret isolation.

```
┌──────────────────────────── per cloud, per environment ───────────────────────────┐
│                                                                                   │
│  foundations/<cloud>                          tenants/<cloud>                     │
│  ┌─────────────────────────────┐              ┌─────────────────────────────┐     │
│  │ Cluster (AKS/EKS/GKE/OKE)   │   remote     │ for each tenant:            │     │
│  │  - workload identity/IRSA   │   state      │  - namespace (+quota,netpol)│     │
│  │  - Cilium / Dataplane V2    │ ──outputs──▶ │  - cloud identity           │     │
│  │  - External Secrets Operator│              │  - ServiceAccount           │     │
│  │  - policy guardrails        │              │  - namespaced SecretStore   │     │
│  │ Secret backend              │              │  - prefix-scoped IAM        │     │
│  │  (KV / SM / GSM / Vault)    │              └─────────────────────────────┘     │
│  └─────────────────────────────┘                                                  │
└───────────────────────────────────────────────────────────────────────────────────┘
```

## Layering and dependency direction

| Layer | Stacks | State | Deploys |
|---|---|---|---|
| Foundations | `foundations/{azure,aws,gcp,oci}` | `foundations/<cloud>/<env>` in that cloud's backend | independently |
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

| Capability | Azure | AWS | GCP | OCI |
|---|---|---|---|---|
| Cluster | AKS | EKS | GKE | OKE (enhanced) |
| Pod-level cloud identity | Workload Identity (OIDC issuer + FIC) | IRSA (IAM OIDC provider) | Workload Identity (`<project>.svc.id.goog`) | OKE Workload Identity (no identity object — the principal *is* cluster+ns+SA) |
| Networking | Azure CNI overlay + **Cilium data plane** | VPC CNI + **Cilium (chaining)** | **Dataplane V2** (Cilium-based) | VCN-native pod networking + **Cilium (chaining)** |
| Secret backend | Key Vault (RBAC + ABAC) | Secrets Manager (+ CMK) | Secret Manager | OCI Vault (+ master key) |
| Tenant namespace | **Azure Managed Namespace** (azapi) | Namespace + quota + netpol | Namespace + quota + netpol | Namespace + quota + netpol |
| Guardrails | Azure Policy add-on + baseline initiative | (optional Kyverno/Gatekeeper) | (optional Kyverno/Gatekeeper) | (optional Kyverno/Gatekeeper) |

## Secret isolation (the core security invariant)

A tenant reaches secrets only through this chain, and every link is scoped
to that single tenant:

```
Pod ──(runs as)──▶ ServiceAccount ──(federated token)──▶ Cloud identity ──(prefix-scoped IAM)──▶ Shared backend
        ▲                     ▲                                  ▲
        │                     │ subject pinned to that           │ ABAC / ARN prefix / IAM condition:
        │                     │ tenant's namespace + SA          │ only "<tenant>-…" / "<env>/<tenant>/…"
        └── ExternalSecret may only reference the SecretStore in its own namespace
```

Secret naming contract per tenant:

- Azure Key Vault: `"<tenant>-<name>"`
- AWS Secrets Manager: `"<env>/<tenant>/<name>"`
- GCP Secret Manager: `"<tenant>-<name>"`
- OCI Vault: `"<tenant>-<name>"`

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
  `ENABLE_CLOUD_PLANS=true`) credentialed dev plans for all eight stacks.
- `deploy-foundations.yml` / `deploy-tenants.yml` — independent pipelines;
  merge to `main` auto-deploys dev on path changes, staging/prod go through
  `workflow_dispatch`. Both delegate to the reusable
  `_terraform-deploy.yml`, which binds each run to the GitHub environment
  `<cloud>-<env>` so protection rules (required reviewers, wait timers)
  gate production applies.
- Authentication uses long-lived cloud credentials stored as GitHub secrets
  (azurerm `ARM_CLIENT_SECRET`, AWS access keys via
  `aws-actions/configure-aws-credentials`, a service account key via
  `google-github-actions/auth`, and an OCI API signing key read from `OCI_*`
  environment variables). See `docs/getting-started.md` for the identities
  and repository secrets/variables to create.

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
- OCI IAM is global but writable only in the tenancy's **home region**, so
  both OCI stacks carry a second `oci.home` provider alias just for policies.
  Because passing any provider to a module disables default inheritance,
  `tenants/main.tf` has to enumerate the full provider set explicitly.
- OCI has no Terraform-native cluster-token source (no equivalent of
  `aws_eks_cluster_auth`), so the tenants stack shells out to
  `oci ce cluster generate-token`; the OCI CLI must be on `PATH`.
- Deleting an OCI Vault is a *scheduled* operation with a mandatory 7-30 day
  waiting period, so `terraform destroy` schedules the deletion rather than
  completing it, and the vault name stays taken until it elapses.
- The OCI tenant policy grants reads of individual secrets by name, not
  listing: a list request has no single `target.secret.name` to match, so
  ESO's `dataFrom.find` (as opposed to `dataFrom.extract`) will not work on
  OCI. That is the same trade-off that makes cross-tenant enumeration
  impossible.
