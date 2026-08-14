# hello

A minimal .NET 10 web application whose only job is to prove, from a browser,
that a cluster is wired up: it renders a welcome message and the value of a
**test secret** read out of that cloud's own secret backend.

```
apps/hello/
├── src/            # Program.cs + Hello.csproj — one file, one page
├── Dockerfile      # SDK build → chiseled ASP.NET runtime
└── chart/          # what Argo CD renders on every cluster
```

One image runs unchanged on AKS, EKS, GKE and OKE, because everything it shows
comes from the environment:

| Variable | Set by | Shown as |
|---|---|---|
| `WELCOME_MESSAGE` | the ApplicationSet, per cloud | the heading |
| `CLOUD` / `ENVIRONMENT` | the ApplicationSet | Cloud / Environment |
| `POD_NAME` / `POD_NAMESPACE` | the downward API | Pod / Namespace |
| `TEST_SECRET_NAME` | `secret.name` in values | the secret's label |
| `TEST_SECRET_FILE` | the chart, pointing at the mounted secret | the secret's value |

The secret is read **per request from a mounted file**, not captured from an
environment variable at start-up. The kubelet refreshes a Secret volume in
place, so a value that External Secrets syncs (or rotates) after the pod
started shows up on a reload — and the volume is `optional`, so the pod starts
and says "not available" rather than hanging in `ContainerCreating` when the
secret does not exist yet. `TEST_SECRET` is honoured as a fallback for running
it outside Kubernetes.

`GET /healthz` is the liveness and readiness probe.

`GET /favicon.svg` is the page's icon: the Kubernetes heptagon with a "1" cut
out of it, held as a string in `Program.cs` rather than a file, because the app
serves no static content and the image has no `wwwroot` to copy in. The
document links it, so no browser falls back to asking for `/favicon.ico`.

## Where it is deployed, and how

Argo CD, from `gitops/argocd/`. The full story — the root Application, the
per-cloud secret naming, the DNS records, the image tag — is in
[docs/hello-app.md](../../docs/hello-app.md).

## Running it locally

```bash
cd apps/hello/src
TEST_SECRET="a local value" WELCOME_MESSAGE="Hello from my laptop" dotnet run
```

Or as the container image the platform actually runs:

```bash
docker build -t hello apps/hello
docker run --rm -p 8080:8080 -e TEST_SECRET="a local value" hello
```
