# tenant-namespace module

Reusable, cloud-aware Terraform module that onboards one tenant onto a
cluster provisioned by `foundations/<cloud>`. It has **one entry point for
all clouds** — the cloud is just a variable:

```
tenant-namespace/
├── main.tf … # dispatcher: cloud = "azure" | "aws" | "gcp" | "oci"
├── common/   # Kubernetes-side resources shared by all clouds
├── azure/    # AKS: Managed Namespace + UAMI + FIC + ABAC on Key Vault
├── aws/      # EKS: Namespace + IAM Role (IRSA) + prefix-scoped Secrets Manager
├── gcp/      # GKE: Namespace + GSA + Workload Identity + IAM condition
└── oci/      # OKE: Namespace + workload-identity policy + secret-name prefix
```

Callers use the module root and pass `cloud` plus the matching foundation's
outputs object; the dispatcher instantiates exactly one cloud
implementation and exposes identically-shaped outputs (`namespace`,
`service_account_name`, `identity`, `secret_prefix`, `secret_store_name`).
The cloud submodules remain callable directly if a root only wants one
cloud's providers. All four delegate the Kubernetes-side work to `common`.

Because the OCI submodule needs the home-region provider alias (`oci.home`)
and aliased configurations are never inherited, callers must pass a
`providers` block — and since that disables default inheritance, it has to
list every provider, not just the OCI ones. See `tenants/main.tf`.

A single caller can onboard tenants across several clouds at once, but it
needs one module block per cloud: provider configurations cannot be selected
per `for_each` instance, so each block passes its own cluster's `kubernetes`
provider. That is exactly what the `tenants` stack does.

## What every tenant gets

| Concern | Azure | AWS | GCP | OCI |
|---|---|---|---|---|
| Namespace | **Azure Managed Namespace** (`azapi`, incl. default quota & network policy) | Namespace + ResourceQuota + NetworkPolicy | Namespace + ResourceQuota + NetworkPolicy | Namespace + ResourceQuota + NetworkPolicy |
| Cloud identity | User-Assigned Managed Identity + Federated Identity Credential | IAM Role trusted via IRSA | Google Service Account + Workload Identity binding | none to create — OKE asserts the (cluster, namespace, SA) tuple itself |
| K8s ServiceAccount | annotated with `azure.workload.identity/client-id` | annotated with `eks.amazonaws.com/role-arn` | annotated with `iam.gke.io/gcp-service-account` | no annotation needed |
| ESO SecretStore | namespaced, `azurekv` + WorkloadIdentity | namespaced, `aws` + jwt auth | namespaced, `gcpsm` + workloadIdentity | namespaced, `oracle` + `principalType: Workload` |
| Secret scoping | ABAC condition: secret name starts with `<tenant>-` | IAM resource ARN prefix `<env>/<tenant>/*` + `kms:ViaService` | IAM condition: `resource.name.startsWith(.../secrets/<tenant>-)` | policy condition: `target.secret.name = /<tenant>-*/` |

## Isolation model

A tenant can never read another tenant's secrets because:

1. The **SecretStore is namespaced** — ESO only lets `ExternalSecret`s in the
   same namespace reference it. There is no `ClusterSecretStore`.
2. The SecretStore authenticates **only** via the tenant's own
   ServiceAccount (`serviceAccountRef`), whose token is exchanged for the
   tenant's cloud identity through workload identity federation.
3. The cloud identity's access to the shared secret backend is **restricted
   by name/prefix** (ABAC on Azure, IAM resource/conditions on AWS/GCP), so
   even a compromised tenant identity cannot cross the prefix boundary.
4. The federation subject is pinned to `system:serviceaccount:<ns>:<sa>`, so
   no other namespace can borrow the identity.

See `docs/adr/0001-per-tenant-identities-and-namespaced-secretstores.md` for
the full rationale.

## Usage

See `tenants/main.tf` for the working example. Sketch:

```hcl
module "tenants_aws" {
  source = "../modules/tenant-namespace"
  # One block per cloud: the tenants of that cloud, and that cluster's
  # kubernetes provider.
  for_each = { for k, t in var.tenants : k => t if t.cloud == "aws" }

  providers = { kubernetes = kubernetes.aws, /* ...the full provider set... */ }

  cloud       = "aws"                     # "azure" | "aws" | "gcp" | "oci"
  tenant_name = coalesce(each.value.name, each.key)
  environment = var.environment
  foundation  = data.terraform_remote_state.foundation["aws"].outputs
  quota       = each.value.quota
}
```

`foundation` is the whole outputs object of the matching
`foundations/<cloud>` stack; the dispatcher picks the keys it needs for the
selected cloud (see `variables.tf` for the per-cloud key list).

## Notes

- `common` uses `kubernetes_manifest` for the SecretStore, which requires the
  ESO CRDs to already exist at plan time. The foundation stack installs ESO,
  and tenants are always planned/applied after the foundation — this is the
  intended dependency direction.
- The Azure managed namespace API is still in preview; bump
  `managed_namespace_api_version` as Azure promotes it.
- OKE Workload Identity requires an **enhanced** OKE cluster; the OCI
  foundation creates one (`type = "ENHANCED_CLUSTER"`).
- The OCI policy grants reads of named secrets, not listing, so ESO's
  `dataFrom.find` is unavailable there — that restriction is what keeps a
  tenant from enumerating the compartment.
