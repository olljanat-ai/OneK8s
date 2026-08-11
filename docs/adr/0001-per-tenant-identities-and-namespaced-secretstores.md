# ADR-0001: Per-tenant cloud identities with namespaced ESO SecretStores

- Status: Accepted
- Date: 2026-08-11

## Context

All tenants on a cluster share one secret backend (Azure Key Vault, AWS
Secrets Manager, GCP Secret Manager). External Secrets Operator (ESO)
synchronizes secrets into the cluster. ESO offers two store types:

1. **`ClusterSecretStore`** — cluster-scoped, one shared credential,
   optionally restricted with namespace `conditions`.
2. **`SecretStore`** — namespaced, referenced only by `ExternalSecret`s in
   the same namespace, with its own credentials.

The security goal: a tenant must never read another tenant's secrets or use
another tenant's store, even if the tenant is malicious or compromised.

## Decision

Every tenant gets its **own namespaced `SecretStore`** backed by its **own
dedicated cloud identity**, and that identity is authorized for **only a
name/prefix slice** of the shared backend:

- Azure: User-Assigned Managed Identity + Federated Identity Credential;
  `Key Vault Secrets User` with an **ABAC condition** on
  `secretName StringStartsWithIgnoreCase '<tenant>-'`.
- AWS: IAM role via IRSA; policy resource restricted to
  `arn:...:secret:<env>/<tenant>/*`, plus `kms:Decrypt` allowed only
  `ViaService` Secrets Manager.
- GCP: Google Service Account + Workload Identity binding;
  `roles/secretmanager.secretAccessor` with an IAM condition
  `resource.name.startsWith("projects/<num>/secrets/<tenant>-")`.

The federation subject is always pinned to
`system:serviceaccount:<tenant-ns>:<sa>`.

## Rationale

**Why not one ClusterSecretStore with namespace conditions?**

- It concentrates a *superset* credential (read access to all tenants'
  secrets) in one object; ESO and its RBAC become the only wall between
  tenants. A single ESO bug, misconfigured condition, or overly permissive
  ClusterSecretStore edit exposes every tenant at once.
- Authorization would be enforced in Kubernetes (soft, mutable YAML) instead
  of in the cloud IAM plane (hard, auditable, independently logged).
- Blast radius: a leaked token from the shared identity is a platform-wide
  incident; a leaked tenant identity is bounded to that tenant's prefix.

**Why namespaced SecretStores + per-tenant identities win:**

- **Defense in depth** — three independent boundaries must all fail:
  namespace scoping of the store, SA-pinned federation subject, and the
  cloud-side prefix condition. Kubernetes RBAC misconfiguration alone is not
  enough to cross tenants.
- **Cloud-side enforcement & audit** — access decisions land in Azure
  Activity Logs / CloudTrail / Cloud Audit Logs with the *tenant's* identity
  as principal, giving per-tenant audit trails for free.
- **Symmetric across clouds** — ABAC prefixes, IAM ARN prefixes and IAM
  conditions express the same rule, so the tenant contract ("you own
  `<prefix>*`") is identical on AKS, EKS and GKE.
- **Clean offboarding** — deleting the tenant module instance deletes the
  identity and role bindings; no shared credential to rotate.

## Consequences

- One cloud identity + role binding per tenant: more objects to manage, and
  cloud limits apply at very high tenant counts (e.g. Azure role assignments
  per subscription). Acceptable for the intended scale; mitigate with one
  vault/cluster pair per environment.
- Secret naming conventions become a hard contract; renaming a tenant means
  migrating its secrets under a new prefix.
- ESO runs without any cloud credentials of its own — the controller only
  exchanges tenant SA tokens. There is deliberately no ClusterSecretStore,
  and platform policy (Azure Policy / admission control) should forbid
  creating one.
