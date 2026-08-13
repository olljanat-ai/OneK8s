# Architecture

## Overview

OneK8s provisions **cluster + secret-backend pairs** ("foundations") on
Azure, AWS, GCP and OCI, and onboards **tenants** onto those clusters with
hard, cloud-enforced secret isolation.

```
┌──────────── per environment: foundations per cloud, one tenants stack ────────────┐
│                                                                                   │
│  foundations/<cloud>                          tenants/ (cloud per tenant)         │
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
| Foundations | `foundations/{azure,aws,gcp,oci}` | `foundations/<cloud>/<env>.tfstate` in the Azure Storage state home | independently |
| Tenants | `tenants/` (one stack, all clouds; `cloud` is a per-tenant parameter) | `tenants/<env>.tfstate` in the Azure Storage state home | independently, **after** the foundations of the clouds its tenants use |

**One state home.** Every stack — whichever cloud it provisions — keeps its
state in the same Azure Storage account, distinguished only by blob key.
Bootstrapping is therefore a single storage account rather than one bucket
per cloud, `terraform_remote_state` is a single `azurerm` read instead of
one data source per backend type, and state RBAC/versioning/retention is
configured in one place. The price is that every deploy needs Azure
credentials in addition to the target cloud's.

Tenants consume foundation outputs via `terraform_remote_state` only.
Foundations never reference tenants — the dependency arrow points one way.

Both layers select an environment the same way, with
`-backend-config=backend/<env>.hcl` and `-var-file=envs/<env>.tfvars`. The
difference is that a foundation is one cloud's cluster, while the **single
tenants stack covers every cloud in one state file and one apply**: `cloud`
is an attribute of each tenant, not of the deployment.

```hcl
tenants = {
  azure-team-alpha = { cloud = "azure", name = "team-alpha" }
  aws-team-alpha   = { cloud = "aws",   name = "team-alpha" }
}
```

Inside the stack, tenants are grouped by cloud and each group is passed its
own cluster's `kubernetes` provider alias — provider configurations cannot be
chosen per `for_each` instance, which is the one place the cloud has to be
enumerated in code. Per tenant, the dispatcher module
(`modules/tenant-namespace`) then instantiates exactly one cloud
implementation. Clouds with no tenants in the environment read no foundation
state, contact no cluster and keep inert provider configurations (mock
credentials, zero resources), so a run needs Azure credentials (state home)
plus the credentials of the clouds that actually have tenants.

The foundation states are addressed by convention rather than configuration:
the tenants stack derives the blob key `foundations/<cloud>/<env>.tfstate`
from the state home account/container and the environment, which is exactly
what `foundations/<cloud>/backend/<env>.hcl` writes. There are no per-cloud
coordinates to keep in sync, so the two halves cannot drift apart — an empty
read now means the foundation was never applied, and the tenant module says
so in one message instead of a list of "Unsupported attribute" errors.

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
  `ENABLE_CLOUD_PLANS=true`) credentialed prototype plans for all five
  stacks.
- `deploy-foundations.yml` / `deploy-tenants.yml` — independent pipelines;
  merge to `main` auto-deploys the prototype environment on path changes,
  other environments go through `workflow_dispatch`. Deploy Foundations fans
  out per cloud; Deploy Tenants is a single all-clouds job. Both delegate to
  the reusable `_terraform-deploy.yml`, which binds each run to a GitHub
  environment — `<cloud>-<env>` for foundations, `tenants-<env>` for the
  tenants stack — so protection rules (required reviewers, wait timers) gate
  production applies.
- Authentication uses long-lived cloud credentials stored as GitHub secrets
  (azurerm `ARM_CLIENT_SECRET`, AWS access keys via
  `aws-actions/configure-aws-credentials`, a service account key via
  `google-github-actions/auth`, and an OCI API signing key read from `OCI_*`
  environment variables). See `docs/getting-started.md` for the identities
  and repository secrets/variables to create.

## Known trade-offs

- The tenant SecretStore is applied with `kubernetes_manifest`, which needs
  cluster reachability and the ESO CRDs at *plan* time. This is inherent to
  the tenants-depend-on-foundations layering, and with one stack per
  environment it applies to every cloud in `var.tenants` at once: list a
  cloud's tenants only once that cloud's foundation is deployed and its
  cluster is reachable from where the plan runs.
- AKS uses cluster-local accounts for CI bootstrap (Helm/add-ons). Harden to
  Entra-only + `kubelogin` once your CI identity has an AAD admin group.
- One NAT gateway per AWS VPC (cost-optimized); use one per AZ for prod HA.
- All state lives in the Azure Storage state home, so every deploy — AWS,
  GCP and OCI foundations included — needs Azure credentials in addition to
  the target cloud's, and Azure Storage is a single point of failure for
  operating the other three clouds. The trade is deliberate: one bootstrap,
  one place to secure and version state, and one remote-state backend type
  (a working directory supports only one anyway, which is what forced the
  unified tenants stack into Azure Storage to begin with). If that coupling
  is unacceptable, move each `foundations/<cloud>` back to its own cloud's
  backend and give the tenants stack one `terraform_remote_state` data
  source per backend type, count-gated on `var.cloud`.
- Azure Managed Namespaces are a preview API surface, addressed via `azapi`
  by design (`managed_namespace_api_version` variable).
- OCI IAM is global but writable only in the tenancy's **home region**, so
  both OCI stacks carry a second `oci.home` provider alias just for policies.
  Because passing any provider to a module disables default inheritance,
  every module block in `tenants/main.tf` has to enumerate the full provider
  set explicitly.
- Deploying all clouds from one state file means one blast radius and one
  lock: a tenant change on GCP plans and applies together with the Azure, AWS
  and OCI tenants, and an unreachable cluster on any cloud in use fails the
  whole run. The trade buys a single source of truth for who is onboarded
  where, and one run instead of four.
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
