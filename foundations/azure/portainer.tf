# Portainer Business Edition, the platform's fleet console.
#
# One server, on the same AKS cluster that runs the Argo CD hub, managing all
# four clouds: this cluster directly (the chart's own cluster-admin
# ServiceAccount) and EKS, GKE and OKE through Edge Agents that the portainer/
# stack registers and installs. Argo CD is how the platform *deploys*;
# Portainer is how an operator *looks at* what is deployed, on every cloud,
# without four kubeconfigs.
#
#   portainer.onek8s.lol:443  --(Traefik, wildcard TLS)--> portainer:9000
#   portainer.onek8s.lol:8000 --(Traefik TCP entrypoint)--> portainer:8000
#                                                           (edge tunnel)
#
# Both hops land on the same load balancer, so the environment has one host
# name and one A record. Port 8000 matters because of how an Edge Agent is
# addressed: Portainer derives the tunnel address from the *host of its own
# URL* and its tunnel port, so an agent told to poll https://portainer.onek8s.lol
# tunnels back to portainer.onek8s.lol:8000 and nowhere else.
#
# The Business Edition licence is not typed into the UI: it is read from this
# environment's Key Vault and passed to the server as --license-key, so a
# cluster rebuild comes up licensed.
locals {
  portainer_namespace = "portainer"

  # Release name == chart name, so the chart's fullname helper (and every
  # object it names) is just "portainer".
  portainer_service_name = "portainer"

  # The UI, served as plain HTTP behind Traefik — the same arrangement as
  # argocd-server, and for the same reason: TLS terminates once, at the
  # ingress, with the platform wildcard.
  portainer_service_port = 9000

  # The Edge tunnel (chisel). Portainer's own default, and left at the default
  # deliberately: it is baked into every Edge key the server hands out.
  portainer_edge_port       = 8000
  portainer_edge_entrypoint = "portainer-edge"

  # What the entrypoint listens on *inside* the Traefik pod. It cannot be 8000
  # as well: the chart runs the web entrypoint on container port 8000 (exposed
  # as :80), and two entrypoints on one container port make Traefik refuse to
  # start. Only the exposed port has to match Portainer's tunnel port.
  portainer_edge_container_port = 8100

  portainer_url = "https://${var.portainer_hostname}"

  portainer_enabled = var.enable_portainer

  # An environment that publishes the UI at all also publishes the tunnel:
  # an Edge Agent needs both, and the ingress is what carries them.
  portainer_edge_published = local.portainer_enabled && var.enable_ingress
}

# --- Licence -----------------------------------------------------------------
# Read at apply time rather than injected as a variable, so the licence lives
# in exactly one place — this environment's Key Vault — next to the wildcard
# certificate and the tenant secrets. It is a paid entitlement, not an
# infrastructure credential: it grants nothing in this platform, and it does
# end up in the Helm release values (hence in the pod's argv and in this
# stack's state) which is the trade-off for a server that boots licensed with
# nothing to click.
data "azurerm_key_vault_secret" "portainer_license" {
  count = local.portainer_enabled ? 1 : 0

  name         = var.portainer_license_secret_name
  key_vault_id = azurerm_key_vault.this.id

  # The role assignment is what makes this readable at all on a cold apply.
  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}

# --- Namespace ---------------------------------------------------------------
# Created here rather than by the Helm release, because the admin-password
# Secret below and the ingress route that the Traefik release renders into this
# namespace both have to be able to exist before (and independently of) the
# Portainer release itself.
resource "kubernetes_namespace_v1" "portainer" {
  count = local.portainer_enabled ? 1 : 0

  metadata {
    name = local.portainer_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "onek8s"
    }
  }
}

# --- Initial admin account ---------------------------------------------------
# Optional, and off by default: without it Portainer asks for an admin password
# on first load, which is a person at a browser within the setup window. With
# it, the server comes up with the account already created from a Key Vault
# secret — which is also what the portainer/ stack authenticates as when it
# registers the spokes, so a fully unattended install sets this.
resource "kubernetes_secret_v1" "portainer_admin_password" {
  count = local.portainer_enabled && var.portainer_admin_password_secret_name != null ? 1 : 0

  metadata {
    name      = "portainer-admin-password"
    namespace = kubernetes_namespace_v1.portainer[0].metadata[0].name
  }

  # The key name is the chart's: it mounts this into the pod and passes
  # --admin-password-file. Portainer reads it once, at first start; rotating
  # the account afterwards is a Portainer operation, not a Terraform one.
  data = {
    password = data.azurerm_key_vault_secret.portainer_admin_password[0].value
  }

  type = "Opaque"
}

data "azurerm_key_vault_secret" "portainer_admin_password" {
  count = local.portainer_enabled && var.portainer_admin_password_secret_name != null ? 1 : 0

  name         = var.portainer_admin_password_secret_name
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}

# --- The server --------------------------------------------------------------
resource "helm_release" "portainer" {
  count = local.portainer_enabled ? 1 : 0

  name       = local.portainer_service_name
  repository = "https://portainer.github.io/k8s/"
  chart      = "portainer"
  version    = var.portainer_chart_version
  namespace  = kubernetes_namespace_v1.portainer[0].metadata[0].name

  # The Business Edition image is large and the readiness probe waits 45s
  # before its first attempt, which on a small node pool is more than the
  # provider's 5-minute default.
  timeout = 600

  values = [yamlencode(merge({
    # Business Edition: a different image (portainer-ee) whose tag the chart
    # version pins, not a flag on the community one.
    enterpriseEdition = {
      enabled = true
    }

    # ClusterIP, like every other platform service here: the load balancer is
    # Traefik's, and the UI is reached through the Ingress below. The chart's
    # own Ingress stays off for the same reason Argo CD's does — two Ingresses
    # for one host would race, and this one deliberately carries no
    # certificate.
    service = {
      type      = "ClusterIP"
      httpPort  = local.portainer_service_port
      httpsPort = 9443
      edgePort  = local.portainer_edge_port
    }

    ingress = {
      enabled = false
    }

    # HTTP inside the cluster: TLS terminates at Traefik. Portainer does not
    # redirect to HTTPS by itself, so unlike argocd-server there is no loop to
    # break here — but it does enforce an Origin check on writes, which is
    # what trusted_origins answers for a server that only ever sees requests
    # forwarded by a proxy. Without it every POST from the UI is rejected.
    tls = {
      force = false
    }

    trusted_origins = {
      enabled = true
      domains = var.portainer_hostname
    }

    # Portainer keeps its database on disk (users, environments, Edge keys),
    # so this is the one platform component in this stack that is stateful.
    #
    # The claim is the chart's, which means it is part of the release: a Helm
    # uninstall would take it, and with the default StorageClass — Delete
    # reclaim policy — the managed disk behind it. That is not a hypothetical
    # here. Terraform uninstalls this release whenever it replaces it: a flip
    # of enable_portainer to false and back, a change to a ForceNew argument
    # (name, namespace, chart, repository), or an install that failed once and
    # left the resource tainted. Every one of those is an ordinary apply, and
    # each would silently discard every environment and Edge key on the
    # server.
    #
    # So the claim opts out of the release's lifecycle. Uninstall leaves it
    # (and its PersistentVolume) alone; a reinstall under the same release
    # name and namespace adopts it back — same name, and the ownership
    # metadata Helm wrote on it still matches — and the server comes up on the
    # database it had. Deleting the data is then a deliberate `kubectl delete
    # pvc portainer -n portainer`, which is the right amount of friction for
    # the one volume in this platform that cannot be rebuilt from Git.
    persistence = {
      enabled      = true
      size         = var.portainer_storage_size
      storageClass = var.portainer_storage_class

      annotations = {
        "helm.sh/resource-policy" = "keep"
      }
    }

    resources = var.portainer_resources

    # "feature.flags" is the chart's passthrough for server arguments. The
    # licence is applied at boot: the alternative is the licence screen on
    # first load, i.e. a person, once per rebuild.
    feature = {
      flags = concat(
        ["--license-key=${data.azurerm_key_vault_secret.portainer_license[0].value}"],
        var.portainer_extra_flags,
      )
    }
    },
    var.portainer_admin_password_secret_name != null ? {
      adminPassword = {
        existingSecret = kubernetes_secret_v1.portainer_admin_password[0].metadata[0].name
      }
    } : {},
  ))]

  # The chart's ServiceAccount is bound to cluster-admin: that is how Portainer
  # manages the cluster it runs on, and it is why no Edge Agent is installed
  # here. The other three clouds get one instead (modules/portainer-agent).
  depends_on = [
    kubernetes_namespace_v1.portainer,
    kubernetes_secret_v1.portainer_admin_password,
  ]
}

# --- Ingress -----------------------------------------------------------------
# The UI. Same shape as the Argo CD Ingress: a host, a backend, no TLS section
# — the default TLSStore serves the wildcard — and the class named only
# because a Terraform-managed Ingress that omits it would see the API server's
# default-class mutation as drift on every plan.
resource "kubernetes_ingress_v1" "portainer" {
  count = local.portainer_enabled ? 1 : 0

  metadata {
    name      = "portainer"
    namespace = kubernetes_namespace_v1.portainer[0].metadata[0].name
  }

  spec {
    ingress_class_name = var.enable_ingress ? local.ingress_class_name : null

    rule {
      host = var.portainer_hostname

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = local.portainer_service_name
              port {
                number = local.portainer_service_port
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.portainer]
}

# --- The Edge tunnel, on the ingress load balancer ---------------------------
# Consumed by module "ingress" in ingress.tf. Two pieces, both rendered with
# the Traefik release:
#
#   * an extra entrypoint, which is what opens :8000 on the ingress Service
#     (and therefore on the cloud load balancer), and
#   * an IngressRouteTCP that hands everything arriving there to Portainer.
#
# The route carries its own namespace so Helm applies it *into* the Portainer
# namespace, next to the Service it names. That keeps the reference
# same-namespace: Traefik would otherwise need allowCrossNamespace, which
# would also let any tenant's IngressRoute reach into any other namespace —
# exactly the isolation this platform enforces everywhere else.
#
# The tunnel is a chisel (SSH-over-websocket) listener and is meant to be
# public: an agent authenticates with its Edge key and pins the server's
# fingerprint, both of which come from the key the portainer/ stack hands it.
locals {
  portainer_ingress_ports = local.portainer_edge_published ? {
    (local.portainer_edge_entrypoint) = {
      port        = local.portainer_edge_container_port
      exposedPort = local.portainer_edge_port
      expose      = { default = true }
      protocol    = "TCP"
    }
  } : {}

  portainer_ingress_objects = local.portainer_edge_published ? [{
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRouteTCP"
    metadata = {
      name      = "portainer-edge"
      namespace = local.portainer_namespace
    }
    spec = {
      entryPoints = [local.portainer_edge_entrypoint]
      routes = [{
        # Not TLS, so there is no SNI to match on and nothing else shares the
        # entrypoint: everything that reaches :8000 is tunnel traffic.
        match = "HostSNI(`*`)"
        services = [{
          name = local.portainer_service_name
          port = local.portainer_edge_port
        }]
      }]
    }
  }] : []
}
