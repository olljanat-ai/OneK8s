environment      = "prototype"
region           = "eu-stockholm-1"
home_region      = "eu-stockholm-1"
tenancy_ocid     = "ocid1.tenancy.oc1..aaaaaaaaaw4bqifybm3pzjeejetacxp6zcuuvbjmw6fykjmishivazmq432q"
compartment_ocid = "ocid1.compartment.oc1..aaaaaaaabxudy3kjrfrxqwu7x5yusaoha2ltfcplhd2ofiela4p2qqbd3pwq"
name_prefix      = "onek8s"
node_shape       = "VM.Standard.E2.1"
node_ocpus       = 1
node_memory_gbs  = 8
node_count       = 1

# Grafana Cloud. The endpoints are on the stack's "Details" page and cannot be
# derived from the stack name, so they are configuration; the credentials are
# not, and reach the cluster from this cloud's secret backend — run the
# Publish Grafana Cloud Credentials workflow once before enabling this.
# See docs/monitoring.md.
#
# enable_monitoring         = true
# grafana_cloud_metrics_url = "https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push"
# grafana_cloud_logs_url    = "https://logs-prod-012.grafana.net/loki/api/v1/push"
# grafana_cloud_traces_url  = "https://tempo-prod-01-prod-eu-west-0.grafana.net:443"
