# Monitoring: one Grafana Cloud stack, four clusters

Every foundation can install Grafana's [**k8s-monitoring**][chart] chart and
ship that cluster's telemetry to **Grafana Cloud**. It is one module
(`modules/platform-monitoring`) on all four clouds, so AKS, EKS, GKE and OKE
arrive in the same stack, under the same metric and label names, and differ
only in the value of their `cluster` label.

[chart]: https://github.com/grafana/k8s-monitoring-helm

```
                    ┌──────────────── Grafana Cloud stack ────────────────┐
                    │  hosted metrics   hosted logs   hosted traces       │
                    └───────▲───────────────▲──────────────▲──────────────┘
                            │               │              │
   cluster="onek8s-azure-prototype"  …-aws-…        …-gcp-… / …-oci-…
                            │               │              │
                    ┌───────┴───────┐ ┌─────┴─────┐  ┌──────┴──────┐
                    │ Alloy on AKS  │ │  on EKS   │  │ on GKE, OKE │
                    └───────────────┘ └───────────┘  └─────────────┘
```

It is off by default (`enable_monitoring = false`), because it needs two
things this repository cannot invent: a Grafana Cloud stack's endpoints, and
its credentials.

## What runs in the cluster

The chart deploys [Grafana Alloy][alloy] through the Alloy Operator, one
instance per job. A collector exists only while a feature needs it, so a
cluster with pod logs turned off runs no log DaemonSet at all:

[alloy]: https://grafana.com/docs/alloy/latest/

| Collector | Shape | Created for |
|---|---|---|
| `alloy-metrics` | clustered StatefulSet | cluster metrics, host metrics, annotation autodiscovery |
| `alloy-logs` | DaemonSet reading `/var/log` | pod logs, node logs |
| `alloy-singleton` | one replica | cluster events |
| `alloy-receiver` | Deployment, OTLP on 4317/4318 | application observability |

`kube-state-metrics` and Node Exporter come with the features that scrape
them. Nothing else is added: there is no in-cluster Prometheus, no Grafana and
no storage — the cluster collects and forwards, and Grafana Cloud keeps.

What each foundation turns on by default:

| Feature | Default | Variable |
|---|---|---|
| Cluster metrics (control plane, kubelets, kube-state-metrics) | on | — |
| Host metrics (Node Exporter) | on | — |
| Annotation autodiscovery (`prometheus.io/scrape`) | on | — |
| Cluster events → logs | on | — |
| Pod logs | on | `monitoring_enable_pod_logs` |
| Node (journald) logs | off | — |
| Application observability (OTLP receiver) | off | — |

Pod logs are the one worth a decision: on a chatty cluster they are the
largest single line on the bill, and turning them off leaves metrics and
events untouched. The rest are module-level inputs
(`modules/platform-monitoring/variables.tf`) that the foundations do not
surface, on the grounds that a platform whose clusters report different things
is worse than one that reports too much.

Annotation autodiscovery is what makes this useful to a tenant: a Pod or
Service carrying `prometheus.io/scrape: "true"` is scraped and its metrics land
in the same stack, with no platform change and nothing for the tenant to
deploy.

## Destinations

Grafana Cloud's native endpoints, one per signal, rather than a single OTLP
gateway. Hosted metrics and hosted logs are what the Kubernetes app in Grafana
Cloud is built on, and sending Prometheus data straight to Prometheus avoids a
round trip through the OpenTelemetry data model:

| Destination | Type | Set from |
|---|---|---|
| `grafana-cloud-metrics` | `prometheus` (remote write) | `grafana_cloud_metrics_url` |
| `grafana-cloud-logs` | `loki` | `grafana_cloud_logs_url` |
| `grafana-cloud-traces` | `otlp`, traces only | `grafana_cloud_traces_url` (optional) |

The URLs are on the stack's **Details** page in Grafana Cloud. They are not
derivable from the stack's name — every stack is assigned its own cluster of
hosted endpoints — so they are configuration, per environment, in
`foundations/<cloud>/envs/<env>.tfvars`:

```hcl
enable_monitoring         = true
grafana_cloud_metrics_url = "https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push"
grafana_cloud_logs_url    = "https://logs-prod-012.grafana.net/loki/api/v1/push"
grafana_cloud_traces_url  = "https://tempo-prod-01-prod-eu-west-0.grafana.net:443"   # optional
```

Leaving `grafana_cloud_traces_url` null defines no traces destination at all.
The traces destination is deliberately restricted to traces: metrics and logs
already have a destination each, and an OTLP destination that accepted them
would be chosen as a second home for the same data.

## Credentials: the certificate's road, a different payload

The token is **not** a Terraform variable. It travels the way the wildcard
certificate does — one Key Vault as the source of truth, one workflow run to
publish it, each cluster reading the copy in the backend it already reads its
tenant secrets from:

```
Publish Grafana Cloud Credentials
        │
        ▼
   Key Vault  platform-grafana-cloud          (source of truth)
        │
        ├──▶ Secrets Manager  <env>/platform/grafana-cloud     (AWS)
        ├──▶ Secret Manager   platform-grafana-cloud           (GCP)
        └──▶ OCI Vault        platform-grafana-cloud           (OCI)
                    │
                    ▼  ESO SecretStore + ExternalSecret, per cluster
             Secret monitoring/grafana-cloud-credentials
                    │
                    ▼  Alloy remote.kubernetes.secret
             every destination's basic auth
```

Two consequences are the point of doing it this way. The token never enters a
state file — Terraform only says which backend object to read and which
Kubernetes Secret it lands in. And Alloy *polls* that Secret rather than
reading it once at startup, so **a rotated token reaches the collectors without
an apply and without restarting them**: publish, wait for the hourly External
Secrets refresh, then revoke the old one.

The object is a single JSON value, because one access-policy token
authenticates every signal and only the instance ID differs between them:

```json
{
  "token": "glc_eyJvIjoi…",
  "metrics-username": "1234567",
  "logs-username": "7654321",
  "traces-username": "1122334"
}
```

### Who may read it

`platform-` is the platform's reserved prefix, which no tenant may claim. The
identities that read this object are narrower than that prefix: each cluster
gets a **monitoring** identity, separate from the ingress' one, pinned to the
`monitoring` namespace's own ServiceAccount and granted this one secret:

| Cloud | Identity | Narrowed by |
|---|---|---|
| Azure | UAMI + federated credential | Key Vault ABAC on `@Resource[…secrets:name] StringEquals 'platform-grafana-cloud'` |
| AWS | IAM role via IRSA | the secret's own ARN, plus `kms:ViaService` on the foundation CMK |
| GCP | GSA + Workload Identity | an IAM condition on the secret's resource name |
| OCI | OKE Workload Identity (no identity object) | a policy condition on `target.secret.name` |

So the monitoring identity cannot read the wildcard certificate's private key,
which shares the `platform-` prefix, and the ingress identity cannot read the
Grafana Cloud token. Neither can read any tenant's secrets, and no tenant can
read either of them.

## Setting it up

### 1. Create the access policy in Grafana Cloud

In the Grafana Cloud portal, create an **access policy** scoped to the stack
with the write scopes the signals you enable need — `metrics:write`,
`logs:write`, and `traces:write` if you configure traces — then create a token
for it. The token starts with `glc_`; a personal API key does not and will
authenticate nothing.

Note the **instance ID** of each hosted service from the stack's Details page.
They are the usernames, and they are not secret.

### 2. Publish the credentials

Store the token as the repository secret `GRAFANA_CLOUD_TOKEN`, and — so a
re-run needs no typing — the instance IDs as the repository variables
`GRAFANA_CLOUD_METRICS_USERNAME`, `GRAFANA_CLOUD_LOGS_USERNAME` and
(optionally) `GRAFANA_CLOUD_TRACES_USERNAME`. Then:

```
Actions -> Publish Grafana Cloud Credentials -> Run workflow
  environment      prototype
  metrics_username        (blank = the repository variable)
  logs_username           (blank = the repository variable)
  traces_username         (blank = the repository variable; leave empty for no traces)
  secret_name      platform-grafana-cloud
```

The run writes Key Vault first — it is the source of truth, and a run that
cannot write it has nothing to distribute — then pushes to the other three.
Each cloud's target is read out of its foundation state, so a cloud with no
foundation in this environment is reported as skipped rather than failing the
run, and the three pushes are independent: one cloud refusing the write leaves
the other two current and fails the run at the end. The summary lists every
target and its result.

The job binds to the `azure-<environment>` GitHub environment, like the
certificate workflow, because the Key Vault it writes is the privileged input.
The AWS/GCP/OCI writes use the repository-level credentials — see
[architecture.md](architecture.md), "Known trade-offs".

### 3. Enable it on the clusters

Set the three (or two) variables above in each cloud's
`envs/<env>.tfvars` and apply the foundation:

```bash
cd foundations/azure
terraform apply -var-file=envs/prototype.tfvars
```

Order does not actually matter. A cluster applied before the credentials exist
leaves the `ExternalSecret` unresolved and the collectors retrying their remote
writes; the apply still succeeds, and the cluster starts reporting on its own
within the hour of the publication.

### 4. Check it

```bash
kubectl -n monitoring get externalsecret grafana-cloud
kubectl -n monitoring get alloy                      # one per collector
kubectl -n monitoring logs -l app.kubernetes.io/part-of=alloy --tail=50
```

In Grafana Cloud, the clusters appear in the Kubernetes app as
`onek8s-<cloud>-<environment>`. A quick check from Explore:

```promql
count by (cluster) (up)
```

Four clusters, one query — which is the whole premise of the platform applied
to observability.

## Naming and the cluster label

`cluster` is the only thing separating four clusters inside one stack, so it
carries both the cloud and the environment:
`<name_prefix>-<cloud>-<environment>` — `onek8s-azure-prototype`,
`onek8s-aws-prototype`, and so on. It is derived, not configured: two clusters
sharing the label would interleave their series, and nothing would notice.

Every environment can therefore share one Grafana Cloud stack, or have one of
its own — the label keeps them apart either way, and the endpoints are per
environment already.

## Trade-offs

- **The credentials exist in four backends**, so a rotation is only complete
  once every copy is refreshed — which is one workflow run, but nothing
  reconciles them and a cluster reading a stale copy will not notice until the
  old token is revoked. It is the same trade the wildcard certificate makes,
  for the same reason: a cluster reaching into Azure for a credential would be
  the first cross-cloud dependency on a platform that has none.
- **One job touches every cloud**, and GitHub can bind it to only one
  environment. It uses `azure-<env>` — the environment guarding the vault that
  is the source of truth — so `aws-prod`'s protection rules do not apply to it.
- **Publication is manual.** Nothing rotates the token on a schedule, and
  nothing notices when it expires: the first symptom is remote writes failing
  on four clusters at once. Give the access policy an expiry you will remember,
  or none.
- **The collectors are a real workload on a one-node prototype.** Three Alloy
  instances plus kube-state-metrics and Node Exporter request roughly a third
  of a `Standard_B2s` / `t3.medium` between them at the `small` preset. Raise
  `monitoring_collector_preset` for real clusters, and consider
  `monitoring_enable_pod_logs = false` on the small ones.
- **Node Exporter wants host mounts**, which the AKS pod security baseline
  initiative flags. That initiative is assigned in *audit* mode
  (`foundations/azure/policy.tf`), so the DaemonSet runs and is recorded as
  non-compliant; an environment that flips the initiative to `deny` needs an
  exemption for the `monitoring` namespace or has to do without host metrics.
- **The chart's own external-secret path is not used.** Setting
  `secret.create = false` makes it emit references to every *optional*
  credential a destination supports — tenant ID, client certificate and its
  key, CA — which would oblige the Secret to carry four empty keys it has no
  use for. The module declares the `remote.kubernetes.secret` component itself
  and points the destinations at it through their `...From` fields instead, so
  the Secret holds exactly the keys that exist. The cost is that the module
  knows one Alloy component name.
- **Telemetry is not restricted per tenant.** Every namespace's pod logs and
  every annotated Service's metrics go to one stack, and Grafana Cloud access
  is granted there, not here — so the hard tenant isolation the secret backends
  have has no counterpart in the observability plane. Splitting it would mean a
  stack (or at least a policy) per tenant, and a collector that knows which is
  which.
