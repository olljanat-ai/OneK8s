locals {
  name = "${var.name_prefix}-${var.environment}"

  tags = merge(var.freeform_tags, {
    environment = var.environment
    managed-by  = "terraform"
    stack       = "foundations-oci"
  })

  availability_domains = [
    for ad in data.oci_identity_availability_domains.this.availability_domains : ad.name
  ]

  # Subnet plan inside var.vcn_cidr (/16 by default):
  #   .0.0/28   API endpoint (public)
  #   .1.0/24   service load balancers (public)
  #   .16.0/20  worker nodes (private)
  #   .64.0/18  pod IPs — VCN-native pod networking gives every pod a VCN IP,
  #             so this range must be sized for pods, not nodes (private)
  api_cidr     = cidrsubnet(var.vcn_cidr, 12, 0)
  lb_cidr      = cidrsubnet(var.vcn_cidr, 8, 1)
  workers_cidr = cidrsubnet(var.vcn_cidr, 4, 1)
  pods_cidr    = cidrsubnet(var.vcn_cidr, 2, 1)
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

# The regional Object Storage / OCI services CIDR label, used by the service
# gateway so private nodes reach OCI APIs without traversing the NAT gateway.
data "oci_core_services" "all_oci_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "vcn-${local.name}"
  dns_label      = replace(substr("vcn${var.name_prefix}${var.environment}", 0, 15), "-", "")
  freeform_tags  = local.tags
}

# --- Gateways ----------------------------------------------------------------
resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "igw-${local.name}"
  enabled        = true
  freeform_tags  = local.tags
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "nat-${local.name}"
  freeform_tags  = local.tags
}

resource "oci_core_service_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "sgw-${local.name}"
  freeform_tags  = local.tags

  services {
    service_id = data.oci_core_services.all_oci_services.services[0]["id"]
  }
}

# --- Route tables ------------------------------------------------------------
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "rt-${local.name}-public"
  freeform_tags  = local.tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "rt-${local.name}-private"
  freeform_tags  = local.tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
  }

  route_rules {
    destination       = data.oci_core_services.all_oci_services.services[0]["cidr_block"]
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this.id
  }
}

# --- Security lists ----------------------------------------------------------
# Intra-VCN traffic is allowed wholesale; the tenant-facing boundary is
# enforced by Kubernetes NetworkPolicy (Cilium), and the secret boundary by
# OCI IAM. Only the deliberately public ports are opened to the internet.
resource "oci_core_security_list" "api" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "sl-${local.name}-api"
  freeform_tags  = local.tags

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    source      = var.api_allowed_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "6" # TCP
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    source      = var.vcn_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "all"
  }
}

resource "oci_core_security_list" "lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "sl-${local.name}-lb"
  freeform_tags  = local.tags

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6" # TCP
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6" # TCP
    tcp_options {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "sl-${local.name}-private"
  freeform_tags  = local.tags

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    source      = var.vcn_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "all"
  }
}

# --- Subnets -----------------------------------------------------------------
resource "oci_core_subnet" "api" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = local.api_cidr
  display_name               = "snet-${local.name}-api"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.api.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "lb" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = local.lb_cidr
  display_name               = "snet-${local.name}-lb"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.lb.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "workers" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = local.workers_cidr
  display_name               = "snet-${local.name}-workers"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "pods" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = local.pods_cidr
  display_name               = "snet-${local.name}-pods"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.tags
}
