# OKE cluster with:
#  - ENHANCED_CLUSTER: required for OKE Workload Identity, which is how
#    tenant pods authenticate to OCI Vault (see modules/tenant-namespace/oci)
#  - VCN-native pod networking: every pod gets a real VCN IP, so OCI security
#    lists and IAM see pods as first-class network principals
resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_ocid
  name               = "oke-${local.name}"
  kubernetes_version = var.kubernetes_version
  vcn_id             = oci_core_vcn.this.id
  type               = "ENHANCED_CLUSTER"
  freeform_tags      = local.tags

  endpoint_config {
    subnet_id            = oci_core_subnet.api.id
    is_public_ip_enabled = true
  }

  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.lb.id]

    kubernetes_network_config {
      services_cidr = var.services_cidr
    }

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }
  }
}

# OKE publishes one worker image per Kubernetes version; pick the newest
# x86_64 Oracle Linux 8 build matching the cluster version. Image names embed
# the version and a build date, so sorting by name yields the newest.
data "oci_containerengine_node_pool_option" "this" {
  node_pool_option_id = "all"
  compartment_id      = var.compartment_ocid
}

locals {
  version_pattern = replace(trimprefix(var.kubernetes_version, "v"), ".", "\\.")

  node_image_candidates = [
    for source in data.oci_containerengine_node_pool_option.this.sources : source
    if can(regex("Oracle-Linux-8\\.", source.source_name))
    && can(regex("OKE-${local.version_pattern}-", source.source_name))
    && !can(regex("aarch64|GPU", source.source_name))
  ]

  node_image_name = element(
    sort([for source in local.node_image_candidates : source.source_name]),
    length(local.node_image_candidates) - 1,
  )

  node_image_id = one([
    for source in local.node_image_candidates : source.image_id
    if source.source_name == local.node_image_name
  ])
}

resource "oci_containerengine_node_pool" "default" {
  cluster_id         = oci_containerengine_cluster.this.id
  compartment_id     = var.compartment_ocid
  name               = "default"
  kubernetes_version = var.kubernetes_version
  node_shape         = var.node_shape
  freeform_tags      = local.tags

  # Only flexible shapes take an OCPU/memory configuration; fixed shapes
  # (e.g. VM.Standard.E2.1) carry their own and the API rejects the block.
  dynamic "node_shape_config" {
    for_each = endswith(var.node_shape, ".Flex") ? [1] : []

    content {
      ocpus         = var.node_ocpus
      memory_in_gbs = var.node_memory_gbs
    }
  }

  node_source_details {
    source_type = "IMAGE"
    image_id    = local.node_image_id
  }

  node_config_details {
    size = var.node_count

    dynamic "placement_configs" {
      for_each = local.availability_domains
      content {
        availability_domain = placement_configs.value
        subnet_id           = oci_core_subnet.workers.id
      }
    }

    node_pool_pod_network_option_details {
      cni_type       = "OCI_VCN_IP_NATIVE"
      pod_subnet_ids = [oci_core_subnet.pods.id]
    }
  }
}

# The OKE API does not expose the cluster CA separately, so it is read out of
# the generated kubeconfig.
data "oci_containerengine_cluster_kube_config" "this" {
  cluster_id = oci_containerengine_cluster.this.id
}

locals {
  kube_config         = yamldecode(data.oci_containerengine_cluster_kube_config.this.content)
  kube_host           = local.kube_config["clusters"][0]["cluster"]["server"]
  kube_ca_certificate = base64decode(local.kube_config["clusters"][0]["cluster"]["certificate-authority-data"])
}
