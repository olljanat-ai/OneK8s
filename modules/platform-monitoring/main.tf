# Grafana's k8s-monitoring chart as the platform's observability agent,
# installed identically on every cloud. It deploys Grafana Alloy collectors
# through the Alloy Operator and ships metrics, logs and (optionally) traces to
# a Grafana Cloud stack — one stack for all four clusters, told apart by the
# "cluster" label this module sets from var.cluster_name.
#
# Everything that differs between clouds is an input, and there is only one
# thing: how the Grafana Cloud credentials get into the cluster. They arrive
# the same way the ingress' certificate does — an ESO SecretStore +
# ExternalSecret over the cloud's own identity, passed in as var.extra_objects —
# so the collectors themselves are configured identically on AKS, EKS, GKE and
# OKE.
#
#   <cloud> secret backend  platform-grafana-cloud
#     --(SecretStore + ExternalSecret, workload identity)-->
#       Secret grafana-cloud-credentials
#         --(Alloy remote.kubernetes.secret)--> every destination's basic auth
locals {
  # Alloy component labels are identifiers, so the name is snake_case where
  # everything else here is kebab-case.
  credentials_component_name = "grafana_cloud"

  # The one Alloy component that reads the credentials Secret. It is declared
  # per collector below rather than left to the chart: the chart's own
  # `secret.create = false` path also emits references to every *optional*
  # credential it supports (tenant ID, client certificate, CA), which would
  # oblige the Secret to carry empty keys it has no use for. Referencing the
  # component explicitly through the destinations' `...From` fields asks for
  # exactly the three keys that exist.
  credentials_component = <<-EOT
    remote.kubernetes.secret "${local.credentials_component_name}" {
      name      = "${var.credentials_secret_name}"
      namespace = "${var.namespace}"
    }
  EOT

  # data[] is a map of Alloy secrets. A password takes one as it is; a
  # username is an ordinary string argument, so it has to be declassified
  # first — the instance IDs are not confidential anyway.
  token_ref = "remote.kubernetes.secret.${local.credentials_component_name}.data[\"${var.credentials_token_key}\"]"

  metrics_username_ref = "convert.nonsensitive(remote.kubernetes.secret.${local.credentials_component_name}.data[\"${var.metrics_username_key}\"])"
  logs_username_ref    = "convert.nonsensitive(remote.kubernetes.secret.${local.credentials_component_name}.data[\"${var.logs_username_key}\"])"
  traces_username_ref  = "convert.nonsensitive(remote.kubernetes.secret.${local.credentials_component_name}.data[\"${var.traces_username_key}\"])"

  # --- Destinations ----------------------------------------------------------
  # Grafana Cloud's native endpoints rather than one OTLP gateway: the hosted
  # metrics and logs endpoints are what the Kubernetes app in Grafana Cloud
  # expects, and going through them keeps Prometheus data in the Prometheus
  # ecosystem instead of round-tripping it through OpenTelemetry.
  destinations = merge(
    {
      grafana-cloud-metrics = {
        type = "prometheus"
        url  = var.metrics_url
        auth = {
          type         = "basic"
          usernameFrom = local.metrics_username_ref
          passwordFrom = local.token_ref
        }
      }

      grafana-cloud-logs = {
        type = "loki"
        url  = var.logs_url
        auth = {
          type         = "basic"
          usernameFrom = local.logs_username_ref
          passwordFrom = local.token_ref
        }
      }
    },
    var.traces_url == null ? {} : {
      grafana-cloud-traces = {
        type     = "otlp"
        url      = var.traces_url
        protocol = var.traces_protocol
        # Traces only. Metrics and logs already have a destination each, and an
        # OTLP destination that accepted them too would be picked as a second
        # home for the same data.
        metrics = { enabled = false }
        logs    = { enabled = false }
        traces  = { enabled = true }
        auth = {
          type         = "basic"
          usernameFrom = local.traces_username_ref
          passwordFrom = local.token_ref
        }
      }
    },
  )

  # --- Collectors ------------------------------------------------------------
  # Each Alloy instance exists only when a feature needs it: the chart refuses
  # to render a collector nothing is assigned to, which is what keeps a
  # metrics-only cluster from running a log DaemonSet.
  metrics_collector_name   = "alloy-metrics"
  logs_collector_name      = "alloy-logs"
  singleton_collector_name = "alloy-singleton"
  receiver_collector_name  = "alloy-receiver"

  needs_metrics_collector   = var.enable_cluster_metrics || var.enable_host_metrics || var.enable_annotation_autodiscovery
  needs_logs_collector      = var.enable_pod_logs || var.enable_node_logs
  needs_singleton_collector = var.enable_cluster_events
  needs_receiver_collector  = var.enable_application_observability

  collectors = merge(
    local.needs_metrics_collector ? {
      # Clustered on a StatefulSet so scrape targets can be spread over more
      # replicas later without the configuration changing shape; at one
      # replica it behaves exactly like a Deployment.
      (local.metrics_collector_name) = {
        presets     = [var.collector_preset, "clustered", "statefulset"]
        extraConfig = local.credentials_component
      }
    } : {},

    local.needs_logs_collector ? {
      # A DaemonSet, because it reads each node's own container log files.
      (local.logs_collector_name) = {
        presets     = [var.collector_preset, "filesystem-log-reader", "daemonset"]
        extraConfig = local.credentials_component
      }
    } : {},

    local.needs_singleton_collector ? {
      # Exactly one replica: two watchers of the Kubernetes event stream would
      # ship every event twice.
      (local.singleton_collector_name) = {
        presets     = [var.collector_preset, "singleton"]
        extraConfig = local.credentials_component
      }
    } : {},

    local.needs_receiver_collector ? {
      (local.receiver_collector_name) = {
        presets     = [var.collector_preset, "deployment", "otel-receiver"]
        extraConfig = local.credentials_component
      }
    } : {},
  )

  values = merge({
    cluster = {
      name = var.cluster_name
    }

    destinations = local.destinations
    collectors   = local.collectors

    clusterMetrics = {
      enabled   = var.enable_cluster_metrics
      collector = local.metrics_collector_name
    }

    hostMetrics = {
      enabled   = var.enable_host_metrics
      collector = local.metrics_collector_name
      linuxHosts = {
        enabled = var.enable_host_metrics
      }
    }

    annotationAutodiscovery = {
      enabled   = var.enable_annotation_autodiscovery
      collector = local.metrics_collector_name
    }

    clusterEvents = {
      enabled   = var.enable_cluster_events
      collector = local.singleton_collector_name
    }

    podLogsViaLoki = {
      enabled   = var.enable_pod_logs
      collector = local.logs_collector_name
    }

    nodeLogs = {
      enabled   = var.enable_node_logs
      collector = local.logs_collector_name
    }

    applicationObservability = {
      enabled   = var.enable_application_observability
      collector = local.receiver_collector_name
      receivers = {
        otlp = {
          grpc = { enabled = var.enable_application_observability }
          http = { enabled = var.enable_application_observability }
        }
      }
    }

    # The workloads that produce what the features above scrape. They are
    # deployed here rather than assumed to exist, because no foundation runs a
    # Prometheus stack of its own.
    telemetryServices = {
      kube-state-metrics = {
        deploy = var.enable_cluster_metrics
      }
      node-exporter = {
        deploy = var.enable_host_metrics
      }
    }

    # Rendered as the chart's `extraObjects`, which runs each entry through Go
    # templating; nothing the callers pass contains template syntax, so the
    # manifests go through unchanged.
    extraObjects = var.extra_objects
  }, var.extra_values)
}

resource "helm_release" "k8s_monitoring" {
  name             = "k8s-monitoring"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "k8s-monitoring"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  values = [yamlencode(local.values)]

  # The Alloy Operator, its CRD and one Alloy object per collector all come up
  # in this release, and the release is not ready until the operator has
  # reconciled the last of them.
  timeout = var.timeout

  lifecycle {
    precondition {
      condition = local.needs_metrics_collector || local.needs_logs_collector || local.needs_singleton_collector || local.needs_receiver_collector
      error_message = join(" ", [
        "platform-monitoring has every feature disabled, so it would install collectors with nothing to collect.",
        "Enable at least one of enable_cluster_metrics, enable_host_metrics, enable_annotation_autodiscovery,",
        "enable_cluster_events, enable_pod_logs, enable_node_logs or enable_application_observability —",
        "or turn the whole module off with the foundation's enable_monitoring.",
      ])
    }
  }
}
