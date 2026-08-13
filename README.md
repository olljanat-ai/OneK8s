# OneK8s

Cloud-agnostic, multi-tenant Kubernetes platform as a Terraform monorepo.
Provisions **cluster + secret-backend pairs** on Azure (AKS + Key Vault),
AWS (EKS + Secrets Manager), GCP (GKE + Secret Manager) and OCI (OKE + OCI
Vault), and onboards tenants with **hard, cloud-enforced secret isolation**
via External Secrets Operator and per-tenant workload identities.

## Repository layout

```
├── foundations/            # Cluster + "vault" pairs — deployed independently
│   ├── azure/              #   AKS (Cilium, Workload Identity, Azure Policy) + Key Vault (RBAC/ABAC)
│   ├── aws/                #   EKS (Cilium chaining, IRSA) + Secrets Manager CMK
│   ├── gcp/                #   GKE (Dataplane V2, Workload Identity) + Secret Manager
│   └── oci/                #   OKE (VCN-native pods + Cilium, Workload Identity) + OCI Vault
├── modules/
│   └── tenant-namespace/   # Reusable tenant module — cloud is a variable
│       ├── main.tf ...     #   dispatcher: cloud = azure|aws|gcp|oci, unified outputs
│       ├── common/         #   namespace, quota, netpol, SA, namespaced SecretStore
│       ├── azure/          #   Managed Namespace (azapi) + UAMI/FIC + ABAC prefix
│       ├── aws/            #   IAM role (IRSA) + ARN-prefix policy
│       ├── gcp/            #   GSA + WI binding + IAM condition
│       └── oci/            #   workload-identity IAM policy + secret-name prefix
├── tenants/                # ONE stack for all clouds — deployed independently
│   ├── envs/               #   <cloud>-<env>.tfvars: cloud is a parameter in the file
│   └── backend/            #   <cloud>-<env>.hcl state configs (Azure state home)
├── .github/workflows/      # PR validation + deploy pipelines
└── docs/                   # architecture, getting started, ADRs
```

Foundations support **dev / staging / prod** via `envs/<env>.tfvars` +
`backend/<env>.hcl`; the single tenants stack targets a cloud and
environment via `envs/<cloud>-<env>.tfvars` (the file sets `cloud = "..."`)
— tenant definition syntax is identical on every cloud. Tenants depend on
foundation remote-state outputs; foundations never depend on tenants.

## Security model (short version)

Every tenant gets a namespace, a dedicated cloud identity federated to
exactly that tenant's `<namespace>`/`<serviceaccount>`, and a **namespaced** ESO
`SecretStore` that authenticates only with that identity. The identity can
read only its own name-prefix slice of the shared secret backend — enforced
with Key Vault **ABAC** conditions, IAM **ARN prefixes** (+ `kms:ViaService`),
Secret Manager **IAM conditions** and OCI **policy conditions** on
`target.secret.name`. Cross-tenant secret access is blocked in the cloud IAM
plane, not just in Kubernetes.
Details: [ADR-0001](docs/adr/0001-per-tenant-identities-and-namespaced-secretstores.md).

## Quick start

```bash
cd foundations/aws
terraform init -backend-config=backend/prototype.hcl
terraform apply -var-file=envs/prototype.tfvars

cd ../../tenants                                      # same stack for every cloud
terraform init -backend-config=backend/aws-prototype.hcl
terraform apply -var-file=envs/aws-prototype.tfvars   # cloud = "aws" set in the file
```

All state — every stack, every cloud — lives in one Azure Storage "state
home", so Azure credentials are required for every deploy alongside the
target cloud's.

Full setup (state bootstrap, GitHub secrets, environment protection):
[docs/getting-started.md](docs/getting-started.md).
Design and trade-offs: [docs/architecture.md](docs/architecture.md).
Tenant module reference: [modules/tenant-namespace/README.md](modules/tenant-namespace/README.md).

## CI/CD

- **PR validation** — fmt, validate (all 8 stacks), tflint, checkov, and
  optional cloud dev plans (`ENABLE_CLOUD_PLANS=true`).
- **Deploy Foundations / Deploy Tenants** — separate pipelines; dev deploys
  on merge to `main`, staging/prod via `workflow_dispatch`, all gated by
  GitHub environments `<cloud>-<env>` and authenticated with cloud
  credentials stored as GitHub secrets.

## License

MIT — see [LICENSE](LICENSE).
