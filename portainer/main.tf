locals {
  # The hub is fixed: Portainer runs on the AKS cluster foundations/azure
  # builds, and it manages that cluster directly through the ServiceAccount the
  # Portainer chart binds to cluster-admin. So "azure" never needs an agent.
  # These are the clouds that do.
  agent_clouds = ["aws"] // , "gcp", "oci"]

  # var.agents is keyed by cloud, and regrouped here for the same reason the
  # gitops stack regroups its spokes: a module's providers are static, so each
  # module block below is passed its own cluster's kubernetes provider and
  # takes its configuration through for_each rather than through an index.
  agents_by_cloud = {
    for c in local.agent_clouds : c => { for k, a in var.agents : k => a if k == c }
  }

  # A cloud left out of var.agents is untouched: no foundation state is read,
  # no cluster is contacted and its provider stays inert, so a run needs
  # credentials only for the clouds actually listed (plus Azure, which hosts
  # both the server and the state home).
  active = { for c in local.agent_clouds : c => length(local.agents_by_cloud[c]) > 0 }

  any_active = length(var.agents) > 0

  # The hub's state is read for two independent reasons: to know where
  # Portainer is (every agent polls that URL, and the provider talks to it),
  # and to manage the server's own settings. Either alone is enough.
  hub_needed = local.any_active || var.settings.enabled
}

# Dependency direction: portainer reads foundation outputs, never the reverse —
# the same rule the tenants and gitops layers follow. Every foundation keeps
# its state in the Azure Storage state home whatever cloud it provisions, so
# one azurerm backend serves all of them; only the blob key differs, and it is
# derived rather than configured so it cannot drift away from
# foundations/<cloud>/backend/<env>.hcl.
data "terraform_remote_state" "hub" {
  count = local.hub_needed ? 1 : 0

  backend = "azurerm"
  config = merge(var.state_home, {
    key              = "foundations/azure/${var.environment}.tfstate"
    use_azuread_auth = true
  })
}

data "terraform_remote_state" "agent" {
  for_each = toset([for c in local.agent_clouds : c if local.active[c]])

  backend = "azurerm"
  config = merge(var.state_home, {
    key              = "foundations/${each.key}/${var.environment}.tfstate"
    use_azuread_auth = true
  })
}

locals {
  # Empty when the blob is missing or holds no outputs, which is "the
  # foundation has not been applied for this environment yet" rather than an
  # error — the checks below name it.
  hub = length(data.terraform_remote_state.hub) > 0 ? try(data.terraform_remote_state.hub[0].outputs, {}) : {}

  foundation = {
    for c in local.agent_clouds : c => try(data.terraform_remote_state.agent[c].outputs, {})
  }

  # Null when foundations/azure was applied with enable_portainer = false, and
  # the reason everything here is gated on it: without a server there is
  # nothing to register an environment with, and the agents would poll an
  # address that answers nothing.
  portainer_url = try(local.hub.portainer_url, null)

  hub_wired = length(local.hub) > 0 && local.portainer_url != null

  wired = {
    for c in local.agent_clouds : c => local.active[c] && local.hub_wired && length(local.foundation[c]) > 0
  }

  # What is actually installed this run: an agent per cloud whose foundation
  # and hub are both present.
  agents = {
    for c in local.agent_clouds : c => { for k, a in local.agents_by_cloud[c] : k => a if local.wired[c] }
  }

  settings_enabled = var.settings.enabled && local.hub_wired
}

# A foundation deployed for a different environment is a failure mode this
# stack can only warn about — registering a prototype cluster with the prod
# Portainer would "work". The hub counts here too.
check "foundation_environment" {
  assert {
    condition = alltrue(concat(
      [try(local.hub.environment, var.environment) == var.environment],
      [for c in local.agent_clouds : try(local.foundation[c].environment, var.environment) == var.environment],
    ))
    error_message = "A foundation state read by this stack was deployed for a different environment than var.environment (${var.environment}). Check that the foundations were applied with envs/${var.environment}.tfvars and backend/${var.environment}.hcl."
  }
}

# The other half: something to register, but nothing to register it with.
check "portainer_server" {
  assert {
    condition     = !local.any_active || local.hub_wired
    error_message = "var.agents lists clusters to onboard, but the hub has no Portainer server: foundations/azure for environment ${var.environment} either has not been applied (state key foundations/azure/${var.environment}.tfstate) or was applied with enable_portainer = false. Nothing is registered until it has one."
  }
}

# And the tunnel, which is what makes an environment browsable rather than
# merely connected. It is published by the hub's ingress, so an environment
# with enable_ingress = false gets Edge Agents that check in and little else.
check "portainer_edge_tunnel" {
  assert {
    condition     = !local.any_active || !local.hub_wired || try(local.hub.portainer_edge_tunnel, null) != null
    error_message = "The hub's Portainer publishes no Edge tunnel (foundations/azure applied with enable_ingress = false). The agents installed here will register and report in, but Portainer cannot open an environment without the tunnel on port 8000."
  }
}

# -----------------------------------------------------------------------------
# The hub side: one Portainer environment per cluster, created through the
# server's API.
#
# Creating it is what generates the Edge key — a base64 blob holding the
# Portainer URL, the tunnel address, the tunnel server's fingerprint and the
# environment's own ID — which is the entire credential the agent then
# authenticates with. It cannot be computed here, which is why this stack
# talks to Portainer at all rather than only to Kubernetes.
# -----------------------------------------------------------------------------
resource "portainer_environment" "agent" {
  for_each = merge([for c in local.agent_clouds : local.agents[c]]...)

  name = coalesce(each.value.name, each.key)

  # The URL as the agent will see it. Portainer derives the tunnel address
  # from this host — <host>:8000 — so it has to be the public name, not an
  # in-cluster Service.
  environment_address = local.portainer_url

  # 4 = Edge Agent. Kubernetes edge environments are created as type 4 and
  # Portainer flips them to 7 ("Kubernetes Edge Agent") once the agent has
  # connected and identified itself; the provider expects that and does not
  # report it as drift. Creating one as 7 outright is rejected by the API.
  type = 4

  group_id = each.value.group_id
  tag_ids  = each.value.tag_ids

  # Edge compute has to be on before an environment can be registered against
  # it, and the URL the UI shows for edge deployments comes from the same
  # settings object.
  depends_on = [portainer_settings.this]
}

# -----------------------------------------------------------------------------
# The cluster side: one module block per cloud. They differ only in which
# cluster's kubernetes provider they are given — provider configurations
# cannot be selected per for_each instance, which is the one place the cloud
# has to be enumerated in code, exactly as in tenants/main.tf and
# gitops/main.tf.
# -----------------------------------------------------------------------------
module "agent_aws" {
  source   = "../modules/portainer-agent"
  for_each = local.agents.aws

  providers = {
    kubernetes = kubernetes.aws
  }

  cloud       = "aws"
  environment = var.environment

  edge_id  = portainer_environment.agent[each.key].edge_id
  edge_key = portainer_environment.agent[each.key].edge_key

  namespace     = each.value.namespace
  agent_version = each.value.agent_version
  insecure_poll = each.value.insecure_poll
  cluster_role  = each.value.cluster_role
  labels        = each.value.labels
}

/*
module "agent_gcp" {
  source   = "../modules/portainer-agent"
  for_each = local.agents.gcp

  providers = {
    kubernetes = kubernetes.gcp
  }

  cloud       = "gcp"
  environment = var.environment

  edge_id  = portainer_environment.agent[each.key].edge_id
  edge_key = portainer_environment.agent[each.key].edge_key

  namespace     = each.value.namespace
  agent_version = each.value.agent_version
  insecure_poll = each.value.insecure_poll
  cluster_role  = each.value.cluster_role
  labels        = each.value.labels
}

module "agent_oci" {
  source   = "../modules/portainer-agent"
  for_each = local.agents.oci

  providers = {
    kubernetes = kubernetes.oci
  }

  cloud       = "oci"
  environment = var.environment

  edge_id  = portainer_environment.agent[each.key].edge_id
  edge_key = portainer_environment.agent[each.key].edge_key

  namespace     = each.value.namespace
  agent_version = each.value.agent_version
  insecure_poll = each.value.insecure_poll
  cluster_role  = each.value.cluster_role
  labels        = each.value.labels
}
*/
