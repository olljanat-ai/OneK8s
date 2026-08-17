environment         = "prototype"
project_id          = "southern-camera-456007-d9"
region              = "europe-north1"
zone                = "europe-north1-c"
name_prefix         = "onek8s"
node_machine_type   = "e2-medium"
node_count_per_zone = 1
deletion_protection = false

# Grafana Cloud. The endpoints are on the stack's "Details" page and cannot be
# derived from the stack name, so they are configuration; the credentials are
# not, and reach the cluster from this cloud's secret backend — run the
# Publish Grafana Cloud Credentials workflow once before enabling this.
# See docs/observability.md.
#
# enable_observability         = true
# grafana_cloud_metrics_url = "https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push"
# grafana_cloud_logs_url    = "https://logs-prod-012.grafana.net/loki/api/v1/push"
# grafana_cloud_traces_url  = "https://tempo-prod-01-prod-eu-west-0.grafana.net:443"
