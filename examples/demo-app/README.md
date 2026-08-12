# OneK8s demo app

Minimal .NET 10 web app that proves the platform's two tenant delegations
work end-to-end **with the workload identity only** — the app is configured
with zero credentials:

- **Vault** — reads the hardcoded secret `demo-secret` from the shared
  backend (Key Vault / Secrets Manager / Secret Manager), using the
  tenant naming contract: `<tenant>-demo-secret` on Azure/GCP,
  `<env>/<tenant>/demo-secret` on AWS.
- **Redis** — connects to the shared managed Redis (endpoint from the
  platform's `redis-connection` ConfigMap), writes the hardcoded key
  `demo-key` (`<tenant>:demo-key` on AWS, where the ACL enforces the
  prefix) and reads it back. AUTH uses an Entra token (Azure), a SigV4 IAM
  token (AWS) or an ADC access token (GCP).

Both the secret value and the Redis key/value are rendered **as plain text
in the UI** — deliberately, to make the demo obvious. Never do that in a
real app.

The same image runs on every cloud; `CLOUD=azure|aws|gcp` selects the
implementation.

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

Edit `k8s/deployment.yaml`: set the image, set `CLOUD`, and fill in the one
cloud-specific variable (`AZURE_KEY_VAULT_URI`, `AWS_REGION` or
`GCP_PROJECT_ID`). Then:

```bash
kubectl -n team-alpha apply -f k8s/
kubectl -n team-alpha port-forward svc/demo-app 8080:80
open http://localhost:8080
```

The page shows the secret name/value and the Redis key/value, or the exact
error per probe if a delegation is missing.

## How auth works per cloud

| | Vault | Redis |
|---|---|---|
| Azure | `DefaultAzureCredential` → federated token of the tenant UAMI | `Microsoft.Azure.StackExchangeRedis` Entra auth against Azure Managed Redis (access keys are disabled platform-side) |
| AWS | IRSA picked up by the AWS SDK default chain | Hand-signed SigV4 presigned URL (`Action=connect&User=<user>`) as password for the tenant's IAM-auth ElastiCache user |
| GCP | Workload Identity → ADC | GSA access token as password (`AUTH default <token>`) against Memorystore IAM auth |

Notes:

- Negative test: point `TENANT_NAME` (or the secret/key names) at another
  tenant's prefix and watch the cloud deny it — that is the isolation
  boundary working.
- The GCP branch skips Redis server-cert validation (cluster-private CA)
  to stay minimal; fetch the CA via `clusters.getCertificateAuthority`
  and trust it properly in real code.
- The app opens a fresh Redis connection per request so short-lived AUTH
  tokens never go stale mid-demo; real apps share a multiplexer and
  refresh credentials.
