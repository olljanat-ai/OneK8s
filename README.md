# OneK8s

Cloud-agnostic, multi-tenant Kubernetes platform as a Terraform monorepo.
Provisions **cluster + secret-backend pairs** on Azure (AKS + Key Vault),
AWS (EKS + Secrets Manager), GCP (GKE + Secret Manager), OCI (OKE + OCI
Vault) and the **private cloud** (Nutanix NKP + HashiCorp Vault), and
onboards tenants with **hard, cloud-enforced secret isolation** via External
Secrets Operator and per-tenant workload identities.

## Repository layout

```
├── foundations/            # Cluster + "vault" pairs — deployed independently
│   ├── azure/              #   AKS (Cilium, Workload Identity, Azure Policy, Argo CD) + Key Vault (RBAC/ABAC)
│   ├── aws/                #   EKS (Cilium chaining, IRSA) + Secrets Manager CMK
│   ├── gcp/                #   GKE (Dataplane V2, Workload Identity) + Secret Manager
│   ├── oci/                #   OKE (VCN-native pods + Cilium, Workload Identity) + OCI Vault
│   └── nutanix/            #   NKP (Cilium, Cluster API) + HashiCorp Vault (KV v2 + k8s auth)
├── modules/
│   ├── platform-ingress/   # Traefik + the platform wildcard as its default certificate
│   ├── tenant-namespace/   # Reusable tenant module — cloud is a variable
│   │   ├── main.tf ...     #   dispatcher: cloud = azure|aws|gcp|oci|nutanix
│   │   ├── common/         #   namespace, quota, netpol, SA, namespaced SecretStore
│   │   ├── azure/          #   Managed Namespace (azapi) + UAMI/FIC + ABAC prefix
│   │   ├── aws/            #   IAM role (IRSA) + ARN-prefix policy
│   │   ├── gcp/            #   GSA + WI binding + IAM condition
│   │   ├── oci/            #   workload-identity IAM policy + secret-name prefix
│   │   └── nutanix/        #   Vault k8s-auth role + path-prefix policy
│   ├── nkp-cluster-access/ # Reads an NKP workload cluster's kubeconfig from NKP
│   └── argocd-spoke/       # Registers one cluster as a spoke of the Argo CD hub
├── tenants/                # ONE stack for all clouds — deployed independently
│   ├── envs/               #   <env>.tfvars: every tenant, each with cloud = "..."
│   └── backend/            #   <env>.hcl state config (Azure state home)
├── gitops/                 # ONE stack for all clouds — Argo CD hub-spoke wiring
│   ├── envs/               #   <env>.tfvars: spokes, keyed by cloud
│   ├── backend/            #   <env>.hcl state config (Azure state home)
│   ├── root-app.tf         #   the one Argo CD object Terraform owns
│   └── argocd/             #   ...pointing at THIS: AppProject + ApplicationSets
├── apps/                   # Workloads Argo CD deploys, source and chart together
│   └── hello/              #   .NET 10 example: a welcome message and a test secret
├── .github/workflows/      # PR validation + deploy pipelines + image build
└── docs/                   # architecture, getting started, ADRs
```

Foundations are per cloud and support **prototype / dev / staging / prod**
via `envs/<env>.tfvars` + `backend/<env>.hcl`. The tenants stack has one
state file per environment covering **all clouds at once**: the cloud is a
per-tenant parameter, so a single `terraform apply` onboards tenants on
azure, aws, gcp, oci and nutanix, with identical tenant syntax everywhere.
Tenants depend on foundation remote-state outputs; foundations never depend
on tenants.

## Security model (short version)

Every tenant gets a namespace, a dedicated cloud identity federated to
exactly that tenant's `<namespace>`/`<serviceaccount>`, and a **namespaced** ESO
`SecretStore` that authenticates only with that identity. The identity can
read only its own name-prefix slice of the shared secret backend — enforced
with Key Vault **ABAC** conditions, IAM **ARN prefixes** (+ `kms:ViaService`),
Secret Manager **IAM conditions**, OCI **policy conditions** on
`target.secret.name`, and — on the private cloud, which has no cloud IAM plane
at all — a **Vault policy** on `<mount>/data/<tenant>-*`, reached by the same
OIDC federation the public clouds use: the cluster is registered with Vault as
an identity provider and the tenant's role pins the token's `sub` claim, so no
credential is stored on either side. Cross-tenant secret access is blocked
outside Kubernetes on every one of them.
Details: [ADR-0001](docs/adr/0001-per-tenant-identities-and-namespaced-secretstores.md)
and, for the private cloud,
[ADR-0002](docs/adr/0002-private-cloud-on-nkp-with-vault-as-the-identity-plane.md).

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
  azure-team-alpha   = { cloud = "azure",   name = "team-alpha" }
  aws-team-alpha     = { cloud = "aws",     name = "team-alpha" }
  nutanix-team-alpha = { cloud = "nutanix", name = "team-alpha" }  # private cloud
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
keeps in Key Vault and distributes to Secrets Manager, Secret Manager, OCI
Vault and HashiCorp Vault, read back in-cluster by External Secrets on every
one of them. Publishing an app is therefore identical on all five clouds, and
carries no TLS configuration of its own:

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

## GitOps

The Azure foundation carries the platform's delivery plane: the
Microsoft-offered **Argo CD cluster extension** (`Microsoft.ArgoCD`),
published on `https://argocd.onek8s.lol` by the same Traefik ingress every
cloud runs and terminating TLS with the `*.onek8s.lol` wildcard that ingress
serves by default. Sign-in is **Entra ID**,
with Entra groups mapped to Argo CD roles and no client secret anywhere —
the SSO app authenticates with the cluster's federated credential.

That AKS cluster is the **hub**. The `gitops/` stack registers the other
clouds' clusters as **spokes** — one Argo CD for all five clouds, no Argo CD
components anywhere else — again as one stack, all clouds, with the cloud as
a key of `var.spokes`:

```hcl
# gitops/envs/prototype.tfvars
spokes = {
  aws     = {}  # or: { namespaces = ["team-alpha"], cluster_resources = false }
  gcp     = {}
  oci     = {}
  nutanix = {}  # the private cloud is an ordinary spoke
}
```

Each spoke gets an `argocd-manager` ServiceAccount with a scoped ClusterRole
on its own cluster, and the hub gets a labelled `cluster` Secret holding that
token — so no cloud's admin kubeconfig ever lives on the hub, and an
`ApplicationSet` cluster generator can select spokes by
`onek8s.io/cloud` / `onek8s.io/environment`. EKS, GKE, OKE and the NKP
cluster are all registered. Details, scoping and trade-offs:
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
tenant's namespaced `SecretStore`. One image and one chart, on all five clouds:

| https://azure-hello.onek8s.lol | https://aws-hello.onek8s.lol | https://gcp-hello.onek8s.lol | https://oci-hello.onek8s.lol | https://nutanix-hello.onek8s.lol |
|---|---|---|---|---|
| AKS (hub) | EKS | GKE | OKE | NKP |

The only cloud-specific thing in it is *how it names the secret* it asks for —
`team-alpha-test` on Key Vault, Secret Manager, OCI Vault and HashiCorp Vault
(where it also names the field inside it, because a KV v2 secret is a map),
`prototype/team-alpha/test` on Secrets Manager, because that is what each
cloud's per-tenant prefix restriction is written against. Everything else,
ingress and TLS included, is identical.
[docs/hello-app.md](docs/hello-app.md).

The private cloud is the one that needs reading about before it is deployed:
its cluster comes from NKP rather than from Terraform, its credentials come
from inside the private network, and its identity plane is Vault —
[docs/nutanix.md](docs/nutanix.md).

Full setup (state bootstrap, GitHub secrets, environment protection):
[docs/getting-started.md](docs/getting-started.md).
Design and trade-offs: [docs/architecture.md](docs/architecture.md).
Tenant module reference: [modules/tenant-namespace/README.md](modules/tenant-namespace/README.md).

## CI/CD

- **PR validation** — fmt, validate (all 7 stacks), Helm lint/render of the
  Argo CD configuration and every application chart, tflint, checkov, and
  optional cloud plans (`ENABLE_CLOUD_PLANS=true`).
- **Deploy Foundations / Deploy Tenants / Deploy GitOps** — separate
  pipelines; the prototype environment deploys on merge to `main`, other
  environments via `workflow_dispatch`, authenticated with cloud credentials
  stored as GitHub secrets. Foundation jobs are gated by the GitHub
  environments `<cloud>-<env>`, the all-clouds tenants and gitops jobs by
  `tenants-<env>` and `gitops-<env>`.
- **Build Hello App** — builds `apps/hello` and pushes the image to GHCR on
  every merge that touches it; pull requests build without pushing. The only
  pipeline here that produces an artefact rather than applying Terraform —
  from there Argo CD takes over.
- **Renew Certificate** — monthly; issues and renews the `*.onek8s.lol`
  wildcard from Let's Encrypt over DNS-01 against the Azure-hosted
  `onek8s.lol` zone and imports it into the AKS cluster's Key Vault, together
  with the tenant test secret the hello application shows. Its `distribute`
  mode copies both out to the AWS, GCP, OCI and Nutanix backends.

## License

MIT — see [LICENSE](LICENSE).
