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
