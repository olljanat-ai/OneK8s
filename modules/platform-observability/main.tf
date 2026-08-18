# Grafana's k8s-monitoring chart as the platform's observability agent,
# installed identically on every cloud. It deploys Grafana Alloy collectors
# through the Alloy Operator and ships metrics, logs and (optionally) traces to
# a Grafana Cloud stack — one stack for all four clusters, told apart by the
# "cluster" label this module sets from var.cluster_name.
#
# Everything that differs between clouds is an input, and there are two things.
# The first is how the Grafana Cloud credentials get into the cluster: they
# arrive the same way the ingress' certificate does — an ESO SecretStore +
# ExternalSecret over the cloud's own identity, passed in as var.extra_objects.
# The second is var.azure_aks, which annotates the Pods that talk to the API
# server the way AKS wants them annotated. Off Azure it changes nothing, so the
# collectors are configured identically on EKS, GKE and OKE.
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
    var.enable_traces ? {
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
    } : {},
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

  # --- Azure AKS -------------------------------------------------------------
  # The one place a cloud shows through in the collectors themselves. AKS' own
  # admission webhook reads this annotation and points KUBERNETES_SERVICE_HOST
  # at the API server's FQDN instead of the in-cluster kubernetes.default
  # ClusterIP, which keeps a Pod's API traffic off kube-proxy and the tunnel
  # behind it. Grafana's chart treats it as mandatory rather than advisory: its
  # validations detect AKS from the nodes' own labels and refuse to render
  # until every Pod that talks to the API server carries it, which is what an
  # Azure apply hits as "execution error at validations.yaml".
  #
  # Empty off Azure, and an empty podAnnotations map is what those fields
  # default to anyway, so the values below are the same on the other clouds.
  aks_pod_annotations = var.azure_aks ? {
    "kubernetes.azure.com/set-kube-service-host-fqdn" = "true"
  } : {}

  values = merge({
    cluster = {
      name = var.cluster_name
    }

    # Applied to every Alloy instance, so the AKS annotation is stated once
    # here rather than repeated in each entry of local.collectors.
    collectorCommon = {
      alloy = {
        controller = {
          podAnnotations = local.aks_pod_annotations
        }
      }
    }

    "alloy-operator" = {
      podAnnotations = local.aks_pod_annotations

      # The post-install and pre-delete hook Jobs that add and remove the
      # operator's finalizer. They run kubectl, so they are API server clients
      # like everything else here.
      waitForAlloyRemoval = {
        podAnnotations = local.aks_pod_annotations
      }
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
        deploy         = var.enable_cluster_metrics
        podAnnotations = local.aks_pod_annotations
      }
      # No annotation: Node Exporter reads /proc and /sys and never speaks to
      # the API server.
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

resource "helm_release" "k8s_observability" {
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
        "platform-observability has every feature disabled, so it would install collectors with nothing to collect.",
        "Enable at least one of enable_cluster_metrics, enable_host_metrics, enable_annotation_autodiscovery,",
        "enable_cluster_events, enable_pod_logs, enable_node_logs or enable_application_observability —",
        "or turn the whole module off with the foundation's enable_observability.",
      ])
    }
  }
}
