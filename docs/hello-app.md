# The hello application

The platform's first workload, and the smallest end-to-end proof that it works:
a .NET 10 web page showing a welcome message and the value of a **test secret**
read out of the host cloud's own secret backend. It runs on all five clouds,
from one image and one chart, published one label deep under the platform
wildcard:

| Cloud | Cluster | URL |
|---|---|---|
| `azure` | AKS — the Argo CD hub | https://azure-hello.onek8s.lol |
| `aws` | EKS — spoke | https://aws-hello.onek8s.lol |
| `gcp` | GKE — spoke | https://gcp-hello.onek8s.lol |
| `oci` | OKE — spoke | https://oci-hello.onek8s.lol |
| `nutanix` | NKP — spoke, the private cloud | https://nutanix-hello.onek8s.lol |

Nothing about it is cloud-specific except *how it names the secret* it asks
for: Secrets Manager names are paths where Key Vault, Secret Manager and OCI
Vault names are flat, and a HashiCorp Vault KV v2 secret is a map, so there the
field inside it is named too.

```
                    ┌── this repository ──────────────────────────────┐
                    │  apps/hello/src   ──build──▶ ghcr.io/…/hello    │
                    │  apps/hello/chart                               │
                    │  gitops/argocd/    ◀──── gitops/root-app.tf      │
                    └──────────────│──────────────────────────────────┘
                                   │ Argo CD syncs
                    ┌──────────────▼───── hub: AKS ───────────────────┐
                    │  Application platform-gitops                    │
                    │    ├── AppProject onek8s-platform               │
                    │    └── ApplicationSet hello                     │
                    └──┬─────────┬─────────┬─────────┬──────────┬─────┘
                       │         │         │         │          │
                  hello-azure hello-aws hello-gcp hello-oci hello-nutanix
                   (in-cluster)   EKS       GKE       OKE        NKP
                       │         │         │         │          │
                       ▼         ▼         ▼         ▼          ▼
                   Key Vault  Secrets   Secret     OCI      HashiCorp
                              Manager   Manager    Vault      Vault
                       via External Secrets, per tenant identity
```

## What Terraform owns, and what Git owns

Exactly one Argo CD object is created by Terraform: the **root Application**,
`gitops/root-app.tf`. It points Argo CD at `gitops/argocd/` in this repository
and owns nothing else. The AppProject, the ApplicationSets and every
Application they generate are YAML in that directory, so after the first apply
a new application — or a change to an existing one — is a commit, and nothing
in the delivery plane is configured by hand in the UI.

```hcl
# gitops/envs/prototype.tfvars
platform_apps = {
  repo_url        = "https://github.com/olljanat-ai/OneK8s.git"
  target_revision = "main"
  tenant          = "team-alpha"
  domain          = "onek8s.lol"
}
```

Those values are handed to `gitops/argocd/` as Helm values rather than
committed into it, which is what lets **one copy** of that directory serve
prototype, dev, staging and prod: the environment decides which spokes the
cluster generator selects, which revision is synced and which hosts the
applications get. `platform_apps = { enabled = false }` registers spokes
without deploying anything, and the root Application is skipped automatically
when the hub's foundation was applied with `enable_argocd = false`.

The root Application carries Argo CD's cascade finalizer, so `terraform
destroy` on the gitops stack takes the ApplicationSets — and the workloads they
put on the spokes — with it.

## Fanning out to five clusters

`gitops/argocd/templates/applicationset-hello.yaml` is one object producing one
Application per cluster. It needs **two generators**, because the hub is not
shaped like a spoke:

- **the spokes** come from a `clusters` generator selecting
  `onek8s.io/environment: <env>`, the label `modules/argocd-spoke` puts on each
  cluster Secret. A cloud that is not in `var.spokes` has no Secret, so it
  produces no Application — the fan-out follows the gitops stack by itself.
- **the hub** is a one-element `list` generator. Argo CD's built-in entry for
  the cluster it runs on (`in-cluster`) has no Secret and therefore no labels
  to select on, so it cannot come from the cluster generator.

Applications address their cluster by `destination.name`, not by server URL:
EKS, GKE, OKE and NKP endpoints are whatever those platforms handed out, and
Argo CD already knows them from the cluster Secret. Registering a new spoke is
therefore the whole of adding a cloud to the fan-out — the private cloud
produced `hello-nutanix` without a line changing in this ApplicationSet.

Per-cluster values reach the chart as Helm parameters — `cloud`, `environment`,
`tenant`, `ingress.host` (`<cloud>-hello.onek8s.lol`) and the welcome message.

### The AppProject

Every generated Application belongs to `onek8s-platform`, which draws three
boundaries Argo CD enforces before applying anything:

| Field | Effect |
|---|---|
| `sourceRepos` | only this repository may be synced |
| `destinations` | only the tenant namespace, on any registered cluster |
| `clusterResourceWhitelist: []` | nothing cluster-scoped, ever |

The last one turns the convention *"tenant onboarding stays in Terraform, only
workloads belong in GitOps"* — listed as a gap in
[argocd.md](argocd.md#known-gaps) — into a mechanism. An Application that tried
to manage the `team-alpha` Namespace is refused rather than left to fight the
tenants stack over it. `CreateNamespace=false` is set for the same reason: a
missing namespace should fail the sync loudly, not produce a namespace with
none of the tenant's quota, network policy or SecretStore.

## The test secret

This is the part worth looking at. The application's manifest names a secret
and a store, and no credential at all:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
spec:
  secretStoreRef:
    name: tenant-store       # namespaced — only this namespace may use it
    kind: SecretStore
  data:
    - secretKey: test
      remoteRef:
        key: team-alpha-test
        # property: test — on nutanix only, where a KV v2 secret is a map
```

`tenant-store` is created by `modules/tenant-namespace` and authenticates as
the tenant's ServiceAccount, exchanged for the tenant's cloud identity through
workload identity federation — or, on the private cloud, for a Vault token
through the same OIDC federation, with Vault as the relying party. That identity can read only its own
name-prefix slice of the shared backend, enforced outside Kubernetes
([ADR-0001](adr/0001-per-tenant-identities-and-namespaced-secretstores.md),
[ADR-0002](adr/0002-private-cloud-on-nkp-with-vault-as-the-identity-plane.md)).
Asking for another tenant's secret is not a mistake this chart can make
quietly: the read is refused and the ExternalSecret goes `SecretSyncedError`.

The prefix is spelled differently on AWS, and the private cloud adds a field
name, which together are the whole of the chart's cloud-specific surface
(`hello.remoteKey` and `hello.remoteProperty` in `_helpers.tpl`):

| Cloud | Backend | Remote key | Enforced by |
|---|---|---|---|
| `azure` | Key Vault | `team-alpha-test` | ABAC `StringStartsWith 'team-alpha-'` |
| `aws` | Secrets Manager | `prototype/team-alpha/test` | IAM ARN prefix `prototype/team-alpha/*` |
| `gcp` | Secret Manager | `team-alpha-test` | IAM condition `resource.name.startsWith(…/team-alpha-)` |
| `oci` | OCI Vault | `team-alpha-test` | policy condition `target.secret.name = /team-alpha-*/` |
| `nutanix` | HashiCorp Vault | `team-alpha-test`, property `test` | Vault policy `read "<mount>/data/team-alpha-*"` |

### Where the value comes from

The secret is **not** created by any Terraform stack here — tenant data is the
tenant's, and the tenants stack deliberately writes none of it. It is created
where the platform's other shared value is: the **Renew Certificate**
workflow, which generates it in Key Vault beside the wildcard and publishes it
to the other four clouds in the same `distribute` run.

```
   Renew Certificate (renew)                Renew Certificate (distribute)
        │                                          │
        ▼                                          ▼
   Key Vault  team-alpha-test  ──────────▶  Secrets Manager  prototype/team-alpha/test
   (the source of truth)                    Secret Manager   team-alpha-test
                                            OCI Vault        team-alpha-test
                                            HashiCorp Vault  <mount>/team-alpha-test
                                                             {"test": "…"}
```

Both objects travel the same road for the same reason — one vault as the
source of truth, one run to copy it out — and the value rotates whenever the
certificate is renewed, so every renewal exercises the rotation path end to
end: ESO re-reads the backend within the hour, the kubelet refreshes the
mounted file, and the page shows the new value without a restart. A run whose
certificate was **not** due leaves the secret alone, unless it is missing
altogether, which is what seeds a fresh environment on the first run.

The value itself is a line naming the environment and the run that wrote it,
identical on all five clouds — comparing the five pages is the whole
end-to-end check:

```
OneK8s prototype test secret — issued 2026-08-14T03:17:12Z by run 17482913 (a1b2c3d4)
```

It is not confidential (a public page publishes it verbatim) and the run
summary prints it, which is what makes "is `gcp-hello` showing the current
value?" answerable without opening a vault. `tenant` is a workflow input,
defaulting to `team-alpha` — it must name the tenant the application is
released into (`platform_apps.tenant` in `gitops/envs/<env>.tfvars`), because
that is the only prefix its identity may read.

Until the first renewal run the page renders *"not available"* instead of a
value, which is also what it looks like while External Secrets is still
syncing. To seed it by hand instead — or to put a value of your own choosing
in front of the page — write it once per cloud:

```bash
# Azure — the vault name carries a random suffix, so read it from the state
KV=$(cd foundations/azure && terraform output -raw key_vault_uri)
az keyvault secret set --id "${KV}secrets/team-alpha-test" --value "hello from Key Vault"

# AWS — must be encrypted with the tenant CMK: the tenant's kms:Decrypt grant
# is scoped to that key, so a secret under the default aws/secretsmanager key
# is unreadable to it.
aws secretsmanager create-secret \
  --name prototype/team-alpha/test \
  --kms-key-id alias/onek8s-prototype-secrets \
  --secret-string "hello from Secrets Manager"

# GCP
printf 'hello from Secret Manager' \
  | gcloud secrets create team-alpha-test --data-file=- --replication-policy=automatic

# OCI — content is base64, and the secret belongs to the foundation's vault/key
cd foundations/oci
oci vault secret create-base64 \
  --compartment-id "$(terraform output -raw compartment_id)" \
  --vault-id       "$(terraform output -raw vault_id)" \
  --key-id         "$(terraform output -raw vault_key_id)" \
  --secret-name    team-alpha-test \
  --secret-content-content "$(printf 'hello from OCI Vault' | base64 -w0)"

# Nutanix — a KV v2 secret is a map, and "test" is the field the chart's
# remoteRef.property asks for. The mount is the foundation's.
cd foundations/nutanix
vault kv put "$(terraform output -raw vault_mount_path)/team-alpha-test" \
  test="hello from HashiCorp Vault"
```

A hand-written value survives until the next renewal overwrites it, which is
the trade for having the workflow keep all five clouds in step.

Rotating the value needs nothing on the Kubernetes side: External Secrets
re-reads the backend hourly, the kubelet refreshes the mounted file in place,
and the app reads that file per request — so the new value appears on a reload
without a pod restart.

## The image

`.github/workflows/build-hello.yml` builds `apps/hello` on every push to `main`
that touches it and pushes to **GHCR** as
`ghcr.io/olljanat-ai/onek8s/hello`, tagged `latest` and `sha-<short>`. Pull
requests build without pushing. The package must be **public** for the clusters
to pull it — none of them has a pull secret, which is deliberate: an image
pull credential per cloud is exactly the kind of sprawl the platform avoids
elsewhere. GHCR packages default to private, so make it public once, under the
package's settings.

The image is a two-stage build: the .NET 10 SDK compiles, and a **chiseled**
ASP.NET runtime serves — Ubuntu with no shell, no package manager and a
non-root default user. The pod adds the rest: read-only root filesystem, all
capabilities dropped, no ServiceAccount token mounted.

## Operating it

```bash
# The hub's view of the whole thing
kubectl -n argocd get application platform-gitops
kubectl -n argocd get applicationset hello
kubectl -n argocd get applications -l app.kubernetes.io/part-of=onek8s

argocd app list --grpc-web
argocd app get hello-aws --grpc-web

# On any cluster: did the secret actually arrive?
kubectl -n team-alpha get externalsecret hello
kubectl -n team-alpha describe externalsecret hello     # the reason, when it did not
kubectl -n team-alpha get pods -l app.kubernetes.io/name=hello

# What is published, and where the A record has to point
kubectl -n team-alpha get ingress hello
kubectl -n traefik get svc traefik
```

DNS is out of band on every cloud, as everywhere else here: create an A record
for each `<cloud>-hello.onek8s.lol` pointing at that cluster's Traefik Service
address. TLS needs nothing — the Ingress carries no certificate and Traefik's
default TLSStore serves the `*.onek8s.lol` wildcard.

## Known gaps

- **The image tag is `latest`.** The build workflow pushes an immutable
  `sha-<short>` tag alongside it, but nothing writes that tag back into
  `apps/hello/chart/values.yaml`, so what Git says is deployed is not by itself
  the whole truth. `imagePullPolicy: Always` means a restarted pod picks up the
  newest build, but Argo CD sees no diff when the image changes and will not
  restart anything by itself. Pin `image.tag` to a `sha-` tag for a
  reproducible deploy, or add an image updater.
- **The test secret follows the certificate's schedule, not its own.** The
  Renew Certificate workflow generates it, so it rotates when the wildcard is
  renewed (roughly quarterly) and reaches the other three clouds only on a
  `distribute` run, which is manual by design. That is deliberate — one
  source of truth and one copy-out path for both objects — but it does mean a
  rotation is not visible on EKS, GKE and OKE until someone distributes it.
- **Hostnames are one label deep and carry no environment.** That is what the
  wildcard covers, so a second environment cannot also publish
  `aws-hello.onek8s.lol`. A second environment needs its own `domain` in
  `platform_apps` (and a wildcard to match).
- **One tenant.** The application is released into `team-alpha` on every cloud
  because that tenant exists everywhere in this environment. The AppProject is
  scoped to that one namespace; a second tenant means a second destination.
- **The hub deploys to itself.** `hello-azure` targets `in-cluster`, so the
  cluster running Argo CD also runs a workload. That is fine for a lab and is
  the reason the hub appears as a static list element rather than as a
  registered spoke.
