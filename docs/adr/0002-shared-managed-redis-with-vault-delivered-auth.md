# ADR-0002: Shared managed Redis with vault-delivered AUTH secrets

## Status

Accepted. (Supersedes an earlier draft of this ADR that used per-cloud
identity auth — Entra tokens / ElastiCache IAM / Memorystore IAM — for the
Redis data plane; see "Alternatives considered".)

## Context

Tenant workloads need a low-latency cache/queue. Running one Redis per
tenant in-cluster wastes the platform's isolation machinery and adds an
operational burden the clouds already sell as a service, so each foundation
deploys **one shared managed Redis per cluster**:

- **Azure Managed Redis** (`Microsoft.Cache/redisEnterprise`, AMR SKUs)
- **Amazon ElastiCache Serverless (Valkey)**
- **GCP Memorystore for Redis**

All three *can* authenticate cloud identities directly (Entra tokens,
SigV4 IAM auth tokens, Memorystore IAM auth), which would mean zero static
credentials. But identity-authenticated Redis pushes cloud-specific code
into every tenant application: each cloud needs its own auth library and a
token-refresh dance inside (or beside) the app. That breaks the promise
that made the secret backend pleasant to use — apps consume vault secrets
through External Secrets Operator with **no cloud SDKs at all** — and it
was judged the wrong trade for application portability.

## Decision

Treat the Redis AUTH secret as *just another vault secret* and reuse the
platform's existing, identity-secured delivery chain end to end:

1. Foundations enable **password-style auth** on the shared Redis:
   - Azure: `accessKeysAuthentication = "Enabled"`; the foundation exports
     the database access key (sensitive output).
   - AWS: the shared serverless cache keeps its RBAC user group; tenant
     users authenticate with passwords.
   - GCP: **Memorystore for Redis** (standalone) with `auth_enabled = true`
     — chosen over Memorystore for Redis *Cluster*, which supports only
     IAM/disabled auth.
2. `redis_enabled = true` on a tenant writes that tenant's Redis credential
   into the shared vault **under the tenant's secret prefix**:
   - Azure: Key Vault secret `<tenant>-redis-auth` = shared access key.
   - AWS: a per-tenant `random_password` for a per-tenant ElastiCache user
     whose ACL is pinned to the `<tenant>:` key slice
     (`on ~<tenant>:* +@all -@admin -@dangerous`); stored as
     `<env>/<tenant>/redis-auth`, encrypted with the platform CMK.
   - GCP: Secret Manager secret `<tenant>-redis-auth` = instance AUTH
     string.
3. The tenant module also creates a **`redis-auth` ExternalSecret** in the
   namespace (next to the existing `redis-connection` ConfigMap), so the
   workload receives `REDIS_PASSWORD` like any other secret — fetched from
   the vault by ESO with the tenant's prefix-scoped workload identity.

Applications therefore configure Redis entirely from
`redis-connection` + `redis-auth` and contain **no cloud-specific code**;
`examples/demo-app` demonstrates this with `StackExchange.Redis` as its
only dependency.

## Consequences

- **Access control is unchanged in shape**: the ability to read
  `...redis-auth` is enforced by the same ABAC / ARN-prefix / IAM-condition
  boundaries as every other tenant secret, and revoking a tenant is
  deleting its vault entry (plus, on AWS, its ElastiCache user).
- **A static credential now exists** — the deliberate trade. Rotation:
  regenerate the key/AUTH string (Azure/GCP) or the tenant password (AWS,
  `terraform taint random_password`), re-apply, and ESO re-syncs within its
  `refreshInterval` (1h); apps must tolerate one reconnect.
- **Isolation strength still differs per cloud.** AWS keeps true per-tenant
  credentials and an ACL-scoped keyspace. Azure and GCP have one shared
  credential and keyspace for all opted-in tenants — treat the shared Redis
  there as a convenience tier, or run separate instances for hostile
  tenants.
- GCP transit encryption is off (VPC-internal endpoint): Memorystore TLS
  requires distributing an instance-private CA to every client, which is
  exactly the cloud-specific client burden this ADR removes. Enable
  `SERVER_AUTHENTICATION` and ship `server_ca_certs` if you need it.
- The Azure/GCP secret writes require the tenants-stack deploy identity to
  hold vault write rights (Key Vault Secrets Officer / Secret Manager
  admin) — the foundation grants them to its own deployer; grant the same
  to the tenants pipeline identity if the two differ.

## Alternatives considered

- **Identity-authenticated Redis everywhere** (the earlier draft): no
  static credentials, but every app needs per-cloud auth libraries and
  token refresh (there is not even an official .NET helper for ElastiCache
  IAM tokens). Rejected for application portability; revisit if a shared
  client library per language becomes worth maintaining.
- **Auth sidecar/proxy**: keeps apps clean without static credentials, but
  adds a per-pod moving part and still means maintaining three auth flows.
