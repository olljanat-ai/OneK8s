# platform-monitoring module

Installs Grafana's [**k8s-monitoring**][chart] chart on one cluster and points
it at a **Grafana Cloud** stack. It is the same module on all four clouds —
AKS, EKS, GKE and OKE — so one Grafana Cloud stack sees four clusters that
differ only by the value of their `cluster` label.

[chart]: https://github.com/grafana/k8s-monitoring-helm

```hcl
module "monitoring" {
  source = "../../modules/platform-monitoring"
  count  = var.enable_monitoring ? 1 : 0

  cluster_name = "onek8s-azure-prototype"
  metrics_url  = var.grafana_cloud_metrics_url
  logs_url     = var.grafana_cloud_logs_url

  extra_objects = [/* ServiceAccount + SecretStore + ExternalSecret */]
}
```

## What it deploys

The chart runs [Grafana Alloy][alloy] through the Alloy Operator, one instance
per job. Each collector exists only while a feature needs it, so a cluster
runs no DaemonSet it has no logs to read:

[alloy]: https://grafana.com/docs/alloy/latest/

| Collector | Shape | Enabled by |
|---|---|---|
| `alloy-metrics` | clustered StatefulSet | `enable_cluster_metrics`, `enable_host_metrics`, `enable_annotation_autodiscovery` |
| `alloy-logs` | DaemonSet, reads `/var/log` | `enable_pod_logs`, `enable_node_logs` |
| `alloy-singleton` | one replica | `enable_cluster_events` |
| `alloy-receiver` | Deployment, OTLP on 4317/4318 | `enable_application_observability` |

`kube-state-metrics` and Node Exporter are deployed with the features that
scrape them (`telemetryServices`), because no foundation runs a Prometheus
stack of its own.

## Destinations

Grafana Cloud's native endpoints, one per signal, rather than a single OTLP
gateway: hosted metrics and hosted logs are what the Kubernetes app in Grafana
Cloud is built on, and sending Prometheus data straight to Prometheus avoids a
round trip through the OpenTelemetry data model.

| Destination | Type | Input | Signal |
|---|---|---|---|
| `grafana-cloud-metrics` | `prometheus` | `metrics_url` | metrics |
| `grafana-cloud-logs` | `loki` | `logs_url` | logs and events |
| `grafana-cloud-traces` | `otlp` | `traces_url` (optional) | traces only |

The traces destination is defined only when `traces_url` is set, and it is
restricted to traces: metrics and logs already have a destination each, and an
OTLP destination that accepted them would be chosen as a second home for the
same data.

## Credentials

The module does **not** fetch the credentials; it only says which Kubernetes
Secret they will be in. Filling that Secret is the caller's job and is the one
genuinely cloud-shaped part, so it is passed in as `extra_objects` — exactly
the arrangement `modules/platform-ingress` uses for the wildcard certificate:
a platform `ServiceAccount`, a namespaced ESO `SecretStore` bound to it, and an
`ExternalSecret` extracting the backend's `platform-grafana-cloud` object.

One Grafana Cloud access-policy token authenticates every signal; what differs
per signal is the instance ID, so the Secret holds one token and one ID each:

```
token             glc_eyJvIjoi…
metrics-username  1234567
logs-username     7654321
traces-username   1122334
```

The collectors read it through Alloy's `remote.kubernetes.secret`, which polls
the Secret, so **a rotated token reaches the collectors without restarting
them** — the same property the platform's certificate distribution has.

The component is declared by this module rather than left to the chart's own
`secret.create = false` path. That path also emits references to every
*optional* credential the destination type supports — tenant ID, client
certificate and its key, CA — which would oblige the Secret to carry four empty
keys it has no use for. Referencing the component explicitly through the
destinations' `...From` fields asks for exactly the three keys that exist.

## Notes

- `extra_objects` is rendered through the chart's `extraObjects`, which passes
  each manifest through Go templating. Nothing the foundations pass uses
  template syntax, but a caller that adds `{{ … }}` should expect it to be
  evaluated.
- ESO objects in `extra_objects` need the External Secrets CRDs to exist when
  the release is applied. Callers order that with `depends_on` on the ESO
  release rather than by using `kubernetes_manifest`, which would need the CRDs
  at *plan* time — before the foundation has ever been applied.
- A backend that has no `platform-grafana-cloud` object yet leaves the
  `ExternalSecret` unresolved and the collectors retrying their remote writes.
  The apply still succeeds, so a new environment can be built before the
  credentials exist and picks them up on its own afterwards.
- `cluster_name` is the only thing separating four clusters inside one Grafana
  Cloud stack. Two clusters sharing it interleave their series, so it carries
  both the cloud and the environment.
- `collector_preset` sizes every collector at once (`small` … `xlarge`). Reach
  for `extra_values` for anything finer; top-level keys there replace the ones
  built here outright, so a partial `clusterMetrics = { … }` drops the
  `collector` assignment with it.
