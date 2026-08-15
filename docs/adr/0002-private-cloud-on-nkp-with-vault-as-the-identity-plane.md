# ADR-0002: A private cloud on NKP, with Vault as its identity plane

- Status: Accepted
- Date: 2026-08-15

## Context

The platform's tenancy model
([ADR-0001](0001-per-tenant-identities-and-namespaced-secretstores.md)) rests
on something a private cloud does not have: a **cloud IAM plane** that can be
told "this pod's identity may read secrets whose name starts with
`<tenant>-`", and that enforces it outside Kubernetes.

Adding a private cloud means supplying that plane. The cluster half is
straightforward — **Nutanix Kubernetes Platform (NKP)**, whose Starter edition
is included with NCI Pro/Ultimate and needs no separate purchase. The secret
half is the decision: Nutanix has no per-pod identity service and no managed
secret store with per-principal, per-name authorization.

Three options were on the table:

1. **Kubernetes Secrets + RBAC only.** No external backend. The boundary
   becomes namespace RBAC, which is exactly the "soft, mutable YAML" ADR-0001
   rejected — and the tenant contract would differ from the other four clouds.
2. **A shared credential to some external store**, distributed to tenants
   through one `ClusterSecretStore`. This is the superset-credential design
   ADR-0001 rejected for the public clouds; it is no better here.
3. **HashiCorp Vault**, one role per tenant — with a second decision inside
   it, and the one that actually matters: *how* Vault establishes that a
   login comes from a given tenant's ServiceAccount.

   - Vault's **Kubernetes auth method** answers it by calling the cluster's
     TokenReview API. That requires Vault to hold a long-lived
     `system:auth-delegator` ServiceAccount token and to have a network path
     into the cluster.
   - Vault's **JWT auth method** answers it by verifying the token's
     signature against the cluster's published public keys and matching its
     `iss`, `aud` and `sub` claims. Nothing is stored and nothing is called
     back.

   The second is what the public clouds do. `AssumeRoleWithWebIdentity` does
   not ask a cluster whether a token is still valid: the Kubernetes API server
   is an OIDC provider, AKS/EKS/GKE/OKE merely *host* its discovery document
   and register it as a trusted issuer, and the exchange is signature
   verification plus three string comparisons.

## Decision

Add `nutanix` as a fifth cloud: an **NKP workload cluster + a HashiCorp Vault
KV v2 mount**, with **Vault as the identity plane**.

- The cluster is registered with Vault as an **OIDC identity provider**: one
  `vault_jwt_auth_backend` per cluster, bound to that cluster's issuer
  (`bound_issuer`) and pointed at its published JWKS. The foundation binds the
  built-in `system:service-account-issuer-discovery` ClusterRole to
  `system:unauthenticated` so those endpoints are readable — the same
  exposure, on a far smaller scale, that every managed cloud makes on the
  public internet.
- Each tenant gets a `vault_jwt_auth_backend_role` with
  `bound_subject = "system:serviceaccount:<tenant ns>:<sa>"`,
  `bound_audiences = ["vault"]` and `user_claim = "sub"`, plus a
  `vault_policy` granting `read` on `<mount>/data/<tenant>-*` and
  `<mount>/metadata/<tenant>-*` — and nothing else. No `list`, no writes, no
  other prefix. That `bound_subject` is character-for-character the string an
  IRSA trust policy or an Entra federated identity credential pins.
- The tenant's ESO `SecretStore` stays namespaced and authenticates with a
  ten-minute token minted for the tenant's own ServiceAccount
  (`auth.jwt.kubernetesServiceAccountToken`), exactly as on the other four
  clouds.
- NKP owns cluster lifecycle. Terraform attaches to the cluster by reading the
  Cluster API `<cluster>-kubeconfig` Secret from the management cluster, and
  can optionally apply NKP-CLI-generated manifests to create it.

## Rationale

**This is the same mechanism, not an analogue of it.** A projected
ServiceAccount token, minted for a named audience, presented to a relying
party that verifies the cluster's signature and pins `sub` — that sentence
describes IRSA, Azure federated identity credentials, GKE Workload Identity
and this, in the same words. Only the party issuing the resulting credential
differs. So the tenant contract, the module shape and the `SecretStore` stay
identical, and the tenant-facing documentation needs no private-cloud dialect.

**No credential exists in either direction.** Vault holds nothing for the
cluster and has no permission in it; the cluster holds nothing for Vault. This
is the concrete reason JWT auth was chosen over Kubernetes auth: the latter
would have added a long-lived `system:auth-delegator` token in Terraform state
and a Vault→cluster network dependency, neither of which has any counterpart on
the four public clouds.

**The boundary stays out of Kubernetes.** Vault decides what a token may read.
A compromise of the cluster's RBAC does not widen a tenant's secret access, and
denials land in Vault's audit log with the tenant's role as principal — the
private cloud's version of "per-tenant audit trails for free".

**Path prefixes are the same rule as everywhere else.** Vault permits a
wildcard only as a path's last character, which *is* a prefix match — the same
thing Key Vault ABAC's `StringStartsWith`, an ARN prefix, an IAM
`resource.name.startsWith` and OCI's `target.secret.name = /<tenant>-*/`
express. The tenant contract "you own `<prefix>*`" is unchanged.

**NKP Starter is what a Nutanix licence already includes**, so the private
cloud costs a cluster, not a product decision. Its CNI is Cilium, which is what
the platform's NetworkPolicy-based ingress isolation needs — the same data
plane four of the five clouds now run.

**Why not run Vault inside the cluster and call it done?** It can be, and this
foundation does not care where Vault runs. What it does care about is that
Vault is *not* the cluster's own API server: the plane that authorizes secret
reads has to be able to say no to someone who controls Kubernetes RBAC.

## Consequences

- **The platform now operates an identity provider.** Vault is a component
  someone has to unseal, back up and upgrade; the other four backends are
  managed services. A Vault outage stops secret refreshes on this cloud.
  Vault 1.21+ is required, because that is where a role without an audience
  stops authenticating.
- **One long-lived credential exists that the public clouds have no equivalent
  of**: the NKP management-cluster token the stacks use to fetch the workload
  cluster's kubeconfig. It ends up in state files in the Azure state home,
  whose RBAC is what protects it — the same position the `gitops` spoke tokens
  are already in, and nothing rotates it. The identity plane itself adds none.
- **Revocation is by expiry, not by callback.** Vault verifies a signature
  rather than asking the cluster whether a token is still valid, so deleting a
  ServiceAccount does not invalidate a token already minted for it; it lapses
  in ten minutes. This is exactly the trade IRSA and Azure/GCP workload
  identity make. Cutting access immediately means deleting the Vault role.
- **The cluster's OIDC discovery endpoints are readable unauthenticated.**
  They expose an issuer URL and public keys — the same two things the managed
  clouds publish to the internet — and `publish_issuer_discovery = false` plus
  `cluster_issuer`/`cluster_jwks_url` covers a cluster where that is not
  acceptable or not possible.
- **The workload cluster's kubeconfig is cluster-admin** and is read by three
  stacks. A narrower per-stack ServiceAccount would be better and would have to
  be created out of band, which is a credential the platform does not otherwise
  hand out.
- **KV v2 secrets are maps, not opaque values**, so a tenant `ExternalSecret`
  on this cloud names a `property` where the others do not. The `hello` chart
  contains that difference in one helper, next to the one that already handles
  Secrets Manager's path-shaped names.
- **`dataFrom.find` does not work here**, because no `list` capability is
  granted — the same functional limit, for the same reason, as OCI.
- **Nothing in this cloud is reachable from a hosted CI runner.** The
  foundation job and the all-clouds tenants/gitops jobs need a self-hosted
  runner inside the private network (`NUTANIX_RUNNER` / `ONEK8S_RUNNER`), and
  so does the certificate distribution run.
- **Cluster lifecycle is NKP's, not Terraform's**, unless
  `cluster_manifests_dir` is pointed at NKP-CLI-generated manifests. Those
  manifests carry the Prism Central credential Secret and are therefore
  git-ignored, so that path is a local one.
