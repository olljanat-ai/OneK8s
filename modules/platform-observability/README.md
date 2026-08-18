# platform-observability module

Installs Grafana's [**k8s-monitoring**][chart] chart on one cluster and points
it at a **Grafana Cloud** stack. It is the same module on all four clouds —
AKS, EKS, GKE and OKE — so one Grafana Cloud stack sees four clusters that
differ only by the value of their `cluster` label.

[chart]: https://github.com/grafana/k8s-monitoring-helm

```hcl
module "observability" {
  source = "../../modules/platform-observability"
  count  = var.enable_observability ? 1 : 0

  cluster_name = "onek8s-azure-prototype"

  # Required on AKS and only on AKS — see "Azure AKS" below.
  azure_aks = true

  # Null — which is what a foundation passes when its tfvars set nothing —
  # takes this module's own endpoints, so all four clusters land in one stack.
  metrics_url = var.grafana_cloud_metrics_url
  logs_url    = var.grafana_cloud_logs_url

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

## Azure AKS

`azure_aks = true` is the one collector setting Azure does not share with the
other clouds, and it is **not optional there**: the chart detects AKS from the
nodes' own labels and refuses to render until every Pod that talks to the API
server carries the annotation, so an Azure apply without it fails at
`validations.yaml` rather than at install time.

The annotation is `kubernetes.azure.com/set-kube-service-host-fqdn`. AKS' own
admission webhook reads it and sets `KUBERNETES_SERVICE_HOST` to the API
server's FQDN instead of the in-cluster `kubernetes.default` ClusterIP, which
takes kube-proxy and the tunnel behind it out of the path. This module applies
it to everything the chart deploys that is an API server client:

| Object | Value |
|---|---|
| every Alloy collector | `collectorCommon.alloy.controller.podAnnotations` |
| the Alloy Operator | `alloy-operator.podAnnotations` |
| its finalizer hook Jobs | `alloy-operator.waitForAlloyRemoval.podAnnotations` |
| `kube-state-metrics` | `telemetryServices.kube-state-metrics.podAnnotations` |

Node Exporter is deliberately not in that list: it reads `/proc` and `/sys` and
never contacts the API server. Off Azure the flag stays `false`, the annotation
map is empty, and the rendered manifests are byte-identical to what the module
produced before the flag existed.

## Destinations

Grafana Cloud's native endpoints, one per signal, rather than a single OTLP
gateway: hosted metrics and hosted logs are what the Kubernetes app in Grafana
Cloud is built on, and sending Prometheus data straight to Prometheus avoids a
round trip through the OpenTelemetry data model.

| Destination | Type | Input | Signal |
|---|---|---|---|
| `grafana-cloud-metrics` | `prometheus` | `metrics_url` | metrics |
| `grafana-cloud-logs` | `loki` | `logs_url` | logs and events |
| `grafana-cloud-traces` | `otlp` | `traces_url`, `enable_traces` | traces only |

**The endpoints live here**, as the defaults of those three inputs, rather than
once per foundation. There is one stack behind all four clusters — the premise
`cluster_name` exists for — so repeating its URLs in `foundations/*/variables.tf`
made four copies of one platform-wide fact. A cluster that has to write
somewhere else still overrides them from its own tfvars, per signal; every
input is `nullable = false`, so a foundation variable left at `null` falls
back to the default here instead of passing the `null` through.

The traces destination is defined unless `enable_traces = false` — a stack
without a Tempo instance, say — and it is restricted to traces: metrics and
logs already have a destination each, and an OTLP destination that accepted
them would be chosen as a second home for the same data.

## Credentials

The module does **not** fetch the credentials; it only says which Kubernetes
Secret they will be in. Filling that Secret is the caller's job and is the other
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
- `azure_aks` is a fact about the cluster, not a preference: leave it `false`
  on EKS, GKE and OKE, where the annotation would be inert but misleading.
- `collector_preset` sizes every collector at once (`small` … `xlarge`). Reach
  for `extra_values` for anything finer; top-level keys there replace the ones
  built here outright, so a partial `clusterMetrics = { … }` drops the
  `collector` assignment with it.
