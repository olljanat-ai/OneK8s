# Architecture

## Overview

OneK8s provisions **cluster + secret-backend pairs** ("foundations") on
Azure, AWS, GCP and OCI, onboards **tenants** onto those clusters with hard,
cloud-enforced secret isolation, and joins all four clusters to a **single
Argo CD control plane** on AKS that the other three reach outbound
(["GitOps: hub and spokes"](#gitops-hub-and-spokes)).

```
┌──────────── per environment: foundations per cloud, one tenants stack ────────────┐
│                                                                                   │
│  foundations/<cloud>                          tenants/ (cloud per tenant)         │
│  ┌─────────────────────────────┐              ┌─────────────────────────────┐     │
│  │ Cluster (AKS/EKS/GKE/OKE)   │   remote     │ for each tenant:            │     │
│  │  - workload identity/IRSA   │   state      │  - namespace (+quota,netpol)│     │
│  │  - Cilium / Dataplane V2    │ ──outputs──▶ │  - cloud identity           │     │
│  │  - External Secrets Operator│              │  - ServiceAccount           │     │
│  │  - policy guardrails        │              │  - namespaced SecretStore   │     │
│  │ Secret backend              │              │  - prefix-scoped IAM        │     │
│  │  (KV / SM / GSM / Vault)    │              └─────────────────────────────┘     │
│  └─────────────────────────────┘                                                  │
└───────────────────────────────────────────────────────────────────────────────────┘
```

## Layering and dependency direction

| Layer | Stacks | State | Deploys |
|---|---|---|---|
| Foundations | `foundations/{azure,aws,gcp,oci}` | `foundations/<cloud>/<env>.tfstate` in the Azure Storage state home | independently |
| Tenants | `tenants/` (one stack, all clouds; `cloud` is a per-tenant parameter) | `tenants/<env>.tfstate` in the Azure Storage state home | independently, **after** the foundations of the clouds its tenants use |
| GitOps | `gitops/` (one stack, all clouds; Azure is the hub, the rest are spokes) | `gitops/<env>.tfstate` in the Azure Storage state home | independently, **after** the foundations of the hub and of every spoke |

**One state home.** Every stack — whichever cloud it provisions — keeps its
state in the same Azure Storage account, distinguished only by blob key.
Bootstrapping is therefore a single storage account rather than one bucket
per cloud, `terraform_remote_state` is a single `azurerm` read instead of
one data source per backend type, and state RBAC/versioning/retention is
configured in one place. The price is that every deploy needs Azure
credentials in addition to the target cloud's.

Tenants consume foundation outputs via `terraform_remote_state` only.
Foundations never reference tenants — the dependency arrow points one way.

Both layers select an environment the same way, with
`-backend-config=backend/<env>.hcl` and `-var-file=envs/<env>.tfvars`. The
difference is that a foundation is one cloud's cluster, while the **single
tenants stack covers every cloud in one state file and one apply**: `cloud`
is an attribute of each tenant, not of the deployment.

```hcl
tenants = {
  azure-team-alpha = { cloud = "azure", name = "team-alpha" }
  aws-team-alpha   = { cloud = "aws",   name = "team-alpha" }
}
```

Inside the stack, tenants are grouped by cloud and each group is passed its
own cluster's `kubernetes` provider alias — provider configurations cannot be
chosen per `for_each` instance, which is the one place the cloud has to be
enumerated in code. Per tenant, the dispatcher module
(`modules/tenant-namespace`) then instantiates exactly one cloud
implementation. Clouds with no tenants in the environment read no foundation
state, contact no cluster and keep inert provider configurations (mock
credentials, zero resources), so a run needs Azure credentials (state home)
plus the credentials of the clouds that actually have tenants.

The foundation states are addressed by convention rather than configuration:
the tenants stack derives the blob key `foundations/<cloud>/<env>.tfstate`
from the state home account/container and the environment, which is exactly
what `foundations/<cloud>/backend/<env>.hcl` writes. There are no per-cloud
coordinates to keep in sync, so the two halves cannot drift apart — an empty
read now means the foundation was never applied, and the tenant module says
so in one message instead of a list of "Unsupported attribute" errors.

## Cloud mapping

| Capability | Azure | AWS | GCP | OCI |
|---|---|---|---|---|
| Cluster | AKS | EKS | GKE | OKE (enhanced) |
| Pod-level cloud identity | Workload Identity (OIDC issuer + FIC) | IRSA (IAM OIDC provider) | Workload Identity (`<project>.svc.id.goog`) | OKE Workload Identity (no identity object — the principal *is* cluster+ns+SA) |
| Networking | Azure CNI overlay + **Cilium data plane** | VPC CNI + **Cilium (chaining)** | **Dataplane V2** (Cilium-based) | VCN-native pod networking + **Cilium (chaining)** |
| Secret backend | Key Vault (RBAC + ABAC) | Secrets Manager (+ CMK) | Secret Manager | OCI Vault (+ master key) |
| Tenant namespace | **Azure Managed Namespace** (azapi) | Namespace + quota + netpol | Namespace + quota + netpol | Namespace + quota + netpol |
| Guardrails | Azure Policy add-on + baseline initiative | (optional Kyverno/Gatekeeper) | (optional Kyverno/Gatekeeper) | (optional Kyverno/Gatekeeper) |

## Secret isolation (the core security invariant)

A tenant reaches secrets only through this chain, and every link is scoped
to that single tenant:

```
Pod ──(runs as)──▶ ServiceAccount ──(federated token)──▶ Cloud identity ──(prefix-scoped IAM)──▶ Shared backend
        ▲                     ▲                                  ▲
        │                     │ subject pinned to that           │ ABAC / ARN prefix / IAM condition:
        │                     │ tenant's namespace + SA          │ only "<tenant>-…" / "<env>/<tenant>/…"
        └── ExternalSecret may only reference the SecretStore in its own namespace
```

Secret naming contract per tenant:

- Azure Key Vault: `"<tenant>-<name>"`
- AWS Secrets Manager: `"<env>/<tenant>/<name>"`
- GCP Secret Manager: `"<tenant>-<name>"`
- OCI Vault: `"<tenant>-<name>"`

Because the prefix *is* the boundary, a tenant name is also a claim on a slice
of the shared backend. `platform-` is reserved for the platform's own objects
(the wildcard certificate and its ACME account key, see below) and must not be
used as a tenant name — a tenant called `platform` would be granted exactly
those. The same contract places the distributed wildcard certificate: it is
the reserved `platform` tenant's secret on every cloud, so it is
`platform-wildcard-onek8s-lol` on Azure, GCP and OCI, and
`<env>/platform/wildcard-onek8s-lol` on AWS.

Consuming a secret from a tenant workload:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-db
  namespace: team-alpha
spec:
  secretStoreRef:
    kind: SecretStore
    name: tenant-store
  target:
    name: app-db
  data:
    - secretKey: password
      remoteRef:
        key: team-alpha-db-password   # Azure/GCP; "dev/team-alpha/db-password" on AWS
```

## GitOps: hub and spokes

Argo CD runs **once**, on the AKS cluster, installed by the Azure Argo CD
cluster extension (`Microsoft.ArgoCD`) and served at
`https://argocd.onek8s.lol`. The other three clusters do not get their own
Argo CD UI, and they do not get an inbound path from the hub either. They join
it as spokes through [argocd-agent](https://github.com/argoproj-labs/argocd-agent),
which inverts the usual multi-cluster direction: the hub never dials a
workload cluster, each workload cluster dials the hub.

```
                          ┌───────────── AKS: the hub ─────────────┐
                          │ Argo CD (AKS extension)                │
  Application in argocd   │  argocd-server ─┐                      │
  destination.name: ──────┼─▶ (routing)     │ live resources       │
    aws-prototype         │                 ▼                      │
                          │  argocd-agent principal                │
                          │   ├─ gRPC          :443  (public, mTLS)│
                          │   ├─ resource proxy:9090 (in-cluster)  │
                          │   └─ redis proxy   :6379 (in-cluster)  │
                          └────────────▲───────────────────────────┘
                     one outbound gRPC │ connection per spoke
             ┌────────────────┬────────┴────────┬────────────────┐
        ┌────┴─────┐     ┌────┴─────┐      ┌────┴─────┐
        │ EKS      │     │ GKE      │      │ OKE      │
        │  agent   │     │  agent   │      │  agent   │
        │  + Argo CD application controller / repo server / redis │
        └──────────┘     └──────────┘      └──────────┘
```

**What is public, and what is not.** Exactly one endpoint in this topology
accepts a connection from outside its own cluster: the principal's gRPC
service on the hub, exposed as an AKS LoadBalancer with a DNS label so its
name is known before it exists (the name goes into a certificate and into
every agent's configuration, both of which are created in the same apply).
The resource proxy and the redis proxy stay `ClusterIP` — they are the hub's
own Argo CD talking to the principal, not cross-cluster traffic. A spoke
exposes nothing: it needs egress to the hub and nothing else, which is the
whole point. A cluster behind NAT with no reachable API server works exactly
like one without.

**Authentication.** mTLS against a CA created in `gitops/pki.tf` and stored
only on the hub. An agent's identity *is* its client certificate: the
principal is configured with `auth = "mtls:CN=([^,]+)"`, so it reads the agent
name out of the certificate subject and requires it to match a registered
agent. There is no bearer token, no shared secret and no password to rotate,
and a spoke cannot claim to be another spoke without a certificate this CA
signed for that name. That is also why a public endpoint is acceptable: an
unauthenticated caller does not get past the TLS handshake.

The project ships a CLI (`argocd-agentctl`) that generates all of this
imperatively, against two kubeconfigs, five commands per agent. It is not used
here. The certificates are `tls_*` resources instead, so an expiring
certificate is a plan diff rather than a runbook entry, and adding a spoke is
one map entry. The secrets produced are what the CLI would have written — same
names, same keys, same subject conventions — so `argocd-agentctl` still works
for inspection. The cost is that the CA private key and every agent key live
in this stack's state, next to the cluster credentials the tenants stack
already keeps there.

**Routing.** Destination-based mapping: an `Application` lives in the hub's
own `argocd` namespace and names its target agent in `spec.destination.name`.
The alternative — namespace-based mapping, where the Application's namespace
*is* the agent name — would need Argo CD's apps-in-any-namespace turned on for
one namespace per agent. That setting lives in `argocd-cmd-params-cm`, which
the AKS extension owns and reverts direct edits to, so it would have to be
pushed through extension configuration. Destination-based mapping avoids the
question entirely and is the model Argo CD users already know from
`argocd cluster add`.

**Agent modes.** Managed by default: Applications are created on the hub and
pushed down, and the agent reports status back. `mode = "autonomous"` inverts
it per spoke — that cluster owns its Applications from its own git and the hub
becomes a read-only mirror that can still sync, refresh and act on resources.

**What runs where.** The hub keeps the full Argo CD the extension installs
(including an application controller, which is why every agent's cluster
secret carries `argocd.argoproj.io/skip-reconcile: "true"` — those clusters
are the principal's to reconcile, through the agent, not the local
controller's). Each spoke gets the workload half: application controller, repo
server and redis, but no `argocd-server`. Leaving the API server out is what
keeps a spoke free of anything worth exposing.

**Live resources** — the resource tree in the UI, pod logs, the terminal —
work through the resource proxy, which forwards Kubernetes API requests down
the agent's existing connection. Two things gate it, and both are handled but
worth knowing about: agents need cluster-wide *read* (the agent chart only
grants access to Argo CD's own resources, so `modules/argocd-spoke` adds a
read-only ClusterRole), and the hub's `argocd-server` must read cached state
through the principal's redis proxy rather than straight from redis. The
second is a change to `argocd-cmd-params-cm`, which only the extension can
make — see the `manage_hub_extension` variable and the `hub_extension_command`
output.

## CI/CD

- `pr-validation.yml` — fmt, per-stack validate, tflint, checkov, and (once
  `ENABLE_CLOUD_PLANS=true`) credentialed prototype plans for all six
  stacks.
- `deploy-foundations.yml` / `deploy-tenants.yml` / `deploy-gitops.yml` —
  independent pipelines; merge to `main` auto-deploys the prototype
  environment on path changes, other environments go through
  `workflow_dispatch`. Deploy Foundations fans out per cloud; Deploy Tenants
  and Deploy GitOps are single all-clouds jobs. All delegate to the reusable
  `_terraform-deploy.yml`, which binds each run to a GitHub environment —
  `<cloud>-<env>` for foundations, `tenants-<env>` and `gitops-<env>` for the
  all-clouds stacks — so protection rules (required reviewers, wait timers)
  gate production applies.
- `renew-certificate.yml` — daily issuance/renewal of the `*.onek8s.lol`
  wildcard from Let's Encrypt, solved with DNS-01 against the Azure-hosted
  `onek8s.lol` zone and imported into the environment's Key Vault. It binds
  to the same `azure-<env>` GitHub environment as the Azure foundation, so
  the vault's credentials are configured in one place.

  The workflow keeps **no state of its own**. It resolves the vault from
  `foundations/azure`'s `key_vault_uri` output — whichever vault the
  foundation built is the one the cluster reads from, so it is the one the
  certificate belongs in — and then the vault answers both questions the
  run has: the stored certificate's `attributes.expires` decides whether a
  renewal is due (under 30 days left, or `force`), and the ACME account key
  is stored beside it as `platform-letsencrypt-account-key` so every renewal
  reuses the same Let's Encrypt account rather than registering a new one.
  A run with nothing to do exits before ACME is contacted, which is why it
  can afford to run daily: the certificate gets ~30 attempts inside its
  renewal window.

  The same workflow's `distribute` mode copies that certificate to the other
  three clouds, so a workload on EKS, GKE or OKE reads it from the backend it
  already reads its tenant secrets from rather than reaching into Azure for
  it. Key Vault stays the single source of truth and the other three hold
  copies; a distribution run publishes whatever version the vault holds and
  never contacts Let's Encrypt, which keeps issuance and replication
  independently retryable. The targets are resolved the way the vault is —
  out of each `foundations/<cloud>` state (`secrets_kms_key_arn` + `region`,
  `project_id`, `vault_id` + `vault_key_id`) — so a cloud with no foundation
  in that environment is skipped instead of failing the run, and there are no
  per-cloud coordinates to keep in sync. The value written is one JSON object
  holding `tls.crt` (leaf + chain) and `tls.key` (PKCS#8), so the key and its
  certificate are always one atomic version and an `ExternalSecret` maps both
  fields through `remoteRef.property`. The three writes are independent: one
  cloud refusing the write leaves the other two on the current certificate
  and fails the run at the end.

  The trade-off against the obvious alternative — cert-manager in-cluster
  with `ClusterIssuer` + workload identity — is that CI, not the cluster,
  holds the DNS-write permission, and the result lands in the secret backend
  every cloud's tenants already read from instead of in one cluster's etcd.
  The cost is that the certificate does not renew while the workflow is
  broken, and nothing in the cluster notices.
- Authentication uses long-lived cloud credentials stored as GitHub secrets
  (azurerm `ARM_CLIENT_SECRET`, AWS access keys via
  `aws-actions/configure-aws-credentials`, a service account key via
  `google-github-actions/auth`, and an OCI API signing key read from `OCI_*`
  environment variables). See `docs/getting-started.md` for the identities
  and repository secrets/variables to create.

## Known trade-offs

- The GitOps stack holds the argocd-agent CA private key and every agent's
  client key in its state. That is the price of issuing them declaratively
  instead of with `argocd-agentctl`, and it is the same exposure the tenants
  stack already carries: whatever protects the state home protects these.
  Leaf certificates are reissued on apply once they are within
  `certificate_renewal_days` of expiry, which means a stack nobody applies for
  a year is a stack whose agents stop connecting. Rotating the CA itself is
  not automatic — it invalidates every certificate below it, so it is a
  deliberate operation.
- The principal's gRPC endpoint is on the public internet. It has to be:
  spokes on three other clouds have no fixed egress addresses to allowlist,
  and making the hub reachable is what buys the spokes not having to be. What
  makes it defensible is that mTLS with a private CA is the only way in — but
  it is still one more listening port than the rest of this repo has.
- The AKS Argo CD extension owns the hub's Argo CD, including its ConfigMaps,
  and reverts direct edits to them. One setting the hub-spoke topology wants
  (`redis.server` pointing at the principal's redis proxy, without which the
  UI cannot render a spoke application's resource tree) therefore cannot be
  applied from this stack unless the extension is imported into it —
  `manage_hub_extension`, off by default because Terraform will not create an
  extension that already exists. Everything else works without it.
- The spokes' Argo CD comes from the community chart, which has no switch to
  omit a component, so `argocd-server` and the ApplicationSet controller are
  scaled to zero rather than left out. Their Services and RBAC objects remain,
  doing nothing. The upstream kustomize overlay does delete them, but applying
  a remote kustomization is not something Terraform does well.
- argocd-agent is a v0.x argoproj-labs project. The protocol between principal
  and agent is versioned, which is why one variable pins the image for both
  halves — they are meant to move together, and a mixed-version fleet is not a
  supported configuration.
- The tenant SecretStore is applied with `kubernetes_manifest`, which needs
  cluster reachability and the ESO CRDs at *plan* time. This is inherent to
  the tenants-depend-on-foundations layering, and with one stack per
  environment it applies to every cloud in `var.tenants` at once: list a
  cloud's tenants only once that cloud's foundation is deployed and its
  cluster is reachable from where the plan runs.
- AKS uses cluster-local accounts for CI bootstrap (Helm/add-ons). Harden to
  Entra-only + `kubelogin` once your CI identity has an AAD admin group.
- One NAT gateway per AWS VPC (cost-optimized); use one per AZ for prod HA.
- All state lives in the Azure Storage state home, so every deploy — AWS,
  GCP and OCI foundations included — needs Azure credentials in addition to
  the target cloud's, and Azure Storage is a single point of failure for
  operating the other three clouds. The trade is deliberate: one bootstrap,
  one place to secure and version state, and one remote-state backend type
  (a working directory supports only one anyway, which is what forced the
  unified tenants stack into Azure Storage to begin with). If that coupling
  is unacceptable, move each `foundations/<cloud>` back to its own cloud's
  backend and give the tenants stack one `terraform_remote_state` data
  source per backend type, count-gated on `var.cloud`.
- Azure Managed Namespaces are a preview API surface, addressed via `azapi`
  by design (`managed_namespace_api_version` variable).
- Distributing the wildcard certificate copies a private key out of Key Vault
  into three more backends, so it exists in four places and a rotation is only
  complete once every copy is refreshed — nothing reconciles them, and a
  cluster reading a stale copy will not notice. It is also a single job
  touching every cloud, which GitHub can bind to only one environment: it uses
  `azure-<env>`, the environment that guards the vault the private key is read
  from, and writes with the repository-level AWS/GCP/OCI credentials, so
  `aws-prod`'s protection rules do not apply to it. The alternative — one job
  per cloud, each bound to its own environment — would have to move the key
  between jobs through a run artifact, which is a worse trade than the one
  taken.
- OCI IAM is global but writable only in the tenancy's **home region**, so
  both OCI stacks carry a second `oci.home` provider alias just for policies.
  Because passing any provider to a module disables default inheritance,
  every module block in `tenants/main.tf` has to enumerate the full provider
  set explicitly.
- Deploying all clouds from one state file means one blast radius and one
  lock: a tenant change on GCP plans and applies together with the Azure, AWS
  and OCI tenants, and an unreachable cluster on any cloud in use fails the
  whole run. The trade buys a single source of truth for who is onboarded
  where, and one run instead of four.
- OCI has no Terraform-native cluster-token source (no equivalent of
  `aws_eks_cluster_auth`), so the tenants stack shells out to
  `oci ce cluster generate-token`; the OCI CLI must be on `PATH`.
- Deleting an OCI Vault is a *scheduled* operation with a mandatory 7-30 day
  waiting period, so `terraform destroy` schedules the deletion rather than
  completing it, and the vault name stays taken until it elapses.
- The OCI tenant policy grants reads of individual secrets by name, not
  listing: a list request has no single `target.secret.name` to match, so
  ESO's `dataFrom.find` (as opposed to `dataFrom.extract`) will not work on
  OCI. That is the same trade-off that makes cross-tenant enumeration
  impossible.
