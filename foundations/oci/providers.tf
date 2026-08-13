# Authentication: the OCI provider reads OCI_TENANCY_OCID, OCI_USER_OCID,
# OCI_FINGERPRINT, OCI_PRIVATE_KEY and OCI_REGION straight from the
# environment, so GitHub Actions only has to export those from repository
# secrets; locally the ~/.oci/config profile is picked up instead.
#
# This stack creates no IAM resources, so it needs only the regional provider.
# It still publishes `home_region` as an output, because the tenants stack
# writes per-tenant policies and IAM can only be written in the tenancy's home
# region.
provider "oci" {
  region = var.region
}

provider "helm" {
  kubernetes = {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca_certificate
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args = [
        "ce", "cluster", "generate-token",
        "--cluster-id", oci_containerengine_cluster.this.id,
        "--region", var.region,
      ]
    }
  }
}
