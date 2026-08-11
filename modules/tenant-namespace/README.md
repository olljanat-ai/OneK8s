# tenant-namespace module

Reusable, cloud-aware Terraform module that onboards one tenant onto a
cluster provisioned by `foundations/<cloud>`. It has **one entry point for
all clouds** — the cloud is just a variable:

```
tenant-namespace/
├── main.tf … # dispatcher: cloud = "azure" | "aws" | "gcp"
├── common/   # Kubernetes-side resources shared by all clouds
├── azure/    # AKS: Managed Namespace + UAMI + FIC + ABAC on Key Vault
├── aws/      # EKS: Namespace + IAM Role (IRSA) + prefix-scoped Secrets Manager
└── gcp/      # GKE: Namespace + GSA + Workload Identity + IAM condition
```

Callers use the module root and pass `cloud` plus the matching foundation's
outputs object; the dispatcher instantiates exactly one cloud
implementation and exposes identically-shaped outputs (`namespace`,
`service_account_name`, `identity`, `secret_prefix`, `secret_store_name`).
The cloud submodules remain callable directly if a root only wants one
cloud's providers. All three delegate the Kubernetes-side work to `common`.

## What every tenant gets

| Concern | Azure | AWS | GCP |
|---|---|---|---|
| Namespace | **Azure Managed Namespace** (`azapi`, incl. default quota & network policy) | Namespace + ResourceQuota + NetworkPolicy | Namespace + ResourceQuota + NetworkPolicy |
| Container limits | LimitRange (`common`) | LimitRange (`common`) | LimitRange (`common`) |
| Cloud identity | User-Assigned Managed Identity + Federated Identity Credential | IAM Role trusted via IRSA | Google Service Account + Workload Identity binding |
| K8s ServiceAccount | annotated with `azure.workload.identity/client-id` | annotated with `eks.amazonaws.com/role-arn` | annotated with `iam.gke.io/gcp-service-account` |
| ESO SecretStore | namespaced, `azurekv` + WorkloadIdentity | namespaced, `aws` + jwt auth | namespaced, `gcpsm` + workloadIdentity |
| Secret scoping | ABAC condition: secret name starts with `<tenant>-` | IAM resource ARN prefix `<env>/<tenant>/*` + `kms:ViaService` | IAM condition: `resource.name.startsWith(.../secrets/<tenant>-)` |

## Resource limits and network policy

Every tenant namespace gets three guardrails, configured with **identical
syntax on every cloud**:

- **`quota`** — namespace-wide ResourceQuota (CPU/memory requests+limits,
  pod count). On Azure it is enforced by the managed namespace's
  `defaultResourceQuota`; on AWS/GCP by an in-cluster `ResourceQuota`.
- **`limit_range`** — per-container default requests/limits injected when a
  workload omits them, plus optional per-container maximums. Created
  in-cluster by `common` on **all** clouds (the Azure managed namespace has
  no LimitRange concept). Without these defaults, the quota's `limits.*`
  entries would reject any pod that does not declare explicit limits.
- **`network_policy`** — `{ ingress, egress }`, each one of `AllowAll`,
  `AllowSameNamespace` or `DenyAll` — the Azure managed-namespace
  `defaultNetworkPolicy` vocabulary, reused verbatim for AWS/GCP where
  `common` renders an equivalent in-cluster NetworkPolicy (enforced by
  Cilium on EKS and Dataplane V2 on GKE, both set up by the foundations).
  Defaults: ingress `AllowSameNamespace`, egress `AllowAll`. Note that
  restricting egress also blocks DNS to `kube-system`, matching the literal
  Azure semantics — pair it with a DNS allowance before using in anger.

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
module "tenant" {
  source   = "../modules/tenant-namespace"
  for_each = var.tenants

  cloud       = var.cloud                 # "azure" | "aws" | "gcp"
  tenant_name = each.key
  environment = var.environment
  foundation  = data.terraform_remote_state.foundation.outputs
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
