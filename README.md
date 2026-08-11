# OneK8s

Cloud-agnostic, multi-tenant Kubernetes platform as a Terraform monorepo.
Provisions **cluster + secret-backend pairs** on Azure (AKS + Key Vault),
AWS (EKS + Secrets Manager) and GCP (GKE + Secret Manager), and onboards
tenants with **hard, cloud-enforced secret isolation** via External Secrets
Operator and per-tenant workload identities.

## Repository layout

```
├── foundations/            # Cluster + "vault" pairs — deployed independently
│   ├── azure/              #   AKS (Cilium, Workload Identity, Azure Policy) + Key Vault (RBAC/ABAC)
│   ├── aws/                #   EKS (Cilium chaining, IRSA) + Secrets Manager CMK
│   └── gcp/                #   GKE (Dataplane V2, Workload Identity) + Secret Manager
├── modules/
│   └── tenant-namespace/   # Reusable, cloud-aware tenant module
│       ├── common/         #   namespace, quota, netpol, SA, namespaced SecretStore
│       ├── azure/          #   Managed Namespace (azapi) + UAMI/FIC + ABAC prefix
│       ├── aws/            #   IAM role (IRSA) + ARN-prefix policy
│       └── gcp/            #   GSA + WI binding + IAM condition
├── tenants/                # Tenant instantiations — deployed independently
│   ├── azure/  aws/  gcp/  #   per-env tfvars define the tenant roster
├── .github/workflows/      # PR validation + OIDC deploy pipelines
└── docs/                   # architecture, getting started, ADRs
```

Each stack supports **dev / staging / prod** via `envs/<env>.tfvars` +
`backend/<env>.hcl`. Tenants depend on foundation remote-state outputs;
foundations never depend on tenants.

## Security model (short version)

Every tenant gets a namespace, a dedicated cloud identity federated to
exactly `system:serviceaccount:<ns>:<sa>`, and a **namespaced** ESO
`SecretStore` that authenticates only with that identity. The identity can
read only its own name-prefix slice of the shared secret backend — enforced
with Key Vault **ABAC** conditions, IAM **ARN prefixes** (+ `kms:ViaService`)
and Secret Manager **IAM conditions**. Cross-tenant secret access is blocked
in the cloud IAM plane, not just in Kubernetes.
Details: [ADR-0001](docs/adr/0001-per-tenant-identities-and-namespaced-secretstores.md).

## Quick start

```bash
cd foundations/aws
terraform init -backend-config=backend/dev.hcl
terraform apply -var-file=envs/dev.tfvars

cd ../../tenants/aws
terraform init -backend-config=backend/dev.hcl
terraform apply -var-file=envs/dev.tfvars       # onboards the tenant roster
```

Full setup (state bootstrap, GitHub OIDC, environment protection):
[docs/getting-started.md](docs/getting-started.md).
Design and trade-offs: [docs/architecture.md](docs/architecture.md).
Tenant module reference: [modules/tenant-namespace/README.md](modules/tenant-namespace/README.md).

## CI/CD

- **PR validation** — fmt, validate (all 6 stacks), tflint, checkov, and
  optional OIDC dev plans (`ENABLE_CLOUD_PLANS=true`).
- **Deploy Foundations / Deploy Tenants** — separate pipelines; dev deploys
  on merge to `main`, staging/prod via `workflow_dispatch`, all gated by
  GitHub environments `<cloud>-<env>` and authenticated with OIDC only.

## License

MIT — see [LICENSE](LICENSE).
