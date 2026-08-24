# AKS cluster, built from the Azure Verified Module for managed clusters.
#
# What the cluster is for has not changed:
#  - OIDC issuer + Workload Identity (tenant identities federate against it,
#    and so do the platform's own ingress, collector and Kargo identities)
#  - Azure CNI overlay with the Cilium data plane
#  - no managed add-on that reads the vault or serves HTTP: secrets come
#    through External Secrets and ingress through Traefik, the same two
#    components every other cloud runs (eso.tf, ingress.tf)
#
# What has changed is the shape of the defaults. Everything below that is not
# forced by the platform's design is set to what a cluster in a large
# enterprise estate is expected to have — a paid SLA, zone-spread system
# nodes, managed upgrades inside a maintenance window, Entra ID with Azure RBAC
# for human access, Azure Policy actually installed, a locked-down node
# resource group, and the control plane's logs going somewhere. The prototype
# environment opts each of those back down for cost in envs/prototype.tfvars,
# and every opt-down there says what production uses instead.
locals {
  # Defender reports into the Log Analytics workspace, so it can only be on
  # when there is one. var.enable_defender's own validation is what turns
  # asking for it without a workspace into an error rather than a silent
  # no-op; this is the value the module actually reads.
  aks_defender_enabled = var.enable_defender && local.log_analytics_enabled
}

module "aks" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "0.8.1"

  name               = "aks-${local.name}"
  location           = var.location
  parent_id          = module.resource_group.resource_id
  dns_prefix         = local.name
  kubernetes_version = var.kubernetes_version
  enable_telemetry   = var.enable_telemetry
  tags               = local.tags

  # Free has no financially backed API server SLA and no support for cost
  # analysis; Standard is the floor for anything a business depends on, and
  # Premium buys long-term support for a Kubernetes minor beyond its community
  # window.
  sku = {
    name = "Base"
    tier = var.aks_sku_tier
  }

  support_plan = var.aks_sku_tier == "Premium" ? "AKSLongTermSupport" : "KubernetesOfficial"

  # Node auto-provisioning (Karpenter) is on, with none of Azure's default
  # NodePools created: workloads that outgrow the system pool are placed by
  # NodePool objects this platform owns, not by pools invented at cluster
  # creation.
  node_provisioning_profile = {
    default_node_pools = "None"
    mode               = "Auto"
  }

  oidc_issuer_profile = {
    enabled = true
  }

  enable_rbac = true

  # Entra ID with Azure RBAC for Kubernetes authorization: a person's access to
  # this cluster is a role assignment in the directory, revoked by removing
  # them from a group, and nothing in the cluster stores who they are.
  #
  # Turning this on changes which credential AKS hands back: with Entra
  # integration the local cluster-admin certificate moves from kube_config to
  # kube_admin_config. The tenants/ and gitops/ stacks read whichever of the
  # two is populated, so they work either way.
  aad_profile = var.aks_entra_authentication_enabled ? {
    managed                = true
    enable_azure_rbac      = true
    admin_group_object_ids = var.aks_admin_group_object_ids
  } : null

  # Local accounts stay enabled so this stack's own Helm provider can bootstrap
  # the add-ons with the cluster admin certificate — External Secrets has to
  # exist before anything can read the vault, and there is no identity to
  # federate as until the cluster it federates against exists. Set this false
  # once CI reaches the API server as an Entra principal instead; the aad
  # profile above is already the other half of that change.
  disable_local_accounts = !var.aks_local_accounts_enabled

  # Empty (the default) leaves the API server reachable from anywhere, which is
  # what a cluster whose deploys come from hosted CI runners needs. An estate
  # with fixed egress addresses lists them here and the API server stops
  # answering everyone else.
  api_server_access_profile = length(var.aks_authorized_ip_ranges) > 0 ? {
    authorized_ip_ranges = var.aks_authorized_ip_ranges
  } : null

  managed_identities = {
    system_assigned = true
  }

  network_profile = {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_dataplane   = "cilium"
    # Cilium is the data plane *and* the policy engine: without this the
    # cluster runs Cilium with no NetworkPolicy enforcement, and every
    # NetworkPolicy the tenant module writes is silently inert.
    network_policy    = "cilium"
    pod_cidr          = var.pod_cidr
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
  }

  default_agent_pool = {
    name           = "system"
    count_of       = var.system_node_count
    vm_size        = var.system_node_vm_size
    vnet_subnet_id = local.aks_subnet_id
    os_sku         = var.system_node_os_sku

    # Empty means "wherever the region puts it", which is the only option in a
    # region without zones and the only affordable one on a single node.
    availability_zones = var.system_node_availability_zones

    # Ephemeral OS disks are faster and cost nothing extra, but they need a VM
    # size with a local disk to put them on — which the default size does not
    # have. "Managed" is the answer that works on every size.
    os_disk_type = var.system_node_os_disk_type

    enable_encryption_at_host = var.system_node_encryption_at_host_enabled

    upgrade_settings = {
      max_surge = "33%"
    }
  }

  # Patch upgrades and node images are applied by Azure rather than by an
  # apply, so a cluster that nobody has touched for a month is still on a
  # supported patch. "patch" tracks the current minor; moving minor versions
  # stays a deliberate change to var.kubernetes_version.
  auto_upgrade_profile = {
    upgrade_channel         = var.aks_upgrade_channel
    node_os_upgrade_channel = var.aks_node_os_upgrade_channel
  }

  # ...and both of them only inside these windows, so an unattended upgrade
  # never lands in the middle of a business day.
  maintenanceconfiguration = {
    auto-upgrade = {
      name = "aksManagedAutoUpgradeSchedule"
      maintenance_window = {
        duration_hours = var.aks_maintenance_window.duration_hours
        start_time     = var.aks_maintenance_window.start_time
        utc_offset     = var.aks_maintenance_window.utc_offset
        schedule = {
          weekly = {
            day_of_week    = var.aks_maintenance_window.day_of_week
            interval_weeks = 1
          }
        }
      }
    }
    node-os-upgrade = {
      name = "aksManagedNodeOSUpgradeSchedule"
      maintenance_window = {
        duration_hours = var.aks_maintenance_window.duration_hours
        start_time     = var.aks_maintenance_window.start_time
        utc_offset     = var.aks_maintenance_window.utc_offset
        schedule = {
          daily = {
            interval_days = 1
          }
        }
      }
    }
  }

  # The add-on is what makes policy.tf's assignment do anything: without
  # Gatekeeper in the cluster the initiative is assigned and reports nothing.
  addon_profile_azure_policy = {
    enabled = var.aks_azure_policy_enabled
  }

  security_profile = {
    workload_identity = {
      enabled = true
    }
    # Removes unreferenced images from the nodes on a schedule. A node that has
    # pulled a year of image tags is a year of unpatched userland sitting on
    # disk.
    image_cleaner = {
      enabled        = true
      interval_hours = var.aks_image_cleaner_interval_hours
    }
    # Defender for Containers: runtime threat detection, reported into the same
    # workspace as the control-plane logs. Priced per vCPU, which is why it is
    # a switch rather than always-on.
    defender = local.aks_defender_enabled ? {
      log_analytics_workspace_resource_id = local.log_analytics_workspace_id
      security_monitoring = {
        enabled = true
      }
    } : null
  }

  # Namespace-level cost attribution in the portal. The API rejects the whole
  # profile on a Free cluster rather than ignoring it, so it follows the SKU
  # instead of being its own switch.
  metrics_profile = var.aks_sku_tier == "Free" ? null : {
    cost_analysis = {
      enabled = true
    }
  }

  storage_profile = {
    disk_csi_driver = {
      enabled = true
    }
    file_csi_driver = {
      enabled = true
    }
    snapshot_controller = {
      enabled = true
    }
    blob_csi_driver = {
      enabled = false
    }
  }

  # The node resource group is Azure's, not an operator's: locking it read-only
  # stops a well-meant edit to a load balancer rule or a scale set from being
  # reverted — or worse, kept — by the cluster's own reconciler.
  node_resource_group_profile = {
    restriction_level = var.aks_node_resource_group_restriction_level
  }

  diagnostic_settings = local.aks_diagnostic_settings
}
