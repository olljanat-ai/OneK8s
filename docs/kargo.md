# Kargo: how a release moves between clouds

Argo CD answers one question — *is the cluster what Git says it is* — and
answers it continuously. It has no opinion about **which** revision of an
application belongs on which cluster, and for a platform whose whole point is
that Azure means staging and AWS means production, that second question is the
interesting one.

[Kargo](https://kargo.io) answers it, and writes the answer down.

```
ghcr.io/…/hello:sha-a1b2c3d ─┐
                             ├─▶ Freight ──▶ Stage staging  ──▶ commit ──┐
apps/hello/chart @ 9f4e2b1 ──┘      │            (auto)                  │
                                    │                                    │
                          a person promotes                        OneK8s-argocd
                                    ▼                            stages/hello/*.yaml
                              Stage production ──▶ commit ───────────────┘
                                                                         │
                                                          Argo CD syncs ─┘
```

Everything on the left is Kargo's; everything on the right is Argo CD's, and it
is unchanged. Both `hello` Applications carry `syncPolicy.automated` — Argo CD
applies what Git says, as fast as it can, on both clouds. **The gate in front of
AWS is that no commit says production runs that build yet.**

## Why this replaced the previous gate

Before this, "production is gated" meant the `hello-production` Application
deliberately carried no `syncPolicy.automated`, plus a *Promote to production*
GitHub workflow that ran `argocd app sync` after an approval on a GitHub
environment. It worked, and it had four problems that were not fixable in that
shape:

| The old gate | With Kargo |
|---|---|
| One missing YAML block, three lines from being "made consistent" by a well-meaning edit | A promotion is a commit; adding a sync policy changes nothing, because the Application is already synced — to the previous release |
| Said nothing about *what* was promoted: the tag was `latest`, so a production pod that restarted pulled the newest build | Freight names an immutable `sha-` tag and a chart commit; the build workflow publishes no moving tag at all |
| The audit trail was a workflow run, in a repository, next to the thing it approved | `git log stages/hello/production.yaml` — the list of every build production has run, and who asked |
| Needed an Argo CD API account (`role:ci`) and a bearer token pasted into a repository secret | Kargo writes `Application` objects as a controller, through the Kubernetes API. No Argo CD machine account exists any more |

The one credential that remains is a Git credential, because a promotion is a
push. That is discussed below.

## The objects, and where each one lives

| Object | Kind | Lives in | Owned by |
|---|---|---|---|
| the engine | Helm release `kargo` | namespace `kargo` on the hub | `foundations/azure/kargo.tf` |
| **how a promotion is performed** | `ClusterPromotionTask` `onek8s-promote` (cluster-scoped, **one for the whole platform**) | the hub | [OneK8s-argocd](https://github.com/olljanat-ai/OneK8s-argocd), `argocd/templates/kargo-promotion-task.yaml` |
| the project | `Project` `onek8s-<app>` (cluster-scoped, **one per application**; Kargo creates a namespace of the same name) | the hub | the same chart, `kargo-projects.yaml` |
| what a release is | `Warehouse` `<app>` | namespace `onek8s-<app>` | the same chart, `kargo-warehouses.yaml` |
| the release path | `Stage` `staging`, `Stage` `production` | namespace `onek8s-<app>` | the same chart, `kargo-stages.yaml` |
| who may promote | `ServiceAccount` + `Role` `promoter` | namespace `onek8s-<app>` | the same chart |
| what each stage runs | `stages/<app>/<stage>.yaml` | OneK8s-argocd | **Kargo** — written by promotions |

Two of those rows carry the design's weight for a platform that expects many
applications:

- **One `ClusterPromotionTask`, shared.** The five steps of a promotion are the
  same for every application and every stage — only the repository, the file and
  the Argo CD Application differ, and those are variables. Fifty applications
  share one copy, so fixing the procedure is one commit rather than fifty.
- **One Kargo `Project` per application.** A Project is Kargo's unit of
  isolation: its own namespace, Freight, promoters and place to hold a
  credential — and its own Stage names, since every application wants one called
  `production`.

No template in that chart names an application. They range over `apps:` in its
values, so onboarding one is an entry there, and CI renders a throwaway second
application on every pull request to prove it stayed that way.

Only the first is Terraform's. Everything else arrives through the same root
`Application` that already brings in the `AppProject` and the ApplicationSets
(`gitops/root-app.tf`), so changing the release path is a reviewed commit in the
delivery-plane repository rather than an apply.

## Installing it: `foundations/azure/kargo.tf`

Kargo is an ordinary Helm release rather than an AKS extension — Azure offers
none — and follows Argo CD in every other respect:

```hcl
enable_kargo        = true
kargo_hostname      = "kargo.onek8s.lol"     # platform wildcard, A record by hand
kargo_sso_client_id = "<app registration>"   # Entra ID, as Argo CD's UI uses
kargo_rbac_groups   = {
  admins           = ["<group object id>"]
  project_creators = ["<group object id>"]
  viewers          = ["<group object id>"]
}
```

- **TLS terminates at Traefik**, as everywhere else: the API serves plain HTTP
  and is told that TLS is terminated upstream, so the URLs it renders and the
  address `kargo login` is pointed at are `https://`.
- **Except for the admission webhooks, which need a certificate of their own.**
  Kargo's `ValidatingWebhookConfiguration` is what enforces who may create a
  `Promotion`, and the Kubernetes API server will only call it over TLS — at
  `kargo-webhooks-server.kargo.svc`, a name the platform wildcard does not
  cover and a request Traefik is nowhere near. The chart's answer is a
  cert-manager `Certificate`, which is what an apply on a cluster without those
  CRDs fails on; `kargo.tf` mints the same self-signed certificate itself
  instead, ten years long, and pins its own PEM as the `caBundle` on every
  webhook entry. No cert-manager, and no wildcard where a wildcard would not
  work.
- **The external webhooks server is off.** That is the *inbound* half — a public
  endpoint for GitHub or Docker Hub to POST to so a Warehouse refreshes on a
  push rather than on its interval. No `WebhookReceiver` is declared anywhere in
  the delivery plane, so it would be a deployment and a route with no callers.
  Turn it back on together with the first receiver.
- **Entra ID is the way in.** The app registration needs no federated credential
  and no client secret — Kargo verifies the ID token rather than calling Graph —
  but four things about it are not optional, and three of them are where a
  first sign-in goes wrong. See *The app registration* below.
- **The UI is installed only once somebody can sign in to it.** With neither
  `kargo_sso_client_id` nor `kargo_admin_password_hash` set, Kargo runs
  controller-only: Warehouses discover artifacts, staging is auto-promoted, and
  a manual promotion is a `Promotion` object created with `kubectl`. The gate
  holds either way — it is the Stage's promotion policy, not the UI.
- **`kargo_rbac_groups` is cluster-wide capability** ("may create Projects",
  "may see everything"). Who may promote *the hello application to production*
  is not here: it is a `Role` in the Project's namespace, and it lives beside the
  Stage it guards.

`enable_kargo` is ignored when `enable_argocd` is false — every Stage's health
and its last promotion step is an Argo CD Application, so a Kargo with no Argo CD
would have nothing to promote onto.

## The app registration

Kargo talks to Entra ID directly — no Dex, no client secret, no Graph call. It
requests `openid profile email`, reads the ID token that comes back, and matches
its claims against `kargo_rbac_groups`. Everything it needs, therefore, has to
already be *in that token*, which is a property of the registration rather than
of the request.

| In the registration | Why |
|---|---|
| **Authentication → Web →** `https://kargo.onek8s.lol/login` | where the UI's browser is sent back to |
| **Authentication → Mobile and desktop →** `http://localhost/auth/callback` | `kargo login --sso` listens on a loopback port; Entra allows an arbitrary port here only on this platform, and only for a public client |
| **Token configuration → Add groups claim** → *Groups assigned to the application* (or *Security groups*), **ID** token, formatted as **Group ID** | `kargo_rbac_groups` is a list of group **object IDs**, matched against the `groups` claim. No claim, no roles — a valid sign-in that can see nothing |
| **Token configuration → Add optional claim → ID →** `email` | `usernameClaim` is `email`, so this is the name on every Promotion Kargo records. Entra emits it only when asked, and only for a user who has a mail address; a directory of `.onmicrosoft.com` accounts with no mailbox will want `preferred_username` in `kargo.tf` instead |

No client secret, no implicit grant, and no API permission beyond the delegated
`openid`/`profile`/`email` that every sign-in carries: the authorization code
flow with PKCE is what both clients use, and Kargo verifies the resulting token
against the tenant's published keys.

**Do not ask Entra for a `groups` scope.** Okta, Keycloak and Google publish one,
so the upstream chart requests it by default (`api.oidc.additionalScopes`), and
`kargo.tf` sets that list back to empty on purpose. Entra resolves an unqualified
scope against Microsoft Graph, and Graph has no `groups`, so the *whole* request
is refused before a consent screen is ever drawn:

```
AADSTS650053: The application 'Kargo SSO' asked for scope 'groups' that doesn't
exist on the resource '00000003-0000-0000-c000-000000000000'.
```

The groups claim in the table above is what replaces it, and it needs no scope —
Entra puts it in every ID token that registration issues.

**Prefer *Groups assigned to the application* to *Security groups*.** Entra
replaces the claim with a `_claim_names` / `_claim_sources` pointer to Graph once
a user is in more than 200 groups, and Kargo does not call Graph — that user
would sign in with no roles at all, while their colleagues are fine. Assigning
the four RBAC groups to the enterprise application keeps the claim to those
four, whatever else the directory grows.

Two client IDs are configured (`kargo_sso_client_id` and
`kargo_sso_cli_client_id`) because the loopback redirect may live on a second
registration; one registration declaring both platforms is the simpler shape,
and then both variables carry the same value. Whichever it is, **each
registration needs its own token configuration** — the claims are not shared,
and a CLI login against a registration missing the groups claim lands in the
same roleless state as above.

## The one credential

A promotion is a commit, so Kargo needs a Git credential that may push to the
delivery-plane repository. It is not created by Terraform, for the same reason
Argo CD's account tokens never were: a credential in state is a credential in
every plan output and every state backup.

```bash
kubectl -n kargo-shared-resources create secret generic onek8s-argocd-repo \
  --from-literal=repoURL=https://github.com/olljanat-ai/OneK8s-argocd.git \
  --from-literal=username=<user or app id> \
  --from-literal=password=<PAT or installation token>

kubectl -n kargo-shared-resources label secret onek8s-argocd-repo \
  kargo.akuity.io/cred-type=git
```

`kargo-shared-resources` is the namespace the chart creates for credentials
shared by every Project (`kargo_shared_resources_namespace` in the foundation's
outputs); put it in the Project's own namespace instead to scope it to one
project. A fine-grained PAT with *contents: read and write* on that one
repository is enough; a GitHub App installation is the better long-lived answer.

Nothing else is manual, and nothing else is a secret. Kargo's access to Argo CD
is Kubernetes RBAC on `Application` resources, installed with its chart.

## What a promotion actually does

The steps live once, in the `ClusterPromotionTask`
(`argocd/templates/kargo-promotion-task.yaml` in OneK8s-argocd); each `Stage`
supplies the variables and delegates to it:

1. `git-clone` — the delivery-plane repository, as the bot.
2. `yaml-update` — write `image.tag` and `chartRevision` into
   `stages/hello/<stage>.yaml`. Two lines: everything else about the stage —
   which cluster, which host, which secret — belongs to the stage rather than to
   the release, and is rendered by the ApplicationSet.
3. `git-commit` — the record. The message carries the Freight, both artifacts
   and, for a promotion somebody asked for, their name.
4. `git-push` — to `main`.
5. `argocd-update` — ask Argo CD to sync now rather than on its next refresh,
   and wait until the Application is synced at both promoted revisions *and*
   healthy. Without that wait a promotion would report success while the old
   pods were still serving.

Argo CD reads the file back through the `hello-<stage>` ApplicationSet, which
uses it twice: `chartRevision` as the chart source's `targetRevision`, and the
file itself as a Helm values file for `image.tag`. So a chart change travels the
release path exactly like an image does — which the old gate did not manage,
since only the image was ever "promoted".

The `argocd-update` step will not touch an Application that has not named the
Stage acting on it (`kargo.akuity.io/authorized-stage: onek8s-hello:<stage>`), so
the production Stage cannot sync staging's Application or the reverse.

## Promoting

```bash
kargo login https://kargo.onek8s.lol --sso

kargo get stages     --project onek8s-hello    # what each stage runs now
kargo get freight    --project onek8s-hello    # what could be promoted
kargo promote        --project onek8s-hello --stage production --freight <name>
kargo get promotions --project onek8s-hello    # who promoted what, when
```

Or the UI at `https://kargo.onek8s.lol`, or — with neither — the object itself:

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Promotion
metadata:
  generateName: production-
  namespace: onek8s-hello
spec:
  stage: production
  freight: <freight name>
```

All three leave the same commit behind.

**Who may.** `apps.<name>.promoters` in the delivery-plane chart's values
(falling back to `kargo.promoters`) is a list of Entra ID group object IDs. It
renders a `ServiceAccount` whose claims Kargo matches against the signed-in
identity, and a `Role` granting `promote` on exactly the stages of *that
application* that wait for a person — plus read on its Project and nothing else.
Not editing a Stage, not changing what the Warehouse watches, not promoting
another application.

**What may.** `production` requests its Freight from `staging`, not from the
Warehouse, so a build that has never run on AKS cannot be promoted to EKS even
by somebody who is allowed to promote. `soakTime` adds "and only after it has
run there this long".

## Operating it

```bash
kubectl -n kargo get pods                       # the engine
kubectl -n onek8s-hello get warehouses,stages,freight
kubectl -n onek8s-hello describe stage production

# why is there no new Freight?
kubectl -n onek8s-hello describe warehouse hello   # discovery errors show here

# what does Git say production runs?
git -C ../OneK8s-argocd log --oneline -- stages/hello/production.yaml
```

Common causes, in the order they usually happen:

| Symptom | Usually |
|---|---|
| no Freight after a merge | the build pushed a tag the Warehouse's `tagRegexes` do not allow, the `selectionStrategy` is `SemVer` and the tag is not one, or the package is private |
| a promotion fails at `git-push` | the Git credential is missing, unlabelled, or has no write access |
| a promotion fails at `argocd-update` | the Application is missing the `kargo.akuity.io/authorized-stage` annotation, or the spoke is not registered so no Application was generated |
| the Application renders "image.tag is required" | nothing has been promoted to that stage yet — the seed file in `stages/` has an empty tag on purpose |
| a promotion succeeds but the page is unchanged | the chart source's `targetRevision` moved; give the ApplicationSet's git generator a moment, or check its `revision` |
| Entra refuses the sign-in with `AADSTS650053` | something is still requesting the `groups` scope — `api.oidc.additionalScopes` in `kargo_extra_values`, or a chart version whose default `kargo.tf` no longer overrides |
| sign-in works but everything is empty, or "you are not authorized" | the ID token carries no `groups` claim (not configured on *that* registration, or a group-overage `_claim_names` pointer), or `kargo_rbac_groups` holds a group's display name rather than its object ID — `kubectl -n kargo logs deploy/kargo-api` prints the claims it matched on |

## Known gaps

- **Kargo commits straight to `main`.** A promotion is not reviewed the way a
  pull request is — the review is the approval to promote, and Kargo's RBAC
  stands in for branch protection on `stages/`. The `git-open-pr` step is the
  alternative, at the cost of a second click on every staging deploy.
- **The Git credential can write to the whole delivery-plane repository.** A
  promotion only ever touches `stages/`, but nothing enforces that.
- **No verification beyond "the pods are healthy".** Kargo can hold Freight
  behind an Argo Rollouts `AnalysisTemplate` or a smoke-test `Job` before it
  becomes promotable; this platform installs no Argo Rollouts, so both
  integrations are explicitly disabled and `soakTime` is the blunt substitute.
- **`db-hello` has no release path.** A single cluster, so no path to travel and
  no Kargo objects — deliberate, but it does mean its image tag is still the
  moving `latest` that `hello` no longer uses.
- **Selection strategy is per application, and `hello` uses the weaker one.**
  `NewestBuild` orders content-addressed `sha-` tags by build time, which is
  right for an application that builds on every merge and has no releases. An
  application with real versions should use `SemVer` with a `semverConstraint`
  per stage — the build workflow already publishes a semver tag on a `v*` git
  tag, so switching is a values change.
- **The webhooks certificate renews only when somebody runs `terraform apply`.**
  It is valid for ten years and an apply inside the last month of that replaces
  it, so in practice the branch that expires it is a cluster nobody has applied
  to in a decade. Nothing in the cluster would notice if that happened — the
  same trade-off the platform wildcard makes (`docs/architecture.md`).
- **The chart version is pinned by hand** (`kargo_chart_version`). Deliberate —
  a promotion engine that upgrades itself unannounced is one nobody can reason
  about — but it means somebody has to bump it.
