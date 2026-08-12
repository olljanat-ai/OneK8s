# OneK8s demo app

Minimal .NET 10 web app that proves a tenant workload can consume the
platform's two shared services — the secret backend ("vault") and the
managed Redis — **without a single cloud SDK, credential, or line of
cloud-specific code**. Its only dependency is `StackExchange.Redis`; the
same image runs unchanged on Azure, AWS and GCP.

The cloud work happens in the platform, authenticated by the tenant's
workload identity:

- **Vault** — the hardcoded secret `demo-secret` is synced from the shared
  backend into a Kubernetes Secret by an `ExternalSecret`
  (`k8s/externalsecret.yaml`) through the tenant's prefix-scoped
  `tenant-store`. The app just reads env `DEMO_SECRET`.
- **Redis** — the endpoint comes from the platform's `redis-connection`
  ConfigMap and the AUTH password from the platform's `redis-auth`
  ExternalSecret (both created by `redis_enabled = true`). The app reads
  env `REDIS_HOST/PORT/TLS/PASSWORD` (+ `REDIS_USERNAME`/`REDIS_KEY_PREFIX`
  on AWS, where each tenant has its own ACL user pinned to the
  `<tenant>:` key slice), writes the hardcoded key `demo-key` and reads it
  back.

Both the secret value and the Redis key/value are rendered **as plain text
in the UI** — deliberately, to make the demo obvious. Never do that in a
real app.

## Prerequisites

- The foundation for your cloud/env is deployed, and the tenant (default
  `team-alpha`) is onboarded with `redis_enabled = true`.
- Seed the demo secret once (any value you like):

```bash
# Azure
az keyvault secret set --vault-name <kv-name> --name team-alpha-demo-secret --value "s3cret from Key Vault"
# AWS
aws secretsmanager create-secret --name dev/team-alpha/demo-secret --secret-string "s3cret from Secrets Manager"
# GCP
printf "s3cret from Secret Manager" | gcloud secrets create team-alpha-demo-secret --data-file=-
```

## Build and push

```bash
cd examples/demo-app
docker build -t <registry>/onek8s-demo:latest .
docker push <registry>/onek8s-demo:latest
```

## Deploy

Set the image in `k8s/deployment.yaml`; on AWS also change the
`remoteRef.key` in `k8s/externalsecret.yaml` to the AWS naming contract
(`dev/team-alpha/demo-secret`). Then:

```bash
kubectl -n team-alpha apply -f k8s/
kubectl -n team-alpha port-forward svc/demo-app 8080:80
open http://localhost:8080
```

The page shows the secret name/value and the Redis key/value, or the exact
error per probe if something is missing (e.g. the tenant isn't
`redis_enabled`, or the ExternalSecret hasn't synced —
`kubectl -n team-alpha describe externalsecret` tells you why).

## Notes

- Negative test: point the ExternalSecret's `remoteRef.key` at another
  tenant's prefix and watch the sync fail — that is the platform's
  isolation boundary working in the cloud IAM plane.
- Why no cloud SDKs: the Redis AUTH secret is deliberately a vault secret
  under the tenant's prefix, so both demos ride the exact same ESO +
  workload-identity chain. See ADR-0002 for the trade-off (static Redis
  credential vs. cloud-free apps) and what rotation looks like.
