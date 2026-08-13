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

### Ingress

Every foundation installs **Traefik** as the cluster's ingress controller
(`enable_ingress`, on by default), with the platform wildcard as its default
certificate. Publishing an application is therefore the same on all four
clouds — an `Ingress` with a host and a backend, no `ingressClassName` and no
`tls:` section:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  namespace: team-alpha
spec:
  rules:
    - host: web-team-alpha.onek8s.lol       # <app>-<tenant>.onek8s.lol
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
```

Two things have to be true around it:

1. **The certificate exists.** `platform-wildcard-onek8s-lol` must be in the
   environment's Key Vault (run **Renew Certificate** once), and — for EKS,
   GKE and OKE — have been copied out with the workflow's `distribute` mode.
   Until then Traefik serves its own self-signed certificate, and on Azure,
   where the certificate is a CSI volume, its pod does not start at all.
   On a brand-new environment the order is: apply the foundation, run the
   renewal (it reads the vault out of the foundation's state), then let the
   ingress pick the certificate up — no second apply needed.
2. **The name resolves.** On Azure, external-dns does it: list the zone in
   `ingress_dns_zone_ids` and every published Ingress host gets its record.
   On the other three clouds the record is manual — take the address from
   the controller's Service and point an A (or CNAME, on AWS) record at it:

   ```bash
   kubectl -n traefik get svc traefik \
     -o jsonpath='{.status.loadBalancer.ingress[0]}'
   ```

Hostnames are one label deep — `*.onek8s.lol` covers
`web-team-alpha.onek8s.lol`, not `web.team-alpha.onek8s.lol`.

> **Migrating an Azure environment off the application routing add-on.**
> Removing the add-on deletes its load balancer, so the ingress address
> changes, and its external-dns owns the records it wrote. The replacement
> uses a different owner ID and deliberately does not touch records it does
> not own, so delete the stale ones once — the A record *and* its
> `externaldns-`/TXT companion — and the new external-dns recreates them:
>
> ```bash
> az network dns record-set a delete -g <zone rg> -z onek8s.lol -n argocd
> az network dns record-set txt list -g <zone rg> -z onek8s.lol \
>   --query "[?contains(name,'argocd')].name" -o tsv
> ```

### Argo CD on the Azure foundation

`foundations/azure` also installs the Microsoft Argo CD cluster extension and
publishes its UI on `var.argocd_hostname` (default `argocd.onek8s.lol`)
through that same Traefik ingress, behind Entra ID sign-in. Three things
must be in place around it, none of which this stack owns:

1. **The certificate.** `var.ingress_certificate_name`
   (`platform-wildcard-onek8s-lol`) must exist in the environment's Key
   Vault — run the **Renew Certificate** workflow at least once first. The
   Argo CD Ingress names no certificate of its own; it is served the
   ingress' default one.
2. **The DNS zone.** List it in `ingress_dns_zone_ids` and external-dns keeps
   the record for every published Ingress host. The stack grants its identity
   DNS Zone Contributor on each zone; if that grant already exists out of
   band, import it (see [argocd.md](argocd.md)). Leave the list empty to
   point records by hand instead.
3. **The Entra objects.** A user-assigned managed identity for the Argo CD
   components, an app registration for sign-in with
   `https://<hostname>/auth/callback` as a redirect URI and the groups claim
   enabled, and the groups themselves. Create them in the directory, then
   record their IDs:

   ```hcl
   argocd_workload_identity_client_id = "<managed identity client id>"
   argocd_sso_client_id               = "<app registration client id>"
   argocd_rbac_group_roles = {
     "<group object id>" = "role:admin"
   }
   ```

   Leave `argocd_sso_client_id` unset and the built-in admin account is the
   only way in.

Set `enable_argocd = false` in an environment's tfvars to skip the extension
(it is in public preview). Details, roles, login and the hub-spoke plan:
[argocd.md](argocd.md).

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
  mode             renew
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
secret of the same name. On AKS the consumer is the Traefik ingress: the
Secrets Store CSI driver mounts it with the Key Vault secrets provider
add-on's identity — which `foundations/azure/ingress.tf` grants *Key Vault
Certificate User*, ABAC-narrowed to this one certificate — and syncs it into
`traefik/platform-wildcard-tls`, the ingress' default certificate. Tenant
identities cannot read it, by design.

Renewals are picked up without an apply: the driver re-reads the vault on its
rotation poll (two minutes), because the certificate is referenced without a
version. Check what actually landed with:

```bash
kubectl -n traefik get secret platform-wildcard-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -enddate
```

### Distributing it to the other clouds

Key Vault holds the certificate, but a workload on EKS, GKE or OKE reads its
secrets from that cloud's own backend. The same workflow copies the vault's
current certificate out to all three in `distribute` mode:

```
Actions -> Renew Certificate -> Run workflow
  mode             distribute
  environment      prototype
  certificate_name platform-wildcard-onek8s-lol
```

`distribute` never contacts Let's Encrypt: it reads whatever version Key Vault
holds right now and publishes it, so run it **after** a renewal (the schedule
only renews). `domains`, `acme_server` and `force` are ignored.

Each cloud's target is read out of its foundation state, the way the Key Vault
is — so a cloud with no foundation in this environment is reported as skipped
rather than failing the run, and the run needs no per-cloud coordinates:

| Cloud | Target | Secret name |
|---|---|---|
| AWS | Secrets Manager, encrypted with the foundation CMK | `<env>/platform/wildcard-onek8s-lol` |
| GCP | Secret Manager (automatic replication) | `platform-wildcard-onek8s-lol` |
| OCI | the foundation's Vault, wrapped by its master key | `platform-wildcard-onek8s-lol` |

The AWS name follows that cloud's `<env>/<tenant>/<name>` layout with the
reserved `platform` tenant; GCP and OCI use the flat `<tenant>-<name>` form,
so the Key Vault name carries over unchanged. All three are outside every
tenant's prefix, so no tenant identity can read them.

The value is one JSON object, so the key and the certificate it belongs to are
always written and read as a single version:

```json
{ "tls.crt": "-----BEGIN CERTIFICATE-----\n…", "tls.key": "-----BEGIN PRIVATE KEY-----\n…" }
```

`tls.crt` is the leaf followed by its chain and `tls.key` is PKCS#8, which is
what a Kubernetes TLS secret wants, so an `ExternalSecret` maps the two fields
straight through:

```yaml
  target:
    name: platform-wildcard-tls
    template:
      type: kubernetes.io/tls
  dataFrom:
    - extract:
        key: platform-wildcard-onek8s-lol   # "prototype/platform/wildcard-onek8s-lol" on AWS
```

That is exactly what each foundation's `ingress.tf` applies into the
`traefik` namespace on EKS, GKE and OKE, so **the distribution now has a
consumer on every cloud**: run `distribute` after a renewal and the ingress
picks the new certificate up within the hour. `dataFrom.extract` rather than
two `remoteRef`s with a `property`: the stored value is exactly these two
fields, and extracting it avoids a property path having to quote the dots in
their names.

The workflow reads the private key out of Key Vault, so it needs *Key Vault
Secrets User* (covered by the Secrets Officer role the foundation already
assigns), and write access to each target backend from the deploy identity of
that cloud. A cloud that refuses the write fails the run but does not stop the
other two — check the run summary, which lists every target and its result.

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
