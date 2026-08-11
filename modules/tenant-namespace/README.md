# tenant-namespace module

Reusable, cloud-aware Terraform module that onboards one tenant onto a
cluster provisioned by `foundations/<cloud>`. It is a composite module:

```
tenant-namespace/
├── common/   # Kubernetes-side resources shared by all clouds
├── azure/    # AKS: Managed Namespace + UAMI + FIC + ABAC on Key Vault
├── aws/      # EKS: Namespace + IAM Role (IRSA) + prefix-scoped Secrets Manager
└── gcp/      # GKE: Namespace + GSA + Workload Identity + IAM condition
```

Callers use the cloud-specific entry point (`.../tenant-namespace/azure`,
`.../aws`, `.../gcp`) so that each root only needs the providers for its own
cloud. All three wrappers delegate the Kubernetes-side work to `common`.

## What every tenant gets

| Concern | Azure | AWS | GCP |
|---|---|---|---|
| Namespace | **Azure Managed Namespace** (`azapi`, incl. default quota & network policy) | Namespace + ResourceQuota + NetworkPolicy | Namespace + ResourceQuota + NetworkPolicy |
| Cloud identity | User-Assigned Managed Identity + Federated Identity Credential | IAM Role trusted via IRSA | Google Service Account + Workload Identity binding |
| K8s ServiceAccount | annotated with `azure.workload.identity/client-id` | annotated with `eks.amazonaws.com/role-arn` | annotated with `iam.gke.io/gcp-service-account` |
| ESO SecretStore | namespaced, `azurekv` + WorkloadIdentity | namespaced, `aws` + jwt auth | namespaced, `gcpsm` + workloadIdentity |
| Secret scoping | ABAC condition: secret name starts with `<tenant>-` | IAM resource ARN prefix `<env>/<tenant>/*` + `kms:ViaService` | IAM condition: `resource.name.startsWith(.../secrets/<tenant>-)` |

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

See `tenants/<cloud>/main.tf` for working examples. Sketch (AWS):

```hcl
module "tenant" {
  source   = "../../modules/tenant-namespace/aws"
  for_each = var.tenants

  tenant_name         = each.key
  environment         = var.environment
  oidc_issuer_url     = data.terraform_remote_state.foundation.outputs.oidc_issuer_url
  oidc_provider_arn   = data.terraform_remote_state.foundation.outputs.oidc_provider_arn
  region              = data.terraform_remote_state.foundation.outputs.region
  account_id          = data.terraform_remote_state.foundation.outputs.account_id
  secrets_kms_key_arn = data.terraform_remote_state.foundation.outputs.secrets_kms_key_arn
  quota               = each.value.quota
}
```

## Notes

- `common` uses `kubernetes_manifest` for the SecretStore, which requires the
  ESO CRDs to already exist at plan time. The foundation stack installs ESO,
  and tenants are always planned/applied after the foundation — this is the
  intended dependency direction.
- The Azure managed namespace API is still in preview; bump
  `managed_namespace_api_version` as Azure promotes it.
