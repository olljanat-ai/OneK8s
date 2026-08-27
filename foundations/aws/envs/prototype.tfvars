environment         = "prototype"
region              = "eu-north-1"
name_prefix         = "onek8s"
node_instance_types = ["t3.medium"]
node_desired_size   = 1

# Grafana Cloud. This environment ships to the one stack every cloud writes to,
# whose endpoints are the defaults in modules/platform-observability, and
# enable_observability defaults to true — so there is nothing to set here. The
# credentials are not configuration and reach the cluster from Secrets Manager:
# run the Publish Grafana Cloud Credentials workflow once before the first
# apply. See docs/observability.md.
#
# Uncomment to turn the collectors off, or to point this environment at a
# different stack:
#
# enable_observability      = false
# grafana_cloud_metrics_url = "https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push"
# grafana_cloud_logs_url    = "https://logs-prod-012.grafana.net/loki/api/v1/push"
# grafana_cloud_traces_url  = "https://tempo-prod-01-prod-eu-west-0.grafana.net:443"

# Flux: this cluster's own delivery plane, beside the Argo CD hub that reaches
# it from AKS. Nothing is registered between the two clusters on this plane —
# each reads OneK8s-fluxcd for itself, from clusters/aws and clusters/azure —
# which is the arrangement being compared against hub-and-spoke.
#
#   aws-hello.onek8s.lol    Argo CD + Kargo, team-alpha, promoted from staging
#   aws-hello2.onek8s.lol   Flux,            team-beta,  committed here
#
# team-beta already exists on this cluster (tenants/envs/prototype.tfvars), and
# its test secret is written into Secrets Manager as
# "prototype/team-beta/test" by the Renew Certificate workflow run with tenant:
# team-beta. The A record for aws-hello2 is pointed at the ingress by hand,
# like every other host. See docs/fluxcd.md.
enable_fluxcd = true
fluxcd_tenant = "team-beta"
