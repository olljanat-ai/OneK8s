# Authentication: the OCI provider reads OCI_TENANCY_OCID, OCI_USER_OCID,
# OCI_FINGERPRINT, OCI_PRIVATE_KEY and OCI_REGION straight from the
# environment, so GitHub Actions only has to export those from repository
# secrets; locally the ~/.oci/config profile is picked up instead.
#
# IAM is global but writable only in the tenancy's home region, so the one
# policy this stack owns — the platform ingress' read access to the wildcard
# certificate, see ingress.tf — goes through the `oci.home` alias. Everything
# else is regional. `home_region` is published as an output too, because the
# tenants stack writes per-tenant policies the same way.
provider "oci" {
  region = var.region
}

provider "oci" {
  alias  = "home"
  region = coalesce(var.home_region, var.region)
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
