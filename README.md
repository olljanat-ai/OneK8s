# OneK8s

Cloud-agnostic, multi-tenant Kubernetes platform as a Terraform monorepo.
Provisions **cluster + secret-backend pairs** on Azure (AKS + Key Vault),
AWS (EKS + Secrets Manager), GCP (GKE + Secret Manager) and OCI (OKE + OCI
Vault), and onboards tenants with **hard, cloud-enforced secret isolation**
via External Secrets Operator and per-tenant workload identities.

## Repository layout

```
├── foundations/            # Cluster + "vault" pairs — deployed independently
│   ├── azure/              #   AKS (Cilium, Workload Identity, Azure Policy, Argo CD) + Key Vault (RBAC/ABAC)
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
│   ├── envs/               #   <env>.tfvars: every tenant, each with cloud = "..."
│   └── backend/            #   <env>.hcl state config (Azure state home)
├── .github/workflows/      # PR validation + deploy pipelines
└── docs/                   # architecture, getting started, ADRs
```

Foundations are per cloud and support **prototype / dev / staging / prod**
via `envs/<env>.tfvars` + `backend/<env>.hcl`. The tenants stack has one
state file per environment covering **all clouds at once**: the cloud is a
per-tenant parameter, so a single `terraform apply` onboards tenants on
azure, aws, gcp and oci, with identical tenant syntax everywhere. Tenants
depend on foundation remote-state outputs; foundations never depend on
tenants.

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

cd ../../tenants                                # one stack, every cloud, one run
terraform init -backend-config=backend/prototype.hcl
terraform apply -var-file=envs/prototype.tfvars  # each tenant sets its own cloud
```

```hcl
# tenants/envs/prototype.tfvars — the cloud is just a tenant attribute
tenants = {
  azure-team-alpha = { cloud = "azure", name = "team-alpha" }
  aws-team-alpha   = { cloud = "aws",   name = "team-alpha" }
}
```

All state — every stack, every cloud — lives in one Azure Storage "state
home", so Azure credentials are required for every deploy alongside the
credentials of every cloud that has tenants. Clouds with no tenants are
skipped entirely: no foundation state is read and their providers stay
inert.

## GitOps

The Azure foundation carries the platform's delivery plane: the
Microsoft-offered **Argo CD cluster extension** (`Microsoft.ArgoCD`),
published on `https://argocd.onek8s.lol` by the AKS application routing
add-on and terminating TLS with the `*.onek8s.lol` wildcard mounted straight
out of Key Vault by the Secrets Store CSI driver. Sign-in is **Entra ID**,
with Entra groups mapped to Argo CD roles and no client secret anywhere —
the SSO app authenticates with the cluster's federated credential. It manages
only the AKS cluster today; the plan is to make it the **hub** that drives
EKS, GKE and OKE as spokes. Details and the hub-spoke plan:
[docs/argocd.md](docs/argocd.md).

Full setup (state bootstrap, GitHub secrets, environment protection):
[docs/getting-started.md](docs/getting-started.md).
Design and trade-offs: [docs/architecture.md](docs/architecture.md).
Tenant module reference: [modules/tenant-namespace/README.md](modules/tenant-namespace/README.md).

## CI/CD

- **PR validation** — fmt, validate (all 5 stacks), tflint, checkov, and
  optional cloud plans (`ENABLE_CLOUD_PLANS=true`).
- **Deploy Foundations / Deploy Tenants** — separate pipelines; the
  prototype environment deploys on merge to `main`, other environments via
  `workflow_dispatch`, authenticated with cloud credentials stored as GitHub
  secrets. Foundation jobs are gated by the GitHub environments
  `<cloud>-<env>`, the all-clouds tenants job by `tenants-<env>`.
- **Renew Certificate** — daily; issues and renews the `*.onek8s.lol`
  wildcard from Let's Encrypt over DNS-01 against the Azure-hosted
  `onek8s.lol` zone and imports it into the AKS cluster's Key Vault.

## License

MIT — see [LICENSE](LICENSE).
