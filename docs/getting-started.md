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
into `state_home` in `tenants/envs/<env>.tfvars`. The keys are:

| Stack | Blob key |
|---|---|
| `foundations/<cloud>` | `foundations/<cloud>/<env>.tfstate` |
| `tenants` (one per environment, all clouds) | `tenants/<env>.tfstate` |

The tenants stack does not take the foundation keys as configuration: it
derives `foundations/<cloud>/<env>.tfstate` from `state_home` and
`environment`, so the only thing that has to match is the storage account and
container.

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
| `LETSENCRYPT_EMAIL` | Renew Certificate (ACME registration + expiry notices) |
| `DNS_ZONE_NAME`, `DNS_ZONE_RESOURCE_GROUP` | Renew Certificate (both optional — see below) |

Create GitHub **environments** for the foundations — `azure-prototype`,
`azure-staging`, `azure-prod`, `aws-prototype`, … `oci-prod` — plus one per
environment for the all-clouds tenants job: `tenants-prototype`,
`tenants-staging`, `tenants-prod`. Attach protection rules (required
reviewers for `*-prod` at minimum). The deploy workflows bind to them
automatically.

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

There is one tenants stack and one state file per environment, covering every
cloud: the target cloud is an attribute of the tenant. Edit
`tenants/envs/prototype.tfvars` and add tenants — the syntax is identical on
every cloud:

```hcl
tenants = {
  aws-team-gamma = {
    cloud  = "aws"
    name   = "team-gamma"                                  # defaults to the key
    quota  = { cpu_requests = "2", memory_requests = "4Gi" }
    labels = { "onek8s.io/cost-center" = "gamma-2002" }
  }
  gcp-team-gamma = {
    cloud = "gcp"
    name  = "team-gamma"
  }
}
```

Map keys must be unique, so the same tenant on several clouds is keyed
`<cloud>-<tenant>` with an explicit `name`; that name is what the namespace,
the cloud identity and the secret prefix are built from.

Then:

```bash
cd tenants
terraform init -backend-config=backend/prototype.hcl
terraform apply -var-file=envs/prototype.tfvars
```

One apply covers every cloud that appears in `tenants`, so it needs those
clouds' credentials — plus Azure credentials in any case, since all state
lives in the Azure Storage state home (use `az login` or ARM_* env vars).
Clouds with no tenants are skipped entirely: their foundation state is never
read and their providers stay inert.

Each cloud's foundation must already be deployed for this environment. The
stack reads `foundations/<cloud>/<environment>.tfstate` from the `state_home`
container; if a foundation was never applied there, the run stops with
"foundation has no attributes" naming the cloud, rather than a list of
unsupported attributes.

Or via Actions: **Deploy Tenants** → environment `prototype`.

## 5. Give the tenant a secret and consume it

```bash
# AWS naming contract: <env>/<tenant>/<name>
aws secretsmanager create-secret --name prototype/team-gamma/db-password --secret-string 'hunter2'

# OCI naming contract: <tenant>-<name>
oci vault secret create-base64 \
  --compartment-id "$COMPARTMENT_OCID" --vault-id "$VAULT_OCID" \
  --key-id "$VAULT_KEY_OCID" --secret-name team-gamma-db-password \
  --secret-content-content "$(printf 'hunter2' | base64)"
```

In the tenant namespace (see `docs/architecture.md` for the full example),
an `ExternalSecret` referencing `secretStoreRef: {kind: SecretStore, name:
tenant-store}` with `remoteRef.key: prototype/team-gamma/db-password` will
materialize the Kubernetes Secret. Any attempt to read another tenant's
prefix fails at the cloud IAM layer.

## 6. Wildcard certificate renewal

The **Renew Certificate** workflow keeps a Let's Encrypt wildcard for the
Azure-hosted `onek8s.lol` zone in the AKS cluster's Key Vault. It runs daily,
solves the DNS-01 challenge by writing TXT records into the zone with
[lego](https://go-acme.github.io/lego/), and imports the result as the Key
Vault certificate `platform-wildcard-onek8s-lol`. Nothing is carried between
runs: the vault's copy decides whether a renewal is due (under 30 days left),
and the ACME account key lives beside it as the secret
`platform-letsencrypt-account-key` (Let's Encrypt's staging directory is a
separate account and gets its own `platform-letsencrypt-staging-account-key`).

Both names use the reserved `platform-` prefix. Tenant access to this vault is
an ABAC condition on `<tenant>-`, so **do not name a tenant `platform`** — it
would be granted read access to the certificate and the account key.

### What to set up

1. **`LETSENCRYPT_EMAIL`** (repository variable) — the ACME registration
   contact. The workflow fails fast without it.
2. **DNS permissions.** Grant the Azure deploy service principal
   **DNS Zone Contributor** on the `onek8s.lol` zone. lego locates the zone
   with an Azure Resource Graph query over the zones the principal can read,
   so a zone it has no read access to is simply not found. Set
   `DNS_ZONE_RESOURCE_GROUP` to narrow that query when the subscription holds
   many zones, and `DNS_ZONE_NAME` when the apex is not `onek8s.lol`; both are
   optional.
3. **Key Vault permissions.** Handled by `foundations/azure` — it assigns the
   deploy principal *Key Vault Certificates Officer* alongside *Secrets
   Officer*. Certificates are a separate RBAC surface from secrets, so
   **re-apply the Azure foundation** before the first renewal, or the import
   fails with `Forbidden`.
4. **Environment protection.** The job binds to `azure-<environment>`, the
   same environment the Azure foundation deploys through. Protection rules
   apply to scheduled runs too: if `azure-prod` requires reviewers, its
   renewals wait for an approval instead of running unattended. Give the
   environments that renew on a schedule a path that does not need a human.

### Running it

```
Actions -> Renew Certificate -> Run workflow
  environment      prototype
  domains          *.onek8s.lol,onek8s.lol
  certificate_name platform-wildcard-onek8s-lol-staging
  acme_server      letsencrypt-staging     # untrusted, but not rate-limited
  force            true                    # ignore the 30-day threshold
```

Do a smoke test like the above first. It exercises the DNS-01 challenge and
the vault import end to end against Let's Encrypt's staging directory, whose
rate limits are far looser than production's five duplicate certificates per
week. Give it its own `certificate_name`: a staging certificate is issued by
an untrusted root, so it must not land on the name real workloads serve.
Delete the throwaway certificate afterwards and run again with the defaults.

The apex `onek8s.lol` is included as a second SAN because a wildcard does not
cover it. Drop it from `domains` if the zone apex is served elsewhere.

### Consuming it from the cluster

The certificate is a normal Key Vault certificate, readable through its
secret of the same name. Platform workloads (ingress, for example) need an
identity with *Key Vault Secrets User* on `platform-` the way
`modules/tenant-namespace/azure` grants it on `<tenant>-`; the tenant
identities cannot read it, by design. Nothing in the cluster is restarted
when a new version is imported — whatever consumes the certificate is
responsible for picking it up.

## Troubleshooting

### `foundation has no attributes`

```
│ Error: Invalid value for variable
│   on main.tf line 88, in module "tenants_azure":
│   No outputs in the azure foundation state for environment prototype:
│   blob key foundations/azure/prototype.tfstate in the state_home container.
```

`terraform_remote_state` read the blob and found no outputs there. The
message names the cloud, the environment and the exact blob key. The
coordinates themselves cannot be wrong any more — the key is derived — so
there are only two possibilities, and they need different fixes:

1. **The blob is not there.** The foundation was never applied, or it was
   applied while its backend pointed somewhere else: at an earlier key (the
   `prototype` backends still wrote `foundations/<cloud>/dev.tfstate` until the
   prototype rename was completed), or at that cloud's own S3/GCS/Object
   Storage bucket, before all state moved to the Azure state home.
2. **The blob is there but carries no outputs.** An apply that failed partway
   leaves resources in state without ever writing the outputs. Re-run
   `terraform apply` on that foundation until it completes; the tenants stack
   can only read what a finished apply published.

Check what the container actually holds — sizes included, since a state blob
with resources is kilobytes and a freshly created one is nearly empty:

```bash
az storage blob list \
  --account-name onek8stfstate --container-name tfstate \
  --auth-mode login --prefix foundations/ -o table
```

If the foundation was never applied, apply it (step 3). If its state exists
under a different key or backend, move it with Terraform rather than by hand
— from the foundation directory, with `backend/<env>.hcl` already updated to
the new key. When `.terraform/` no longer records the old location (a fresh
clone, or an init that already switched), point it back explicitly first:

```bash
cd foundations/azure

# 1. Re-init against the OLD key, so Terraform knows what to migrate from.
terraform init -reconfigure \
  -backend-config=resource_group_name=rg-onek8s-tfstate \
  -backend-config=storage_account_name=onek8stfstate \
  -backend-config=container_name=tfstate \
  -backend-config=key=foundations/azure/dev.tfstate \
  -backend-config=use_azuread_auth=true

# 2. Migrate it to the key the backend file (and the tenants stack) now uses.
terraform init -migrate-state -backend-config=backend/prototype.hcl
```

Verify before applying — a foundation re-applied against an empty state will
try to build a second cluster:

```bash
terraform plan -var-file=envs/prototype.tfvars   # expect "No changes"
```

### Tenants deployed before the per-cloud stacks were merged

The tenants layer used to keep one state per cloud
(`tenants/<cloud>/<env>.tfstate`) and now keeps one per environment
(`tenants/<env>.tfstate`), with different resource addresses
(`module.tenant["team-alpha"]` → `module.tenants_azure["azure-team-alpha"]`).
A first apply on the new stack therefore plans to *create* tenants that the
old states may already own. Before running it, check the old blobs:

```bash
az storage blob list \
  --account-name onek8stfstate --container-name tfstate \
  --auth-mode login --prefix tenants/ -o table
```

If they exist and hold resources, either destroy those tenants with the old
configuration first (`git checkout` the previous commit, `terraform destroy`
per cloud), or move the resources into the new state with
`terraform state mv`, then delete the stale blobs. If they are empty — which
is the case when the per-cloud stacks never applied cleanly — nothing needs
to move.

## Environment promotion

prototype → staging → prod is data-driven: the same code reads a different
`envs/<env>.tfvars` + `backend/<env>.hcl`, in both layers — the tenants stack
uses the plain environment name too, because the cloud is a per-tenant
parameter rather than part of the deployment. Merges to `main` roll the
prototype environment automatically; staging and prod are explicit
`workflow_dispatch` runs gated by their GitHub environments.
