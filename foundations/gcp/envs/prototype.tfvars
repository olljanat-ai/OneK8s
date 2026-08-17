environment         = "prototype"
project_id          = "southern-camera-456007-d9"
region              = "europe-north1"
zone                = "europe-north1-c"
name_prefix         = "onek8s"
node_machine_type   = "e2-medium"
node_count_per_zone = 1
deletion_protection = false

# Grafana Cloud. Off on this cloud in this lab. Turning it on needs nothing but
# the switch: the stack's endpoints are the defaults in
# modules/platform-observability, the same ones Azure and AWS write to. The
# credentials are not configuration and reach the cluster from this cloud's
# secret backend — run the Publish Grafana Cloud Credentials workflow once
# before the first apply. See docs/observability.md.
#
# enable_observability = true
#
# Only a cluster that has to write to a different stack sets these:
#
# grafana_cloud_metrics_url = "https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push"
# grafana_cloud_logs_url    = "https://logs-prod-012.grafana.net/loki/api/v1/push"
# grafana_cloud_traces_url  = "https://tempo-prod-01-prod-eu-west-0.grafana.net:443"
