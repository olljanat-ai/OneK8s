environment         = "prototype"
region              = "eu-north-1"
name_prefix         = "onek8s"
node_instance_types = ["t3.medium"]
node_desired_size   = 1

# Grafana Cloud. This environment ships to the one stack every cloud writes
# to, so the endpoints and enable_observability = true are the defaults in
# variables.tf; the credentials are not configuration and reach the cluster
# from Secrets Manager — run the Publish Grafana Cloud Credentials workflow
# once before the first apply. See docs/observability.md.
#
# Override here to point this environment somewhere else, or to turn the
# collectors off:
#
# enable_observability      = false
# grafana_cloud_metrics_url = "https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push"
# grafana_cloud_logs_url    = "https://logs-prod-012.grafana.net/loki/api/v1/push"
# grafana_cloud_traces_url  = "https://tempo-prod-01-prod-eu-west-0.grafana.net:443"
