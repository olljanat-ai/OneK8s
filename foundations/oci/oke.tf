# OKE cluster with:
#  - ENHANCED_CLUSTER: required for OKE Workload Identity, which is how
#    tenant pods authenticate to OCI Vault (see modules/tenant-namespace/oci)
#  - VCN-native pod networking: every pod gets a real VCN IP, so OCI security
#    lists and IAM see pods as first-class network principals
resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_ocid
  name               = "oke-${local.name}"
  kubernetes_version = local.kubernetes_version
  vcn_id             = oci_core_vcn.this.id
  type               = "ENHANCED_CLUSTER"
  freeform_tags      = local.tags

  lifecycle {
    precondition {
      condition     = local.kubernetes_version != null
      error_message = "kubernetes_version \"${var.kubernetes_version}\" is not offered by OKE in this region. Available: ${join(", ", data.oci_containerengine_cluster_option.this.kubernetes_versions)}."
    }
  }

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

# OKE's cluster and node-pool APIs want an exact "vX.Y.Z", and worker image
# names embed that exact string — but only a few patch levels are offered at
# any time and they roll forward. So var.kubernetes_version may name just the
# minor ("v1.36") and is resolved here to the newest patch the region offers,
# which keeps the config from needing a bump every few weeks.
data "oci_containerengine_cluster_option" "this" {
  cluster_option_id = "all"
  compartment_id    = var.compartment_ocid
}

locals {
  requested_version = "v${trimprefix(var.kubernetes_version, "v")}"

  # An exact request matches itself; a minor request matches its patches.
  # The trailing dot keeps "v1.3" from matching "v1.36.1".
  candidate_versions = [
    for version in data.oci_containerengine_cluster_option.this.kubernetes_versions : version
    if version == local.requested_version || startswith(version, "${local.requested_version}.")
  ]

  # Rank numerically, not lexically: "v1.34.10" must sort above "v1.34.9".
  version_by_rank = {
    for version in local.candidate_versions :
    join(".", [for part in split(".", trimprefix(version, "v")) : format("%04d", tonumber(part))]) => version
  }

  # null rather than an error when nothing matches: the cluster's precondition
  # reports that case with the list of versions OKE actually offers.
  kubernetes_version = try(local.version_by_rank[reverse(sort(keys(local.version_by_rank)))[0]], null)
}

# Worker image for the resolved version: newest x86_64 Oracle Linux 8 build.
# Image names embed the version and a build date, so sorting by name yields
# the newest build of a given OKE version.
data "oci_containerengine_node_pool_option" "this" {
  node_pool_option_id = "all"
  compartment_id      = var.compartment_ocid
}

locals {
  version_pattern = replace(trimprefix(coalesce(local.kubernetes_version, "none"), "v"), ".", "\\.")

  node_image_candidates = [
    for source in data.oci_containerengine_node_pool_option.this.sources : source
    if can(regex("Oracle-Linux-8\\.", source.source_name))
    && can(regex("OKE-${local.version_pattern}-", source.source_name))
    && !can(regex("aarch64|GPU", source.source_name))
  ]

  node_image_name = try(
    reverse(sort([for source in local.node_image_candidates : source.source_name]))[0],
    null,
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
  kubernetes_version = local.kubernetes_version
  node_shape         = var.node_shape
  freeform_tags      = local.tags

  lifecycle {
    precondition {
      condition     = local.node_image_id != null
      error_message = "No Oracle Linux 8 x86_64 worker image found for OKE ${coalesce(local.kubernetes_version, var.kubernetes_version)}. OKE publishes node images a while after it starts offering a version; pin kubernetes_version to an older one until the image ships."
    }
  }

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
