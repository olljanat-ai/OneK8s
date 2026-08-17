# OneK8s

Cloud-agnostic, multi-tenant Kubernetes platform as a Terraform monorepo.
Provisions **cluster + secret-backend pairs** on Azure (AKS + Key Vault),
AWS (EKS + Secrets Manager), GCP (GKE + Secret Manager) and OCI (OKE + OCI
Vault), and onboards tenants with **hard, cloud-enforced secret isolation**
via External Secrets Operator and per-tenant workload identities.

## Repository layout

```
├── foundations/            # Cluster + "vault" pairs — deployed independently
│   ├── azure/              #   AKS (Cilium, Workload Identity, Argo CD, Portainer) + Key Vault (RBAC/ABAC)
│   │                       #   ...and Azure SQL on the free offer, Entra-only (sql.tf)
│   ├── aws/                #   EKS (Cilium chaining, IRSA) + Secrets Manager CMK
│   ├── gcp/                #   GKE (Dataplane V2, Workload Identity) + Secret Manager
│   └── oci/                #   OKE (VCN-native pods + Cilium, Workload Identity) + OCI Vault
├── modules/
│   ├── platform-ingress/   # Traefik + the platform wildcard as its default certificate
│   ├── platform-observability/# Grafana Alloy (k8s-monitoring) shipping to Grafana Cloud
│   ├── tenant-namespace/   # Reusable tenant module — cloud is a variable
│   │   ├── main.tf ...     #   dispatcher: cloud = azure|aws|gcp|oci, unified outputs
│   │   ├── common/         #   namespace, quota, netpol, SA, namespaced SecretStore
│   │   ├── azure/          #   Managed Namespace (azapi) + UAMI/FIC + ABAC prefix
│   │   ├── aws/            #   IAM role (IRSA) + ARN-prefix policy
│   │   ├── gcp/            #   GSA + WI binding + IAM condition
│   │   └── oci/            #   workload-identity IAM policy + secret-name prefix
│   ├── argocd-spoke/       # Registers one cluster as a spoke of the Argo CD hub
│   └── portainer-agent/    # Installs the Portainer Edge Agent on one cluster
├── tenants/                # ONE stack for all clouds — deployed independently
│   ├── envs/               #   <env>.tfvars: every tenant, each with cloud = "..."
│   └── backend/            #   <env>.hcl state config (Azure state home)
├── gitops/                 # ONE stack for all clouds — Argo CD hub-spoke wiring
│   ├── envs/               #   <env>.tfvars: spokes, keyed by cloud
│   ├── backend/            #   <env>.hcl state config (Azure state home)
│   ├── root-app.tf         #   the one Argo CD object Terraform owns
│   └── argocd/             #   ...pointing at THIS: AppProject + ApplicationSets
├── portainer/              # ONE stack for all clouds — Portainer server + agents
│   ├── envs/               #   <env>.tfvars: clusters to onboard, keyed by cloud
│   └── backend/            #   <env>.hcl state config (Azure state home)
├── apps/                   # Workloads Argo CD deploys, source and chart together
│   ├── hello/              #   .NET 10 example: a welcome message and a test secret
│   └── db-hello/           #   .NET 10 example: Azure SQL as the tenant's managed identity
├── .github/workflows/      # PR validation + deploy pipelines + image build
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

Every tenant namespace also enforces the **`restricted` Pod Security
Standard** — the only built-in level that requires a **non-root user**, so a
workload that has not said who it runs as is refused at admission rather than
started as root. It is labelled on the namespace on every cloud (on the ARM
managed namespace on AKS) and lowered per tenant, in Git, when something
genuinely cannot comply.

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

## Ingress

Every cluster runs **Traefik**, installed from one module, with its
IngressClass as the cluster default and the `*.onek8s.lol` wildcard as its
**default certificate** — the certificate the Renew Certificate workflow
keeps in Key Vault and distributes to Secrets Manager, Secret Manager and OCI
Vault, read back in-cluster by External Secrets on every one of them.
Publishing an app is therefore identical on all four clouds, and carries no
TLS configuration of its own:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: web, namespace: team-alpha }
spec:
  rules:
    - host: web-team-alpha.onek8s.lol      # <app>-<tenant>.onek8s.lol
      http:
        paths:
          - { path: /, pathType: Prefix, backend: { service: { name: web, port: { number: 80 } } } }
```

Names are one label deep, because that is what the wildcard covers. DNS is
out of band on every cloud — point a record at `kubectl -n traefik get svc
traefik`. Turn the whole thing off per environment with `enable_ingress`.

Each cluster also publishes its Traefik dashboard and API on
`https://<cloud>-traefik.onek8s.lol/`, **unauthenticated** — a deliberate lab
convenience, switched off per environment with
`ingress_dashboard_hostname = null`.

## Observability

Every cluster can run **Grafana Alloy**, installed from one module
(`modules/platform-observability`, Grafana's [k8s-monitoring][k8smon] chart), and
ship its metrics, logs and events to **one Grafana Cloud stack**. Four
clusters, one stack, told apart only by a `cluster` label carrying the cloud
and the environment:

```promql
count by (cluster) (up)
# onek8s-azure-prototype  onek8s-aws-prototype  onek8s-gcp-prototype  onek8s-oci-prototype
```

[k8smon]: https://github.com/grafana/k8s-monitoring-helm

The collectors are the same everywhere and only the ones the enabled features
need are created, so a cluster with pod logs turned off runs no log DaemonSet
at all. The one cloud-shaped part is how the credentials arrive, and it is the
wildcard certificate's road with a different payload: written to Key Vault by
the **Publish Grafana Cloud Credentials** workflow, distributed to the other
three backends, then read in-cluster by External Secrets over that cloud's own
identity — so the token is in no state file, and a rotation reaches the
collectors without an apply or a restart.

The stack's endpoints are configuration of the platform rather than of a
cloud, so they are the module's own defaults and no foundation repeats them; a
cluster that has to write somewhere else overrides them per signal from its
environment.

```hcl
# foundations/<cloud>/envs/<env>.tfvars — one switch per cluster
enable_observability = true
```

**Azure** and **AWS** — the two clouds this lab runs — have it on, so the
collectors come up with the foundation; GCP and OCI are off. Setup, the
feature set and the trade-offs: [docs/observability.md](docs/observability.md).

## GitOps

The Azure foundation carries the platform's delivery plane: the
Microsoft-offered **Argo CD cluster extension** (`Microsoft.ArgoCD`),
published on `https://argocd.onek8s.lol` by the same Traefik ingress every
cloud runs and terminating TLS with the `*.onek8s.lol` wildcard that ingress
serves by default. Sign-in is **Entra ID**,
with Entra groups mapped to Argo CD roles and no client secret anywhere —
the SSO app authenticates with the cluster's federated credential.

That AKS cluster is the **hub**. The `gitops/` stack registers the other
clouds' clusters as **spokes** — one Argo CD for all four clouds, no Argo CD
components anywhere else — again as one stack, all clouds, with the cloud as
a key of `var.spokes`:

```hcl
# gitops/envs/prototype.tfvars
spokes = {
  aws = {}    # or: { namespaces = ["team-alpha"], cluster_resources = false }
  gcp = {}
  oci = {}
}
```

Each spoke gets an `argocd-manager` ServiceAccount with a scoped ClusterRole
on its own cluster, and the hub gets a labelled `cluster` Secret holding that
token — so no cloud's admin kubeconfig ever lives on the hub, and an
`ApplicationSet` cluster generator can select spokes by
`onek8s.io/cloud` / `onek8s.io/environment`. EKS, GKE and OKE are all
registered. Details, scoping and trade-offs:
[docs/argocd.md](docs/argocd.md).

Argo CD's own configuration is version-controlled too. Terraform creates
exactly one object — a **root Application** pointing at `gitops/argocd/` in
this repository — and everything below it (the platform `AppProject`, the
`ApplicationSet`s, and every `Application` they generate on the hub and on each
spoke) is YAML in that directory. Adding an application is a commit, not a
`terraform apply`, and nothing is clicked together in the UI.

## Applications

`apps/` holds what Argo CD deploys, source and chart side by side. The example
is **hello**: a minimal .NET 10 page showing a welcome message and the value of
a test secret, read out of the host cloud's own secret backend through the
tenant's namespaced `SecretStore`. One image and one chart, on all four clouds:

| https://azure-hello.onek8s.lol | https://aws-hello.onek8s.lol | https://gcp-hello.onek8s.lol | https://oci-hello.onek8s.lol |
|---|---|---|---|
| AKS (hub) | EKS | GKE | OKE |

The only cloud-specific thing in it is the *name* of the secret it asks for —
`team-alpha-test` on Key Vault, Secret Manager and OCI Vault,
`prototype/team-alpha/test` on Secrets Manager, because that is what each
cloud's per-tenant prefix restriction is written against. Everything else,
ingress and TLS included, is identical.
[docs/hello-app.md](docs/hello-app.md).

The second example is **db-hello**, on <https://azure-db-hello.onek8s.lol>, and
it carries no secret at all: it reads and writes an **Azure SQL Database** as
the tenant's own managed identity, with a token minted from the ServiceAccount
token Kubernetes projects into the pod. No connection string, no password,
nothing to rotate — the chart passes it a host name and a database name, and
neither authorizes anybody. Data access is **Entity Framework Core**,
code-first: the model in `apps/db-hello/src/Data` is the only description of
the schema anywhere, and the migrations generated from it are committed
alongside the code.

The database is the Azure foundation's, on the **free offer**: 100,000 vCore
seconds and 32 GB a month, auto-pausing rather than billing when that runs out.
The server is **Entra-only**, so it has no SQL login to leak. Two things about it cannot be Terraform — applying a migration and creating a
contained database user both happen *inside* the database — so both are one
command in the application itself, run by a workflow like the tenant test
command in the application itself, which **Deploy Tenants** runs for every
Azure tenant it onboards — so there is nothing separate to remember. The pod
runs that same image and cannot do either: it holds `db_datareader` and
`db_datawriter`, so the database refuses it DDL.
This is the platform's one deliberately Azure-only application, because its
database is an Azure resource and its identity is an Entra one.
[docs/db-hello-app.md](docs/db-hello-app.md).

## Fleet console

The same AKS cluster runs **Portainer Business Edition**, published on
`https://portainer.onek8s.lol` by the same Traefik ingress and terminating TLS
with the same wildcard. Its licence and its initial admin password are read
from the environment's Key Vault, so a rebuilt cluster comes up licensed with
nothing to click.

Portainer manages the AKS cluster directly — its chart binds a `cluster-admin`
ServiceAccount there — and the other three clouds through **Edge Agents**,
installed by the `portainer/` stack, again as one stack, all clouds, with the
cloud as a key of `var.agents`:

```hcl
# portainer/envs/prototype.tfvars
agents = {
  aws = {}    # or: { name = "eks-prototype", cluster_role = "view" }
  gcp = {}
  oci = {}
}
```

An Edge Agent connects **outbound only**: it polls the Portainer URL and opens
a reverse tunnel back to `portainer.onek8s.lol:8000` — an extra TCP entrypoint
on the same ingress load balancer — so nothing on EKS, GKE or OKE has to be
reachable from anywhere, and the whole credential is one Edge key the server
can revoke. Registering an environment is what generates that key, which is why
this is a layer of its own rather than part of a foundation.

Argo CD deploys; Portainer is how an operator looks at what is deployed, on any
cloud, without four kubeconfigs. Details, prerequisites and trade-offs:
[docs/portainer.md](docs/portainer.md).

Full setup (state bootstrap, GitHub secrets, environment protection):
[docs/getting-started.md](docs/getting-started.md).
Design and trade-offs: [docs/architecture.md](docs/architecture.md).
Tenant module reference: [modules/tenant-namespace/README.md](modules/tenant-namespace/README.md).

## CI/CD

- **PR validation** — fmt, validate (all 7 stacks), Helm lint/render of the
  Argo CD configuration and every application chart, tflint, checkov, and
  optional cloud plans (`ENABLE_CLOUD_PLANS=true`).
- **Deploy Foundations / Deploy Tenants / Deploy GitOps / Deploy Portainer** —
  separate pipelines; the prototype environment deploys on merge to `main`,
  other environments via `workflow_dispatch`, authenticated with cloud
  credentials stored as GitHub secrets. Foundation jobs are gated by the GitHub
  environments `<cloud>-<env>`, the all-clouds tenants, gitops and portainer
  jobs by `tenants-<env>`, `gitops-<env>` and `portainer-<env>`.
- **Build Hello App** / **Build DB Hello App** — build `apps/hello` and
  `apps/db-hello` and push their images to GHCR on every merge that touches
  them; pull requests build without pushing. The only pipelines here that
  produce an artefact rather than applying Terraform — from there Argo CD takes
  over.
  **Deploy Tenants** has a second job for the one thing a tenant gets that
  cannot be a Terraform resource: it runs `apps/db-hello/bootstrap.sh`, which
  invokes the application's own migrate-and-grant command as the SQL server's
  Entra administrator for every Azure tenant the apply just onboarded.
  Idempotent, and where a later schema change is deployed from — neither a
  table nor a database user has an ARM representation, so neither can be in
  the stack. Run the same script by hand after applying the stacks by hand;
  `terraform apply` alone never creates the database user.
- **Publish Grafana Cloud Credentials** — on demand; writes the Grafana Cloud
  access-policy token and instance IDs into Key Vault as one JSON object and
  copies it to the AWS, GCP and OCI backends, so no cluster's observability
  credentials come from Terraform.
- **Renew Certificate** — monthly; issues and renews the `*.onek8s.lol`
  wildcard from Let's Encrypt over DNS-01 against the Azure-hosted
  `onek8s.lol` zone and imports it into the AKS cluster's Key Vault, together
  with the tenant test secret the hello application shows. Its `distribute`
  mode copies both out to the AWS, GCP and OCI backends.

## License

MIT — see [LICENSE](LICENSE).
