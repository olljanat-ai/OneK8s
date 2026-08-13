# Getting started

## Prerequisites

- Terraform >= 1.9 (CI pins 1.15.x)
- Cloud CLIs for local work: `az`, `aws`, `gcloud`
  (+ `gke-gcloud-auth-plugin`), `oci`
- Permissions to create clusters, identities and IAM/role assignments in the
  target subscription/account/project

## 1. Bootstrap state storage (once, out of band)

There is a single **state home** for the whole monorepo: an Azure Storage
account that holds the state of every stack on every cloud. Create a
resource group + storage account + `tfstate` container (enable blob
versioning), and put its coordinates into each stack's `backend/*.hcl` and
the tenants' `envs/*.tfvars` (`foundation_state`). The keys are:

| Stack | Blob key |
|---|---|
| `foundations/<cloud>` | `foundations/<cloud>/<env>.tfstate` |
| `tenants` (cloud is a parameter) | `tenants/<cloud>/<env>.tfstate` |

Consequence: **every** deploy needs Azure credentials, including the AWS,
GCP and OCI ones, in addition to the target cloud's. Grant the Azure deploy
identity *Storage Blob Data Contributor* on the state container — the
backends use `use_azuread_auth = true`, not storage account keys. No S3 /
GCS / Object Storage bucket is needed for Terraform state.

## 2. Configure GitHub credentials (secrets)

Create a deploy identity per cloud and store its credentials as GitHub
secrets:

- **Azure**: an Entra app (service principal) with a client secret. Note:
  the Azure secrets are needed by **all** deploy jobs, not just the Azure
  ones — every stack keeps its state in the Azure Storage state home, so
  AWS/GCP/OCI deploys also authenticate to Azure for state access. Grant the
  app Contributor + RBAC-admin rights scoped to the platform subscription,
  plus Storage Blob Data Contributor on the state container.
- **AWS**: an IAM user with an access key. Grant it the rights to manage
  the foundation + tenant resources.
- **GCP**: a deploy service account with a JSON key.
- **OCI**: a deploy user with an API signing key. Grant it `manage` on the
  platform compartment plus `manage policies` — per-tenant policies are
  created at deploy time. Note that IAM writes always go to the tenancy's
  **home region**, which the stacks address through a separate `oci.home`
  provider alias. No Customer Secret Key is needed: OCI state lives in the
  Azure state home like everything else.

Then set repository **secrets** (Settings → Secrets and variables →
Actions → Secrets):

| Secret | Used by |
|---|---|
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_SECRET` | azurerm/azapi providers + the azurerm state backend of **every** stack |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | aws-actions/configure-aws-credentials |
| `GCP_CREDENTIALS_JSON` | google-github-actions/auth (service account key JSON) |
| `OCI_FINGERPRINT`, `OCI_PRIVATE_KEY` | oci provider + OCI CLI (API signing key, PEM contents) |

And repository **variables**:

| Variable | Used by |
|---|---|
| `AWS_REGION` | aws-actions/configure-aws-credentials |
| `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_REGION` | oci provider + OCI CLI |
| `ENABLE_CLOUD_PLANS` | set to `true` to enable PR plans |

Create GitHub **environments** `azure-dev`, `azure-staging`, `azure-prod`,
`aws-dev`, … `oci-prod` and attach protection rules (required reviewers for
`*-prod` at minimum). The deploy workflows bind to them automatically.

## 3. Deploy a foundation

```bash
cd foundations/aws
terraform init -backend-config=backend/prototype.hcl   # Azure creds needed here too
terraform plan  -var-file=envs/prototype.tfvars
terraform apply -var-file=envs/prototype.tfvars
```

Or via Actions: **Deploy Foundations** → cloud `aws`, environment
`prototype`.

## 4. Onboard tenants

There is one tenants stack for all clouds; the target cloud is just the
`cloud = "..."` parameter inside the env file. Edit
`tenants/envs/aws-prototype.tfvars` and add a tenant — the syntax is
identical on every cloud:

```hcl
tenants = {
  team-gamma = {
    quota  = { cpu_requests = "2", memory_requests = "4Gi" }
    labels = { "onek8s.io/cost-center" = "gamma-2002" }
  }
}
```

Then:

```bash
cd tenants
terraform init -backend-config=backend/aws-prototype.hcl
terraform apply -var-file=envs/aws-prototype.tfvars
```

(Azure credentials are needed too — all state lives in the Azure Storage
state home regardless of cloud; use `az login` or ARM_* env vars. The stack
also *reads* the foundation's state from there, so `foundation_state` in the
tfvars must match `foundations/aws/backend/prototype.hcl`.)

Or via Actions: **Deploy Tenants** → cloud `aws`, environment `prototype`.

## 5. Give the tenant a secret and consume it

```bash
# AWS naming contract: <env>/<tenant>/<name>
aws secretsmanager create-secret --name dev/team-gamma/db-password --secret-string 'hunter2'

# OCI naming contract: <tenant>-<name>
oci vault secret create-base64 \
  --compartment-id "$COMPARTMENT_OCID" --vault-id "$VAULT_OCID" \
  --key-id "$VAULT_KEY_OCID" --secret-name team-gamma-db-password \
  --secret-content-content "$(printf 'hunter2' | base64)"
```

In the tenant namespace (see `docs/architecture.md` for the full example),
an `ExternalSecret` referencing `secretStoreRef: {kind: SecretStore, name:
tenant-store}` with `remoteRef.key: dev/team-gamma/db-password` will
materialize the Kubernetes Secret. Any attempt to read another tenant's
prefix fails at the cloud IAM layer.

## Environment promotion

dev → staging → prod is data-driven: the same code reads a different
`envs/<env>.tfvars` + `backend/<env>.hcl` (foundations) or
`envs/<cloud>-<env>.tfvars` + `backend/<cloud>-<env>.hcl` (tenants).
Merges to `main` roll dev automatically; staging and prod are explicit
`workflow_dispatch` runs gated by their GitHub environments.
