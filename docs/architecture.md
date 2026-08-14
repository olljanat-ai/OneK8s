# Architecture

## Overview

OneK8s provisions **cluster + secret-backend pairs** ("foundations") on
Azure, AWS, GCP and OCI, and onboards **tenants** onto those clusters with
hard, cloud-enforced secret isolation.

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
| Platform ingress | **Traefik** + ESO (Key Vault) | **Traefik** + ESO (Secrets Manager) | **Traefik** + ESO (Secret Manager) | **Traefik** + ESO (Vault) |
| Ingress DNS | manual records | manual records | manual records | manual records |
| GitOps | **Argo CD cluster extension** (`Microsoft.ArgoCD`) | — | — | — |

## Ingress

Every cluster runs the **same ingress controller**: Traefik, installed from
`modules/platform-ingress` by each foundation's `ingress.tf` and opt-in per
environment with `enable_ingress`. A tenant that publishes an application
writes the same four lines of Ingress on AKS, EKS, GKE and OKE — which is the
whole premise of the platform applied to HTTP.

```
   <app>-<tenant>.onek8s.lol
        │
        ▼
   Traefik (namespace "traefik", IngressClass "traefik", cluster default)
        │  :80 ── permanent redirect ──▶ :443
        │  :443 TLS, default TLSStore ──▶ Secret platform-wildcard-tls
        ▼
   tenant Service (NetworkPolicy allows the ingress namespace)
```

**The certificate is the ingress', not the application's.** Traefik's default
`TLSStore` serves `platform-wildcard-tls` for every host that carries no
certificate of its own, so a tenant `Ingress` has **no `tls:` section, no
secret and no `ingressClassName`**:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  namespace: team-alpha
spec:
  rules:
    - host: web-team-alpha.onek8s.lol
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

**Hostnames are `<app>-<tenant>.onek8s.lol`** — one label deep, because
`*.onek8s.lol` covers `web-team-alpha.onek8s.lol` and does *not* cover
`web.team-alpha.onek8s.lol`. A deeper scheme would mean reissuing and
redistributing the wildcard, so the naming follows the certificate that
exists.

That secret is where the certificate distribution finally lands. Each cloud
fills it from the backend its tenants already read:

| Cloud | How `platform-wildcard-tls` is filled |
|---|---|
| Azure | ESO `SecretStore` + `ExternalSecret` on the Key Vault certificate, over a UAMI + federated credential; Key Vault returns one PEM bundle, which `filterPEM` splits into the two fields |
| AWS | ESO `SecretStore` + `ExternalSecret` on `<env>/platform/wildcard-onek8s-lol` in Secrets Manager, over IRSA |
| GCP | ESO on `platform-wildcard-onek8s-lol` in Secret Manager, over Workload Identity |
| OCI | ESO on `platform-wildcard-onek8s-lol` in the Vault, over OKE Workload Identity |

The identity that reads it is the platform's counterpart of a tenant
identity: pinned to the ingress namespace's own ServiceAccount and scoped to
the reserved `platform-` prefix by the same ABAC condition / IAM prefix /
policy condition that scopes a tenant to `<tenant>-`. No tenant can read the
private key, and the ingress can read no tenant's secrets.

The distributed value is one JSON object holding `tls.crt` and `tls.key`, so
those three `ExternalSecret`s use `dataFrom.extract` and materialize a
`kubernetes.io/tls` secret in one step. Azure reads the vault the workflow
writes to directly, and what Key Vault returns for a certificate is the PEM
bundle that was imported — key followed by chain — so there the same two
fields come out of `filterPEM` in the target template instead. Either way the
certificate is referenced without a version, so renewals are picked up on the
next hourly refresh and never by an apply.

**DNS is out of band, on every cloud.** The `onek8s.lol` zone lives in Azure
DNS, and no cluster writes it: a record is pointed at the ingress load
balancer by hand, once per published host.

```bash
kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0]}'
```

Running external-dns would only ever have been symmetric on Azure — the three
other clusters would need Azure credentials to write that zone, the first
stored cross-cloud credential on a platform that has none — so no cluster
runs it, and every cloud's hostnames are maintained the same way.

A tenant namespace's NetworkPolicy allows the ingress namespace by its
`kubernetes.io/metadata.name` label, on top of the "same namespace only" rule
(policies are additive, so this holds on Azure too, where the namespace and
its policy are managed by AKS).

## GitOps (Azure only, today)

The Azure foundation additionally carries the platform's delivery plane:
the **Argo CD cluster extension** offered by Microsoft, published on
`argocd.onek8s.lol` through the same Traefik ingress every other cloud runs
and terminating TLS with the platform wildcard, which the Ingress does not
have to name — it is the ingress' default certificate (see **Ingress**
above). Its Ingress object is deliberately the plainest one on the platform:
a host and a backend, nothing else.

Access follows the same "no stored credentials" line as everything else:
users sign in with **Entra ID**, Entra group object IDs map to Argo CD roles,
and the SSO app registration authenticates with the cluster's federated
credential rather than a client secret. The directory objects themselves are
created out of band and referenced by ID.

This is deliberately a **single-cluster install** for now, and deliberately
placed on the cluster that is meant to become the **hub**: the plan is for
Argo CD on AKS to drive EKS, GKE and OKE as registered spokes, so there is
one delivery plane for all four clouds rather than one Argo CD per cloud —
the same "one stack, all clouds" shape the tenants layer already has. None of
the spoke registration exists yet. See [argocd.md](argocd.md) for the
mechanics, the operational commands and the full hub-spoke plan.

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

## CI/CD

- `pr-validation.yml` — fmt, per-stack validate, tflint, checkov, and (once
  `ENABLE_CLOUD_PLANS=true`) credentialed prototype plans for all five
  stacks.
- `deploy-foundations.yml` / `deploy-tenants.yml` — independent pipelines;
  merge to `main` auto-deploys the prototype environment on path changes,
  other environments go through `workflow_dispatch`. Deploy Foundations fans
  out per cloud; Deploy Tenants is a single all-clouds job. Both delegate to
  the reusable `_terraform-deploy.yml`, which binds each run to a GitHub
  environment — `<cloud>-<env>` for foundations, `tenants-<env>` for the
  tenants stack — so protection rules (required reviewers, wait timers) gate
  production applies.
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

- The tenant SecretStore is applied with `kubernetes_manifest`, which needs
  cluster reachability and the ESO CRDs at *plan* time. This is inherent to
  the tenants-depend-on-foundations layering, and with one stack per
  environment it applies to every cloud in `var.tenants` at once: list a
  cloud's tenants only once that cloud's foundation is deployed and its
  cluster is reachable from where the plan runs.
- AKS uses cluster-local accounts for CI bootstrap (Helm/add-ons, and the
  Argo CD ingress object). Harden to Entra-only + `kubelogin` once your CI
  identity has an AAD admin group.
- The Argo CD extension is in **public preview**, so the Azure foundation
  pins the `Preview` release train and, with no version pinned, takes Azure's
  auto-upgrades. `enable_argocd = false` opts an environment out of the whole
  thing.
- Argo CD's Entra ID sign-in depends on directory objects this stack does not
  manage: the app registration, the managed identity the components federate
  as, and the groups bound to Argo CD roles are created out of band and
  referenced by ID from `envs/<env>.tfvars`. Managing them would mean giving
  the deploy identity directory write permission, which is a larger grant
  than the platform otherwise needs; the cost is that nothing notices when
  one of those objects is deleted or renamed.
- The AKS cluster is the only one with GitOps, which makes it a de-facto hub
  before the hub-spoke work has been done. Until spokes are registered,
  EKS/GKE/OKE have no delivery plane at all — they now have an ingress
  controller, but nothing that deploys to them.
- Traefik replaced the AKS **application routing add-on** on Azure, trading a
  managed component for one the platform now upgrades itself. The add-on was
  managed NGINX with Azure-specific Ingress annotations and no counterpart on
  the other three clouds, so keeping it would have meant a per-cloud ingress
  contract for tenants. The Key Vault secrets provider add-on went with it:
  the certificate is now read by External Secrets, the component that already
  reads every tenant secret, with the same ABAC narrowing to one certificate,
  so the cluster carries no Azure-only add-on for either job. Two
  consequences on an existing environment. The load balancer address changes,
  and the add-on's external-dns is gone with it, so the records it kept are
  now stale and unmanaged — repoint the A record at the new address and
  delete the `externaldns-` TXT record that recorded its ownership. And the
  Key Vault secrets provider add-on cannot be disabled while a
  `SecretProviderClass` exists, which the app routing add-on generated from
  the annotated Argo CD Ingress: that Ingress and its generated class have to
  be deleted before the apply, because the Kubernetes provider is configured
  from the cluster resource and so nothing in the cluster can be ordered
  ahead of it.
- Reading the Key Vault certificate through External Secrets means the
  private key is fetched by a cluster component and written to a Kubernetes
  Secret, where the Secrets Store CSI driver would have had kubelet mount it
  from the vault. The etcd copy exists either way — the CSI driver's
  `secretObjects` sync creates the same Secret — so what is actually traded
  is one Azure-only add-on for symmetry with the other three clouds, and a
  vault that has no certificate yet now leaves an unresolved `ExternalSecret`
  instead of a pod that cannot start.
- No cluster manages DNS, so every published hostname — `argocd.onek8s.lol`
  included — is a record someone creates by hand, and a load balancer that is
  replaced (a destroy/apply of the ingress, a cloud-side reassignment) breaks
  every host on that cluster until the records are repointed. Azure could run
  external-dns against its own zone, but that would automate one cloud out of
  four and leave the other three exactly as they are now.
- The ingress' certificate is the platform wildcard and nothing else, so a
  tenant that needs its own certificate (its own domain, or a client-facing
  CA) has to bring an `Ingress` with a `tls:` section and a secret it
  manages. That case is not wired up: nothing today issues per-tenant
  certificates.
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
