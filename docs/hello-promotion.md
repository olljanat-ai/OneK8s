# Promoting the hello application across the clouds

- Status: **Proposed** — nothing in this document is implemented yet.
- Goal: a change to `apps/hello` reaches **azure → aws → gcp → oci**, in that
  order, and reaches the next cloud only after it was proven working on the
  previous one.

Today it reaches all four at once, and "proven working" is not a thing the
platform can say about anything. This is what has to change, and in what order.

## What is in the way today

Three facts, and each of them has to be fixed before an order can exist at all:

1. **Nothing identifies a version.** `apps/hello/chart/values.yaml` pins
   `image.tag: latest` with `imagePullPolicy: Always`. A merge to `main`
   replaces `latest` in GHCR; Argo CD sees no diff, syncs nothing, and restarts
   nothing. Whatever runs on a cluster is whatever that node last pulled. There
   is no "this version" to promote, and no way to ask a cluster which one it is
   on.
2. **All four clouds read the same line of Git.** The `hello` ApplicationSet
   renders one Application per cluster from one `targetRevision` and one chart
   path, so a chart change lands on AKS, EKS, GKE and OKE within one Argo CD
   poll of each other. There is nowhere to say "gcp is one version behind".
3. **There are no tests.** `pr-validation.yml` renders the chart, and that is
   the whole of it. Nothing checks that a deployed page answers, that its
   secret arrived, or that it is the version somebody intended to deploy.

## The shape of the proposal

One file in Git records **what each cloud is running**, one workflow moves that
file forward one cloud at a time, and the move only happens if the previous
cloud passed its tests.

```
  merge to main ──▶ Build Hello App ──▶ ghcr.io/…/hello:sha-a1b2c3d
                                              │
                                              ▼  Promote Hello (one job per cloud)
   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
   │  azure   │───▶│   aws    │───▶│   gcp    │───▶│   oci    │
   └────┬─────┘    └────┬─────┘    └────┬─────┘    └────┬─────┘
     commit          commit          commit          commit
   versions.yaml   versions.yaml   versions.yaml   versions.yaml
        │               │               │               │
        ▼               ▼               ▼               ▼
   Argo CD syncs   Argo CD syncs   Argo CD syncs   Argo CD syncs
   hello-azure     hello-aws       hello-gcp       hello-oci
        │               │               │               │
        ▼               ▼               ▼               ▼
   smoke test      smoke test      smoke test      smoke test
   azure-hello…    aws-hello…      gcp-hello…      oci-hello…
        │               │               │               │
        └── pass ───────┴── pass ───────┴── pass ───────┴──▶ done
            fail: every later cloud stays where it is
```

Nothing about the delivery plane changes: Argo CD still pulls, still self-heals,
still owns what runs where. The workflow does not deploy anything — it writes a
version into Git and then *waits to be convinced* that the cluster caught up.
That is what keeps this GitOps rather than a push pipeline wearing a GitOps hat.

## Piece 1 — a version worth promoting

Promote a **commit**, not a tag. Per cloud, one Git revision decides both which
chart is rendered and which image it names, so a chart change is gated exactly
like an image change. Without this, `apps/hello/chart` edits would keep going
out to all four clouds at once and the promotion would only cover half the app.

That needs three small changes:

| Change | Where | Why |
|---|---|---|
| `image.tag` set per cloud by the ApplicationSet | `gitops/argocd/` | `latest` cannot be promoted, and pinning it in `values.yaml` would pin it for everyone at once |
| `imagePullPolicy: IfNotPresent` | `apps/hello/chart/values.yaml` | an immutable `sha-` tag makes `Always` a registry round-trip per pod start, for nothing |
| a `/version` endpoint | `apps/hello/src/Program.cs` | the gate has to be able to ask a cluster *which version answered*, from outside |

`/version` returns what the chart handed the pod, as JSON:

```json
{ "image": "sha-a1b2c3d", "revision": "a1b2c3d…", "cloud": "gcp", "environment": "prototype" }
```

It is not a claim the pod can get wrong: the env vars and the container image
come out of the same render, and the pod only exists if that image pulled. So
"`/version` says `sha-a1b2c3d`" is the same statement as "this cluster is
running `sha-a1b2c3d`", which is the whole question the gate has to answer.

## Piece 2 — where the promotion state lives

One file, inside the gitops chart so Helm can read it, holding one entry per
cloud:

```yaml
# gitops/argocd/versions/hello.yaml
# Written by the Promote Hello workflow, one line per cloud. This file is the
# answer to "what is running where" — read it, do not guess from main.
defaults:
  revision: main
  image: latest
environments:
  prototype:
    azure: { revision: a1b2c3d4e5f6…, image: sha-a1b2c3d }
    aws:   { revision: a1b2c3d4e5f6…, image: sha-a1b2c3d }
    gcp:   { revision: 9f8e7d6c5b4a…, image: sha-9f8e7d6 }
    oci:   { revision: 9f8e7d6c5b4a…, image: sha-9f8e7d6 }
```

A cloud with no entry falls back to `defaults`, so adding a spoke needs no edit
here and a fresh environment starts on `main`/`latest` exactly as it does today.

The ApplicationSet reads it with `.Files.Get` and turns it into the two
per-cluster values it does not have at Helm time — the cloud is only known once
the cluster generator runs, so the choice has to be an Argo CD-side expression:

```yaml
      source:
        targetRevision: '{{ include "hello.perCloud" (dict "versions" $v "field" "revision" "default" "main") }}'
        …
          parameters:
            - name: image.tag
              value: '{{ include "hello.perCloud" (dict "versions" $v "field" "image" "default" "latest") }}'
```

where `hello.perCloud` emits the same nested-template chain the file already
uses for `secret.remoteKey` — Helm writes it, the ApplicationSet controller
evaluates it:

```
{{ if eq .values.cloud "azure" }}a1b2c3d…{{ else if eq .values.cloud "aws" }}a1b2c3d…{{ else }}main{{ end }}
```

That keeps the generator topology untouched: the cluster generator still
self-adjusts as `var.spokes` gains or loses a cloud, and the hub is still one
static list element. (A `merge` generator overlaying per-cloud values onto the
two existing generators would express this more directly, and is worth
revisiting if the chains grow past two fields — but it restructures the one
object this repository most wants to stay readable, to save an `if/else`.)

## Piece 3 — the gate

`apps/hello/tests/smoke.sh <cloud> <environment> <expected image tag>`, run from
the GitHub runner against the **public URL**, because that is the path a user
takes and it exercises DNS, Traefik, the wildcard certificate and the pod in one
request. It needs no cluster and no cloud credentials at all — the entire
promotion pipeline holds nothing more privileged than a push to this repository,
which is a rare property for a deploy pipeline and worth keeping deliberately.

| Check | Passes when | Catches |
|---|---|---|
| `GET /healthz` over HTTPS, no `-k` | `200`, body `ok` | pod down, ingress gone, wildcard expired or not served |
| `GET /version` | `image` equals the promoted tag | the sync never landed, or landed on the wrong version |
| `GET /` | `200`, page names this `cloud` and `environment` | wrong Application answered this host |
| the secret cell | present, matching `OneK8s <env> test secret …` | ESO never synced, or the tenant identity was refused |

The `/version` check is also the **wait**: poll it until it reports the promoted
tag or a timeout (15 minutes is comfortable — Argo CD polls the repository every
three), then run the rest once. A cloud that never converges fails the same way
a cloud that serves a broken page does, which is correct: both mean the version
is not proven there and nothing should move on.

One check deliberately left out: comparing the secret's **value** across clouds.
It is tempting — comparing the four pages is the platform's end-to-end check —
but the test secret only reaches AWS, GCP and OCI on a manual `distribute` run
of Renew Certificate, so a stale value on a spoke is expected and would fail
promotions for a reason that has nothing to do with the release.

## Piece 4 — the driver

`.github/workflows/promote-hello.yml`, four jobs chained with `needs:`, each
delegating to a reusable `_promote-cloud.yml` — the same split
`deploy-gitops.yml` already uses with `_terraform-deploy.yml`.

```yaml
on:
  workflow_run:                      # after a successful image build on main
    workflows: ["Build Hello App"]
    types: [completed]
    branches: [main]
  workflow_dispatch:                 # re-promote, resume, or roll back by hand
    inputs: { environment, revision, start_at, clouds }

concurrency:
  group: promote-hello-${{ inputs.environment || 'prototype' }}
  cancel-in-progress: false          # never overtake a promotion in flight

permissions:
  contents: write                    # the version file, and nothing else

jobs:
  azure: { uses: ./.github/workflows/_promote-cloud.yml, with: { cloud: azure } }
  aws:   { needs: azure, … }
  gcp:   { needs: aws,   … }
  oci:   { needs: gcp,   … }
```

Each per-cloud job does four things: write this cloud's entry in
`versions/hello.yaml`, commit and push to `main` (rebase-and-retry, since four
jobs of one run push in sequence), wait for `/version`, run the smoke test. The
ordering guarantee is GitHub's own — a failed job leaves everything downstream
skipped, so a cloud that fails is where the release stops.

Two details worth stating rather than discovering:

- **Pushes made with `GITHUB_TOKEN` do not trigger workflows.** The promotion
  commits touch `gitops/**`, which no workflow watches on push today anyway, so
  there is no loop from either direction — but that is two independent reasons
  and only one of them survives switching to a PAT or a GitHub App token.
- **`main` must accept those pushes.** If branch protection is ever turned on,
  this needs an App token or the promotion has to run through a PR per cloud,
  which costs the automation its ordering guarantee. Decide it once, here.

Bind each job to a GitHub environment `hello-<cloud>-<environment>` holding **no
secrets** — purely for the deployment history per cloud, and so that "oci needs
an approval" later is a checkbox rather than a workflow change. `prod` will want
exactly that on the last cloud or two.

Expect a full run to take 15–25 minutes: four clouds, each a repository poll
(≤3 min) plus a rollout plus the tests.

## When it fails

| Situation | What happens | What to do |
|---|---|---|
| smoke test fails on `aws` | `aws` red, `gcp` and `oci` skipped; both stay on the previous revision | fix forward, or revert the `aws` line |
| the version never appears on `/version` | same as a failed test, after the timeout | check `hello-aws` in Argo CD — this is a sync problem, not an app problem |
| a cloud has no foundation in this environment | its job is skipped by the `clouds` input | nothing |
| the whole release is bad | `azure` already has it | `git revert` the promotion commit(s); Argo CD self-heals back |

Failure deliberately **leaves the failed cloud on the new version** rather than
auto-reverting it: a broken page you can open is how the failure gets diagnosed,
and the three clouds that matter for the blast radius are the ones that never
got it. The step summary prints the exact one-line revert for when that trade is
the wrong way round.

Rolling back a single cloud is `workflow_dispatch` with an older `revision` and
`clouds: gcp` — promotion and rollback are the same mechanism, which is the
point of keeping the state in a file rather than in the pipeline's memory.

## The alternative: Argo CD's own progressive sync

`ApplicationSet` supports `strategy: RollingSync`, which walks Applications in
labelled waves and advances when the previous wave is Healthy. Four waves keyed
on `onek8s.io/cloud` express the required order in about twelve lines, with no
workflow and no commits at all, and it would gate *every* sync — including
self-heal — not just releases. Gating on tests rather than on health is possible
too: a `PostSync` hook Job running the smoke test in-cluster fails the sync, and
a failed wave stalls the rollout.

It is not the recommendation, for three reasons:

- Progressive syncs are **alpha** and need
  `ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_PROGRESSIVE_SYNCS=true` on the
  controller. The hub runs the **Azure-managed Argo CD extension**, itself in
  public preview and configured through one flat Helm values map that Azure
  reconciles — an alpha flag on a preview extension is two layers of "supported
  until it isn't" under the platform's only delivery plane.
- A `PostSync` hook tests from **inside** the cluster, so it proves nothing
  about DNS, Traefik or the wildcard certificate — the three things that
  actually differ between these four clouds.
- There is no release identity and no approval surface: nothing to point at and
  say "gcp is on `sha-9f8e7d6` and azure is on `sha-a1b2c3d`", and nowhere to
  hang a required reviewer.

Worth revisiting when progressive syncs go stable, and the two are not exclusive
— the version file stays the source of truth either way.

## The other alternative: the chart as an OCI artifact

`helm package` + `helm push` to `ghcr.io/olljanat-ai/onek8s/charts/hello`, and
the Applications source a chart *version* instead of a repository path:

```yaml
      source:
        repoURL: ghcr.io/olljanat-ai/onek8s/charts     # oci://, on a new enough Argo CD
        chart: hello
        targetRevision: 0.4.0-sha.a1b2c3d              # what this cloud is promoted to
```

The genuine win is not "artifacts are nicer than Git". It is that **the version
collapses from two fields to one**. In the Git model the promotion state has to
carry a revision *and* an image tag, because the chart in Git says
`image.tag: latest` and something has to override it — and the alternative, a
bot committing the tag into `apps/hello/chart/values.yaml`, puts an automated
commit into the path that triggers the image build. Packaging removes the
question: CI sets `image.tag` in the chart it packages, so the released chart
*contains* the image it was built with, no commit required. One immutable
artifact, one line per cloud, and "what is `gcp` running" has exactly one
answer.

Against that, four costs, in the order they will actually be felt:

- **The hub needs to know about the registry.** An OCI Helm repository is a
  labelled Secret in the `argocd` namespace — so `gitops/` grows a
  `kubernetes_secret` and Terraform owns one more thing about the delivery
  plane, which is the boundary this repository has been careful about. No
  credential is needed while the package is public, but the entry is.
- **The chart and the object that deploys it stop travelling together.** Today
  a change to `apps/hello/chart` and a change to the ApplicationSet that
  configures it are one commit and one diff — a property `values.yaml` calls
  out by name. With OCI they are a commit and a published artifact, and the
  version in between is CI's.
- **Versioning becomes a scheme rather than a fact.** A Git revision is
  identity for free; a chart needs a SemVer that CI has to derive and never
  reuse. Use the prerelease form (`0.4.0-sha.a1b2c3d`), not build metadata —
  OCI tags cannot contain `+`, and Helm silently rewrites it to `_`.
- **PR validation drifts a little.** `helm template apps/hello/chart` still
  proves the chart in the PR renders; it no longer proves that *that* is what
  deploys, because what deploys is whatever was packaged from it.

**Recommendation: not yet, and it is cheap to change our minds.** The version
file is the same file either way — `revision` + `image` becomes
`chartVersion` — so the promotion order, the gate and the workflow are
unaffected by the choice. Nothing here consumes the chart from outside this
repository, nothing is air-gapped from GitHub, and the one problem OCI solves
(the two-field version) has an adequate Git answer. Revisit when any of these
becomes true, and prefer doing it *before* a second application exists, since
migrating later means changing every Application's source at once:

- a chart is consumed by something that does not sync this repository;
- charts should be signed and attested next to the images they deploy, on the
  same cosign road;
- the repo-server should stop cloning a growing repository to render one
  subdirectory, four revisions at a time.

## What this adds to the repository

| Path | What |
|---|---|
| `gitops/argocd/versions/hello.yaml` | the promotion state, one entry per cloud |
| `gitops/argocd/templates/_helpers.tpl` | `hello.perCloud`, the Helm→Argo CD chain |
| `gitops/argocd/templates/applicationset-hello.yaml` | per-cloud `targetRevision` and `image.tag` |
| `apps/hello/src/Program.cs` | `GET /version`, and the version on the page footer |
| `apps/hello/chart/` | `VERSION`/`REVISION` env, `imagePullPolicy: IfNotPresent` |
| `apps/hello/tests/smoke.sh` | the gate |
| `.github/workflows/promote-hello.yml` | the order |
| `.github/workflows/_promote-cloud.yml` | one cloud: commit, wait, test |
| `.github/workflows/pr-validation.yml` | render the ApplicationSet against the version file; shellcheck the test |

Nothing in `gitops/` Terraform changes — which is the point of keeping the
chart in Git rather than in a registry (see above): the promotion is entirely a
commit.

## Known gaps in this proposal

- **The order is hard-coded in `needs:`.** Four clouds in one sequence, spelled
  in the workflow. Reordering means editing it — deliberate, since the order is
  a decision and not configuration, but it does mean the workflow and
  `var.spokes` can disagree about which clouds exist. The `clouds` input is the
  seam where that disagreement shows up.
- **Promotion is per application.** A second application needs its own version
  file and its own workflow, or this needs generalising to
  `gitops/argocd/versions/<app>.yaml` plus a matrix. Worth doing at the second
  application, not before.
- **The environment is still `prototype` only.** Promotion here moves a version
  across *clouds within one environment*. Promoting across environments
  (prototype → dev → staging → prod) is a second axis this does not address,
  and the two will need to compose: most likely the same file keyed by
  environment, promoted by the same workflow with the environments chained
  instead of the clouds.
- **The smoke test is a smoke test.** Four HTTP checks against one page. It
  proves the platform delivered the app, which is what this application exists
  to prove, and it will not catch anything about an application with real
  behaviour. A real workload's gate belongs to that workload.
- **Nothing holds a cloud.** There is no "pin `oci` and stop promoting to it"
  switch beyond leaving it out of the `clouds` input on every run. A `hold: true`
  in the version file would be the honest place for it.
