locals {
  # Azure is the hub, and is therefore always read; the rest are candidate
  # spokes.
  spoke_clouds = ["aws", "gcp", "oci"]
  clouds       = concat(["azure"], local.spoke_clouds)

  # Clouds nobody puts a spoke on are left completely alone: no foundation
  # state is read, no cluster is contacted and their providers stay inert, so
  # this stack only needs credentials for the clouds actually in use (plus
  # Azure, which hosts both the state home and the hub).
  active = merge(
    { azure = true },
    { for c in local.spoke_clouds : c => contains(keys(var.spokes), c) },
  )
}

# Dependency direction: gitops reads foundation outputs, never the reverse —
# the same one-way arrow the tenants stack follows. Every foundation keeps its
# state in the Azure Storage state home whatever cloud it provisions, so one
# azurerm backend serves all four; only the blob key differs, and it is derived
# rather than configured so that it cannot drift away from
# foundations/<cloud>/backend/<env>.hcl.
data "terraform_remote_state" "foundation" {
  for_each = toset([for c in local.clouds : c if local.active[c]])

  backend = "azurerm"
  config = merge(var.state_home, {
    key              = "foundations/${each.key}/${var.environment}.tfstate"
    use_azuread_auth = true
  })
}

locals {
  # Keyed by cloud, always complete: inactive clouds map to {}. An *active*
  # cloud mapping to {} means its foundation state blob is missing or holds no
  # outputs.
  foundation = {
    for c in local.clouds : c => try(data.terraform_remote_state.foundation[c].outputs, {})
  }

  # Wired = there is something to deploy and something to deploy it against.
  wired = { for c in local.clouds : c => local.active[c] && length(local.foundation[c]) > 0 }
}

# The hub is not optional: without the Azure foundation there is nothing for
# the agents to connect to, and every certificate below is issued for names
# that come out of its state.
check "hub_foundation" {
  assert {
    condition     = local.wired.azure
    error_message = "The Azure foundation state for environment ${var.environment} is missing or empty. Deploy foundations/azure first — it is the hub this stack hangs everything off."
  }
}

# A foundation deployed for a different environment is the other half of the
# same failure mode, and one this stack can only warn about.
check "foundation_environment" {
  assert {
    condition = alltrue([
      for c in local.clouds : try(local.foundation[c].environment, var.environment) == var.environment
    ])
    error_message = "A foundation state read by this stack was deployed for a different environment than var.environment (${var.environment}). Check that the foundations were applied with envs/${var.environment}.tfvars and backend/${var.environment}.hcl."
  }
}

locals {
  # One agent per spoke. The name is the agent's identity everywhere it
  # matters: the CN of its client certificate, the name of its cluster in the
  # hub's Argo CD, and the value an Application sets as spec.destination.name.
  agents = {
    for cloud, spoke in var.spokes : cloud => {
      name               = coalesce(spoke.agent_name, "${cloud}-${var.environment}")
      mode               = spoke.mode
      install_argocd     = spoke.install_argocd
      log_level          = spoke.log_level
      heartbeat_interval = spoke.heartbeat_interval
      argocd_values      = spoke.argocd_values
    } if local.wired[cloud]
  }

  # AKS turns this label into "<label>.<region>.cloudapp.azure.com". The
  # default is derived from the cluster name because the label has to be unique
  # within the region across all of Azure, and because it must be known before
  # the load balancer exists — it goes into the principal's certificate and
  # into every agent's configuration.
  principal_dns_label = coalesce(
    var.principal_dns_label,
    "argocd-agent-${try(local.foundation.azure.cluster_name, var.environment)}",
  )

  principal_fqdn    = "${local.principal_dns_label}.${try(local.foundation.azure.location, "unknown")}.cloudapp.azure.com"
  principal_address = coalesce(var.principal_address, local.principal_fqdn)

  hub_labels = {
    "app.kubernetes.io/part-of"    = "argocd-agent"
    "app.kubernetes.io/managed-by" = "terraform"
  }

  # The hub's argocd-server reads application state through the principal's
  # redis proxy rather than straight from redis: keys that belong to an agent
  # are answered from that agent's cache, over the connection the agent
  # already holds open. Without it the UI can show a spoke application's sync
  # status but not its resources.
  #
  # It has to be set through the extension because the extension owns
  # argocd-cmd-params-cm and reverts direct edits to it.
  hub_extension_required_settings = {
    "configs.params.redis\\.server" = "argocd-agent-redis-proxy:6379"
  }
}

# -----------------------------------------------------------------------------
# One module block per spoke. They differ only in which cluster's kubernetes
# and helm providers they get: provider configurations cannot be selected per
# for_each instance, so the per-cloud split has to happen here rather than
# inside the module. Everything else about a spoke is cloud-agnostic — an agent
# does not care what kind of cluster it runs on.
# -----------------------------------------------------------------------------
module "spoke_aws" {
  source   = "../modules/argocd-spoke"
  for_each = { for c, a in local.agents : c => a if c == "aws" }

  providers = {
    kubernetes = kubernetes.aws
    helm       = helm.aws
  }

  agent_name                = each.value.name
  namespace                 = var.spoke_namespace
  agent_mode                = each.value.mode
  destination_based_mapping = var.destination_based_mapping
  log_level                 = each.value.log_level
  heartbeat_interval        = each.value.heartbeat_interval

  principal_address = local.principal_address
  principal_port    = var.principal_port

  ca_cert_pem     = tls_self_signed_cert.ca.cert_pem
  client_cert_pem = tls_locally_signed_cert.agent[each.key].cert_pem
  client_key_pem  = tls_private_key.agent[each.key].private_key_pem

  install_argocd         = each.value.install_argocd
  argocd_chart_version   = var.argocd_chart_version
  argocd_values          = each.value.argocd_values
  agent_chart_version    = var.agent_chart_version
  agent_image_repository = var.agent_image_repository
  agent_image_tag        = var.agent_image_tag
  live_resources_rbac    = var.live_resources_rbac

  # An agent is only let in once the hub knows its name, so register first and
  # start the agent second. Not strictly required — the agent retries — but it
  # keeps the first apply from logging a round of rejected connections.
  depends_on = [kubernetes_secret_v1.cluster]
}

module "spoke_gcp" {
  source   = "../modules/argocd-spoke"
  for_each = { for c, a in local.agents : c => a if c == "gcp" }

  providers = {
    kubernetes = kubernetes.gcp
    helm       = helm.gcp
  }

  agent_name                = each.value.name
  namespace                 = var.spoke_namespace
  agent_mode                = each.value.mode
  destination_based_mapping = var.destination_based_mapping
  log_level                 = each.value.log_level
  heartbeat_interval        = each.value.heartbeat_interval

  principal_address = local.principal_address
  principal_port    = var.principal_port

  ca_cert_pem     = tls_self_signed_cert.ca.cert_pem
  client_cert_pem = tls_locally_signed_cert.agent[each.key].cert_pem
  client_key_pem  = tls_private_key.agent[each.key].private_key_pem

  install_argocd         = each.value.install_argocd
  argocd_chart_version   = var.argocd_chart_version
  argocd_values          = each.value.argocd_values
  agent_chart_version    = var.agent_chart_version
  agent_image_repository = var.agent_image_repository
  agent_image_tag        = var.agent_image_tag
  live_resources_rbac    = var.live_resources_rbac

  # An agent is only let in once the hub knows its name, so register first and
  # start the agent second. Not strictly required — the agent retries — but it
  # keeps the first apply from logging a round of rejected connections.
  depends_on = [kubernetes_secret_v1.cluster]
}

module "spoke_oci" {
  source   = "../modules/argocd-spoke"
  for_each = { for c, a in local.agents : c => a if c == "oci" }

  providers = {
    kubernetes = kubernetes.oci
    helm       = helm.oci
  }

  agent_name                = each.value.name
  namespace                 = var.spoke_namespace
  agent_mode                = each.value.mode
  destination_based_mapping = var.destination_based_mapping
  log_level                 = each.value.log_level
  heartbeat_interval        = each.value.heartbeat_interval

  principal_address = local.principal_address
  principal_port    = var.principal_port

  ca_cert_pem     = tls_self_signed_cert.ca.cert_pem
  client_cert_pem = tls_locally_signed_cert.agent[each.key].cert_pem
  client_key_pem  = tls_private_key.agent[each.key].private_key_pem

  install_argocd         = each.value.install_argocd
  argocd_chart_version   = var.argocd_chart_version
  argocd_values          = each.value.argocd_values
  agent_chart_version    = var.agent_chart_version
  agent_image_repository = var.agent_image_repository
  agent_image_tag        = var.agent_image_tag
  live_resources_rbac    = var.live_resources_rbac

  # An agent is only let in once the hub knows its name, so register first and
  # start the agent second. Not strictly required — the agent retries — but it
  # keeps the first apply from logging a round of rejected connections.
  depends_on = [kubernetes_secret_v1.cluster]
}
