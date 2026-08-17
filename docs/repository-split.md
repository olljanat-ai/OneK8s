# Splitting OneK8s into several repositories

- Status: **Proposed** — nothing here is done yet.
- Short answer: **yes, but along one seam and not four**, and the seam is
  *which credentials the repository's automation holds*, not which layer of
  the stack it describes.

## Why the question comes up now

Three things push against one repository, and all three are recent:

1. **Something is about to write commits.** The promotion design
   ([hello-promotion.md](hello-promotion.md)) has a bot moving a version file
   forward, and Kargo would do the same from inside the hub. A write token on
   this repository is a write token on `foundations/`, on every workflow, and
   on the workflows' own permissions. GitHub cannot scope that per path.
2. **`sourceRepos` is the whole repository.** The `onek8s-platform` AppProject
   allows exactly one repository — this one — which is a real boundary, but the
   thing it permits contains every Terraform stack in the platform. Argo CD
   only ever needs the delivery half.
3. **The application has nothing to do with any of it.** `apps/hello` shares no
   file, no credential and no release cadence with `foundations/oci`. It is
   here because it was the first workload and there was nowhere else to put it.

## What one repository is buying today

Worth being honest about, because these are real and the split spends them:

- **A change crosses layers in one diff.** "The chart takes a new required
  value and the ApplicationSet passes it" is one PR, reviewed once, merged
  atomically. `gitops/argocd/values.yaml` names this property as a reason the
  chart and the object deploying it live together.
- **One PR is validated across every cloud.** `pr-validation.yml` runs `fmt`,
  `validate`, `tflint`, `checkov`, the Helm renders and six `terraform plan`s
  against one commit.
- **Modules are paths, not versions.** `modules/tenant-namespace` is
  `source = "../modules/..."`; nothing pins a module version because there are
  none to pin.
- **The documentation is one set of cross-links,** and every trade-off is
  written down next to the thing it applies to.

None of that is worth giving up for tidiness. It is worth giving up for the
credential boundary — the same reasoning
[ADR-0001](adr/0001-per-tenant-identities-and-namespaced-secretstores.md) uses
for tenants: the boundary goes where the credentials differ.

## The seam that matters

| Repository | Its CI holds | Who may write | Argo CD reads it |
|---|---|---|---|
| `onek8s` (platform) | Azure, AWS, GCP, OCI credentials; the Terraform state home | humans, reviewed | no — it only bootstraps the root Application, pointed elsewhere |
| `onek8s-delivery` | **nothing** | humans **and the promotion bot** | yes — the only entry in `sourceRepos` |
| `onek8s-hello` (application) | `packages: write` on GHCR, nothing else | humans | no — it publishes artifacts, it is not synced |

Read the table as one sentence: *the only repository automation may write holds
no cloud credentials, no Terraform and no application code, and the only
repository Argo CD may sync is that same one.* That is the whole argument for
splitting, and it is also what makes Kargo cheap to adopt later — its Git
credential would be scoped to a repository where the worst a compromise can do
is deploy a wrong version of an already-built artifact to a tenant namespace.

## Proposed structure

```
olljanat-ai/onek8s                    the platform: what clouds exist
├── foundations/{azure,aws,gcp,oci}/  unchanged
├── modules/                          unchanged — paths, not versions
├── tenants/                          unchanged
├── gitops/                           unchanged, except repo_url now points at
│   └── root-app.tf                     onek8s-delivery
├── docs/                             architecture, ADRs, getting started
└── .github/workflows/                terraform CI, renew-certificate

olljanat-ai/onek8s-delivery           what runs where
├── argocd/                           the chart today at gitops/argocd/
│   ├── templates/                      AppProject, ApplicationSets
│   ├── versions/hello.yaml             the promotion state — the bot's only file
│   └── values.yaml
├── envs/                             per-environment values, if they diverge
└── .github/workflows/                helm lint/render, promotion (or Kargo owns it)

olljanat-ai/onek8s-hello              what the application is
├── src/, Dockerfile                  unchanged
├── chart/                            unchanged, published as an OCI artifact
├── tests/smoke.sh                    the promotion gate travels with the app
└── .github/workflows/build.yml       image + chart to GHCR
```

Three repositories, one job each: **what clouds exist**, **what runs where**,
**what the application is**. A fourth (`onek8s-modules`) and a fifth (per-tenant
repositories) are discussed at the end; neither is worth doing yet.

### Why the chart goes with the application, not with delivery

A chart is the application's deployment contract — its values are as much its
API as its HTTP routes — so it is reviewed by whoever changes the code, in the
same PR. What delivery owns is not *how* the app is deployed but *which version
of it is deployed where*, which is one line per cloud.

That answers the [OCI question](hello-promotion.md#the-other-alternative-the-chart-as-an-oci-artifact)
by itself: with the chart in another repository, either Argo CD is given a
second `sourceRepos` entry and a Git revision to pin, or the chart is published
as an artifact and delivery pins a version. The second is the reason the first
was ever tempting. **Split the repositories and OCI stops being a preference and
starts being the simpler option** — Argo CD reads one repository and one
registry, and the delivery repository holds no code at all.

## What actually moves

Less than it looks like, because the seams are already parameterised:

| Change | Where | Size |
|---|---|---|
| `platform_apps.repo_url` → the delivery repository | `gitops/envs/<env>.tfvars` | one line — the variable already exists |
| `sourceRepos` narrows to the delivery repository | nothing: it renders from `.Values.repoURL` | none |
| `gitops/argocd/` → `argocd/` in the new repository | `git filter-repo`, history kept | one move |
| `apps/hello/` → the application repository | same | one move |
| the Helm half of `pr-validation.yml` | follows each chart to its repository | split, not rewritten |
| `build-hello.yml` | moves whole; add `helm push` if charts go OCI | one move |
| the application's Argo CD source | `repoURL`/`path` → `repoURL`/`chart`/`targetRevision` | the ApplicationSet, ~5 lines |

Nothing in `foundations/`, `modules/` or `tenants/` is touched, and no Terraform
state moves — which is what makes this a cheap split rather than a migration.

## What it costs

- **Cross-layer changes become two PRs, in order.** A chart that takes a new
  required value must be published before the ApplicationSet passes it, or the
  sync fails in between. That is a real regression against today's single diff,
  and the mitigation is the ordinary one: additive first (a default), then use
  it, then remove the default.
- **Four CI setups instead of one**, and three repositories' worth of branch
  protection, secrets and settings to keep in step.
- **The documentation splits or it goes stale.** Keep `docs/` in the platform
  repository as the single narrative, give the other two a README that links
  into it, and accept that "everything in one place" is now a claim about
  `docs/`, not about the code.
- **Nothing enforces the boundary but the split itself.** A human with write
  access to all three can still make a mess; what changed is that the *bot*
  cannot.

## Sequencing

Do it in the order in which each split pays for itself, not all at once:

| Step | Trigger | What |
|---|---|---|
| 0 — now | — | nothing. Land the promotion design in this repository first; the version file is what everything else hangs off, and it is easier to iterate on in one place. |
| 1 | the first promotion bot commit | split **`onek8s-hello`**. Lowest coupling — the app touches no Terraform — and the highest single gain: its CI stops holding anything but a GHCR token. Publish the chart to GHCR at the same time. |
| 2 | a second application, a second tenant deploying, or adopting Kargo | split **`onek8s-delivery`**. This is the one that scopes the write credential and narrows `sourceRepos`. |
| 3 | a module is consumed by something that is not this platform | split **`onek8s-modules`**, tagged and pinned. Not before: version pinning is pure overhead while there is one consumer. |
| 4 | a tenant wants to deploy their own workload | per-tenant repositories, one `AppProject` each, `sourceRepos` scoped to that repository and `destinations` to that namespace. This is what the platform's tenant isolation has been building toward — the delivery repository stops being the only writer of Applications, and the AppProject stops being a single shared object. |

Steps 1 and 2 are the proposal. Steps 3 and 4 are the direction, written down so
the earlier steps do not accidentally close them off.

## Known gaps and open questions

- **Where do the ADRs live?** They describe the platform, so `docs/` in the
  platform repository — but ADR-0001 is about tenant identity, which a tenant
  repository would want too. Cross-linking is the cheap answer and the one to
  start with.
- **Who owns `versions/hello.yaml` in review?** It is the one file a bot writes,
  and the one file a human should almost never edit by hand. `CODEOWNERS` plus
  a comment at the top of the file is the whole mechanism available.
- **Release coupling is now a convention.** Nothing stops the delivery
  repository pinning a chart version that was never built, or a chart from
  naming an image that was never pushed. The promotion gate catches it after
  the fact (the sync never converges and `/version` never matches); catching it
  before would mean the delivery repository validating against the registry.
- **This does not split the environments.** `prototype`, `dev`, `staging` and
  `prod` stay branches/values inside the delivery repository, not repositories
  of their own. A repository per environment is the classic wrong turn: it
  duplicates every object four times so that four copies can drift.
