# The Portainer server's own settings, as far as onboarding needs them.
#
# Two of these are prerequisites rather than preferences: Edge compute has to
# be enabled before an Edge environment can be registered, and the Edge
# Portainer URL is what the server tells agents (and the UI's deployment
# commands) to come back to. The rest are the defaults a lab wants on a fresh
# install. A third prerequisite, the tunnel server address, is not something
# this resource can carry — it is written below.
#
# This is a singleton: Portainer's settings API replaces the whole object, so
# whatever is not set here goes back to its zero value. That is fine for a
# server this stack installs and owns, and it is why var.settings.enabled
# exists — turn it off in an environment where Portainer's settings (SSO, for
# one) are managed somewhere else, and set the prerequisites by hand — all
# three of them, because the write below is gated on the same switch.
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

# --- The tunnel server address -----------------------------------------------
# Business Edition keeps the Edge tunnel address as a setting of its own,
# Edge.TunnelServerAddress, instead of deriving it from the Edge Portainer URL
# the way Community Edition does. Left empty — which is how a freshly
# installed server comes up, whatever --tunnel-addr says
# (portainer/portainer#12744) — registering an Edge environment does not
# degrade, it fails:
#
#   Error: failed to create environment: [POST /endpoints][500]
#   {"message":"Tunnel server address not set in Edge Compute settings"}
#
# The provider cannot set it. Its portainer_settings resource sends no Edge
# object at all (v1.34.3), and portainer_environment sends no
# EdgeTunnelServerAddress form field, which is the only other place the API
# takes one. So this stack writes that one field itself, over the same API and
# with the same credentials the provider reads out of the environment —
# PORTAINER_API_KEY, or PORTAINER_USER + PORTAINER_PASSWORD.
#
# The request carries nothing but the field: Portainer's settings payload is
# all optional members, so an omitted one is left alone rather than zeroed —
# which is also why portainer_settings above, sending no Edge object, does not
# undo this. The lifecycle block re-asserts it anyway whenever that resource
# is planned to change, because being wrong about that is one 500 in a later
# apply and no other symptom.
#
# Requires curl on the machine running Terraform. In CI that is the runner
# image; locally it is the same shell that holds the credentials.
resource "terraform_data" "edge_tunnel_address" {
  count = local.settings_enabled && local.edge_tunnel_address != null ? 1 : 0

  triggers_replace = {
    endpoint = local.portainer_url
    address  = local.edge_tunnel_address
  }

  provisioner "local-exec" {
    quiet = true

    # The address travels as an environment variable rather than inline in the
    # script, so a host name is never a shell quoting problem. The credentials
    # are not passed at all: they are inherited from the Terraform process,
    # the same environment the provider reads them from.
    environment = {
      PORTAINER_ENDPOINT = local.portainer_url
      TUNNEL_ADDRESS     = local.edge_tunnel_address
    }

    command = <<-EOT
      set -eu

      api="$${PORTAINER_ENDPOINT%/}/api"

      if [ -n "$${PORTAINER_API_KEY:-}" ]; then
        auth="X-API-Key: $${PORTAINER_API_KEY}"
      elif [ -n "$${PORTAINER_USER:-}" ] && [ -n "$${PORTAINER_PASSWORD:-}" ]; then
        # A Key Vault password is whatever was put in it, and it is going into
        # a JSON document: the two characters that would end the string early
        # are escaped rather than assumed absent.
        json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

        jwt=$(curl -fsS -X POST "$${api}/auth" \
          -H 'Content-Type: application/json' \
          -d "{\"username\":\"$(json_escape "$${PORTAINER_USER}")\",\"password\":\"$(json_escape "$${PORTAINER_PASSWORD}")\"}" \
          | sed -n 's/.*"jwt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        [ -n "$${jwt}" ] || {
          echo "portainer: authenticating as $${PORTAINER_USER} returned no token" >&2
          exit 1
        }
        auth="Authorization: Bearer $${jwt}"
      else
        echo "portainer: set PORTAINER_API_KEY, or PORTAINER_USER and PORTAINER_PASSWORD" >&2
        exit 1
      fi

      curl -fsS -o /dev/null -X PUT "$${api}/settings" \
        -H "$${auth}" \
        -H 'Content-Type: application/json' \
        -d "{\"edge\":{\"tunnelServerAddress\":\"$${TUNNEL_ADDRESS}\"}}"

      # Read it back. A server that accepts the write and keeps its old value
      # is the failure this exists for, and its only other symptom is a 500 on
      # the next resource.
      curl -fsS "$${api}/settings" -H "$${auth}" | tr -d ' \t\n' \
        | grep -q "\"TunnelServerAddress\":\"$${TUNNEL_ADDRESS}\"" || {
          echo "portainer: server did not keep TunnelServerAddress=$${TUNNEL_ADDRESS}" >&2
          exit 1
        }
    EOT
  }

  lifecycle {
    replace_triggered_by = [portainer_settings.this[0]]
  }

  depends_on = [portainer_settings.this]
}
