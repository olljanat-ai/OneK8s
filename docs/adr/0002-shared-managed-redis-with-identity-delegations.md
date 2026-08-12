# ADR-0002: Shared managed Redis with per-tenant identity delegations

## Status

Accepted.

## Context

Tenant workloads need a low-latency cache/queue. Running one Redis per
tenant in-cluster wastes the platform's isolation machinery (every tenant
already has a dedicated, federation-pinned cloud identity) and adds an
operational burden (patching, HA, persistence) the clouds already sell as a
service. All three clouds now offer a managed Redis(-compatible) service
that can authenticate **cloud identities** instead of passwords:

- **Azure Managed Redis** (`Microsoft.Cache/redisEnterprise`, AMR SKUs) —
  Entra ID data-plane auth via access policy assignments; access keys can
  be disabled entirely.
- **Amazon ElastiCache Serverless (Valkey)** — RBAC users with
  `authentication_mode = iam` and ACL key patterns, connected via
  `elasticache:Connect`.
- **GCP Memorystore for Redis Cluster** — `AUTH_MODE_IAM_AUTH`, connect
  gated by `roles/redis.dbConnectUser` (permission `redis.clusters.connect`).

## Decision

1. Every foundation deploys **one shared managed Redis per cluster**, next
   to the shared secret backend, and exports its endpoint plus the handles
   tenants need for delegation.
2. Tenant onboarding grows a single flag, `redis_enabled` (default
   `false`), with identical syntax on every cloud. When set, the
   tenant-namespace module creates the delegation **for the tenant's
   existing workload identity**:
   - Azure: an `accessPolicyAssignments` child resource (policy `default`)
     for the tenant UAMI on the Managed Redis database. The database is
     created with `accessKeysAuthentication = "Disabled"`, so Entra is the
     only path in.
   - AWS: an `aws_elasticache_user` with `user_id == user_name`
     (IAM-auth requirement) and access string
     `on ~<tenant>:* +@all -@admin -@dangerous`, an
     `aws_elasticache_user_group_association` into the foundation's user
     group, and an inline `elasticache:Connect` policy on the tenant role
     restricted to exactly the shared cache ARN and the tenant's user ARN.
   - GCP: `roles/redis.dbConnectUser` for the tenant GSA with an IAM
     condition `resource.name.startsWith(projects/<number>/locations/
     <region>/clusters/<name>)`.
3. Enabled tenants get a **`redis-connection` ConfigMap** (host, port, TLS
   flag, username hint, and the key prefix on AWS) in their namespace.
   Passwords are never distributed: the "password" at AUTH time is a
   short-lived token minted through the same workload-identity federation
   chain used for secrets (ADR-0001).

## Consequences

- **No static Redis credentials** exist in the platform; revoking a tenant
  is deleting its delegation resource.
- **Isolation strength differs per cloud.** AWS slices the shared keyspace
  per tenant with ACL key patterns (`~<tenant>:*`), mirroring the secret
  prefix model. Azure's `default` access policy and GCP's IAM auth are
  instance-scoped: opted-in tenants share one keyspace. Where tenants are
  hostile to each other, treat the shared Redis as a convenience tier, run
  separate instances, or (Azure) define narrower custom access policies.
- The AWS user group's membership is mutated from the tenants stack
  (`aws_elasticache_user_group_association`), so the foundation ignores
  `user_ids` drift on `aws_elasticache_user_group`.
- Azure Managed Redis has no azurerm resource yet; it is managed with
  `azapi` (like managed namespaces) behind `managed_redis_api_version` /
  `redis_api_version` variables to track API promotion.
- Foundations deployed before this ADR export no Redis outputs; enabling
  `redis_enabled` against such state fails with an explicit precondition
  message instead of a null-reference error.
