locals {
  # The hub is fixed: Argo CD runs on the AKS cluster foundations/azure builds,
  # so "azure" is never a spoke. These are the clouds that can be one.
  spoke_clouds = ["aws", "gcp", "oci"]

  # var.spokes is keyed by cloud, and it is regrouped here for the same reason
  # the tenants stack groups its tenants: a module's providers are static, so
  # each block below is passed its own cluster's kubernetes provider and takes
  # its configuration through for_each rather than through an index.
  spokes_by_cloud = {
    for c in local.spoke_clouds : c => { for k, s in var.spokes : k => s if k == c }
  }

  # A cloud left out of var.spokes is untouched: no foundation state is read,
  # no cluster is contacted and its provider stays inert, so this stack only
  # needs credentials for the clouds actually registered (plus Azure, which
  # hosts both the hub and the state home).
  active = { for c in local.spoke_clouds : c => length(local.spokes_by_cloud[c]) > 0 }

  any_active = length(var.spokes) > 0

  # The hub's state is read for two independent reasons: to register spokes
  # against it, and to plant the root Application on it (root-app.tf). Either
  # one alone is enough — a hub-only environment with no spokes yet still gets
  # its delivery plane.
  hub_needed = local.any_active || var.platform_apps.enabled
}

# Dependency direction: gitops reads foundation outputs, never the reverse —
# the same rule the tenants layer follows, and the reason spoke registration
# is a layer of its own rather than something foundations/aws does to
# foundations/azure. Every foundation keeps its state in the Azure Storage
# state home whatever cloud it provisions, so one azurerm backend serves all
# of them; only the blob key differs, and it is derived rather than configured
# so it cannot drift away from foundations/<cloud>/backend/<env>.hcl.
data "terraform_remote_state" "hub" {
  count = local.hub_needed ? 1 : 0

  backend = "azurerm"
  config = merge(var.state_home, {
    key              = "foundations/azure/${var.environment}.tfstate"
    use_azuread_auth = true
  })
}

data "terraform_remote_state" "spoke" {
  for_each = toset([for c in local.spoke_clouds : c if local.active[c]])

  backend = "azurerm"
  config = merge(var.state_home, {
    key              = "foundations/${each.key}/${var.environment}.tfstate"
    use_azuread_auth = true
  })
}

locals {
  # Empty when nothing is registered, or when the blob is missing / holds no
  # outputs. The module turns either case into one actionable error naming the
  # cloud, the environment and the blob key.
  hub = length(data.terraform_remote_state.hub) > 0 ? try(data.terraform_remote_state.hub[0].outputs, {}) : {}

  foundation = {
    for c in local.spoke_clouds : c => try(data.terraform_remote_state.spoke[c].outputs, {})
  }

  # Wired = there is something to register and something to register it
  # against. Provider and cluster-lookup wiring is gated on this so that a
  # missing foundation surfaces as the module's validation message rather than
  # as a pile of "Unsupported attribute" errors from provider configuration.
  hub_wired = length(local.hub) > 0

  wired = { for c in local.spoke_clouds : c => local.active[c] && length(local.foundation[c]) > 0 }

  # Where an agent dials, and what it has to prove to get in. Read out of the
  # hub's outputs rather than configured here: the host name, the port and the
  # label selector are all decided where the principal is installed
  # (foundations/azure/argocd-agent.tf), and a spoke that disagreed with any of
  # them would simply fail to connect.
  principal = {
    address                = try(local.hub.argocd_agent_address, "")
    port                   = try(local.hub.argocd_agent_port, 8443)
    namespace              = try(local.hub.argocd_agent_namespace, local.argocd_namespace)
    resource_proxy_address = try(local.hub.argocd_agent_resource_proxy_address, "")
    label_selector         = try(local.hub.argocd_agent_label_selector, "")
  }

  # The certificate authority every agent's identity is signed by.
  #
  # Read from the hub cluster at apply time rather than carried through a
  # foundation output, so the private key is published by nothing and lives
  # only where it is used: the hub's Secret, and this stack's state while it
  # signs. The kubernetes provider hands back already-decoded data.
  argocd_agent_ca = {
    cert_pem        = try(data.kubernetes_secret_v1.argocd_agent_ca[0].data["tls.crt"], "")
    private_key_pem = try(data.kubernetes_secret_v1.argocd_agent_ca[0].data["tls.key"], "")
  }
}

# Guarded on there being a spoke to attach at all, so a hub-only environment
# neither reads the Secret nor needs the hub to have a principal.
data "kubernetes_secret_v1" "argocd_agent_ca" {
  count    = local.any_active && local.hub_wired ? 1 : 0
  provider = kubernetes.azure

  metadata {
    name      = try(local.hub.argocd_agent_ca_secret, "argocd-agent-ca")
    namespace = local.principal.namespace
  }
}

# A foundation deployed for a different environment is the other half of the
# same failure mode, and one this stack can only warn about. The hub counts
# here too: registering a prototype spoke with the prod hub would "work".
# A hub without a principal cannot take an agent, and the failure is otherwise
# a connection timeout on the spoke half an hour after a green apply. The
# module's own validation catches it too; this says it once, up front, for the
# whole run.
check "argocd_agent_principal" {
  assert {
    condition     = !local.any_active || !local.hub_wired || try(local.hub.argocd_agent_enabled, false)
    error_message = "The azure foundation for environment ${var.environment} was applied without the argocd-agent principal (enable_argocd_agent = false, or enable_argocd/enable_ingress false), so an agent installed on a spoke would have nothing to connect to. Apply foundations/azure with enable_argocd_agent = true, or empty var.spokes."
  }
}

check "foundation_environment" {
  assert {
    condition = alltrue(concat(
      [try(local.hub.environment, var.environment) == var.environment],
      [for c in local.spoke_clouds : try(local.foundation[c].environment, var.environment) == var.environment],
    ))
    error_message = "A foundation state read by this stack was deployed for a different environment than var.environment (${var.environment}). Check that the foundations were applied with envs/${var.environment}.tfvars and backend/${var.environment}.hcl."
  }
}

# -----------------------------------------------------------------------------
# One module block per spoke cloud. They differ only in which cluster's
# kubernetes and helm providers are the spoke's; the hub alias is the same AKS
# cluster in all of them. Provider configurations cannot be selected per
# for_each instance, which is the one place the cloud has to be enumerated in
# code — exactly as in tenants/main.tf.
# -----------------------------------------------------------------------------
module "spoke_aws" {
  source   = "../modules/argocd-spoke"
  for_each = local.spokes_by_cloud.aws

  providers = {
    kubernetes     = kubernetes.aws
    kubernetes.hub = kubernetes.azure
    helm           = helm.aws
  }

  cloud       = "aws"
  environment = var.environment
  foundation  = local.foundation.aws
  principal   = local.principal
  ca          = local.argocd_agent_ca

  name              = each.value.name
  namespaces        = each.value.namespaces
  cluster_resources = each.value.cluster_resources
  project           = each.value.project
  labels            = each.value.labels

  agent_chart_version  = var.agent_chart_version
  argocd_chart_version = var.spoke_argocd_chart_version
  agent_extra_values   = each.value.agent_values
  argocd_extra_values  = each.value.argocd_values
}

module "spoke_gcp" {
  source   = "../modules/argocd-spoke"
  for_each = local.spokes_by_cloud.gcp

  providers = {
    kubernetes     = kubernetes.gcp
    kubernetes.hub = kubernetes.azure
    helm           = helm.gcp
  }

  cloud       = "gcp"
  environment = var.environment
  foundation  = local.foundation.gcp
  principal   = local.principal
  ca          = local.argocd_agent_ca

  name              = each.value.name
  namespaces        = each.value.namespaces
  cluster_resources = each.value.cluster_resources
  project           = each.value.project
  labels            = each.value.labels

  agent_chart_version  = var.agent_chart_version
  argocd_chart_version = var.spoke_argocd_chart_version
  agent_extra_values   = each.value.agent_values
  argocd_extra_values  = each.value.argocd_values
}

module "spoke_oci" {
  source   = "../modules/argocd-spoke"
  for_each = local.spokes_by_cloud.oci

  providers = {
    kubernetes     = kubernetes.oci
    kubernetes.hub = kubernetes.azure
    helm           = helm.oci
  }

  cloud       = "oci"
  environment = var.environment
  foundation  = local.foundation.oci
  principal   = local.principal
  ca          = local.argocd_agent_ca

  name              = each.value.name
  namespaces        = each.value.namespaces
  cluster_resources = each.value.cluster_resources
  project           = each.value.project
  labels            = each.value.labels

  agent_chart_version  = var.agent_chart_version
  argocd_chart_version = var.spoke_argocd_chart_version
  agent_extra_values   = each.value.agent_values
  argocd_extra_values  = each.value.argocd_values
}
