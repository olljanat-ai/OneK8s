# The Portainer server's own settings, as far as onboarding needs them.
#
# Two of these are prerequisites rather than preferences: Edge compute has to
# be enabled before an Edge environment can be registered, and the Edge
# Portainer URL is what the server tells agents (and the UI's deployment
# commands) to come back to. The rest are the defaults a lab wants on a fresh
# install.
#
# This is a singleton: Portainer's settings API replaces the whole object, so
# whatever is not set here goes back to its zero value. That is fine for a
# server this stack installs and owns, and it is why var.settings.enabled
# exists — turn it off in an environment where Portainer's settings (SSO, for
# one) are managed somewhere else, and set the two prerequisites by hand.
resource "portainer_settings" "this" {
  count = local.settings_enabled ? 1 : 0

  # 1 = Portainer's internal user database. The admin account the foundation
  # bootstraps from Key Vault is the one this stack authenticates as.
  authentication_method = var.settings.authentication_method

  enable_edge_compute_features = var.settings.enable_edge_compute_features
  edge_portainer_url           = local.portainer_url
  edge_agent_checkin_interval  = var.settings.edge_agent_checkin_interval

  enable_telemetry = var.settings.enable_telemetry
}
