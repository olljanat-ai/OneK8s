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
| `gitops` (one per environment, all clouds) | `gitops/<env>.tfstate` |
| `portainer` (one per environment, all clouds) | `portainer/<env>.tfstate` |

The tenants, gitops and portainer stacks do not take the foundation keys as
configuration: they derive `foundations/<cloud>/<env>.tfstate` from
`state_home` and `environment`, so the only thing that has to match is the
storage account and container.

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
| `GRAFANA_CLOUD_TOKEN` | Publish Grafana Cloud Credentials (the access-policy token; only needed with observability enabled) |
| `PORTAINER_API_KEY` *or* `PORTAINER_PASSWORD` | the portainer stack, to register environments with the Portainer server (an API token from its UI, or the password of the admin account the Azure foundation bootstraps from Key Vault) |

And repository **variables**:

| Variable | Used by |
|---|---|
| `AWS_REGION` | aws-actions/configure-aws-credentials |
| `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_REGION` | oci provider + OCI CLI |
| `ENABLE_CLOUD_PLANS` | set to `true` to enable PR plans |
| `PORTAINER_USER` | the portainer stack, when authenticating with a username/password rather than an API key (`admin`) |
| `LETSENCRYPT_EMAIL` | Renew Certificate (ACME registration + expiry notices) |
| `DNS_ZONE_NAME`, `DNS_ZONE_RESOURCE_GROUP` | Renew Certificate (both optional — see below) |
| `GRAFANA_CLOUD_METRICS_USERNAME`, `GRAFANA_CLOUD_LOGS_USERNAME`, `GRAFANA_CLOUD_TRACES_USERNAME` | Publish Grafana Cloud Credentials (the hosted services' instance IDs; all optional, they can be typed per run) |

Create GitHub **environments** for the foundations — `azure-prototype`,
`azure-staging`, `azure-prod`, `aws-prototype`, … `oci-prod` — plus one per
environment for each of the three all-clouds jobs: `tenants-prototype` …
`tenants-prod`, `gitops-prototype` … `gitops-prod` and
`portainer-prototype` … `portainer-prod`. Attach protection
rules (required reviewers for `*-prod` at minimum). The deploy workflows bind
to them automatically.

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
   Until then the `ExternalSecret` stays unresolved and Traefik serves its own
   self-signed certificate; nothing fails. On a brand-new environment the
   order is: apply the foundation, run the renewal (it reads the vault out of
   the foundation's state), then let the ingress pick the certificate up
   within the hour — no second apply needed.
2. **The name resolves.** No cluster writes DNS, on any cloud: take the
   address from the controller's Service and point an A record (a CNAME on
   AWS, where the load balancer has a hostname) at it, once per published
   host.

   ```bash
   kubectl -n traefik get svc traefik \
     -o jsonpath='{.status.loadBalancer.ingress[0]}'
   ```

Hostnames are one label deep — `*.onek8s.lol` covers
`web-team-alpha.onek8s.lol`, not `web.team-alpha.onek8s.lol`.

#### The Traefik dashboard

Each cluster publishes Traefik's own dashboard and API on
`https://<cloud>-traefik.onek8s.lol/` — `azure-traefik`, `aws-traefik`,
`gcp-traefik`, `oci-traefik` — with the UI at `/dashboard/` (the bare host
redirects there) and the API at `/api`. It rides the same load balancer and
the same wildcard certificate as everything else, so it needs the same kind
of manual A record.

**There is no authentication on it.** Whoever reaches the host reads that
cluster's whole routing configuration: every router, service, middleware and
which certificates are loaded. It is deliberate for a lab and wrong for
anything else — set `ingress_dashboard_hostname = null` in that environment's
tfvars and reach it locally instead:

```bash
kubectl -n traefik port-forward deploy/traefik 8080:8080   # /dashboard/
```

So a fully published cluster has one record per tenant host plus one for the
dashboard, all pointed at the same address:

```
web-team-alpha.onek8s.lol   A   <ingress address>
azure-traefik.onek8s.lol    A   <ingress address>
```

#### Migrating an Azure environment off the add-ons

An environment that already ran the application routing add-on needs one
manual step **before** the apply, and one after it.

**Before.** Disabling the Key Vault secrets provider add-on fails while any
`SecretProviderClass` exists in the cluster:

```
"message": "AzureKeyvaultSecretsProvider addon cannot be disabled due to
            more than 0 Secret Provider Classes"
```

The add-on generated one from the annotation on the old Argo CD Ingress
(`keyvault-argocd`), and Terraform cannot order that cleanup itself: the
Kubernetes provider is configured *from* the cluster resource, so no
Kubernetes object can be updated before it. Delete the annotated Ingress
first — otherwise the add-on immediately regenerates the class — then the
class, then apply:

```bash
kubectl -n argocd delete ingress argocd
kubectl get secretproviderclass -A          # expect only keyvault-argocd
kubectl -n argocd delete secretproviderclass keyvault-argocd

terraform apply -var-file=envs/prototype.tfvars   # recreates the Ingress on Traefik
```

**After.** Removing the add-on deletes its load balancer *and* the
external-dns that came with it, so the records it kept are stale and now
unmanaged. Repoint the A record at the Traefik Service's address and delete
the TXT record that recorded the old controller's ownership:

```bash
az network dns record-set a update -g <zone rg> -z onek8s.lol -n argocd \
  --set arecords[0].ipv4Address=<new address>
az network dns record-set txt list -g <zone rg> -z onek8s.lol \
  --query "[?contains(name,'argocd')].name" -o tsv     # then: ... txt delete
```

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
2. **The DNS record.** `argocd.onek8s.lol` is a record like any other tenant
   host: point it at the ingress load balancer by hand (see **Ingress**
   above). Nothing in the cluster maintains it, so it has to be repointed if
   that load balancer is ever replaced.
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
(it is in public preview). Details, roles and login: [argocd.md](argocd.md).
That cluster is also the **hub** the other clouds are registered with in step
5.

### Portainer on the Azure foundation

The same stack installs **Portainer Business Edition** — the platform's fleet
console — and publishes it on `var.portainer_hostname` (default
`portainer.onek8s.lol`) through the same Traefik ingress. It needs the same
certificate and the same kind of DNS record as Argo CD, plus two secrets in
the environment's **Key Vault**, put there out of band:

| Secret | Required | What it is |
|---|---|---|
| `portainer-license` | yes | The Business Edition licence key. Passed to the server as `--license-key`, so a rebuilt cluster comes up licensed. |
| `portainer-admin-password` | recommended | Password for the built-in `admin` account, created at first start. Without it the account is created in the browser instead — and the `portainer/` stack (step 6) authenticates as it. |

```bash
az keyvault secret set --vault-name <kv> --name portainer-license       --value '<licence key>'
az keyvault secret set --vault-name <kv> --name portainer-admin-password --value '<password>'
```

Terraform reads them at apply time, so on a **brand-new** environment — where
this same apply is what creates the vault — the order is: apply once with
`enable_portainer = false`, add the secrets to the vault it created, then
apply again with it on. (The wildcard certificate has the same shape of
bootstrap, for the same reason.) An apply that cannot find the licence secret
fails rather than installing an unlicensed server.

```hcl
enable_portainer                     = true
portainer_hostname                   = "portainer.onek8s.lol"
portainer_admin_password_secret_name = "portainer-admin-password"   # null = set it in the browser
```

The DNS record carries more than the UI: `portainer.onek8s.lol:8000` on the
same load balancer is the Edge tunnel the agents on the other clouds connect
back to (Portainer derives that address from the host of its own URL). The
Azure foundation opens that port as an extra Traefik entrypoint, so one A
record covers both.

Set `enable_portainer = false` to skip the whole thing. Details and
trade-offs: [portainer.md](portainer.md).

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

## 5. Register the GitOps spokes

Argo CD runs only on the AKS cluster (step 3). The `gitops/` stack registers
the other clouds' clusters with it as spokes, so one Argo CD delivers to all
four. Like the tenants stack it is one stack and one state file per
environment, with the cloud as a key of `var.spokes`:

```hcl
# gitops/envs/prototype.tfvars
spokes = {
  aws = {}   # unrestricted; or { namespaces = [...], cluster_resources = false }
  gcp = {}
  oci = {}
}
```

```bash
cd gitops
terraform init -backend-config=backend/prototype.hcl
terraform apply -var-file=envs/prototype.tfvars
```

The run needs the hub's foundation (`foundations/azure`, applied with
`enable_argocd = true`) plus each listed spoke's foundation to exist for this
environment; it reads both out of the state home. A cloud left out of
`spokes` is skipped entirely — its foundation state is never read and its
provider stays inert — so the run needs Azure credentials plus the
credentials of the clouds actually registered.

Creating a ClusterRole is a privileged act, so each cloud's deploy identity
needs cluster-admin rights on its own spoke **for this run only** — an EKS
access entry mapping to a cluster admin, `roles/container.admin` on GCP,
`manage cluster-family` on OCI. Everything Argo CD does afterwards uses the
`argocd-manager` token instead, never those credentials. The OCI spoke also
needs the `oci` CLI on `PATH`, the way the tenants stack does: it is what
mints the cluster token.

Each spoke gets an `argocd-manager` ServiceAccount and a ClusterRole on its
own cluster, and the hub gets a labelled `cluster` Secret carrying that
token. Check the result:

```bash
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster \
  -L onek8s.io/cloud,onek8s.io/environment
```

Or via Actions: **Deploy GitOps** → environment `prototype`. Scoping,
fan-out with an `ApplicationSet` and the trade-offs (the token is long-lived
and lands in state): [argocd.md](argocd.md).

### What the same run deploys

That apply also plants the **root Application** on the hub, which is how Argo
CD's own configuration stays in this repository instead of in the UI:

```hcl
# gitops/envs/prototype.tfvars
platform_apps = {
  repo_url        = "https://github.com/olljanat-ai/OneK8s.git"
  target_revision = "main"
  tenant          = "team-alpha"
  domain          = "onek8s.lol"
}
```

It syncs `gitops/argocd/`, which holds the platform `AppProject` and the
`ApplicationSet`s — and those deploy the example application to the hub and to
every spoke registered above:

```bash
kubectl -n argocd get application platform-gitops
kubectl -n argocd get applications -l app.kubernetes.io/part-of=onek8s
# hello-azure  hello-aws  hello-gcp  hello-oci
```

Three things are needed before the pages actually render, none of them in
Terraform:

1. the image must be **public** on GHCR (the **Build Hello App** workflow
   pushes it; GHCR packages default to private and no cluster has a pull
   secret),
2. an A record per host — `azure-hello.onek8s.lol`, `aws-hello.onek8s.lol`,
   … — pointed at that cluster's Traefik Service, like every other host here,
3. the test secret in each cloud's backend, which the **Renew Certificate**
   workflow writes (section 8); until it exists the page renders "not
   available" rather than failing.

`platform_apps = { enabled = false }` registers spokes without deploying
anything. Full walkthrough: [hello-app.md](hello-app.md).

### The Azure SQL example

The same run also deploys **db-hello** to the hub — and only to the hub —
whenever the Azure foundation was applied with `enable_sql = true`. It reads
and writes the free-offer Azure SQL database as the tenant's managed identity,
so it carries no secret at all. Its coordinates are not configured anywhere:
the gitops stack takes `sql_server_fqdn` and `sql_database_name` out of the
foundation's outputs and passes them down, so a rebuilt foundation reaches the
application on the next apply.

One step is needed before the page works, and it is not Terraform — the
tenant's identity has no user in the database until somebody creates one:

```bash
gh workflow run deploy-tenants.yml -f environment=prototype

# or, if you applied the stacks yourself rather than through CI — as the SQL
# server's Entra administrator, which by default is whoever applied
# foundations/azure. Same script the workflow runs.
az login
./apps/db-hello/bootstrap.sh prototype
```

Either runs the application's own `bootstrap` command as the SQL server's Entra
administrator: it applies the EF Core migrations — the schema is code-first, so
the model in `apps/db-hello/src/Data` is where the table is defined — and
creates the database user with `db_datareader` + `db_datawriter`. It is safe to
re-run, it is how a later schema change is deployed, and it must be re-run
after a foundation rebuild (the server name carries a random suffix, so a new
foundation is a new, empty database). Until then the page says *"no
database user"* rather than failing. Plus the usual two: the image public on
GHCR, and an A record for `azure-db-hello.onek8s.lol`. Details, the free
offer's limits and the known gaps: [db-hello-app.md](db-hello-app.md).

## 6. Onboard the clusters into Portainer

Portainer runs only on the AKS cluster (step 3), where it manages that cluster
itself. The `portainer/` stack onboards the other three: it registers one
Portainer environment per cluster through the server's API and installs an
**Edge Agent** on each with the Edge key that registration generates. One
stack, one state file per environment, the cloud as a key of `var.agents`:

```hcl
# portainer/envs/prototype.tfvars
agents = {
  aws = {}   # or: { name = "eks-prototype", cluster_role = "view" }
  gcp = {}
  oci = {}
}
```

```bash
cd portainer
terraform init -backend-config=backend/prototype.hcl
PORTAINER_USER=admin PORTAINER_PASSWORD='<password>' \
  terraform apply -var-file=envs/prototype.tfvars
```

Or via Actions: **Deploy Portainer** → environment `prototype`.

Unlike the other stacks this one calls an API over the public host name, so
its prerequisites include DNS:

1. `foundations/azure` applied with `enable_portainer = true` and the
   `portainer-license` secret in its Key Vault.
2. An A record for `portainer.onek8s.lol` pointing at the AKS ingress load
   balancer. It carries both the UI (:443) and the Edge tunnel (:8000).
3. The foundations of every cloud listed in `var.agents`.
4. `PORTAINER_API_KEY`, or `PORTAINER_USER` + `PORTAINER_PASSWORD` — the
   provider reads them from the environment; the endpoint comes from the hub's
   state.

Then `terraform output environments` lists what was registered, and the
agents show up in the UI within a check-in interval:

```
$ kubectl -n portainer logs deploy/portainer-agent    # on any spoke
... [INFO] [edge] [message: Edge agent registered with the Portainer instance]
```

Each agent is granted `cluster-admin` on its own cluster — what Portainer
assumes, and wider than Argo CD's spoke ServiceAccount. The reasoning, the
`view` alternative and the operational commands are in
[portainer.md](portainer.md).

## 7. Give the tenant a secret and consume it

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

The `hello` application is the working version of exactly that, on all four
clouds at once — its secret is `test` under the `team-alpha` prefix, and it is
the one tenant secret nobody has to write: the **Renew Certificate** workflow
generates it in Key Vault and distributes it with the wildcard (section 8).
[hello-app.md](hello-app.md) has the four commands to seed it by hand instead
(note the AWS one: the secret must be encrypted with the tenant CMK, or the
tenant's scoped `kms:Decrypt` grant cannot read it back).

## 8. Wildcard certificate renewal

The **Renew Certificate** workflow keeps a Let's Encrypt wildcard for the
Azure-hosted `onek8s.lol` zone in the AKS cluster's Key Vault. It runs monthly,
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

The workflow writes one object outside that prefix, on purpose: the tenant
**test secret** `team-alpha-test`, which the hello application reads on every
cloud ([hello-app.md](hello-app.md#the-test-secret)). It is generated in the
same vault, rotated whenever the certificate is renewed — and seeded when it
is missing, so a fresh environment gets one on the first run — and copied out
to the other clouds by the same `distribute` mode. The `tenant` input names
it; it must match `platform_apps.tenant` in `gitops/envs/<env>.tfvars`, since
that is the only prefix the application's identity may read.

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
secret of the same name. On AKS the consumer is the Traefik ingress, and it
reads the vault the same way a tenant reads its own secrets: an ESO
`SecretStore` authenticating as a user-assigned identity that
`foundations/azure/ingress.tf` creates, federates to the ingress'
ServiceAccount and grants *Key Vault Secrets User* — ABAC-narrowed to this one
certificate. Tenant identities cannot read it, by design.

What the vault returns for a certificate is the PEM bundle that was imported,
key followed by chain, so the `ExternalSecret` splits it with `filterPEM`
into the `tls.crt` and `tls.key` of `traefik/platform-wildcard-tls` — the
ingress' default certificate. Renewals are picked up without an apply: the
certificate is referenced without a version and ESO refreshes hourly. Check
what actually landed with:

```bash
kubectl -n traefik get secret platform-wildcard-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -enddate
```

### Distributing it to the other clouds

Key Vault holds the certificate, but a workload on EKS, GKE or OKE reads its
secrets from that cloud's own backend. The same workflow copies the vault's
current certificate — and the test secret beside it — out to all three in
`distribute` mode:

```
Actions -> Renew Certificate -> Run workflow
  mode             distribute
  environment      prototype
  certificate_name platform-wildcard-onek8s-lol
  tenant           team-alpha
```

`distribute` never contacts Let's Encrypt: it reads whatever versions Key
Vault holds right now and publishes them, so run it **after** a renewal (the
schedule only renews). `domains`, `acme_server` and `force` are ignored.

Each cloud's target is read out of its foundation state, the way the Key Vault
is — so a cloud with no foundation in this environment is reported as skipped
rather than failing the run, and the run needs no per-cloud coordinates:

| Cloud | Target | Certificate | Test secret |
|---|---|---|---|
| AWS | Secrets Manager, encrypted with the foundation CMK | `<env>/platform/wildcard-onek8s-lol` | `<env>/team-alpha/test` |
| GCP | Secret Manager (automatic replication) | `platform-wildcard-onek8s-lol` | `team-alpha-test` |
| OCI | the foundation's Vault, wrapped by its master key | `platform-wildcard-onek8s-lol` | `team-alpha-test` |

The AWS names follow that cloud's `<env>/<tenant>/<name>` layout — the
certificate under the reserved `platform` tenant, the test secret under the
real one; GCP and OCI use the flat `<tenant>-<name>` form, so the Key Vault
names carry over unchanged. The certificate's three names are outside every
tenant's prefix, so no tenant identity can read it. The test secret's are
inside `team-alpha`'s, which is what lets that tenant — and only that tenant —
read it. On AWS it is encrypted with the same foundation CMK as the
certificate, which is also the key the tenant's scoped `kms:Decrypt` grant
names; under any other key the tenant could not read it back.

A vault with no test secret yet is a warning, not a failure: the certificate
is what this job exists for, and the run summary says which objects each
cloud received.

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

## 9. Observability with Grafana Cloud

Every foundation can run Grafana Alloy and ship that cluster's metrics, logs
and events to one Grafana Cloud stack, where all four clusters show up under
`onek8s-<cloud>-<environment>`. It needs two things, and neither of them can be
guessed from this repository.

1. **The endpoints**, which are per stack and on its Details page in Grafana
   Cloud. Azure and AWS already carry this lab's stack as defaults in
   `foundations/<cloud>/variables.tf` — a different stack, or one of the two
   clouds that are still off, is configured in that cloud's tfvars, where a
   commented block is waiting:

   ```hcl
   # foundations/<cloud>/envs/prototype.tfvars
   enable_observability      = true
   grafana_cloud_metrics_url = "https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push"
   grafana_cloud_logs_url    = "https://logs-prod-012.grafana.net/loki/api/v1/push"
   grafana_cloud_traces_url  = "https://tempo-prod-01-prod-eu-west-0.grafana.net:443"   # optional
   ```

2. **The credentials**, which are not configuration and never reach Terraform.
   Create an access policy on the stack with the `*:write` scopes for the
   signals you enable, take a token from it (it starts with `glc_`), store it as
   the `GRAFANA_CLOUD_TOKEN` repository secret, and run:

   ```
   Actions -> Publish Grafana Cloud Credentials -> Run workflow
     environment      prototype
     metrics_username 1234567          # or leave blank and set the repository variables
     logs_username    7654321
   ```

   That writes one JSON object to the environment's Key Vault and copies it to
   the AWS, GCP and OCI backends — the same road the wildcard certificate
   takes, so each cluster reads it from the backend it already reads its tenant
   secrets from, through a observability identity granted that one secret and
   nothing else.

Then apply the foundations. Order does not matter: a cluster applied before
the credentials exist leaves the `ExternalSecret` unresolved and starts
reporting on its own within the hour of the publication.

```bash
kubectl -n observability get externalsecret grafana-cloud   # SecretSynced
kubectl -n observability get alloy                          # one per collector
```

Pod logs are the largest single contributor to the bill on a chatty cluster, so
Azure and AWS ship with `observability_enable_pod_logs = false`; metrics and
cluster events are unaffected by that, and `= true` turns the log DaemonSet on.
Feature set, the cluster label, rotation and the trade-offs:
[observability.md](observability.md).

## Troubleshooting

### `AzureKeyvaultSecretsProvider addon cannot be disabled`

```
│ Error: updating Kubernetes Cluster … unexpected status 400 (400 Bad Request)
│   "message": "AzureKeyvaultSecretsProvider addon cannot be disabled due to
│               more than 0 Secret Provider Classes"
```

AKS will not turn the add-on off while a `SecretProviderClass` still exists,
and the application routing add-on generates one per Ingress annotated with
`kubernetes.azure.com/tls-cert-keyvault-uri`. This is the one-time migration
off the add-ons: delete the annotated Ingress, then the generated class, then
re-apply — the sequence is under **Ingress → Migrating an Azure environment
off the add-ons** above. Deleting the class alone is not enough; while the
annotated Ingress is still there, the add-on writes it back.

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
