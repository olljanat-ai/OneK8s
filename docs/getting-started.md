# Getting started

## Prerequisites

- Terraform >= 1.9 (CI pins 1.15.x)
- Cloud CLIs for local work: `az`, `aws`, `gcloud` (+ `gke-gcloud-auth-plugin`)
- Permissions to create clusters, identities and IAM/role assignments in the
  target subscription/account/project

## 1. Bootstrap state storage (once, out of band)

Create the state stores and put their coordinates into each stack's
`backend/*.hcl` and the tenants' `envs/*.tfvars` (`foundation_state`):

- **Azure**: resource group + storage account + `tfstate` container
- **AWS**: S3 bucket (versioned; native lockfile locking is enabled via
  `use_lockfile`)
- **GCP**: GCS bucket (versioned)

## 2. Configure GitHub OIDC (no long-lived secrets)

Create a deploy identity per cloud, trusted for this repository via OIDC:

- **Azure**: an Entra app (or UAMI) with federated credentials for
  `repo:<org>/<repo>:environment:<cloud>-<env>` (and `:pull_request` if PR
  plans should run). Note: **all nine** `<cloud>-<env>` environments need a
  federated credential, not just the `azure-*` ones — the unified tenants
  stack keeps its state in Azure Storage, so AWS/GCP tenant deploys also
  authenticate to Azure for state access. Grant the app Contributor +
  RBAC-admin rights scoped to the platform subscription.
- **AWS**: an IAM role trusting `token.actions.githubusercontent.com` with
  `sub` conditions for this repo. Grant it the rights to manage the
  foundation + tenant resources.
- **GCP**: a Workload Identity Pool + provider for GitHub, and a deploy
  service account the pool can impersonate.

Then set repository **variables** (Settings → Secrets and variables →
Actions → Variables):

| Variable | Used by |
|---|---|
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | azurerm/azapi OIDC |
| `AWS_ROLE_ARN`, `AWS_REGION` | aws-actions/configure-aws-credentials |
| `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT` | google-github-actions/auth |
| `ENABLE_CLOUD_PLANS` | set to `true` to enable PR plans |

Create GitHub **environments** `azure-dev`, `azure-staging`, `azure-prod`,
`aws-dev`, … `gcp-prod` and attach protection rules (required reviewers for
`*-prod` at minimum). The deploy workflows bind to them automatically.

## 3. Deploy a foundation

```bash
cd foundations/aws
terraform init -backend-config=backend/dev.hcl
terraform plan  -var-file=envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars
```

Or via Actions: **Deploy Foundations** → cloud `aws`, environment `dev`.

## 4. Onboard tenants

There is one tenants stack for all clouds; the target cloud is just the
`cloud = "..."` parameter inside the env file. Edit
`tenants/envs/aws-dev.tfvars` and add a tenant — the syntax is identical on
every cloud:

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
terraform init -backend-config=backend/aws-dev.hcl
terraform apply -var-file=envs/aws-dev.tfvars
```

(Azure credentials are needed too — tenant state lives in the Azure Storage
state home regardless of cloud; use `az login` or ARM_* env vars.)

Or via Actions: **Deploy Tenants** → cloud `aws`, environment `dev`.

## 5. Give the tenant a secret and consume it

```bash
# AWS naming contract: <env>/<tenant>/<name>
aws secretsmanager create-secret --name dev/team-gamma/db-password --secret-string 'hunter2'
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
